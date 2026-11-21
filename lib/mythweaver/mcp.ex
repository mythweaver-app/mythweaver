defmodule Mythweaver.MCP do
  @moduledoc """
  MCP access tokens and the tool catalog the MCP server exposes. The web transport is
  `MythweaverWeb.MCPController`.

  A token acts as its owner: every request re-resolves the owner's permissions
  (`authenticate/2`), so denying `"mcp.use"` stops every token on the next call. A token-built
  scope never holds sudo, so sudo-gated contexts refuse it. Creating a token needs sudo (it is a
  long-lived credential); revoking one does not.

  A non-`:site` token never holds site permissions (the Administration and Moderation catalog
  keys) or the owner role. Each tool call is logged as a `Mythweaver.MCP.Call`
  (`list_calls/2`, pruned by `prune_calls/0`).
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Changes
  alias Mythweaver.MCP.Call
  alias Mythweaver.MCP.Token
  alias Mythweaver.Moderation.Sanctions
  alias Mythweaver.Permissions.Catalog
  alias Mythweaver.Repo

  # Thread-bound (they need an assistant chat), or sudo-only: a long-lived token must never
  # satisfy sudo.
  @excluded ~w(read_tool_result transfer_lore_books transfer_connections transfer_models)

  @prefix "mwp_"
  @touch_after_seconds 60

  @site_keys Catalog.keys_in_categories(["Administration", "Moderation"]) -- ["reports.create"]

  @doc "Whether `scope` may create a `:site` token: the owner, or a holder of any site permission."
  @spec site_access?(Scope.t()) :: boolean()
  def site_access?(%Scope{} = scope), do: Scope.owner?(scope) or Enum.any?(@site_keys, &Scope.can?(scope, &1))

  @doc "The scope's user's tokens, newest first."
  @spec list_tokens(Scope.t()) :: [Token.t()]
  def list_tokens(%Scope{user: user}) do
    Token
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> Repo.all()
  end

  @doc "A changeset for the token form."
  @spec change_token(Token.t(), map()) :: Ecto.Changeset.t()
  def change_token(%Token{} = token, attrs \\ %{}), do: Token.changeset(token, attrs)

  @doc """
  Creates a token for the scope's user and returns its secret, which is shown once and never
  stored. Needs `"mcp.use"` and sudo.
  """
  @spec create_token(Scope.t(), map()) ::
          {:ok, Token.t(), String.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :sudo_required}
  def create_token(%Scope{} = scope, attrs) do
    with :ok <- Scope.authorize(scope, "mcp.use"),
         :ok <- Accounts.authorize_sudo(scope) do
      secret = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      %Token{user_id: scope.user.id, token_hash: hash(secret), hint: String.slice(secret, -4, 4)}
      |> Token.changeset(attrs)
      |> Ecto.Changeset.validate_change(:access, fn :access, v ->
        if v == :site and not site_access?(scope),
          do: [access: dgettext_noop("errors", "needs site administration permissions")],
          else: []
      end)
      |> Repo.insert()
      |> Changes.notify(:accounts)
      |> case do
        {:ok, token} -> {:ok, token, secret}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc "Deletes one of the scope's user's tokens."
  @spec revoke_token(Scope.t(), term()) :: {:ok, Token.t()} | {:error, :not_found}
  def revoke_token(%Scope{user: user}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Token{} = token <- Repo.get_by(Token, id: id, user_id: user.id) do
      token |> Repo.delete() |> Changes.notify(:accounts)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The scope and token for a bearer `secret`. The scope is built fresh (no session, no sudo);
  `{:error, :unauthorized}` when the owner no longer holds `"mcp.use"`, `{:error, :banned}` while
  the account, or the device or network in `signals`, is banned
  (`Mythweaver.Moderation.Sanctions.active_ban/2`).
  """
  @spec authenticate(term(), map()) :: {:ok, Scope.t(), Token.t()} | {:error, :invalid_token | :unauthorized | :banned}
  def authenticate(@prefix <> _ = secret, signals) do
    case Repo.one(from t in Token, where: t.token_hash == ^hash(secret), preload: :user) do
      nil ->
        {:error, :invalid_token}

      token ->
        scope = token.user |> Scope.for_user() |> restrict(token)

        cond do
          Sanctions.active_ban(token.user, signals) -> {:error, :banned}
          Scope.can?(scope, "mcp.use") -> {:ok, scope, touch(token)}
          true -> {:error, :unauthorized}
        end
    end
  end

  def authenticate(_secret, _signals), do: {:error, :invalid_token}

  defp restrict(scope, %Token{access: :site}), do: scope

  defp restrict(scope, _token) do
    %{
      scope
      | user: %{scope.user | role: :user},
        permissions: Map.merge(scope.permissions, Map.new(@site_keys, &{&1, false}))
    }
  end

  defp touch(token) do
    now = DateTime.utc_now(:second)

    if is_nil(token.last_used_at) or
         DateTime.diff(now, token.last_used_at) > @touch_after_seconds do
      Repo.update_all(from(t in Token, where: t.id == ^token.id), set: [last_used_at: now])
      %{token | last_used_at: now}
    else
      token
    end
  end

  @doc "The tools `token` may call: no input or excluded tools, and only reading tools for a read-only token."
  @spec tools(Token.t()) :: [Tool.t()]
  def tools(%Token{access: access}) do
    Enum.filter(Tools.all(), fn tool ->
      tool.kind != :input and tool.name not in @excluded and
        (access in [:full, :site] or tool.kind == :read)
    end)
  end

  @doc "Runs the tool `name` as `scope`, if `token` may call it, and logs the call (unknown tools aren't logged)."
  @spec call_tool(Scope.t(), Token.t(), String.t(), term()) ::
          {:ok, map()} | {:error, map()} | :unknown_tool
  def call_tool(%Scope{} = scope, %Token{} = token, name, args) do
    case Enum.find(tools(token), &(&1.name == name)) do
      nil ->
        :unknown_tool

      tool ->
        result =
          if is_map(args),
            do: Tools.run(scope, tool, args),
            else: {:error, %{"error" => "arguments must be an object"}}

        Repo.insert!(%Call{
          token_id: token.id,
          user_id: scope.user.id,
          tool: tool.name,
          outcome: if(match?({:ok, _}, result), do: :ok, else: :error)
        })

        result
    end
  end

  @call_days 30
  @calls_per_token 20
  @prune_days 90

  @doc "The scope's user's calls with `token_ids` from the last #{@call_days} days, newest first, at most #{@calls_per_token} per token."
  @spec list_calls(Scope.t(), [Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [Call.t()]}
  def list_calls(%Scope{user: user}, token_ids) do
    since = DateTime.add(DateTime.utc_now(:second), -@call_days, :day)

    ranked =
      from(c in Call,
        where: c.user_id == ^user.id and c.token_id in ^token_ids and c.inserted_at >= ^since,
        select: %{
          id: c.id,
          rank: over(row_number(), partition_by: c.token_id, order_by: [desc: c.inserted_at, desc: c.id])
        }
      )

    from(c in Call,
      join: r in subquery(ranked),
      on: r.id == c.id,
      where: r.rank <= @calls_per_token,
      order_by: [desc: c.inserted_at, desc: c.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.token_id)
  end

  @doc "Deletes calls older than #{@prune_days} days; returns how many."
  @spec prune_calls() :: non_neg_integer()
  def prune_calls do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@prune_days, :day)
    {count, _} = Repo.delete_all(from(c in Call, where: c.inserted_at < ^cutoff))
    count
  end

  defp hash(secret), do: :crypto.hash(:sha256, secret)
end
