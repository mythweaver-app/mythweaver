defmodule Mythweaver.Accounts.Scope do
  @moduledoc """
  Who a request acts as, assigned as `current_scope` by `MythweaverWeb.UserAuth`.

  It carries the user and the user's effective permissions (`Mythweaver.Permissions.effective/1`),
  computed once when the scope is built: `can?/2` for a flag, `limit/2` for a limit. A user's `role`
  is `:owner` (holds every permission; only another owner can remove an owner) or `:user`. Every
  user sees and acts on only its own chats and those it is a member of (`Chats.authorize/3`). Contexts take the scope as their
  first argument to authorize and filter.

  `initiator_id` is set only on a scope that runs work for a chat's owner on behalf of someone else
  (`Mythweaver.Chats.run_scope/2`: a chat member's reply runs on the owner's models, prompts, lore,
  scripts and quota): the id of the user who asked, whom the jobs it starts are attributed to
  (`initiator_id/1`).
  """

  alias Mythweaver.Accounts.User
  alias Mythweaver.Permissions
  alias Mythweaver.Permissions.Catalog

  defstruct user: nil, permissions: %{}, session_token_id: nil, sudo_until: nil, initiator_id: nil

  @type t :: %__MODULE__{
          user: User.t() | nil,
          permissions: %{String.t() => Permissions.value()},
          session_token_id: Ecto.UUID.t() | nil,
          sudo_until: DateTime.t() | nil,
          initiator_id: Ecto.UUID.t() | nil
        }

  @doc """
  The scope for `user`, with its permissions resolved, or nil when there is no user. `opts`: the
  request's `:session_token_id` and its `:sudo_until` (`Mythweaver.Accounts.enter_sudo/2`).
  """
  def for_user(user, opts \\ [])

  def for_user(%User{} = user, opts) do
    %__MODULE__{
      user: user,
      permissions: Permissions.effective(user),
      session_token_id: opts[:session_token_id],
      sudo_until: opts[:sudo_until]
    }
  end

  def for_user(nil, _opts), do: nil

  @doc "Who the scope's work is attributed to: its `initiator_id`, else its user's id (nil without one)."
  @spec initiator_id(t()) :: Ecto.UUID.t() | nil
  def initiator_id(%__MODULE__{initiator_id: id}) when is_binary(id), do: id
  def initiator_id(%__MODULE__{user: %User{id: id}}), do: id
  def initiator_id(%__MODULE__{}), do: nil

  @doc "Whether the scope's user is an owner."
  def owner?(%__MODULE__{user: %User{role: :owner}}), do: true
  def owner?(_), do: false

  @doc "Whether the scope holds the flag `key` (an owner holds all). Raises for an unknown key."
  @spec can?(t() | nil, String.t()) :: boolean()
  def can?(scope, key) do
    _ = Catalog.flag?(key)

    case scope do
      %__MODULE__{user: %User{role: :owner}} -> true
      %__MODULE__{permissions: permissions} -> Map.get(permissions, key) == true
      nil -> false
    end
  end

  @doc "The scope's limit `key`: a number or `:unlimited` (an owner: always unlimited)."
  @spec limit(t() | nil, String.t()) :: non_neg_integer() | :unlimited
  def limit(scope, key) do
    _ = Catalog.flag?(key)

    case scope do
      %__MODULE__{user: %User{role: :owner}} -> :unlimited
      %__MODULE__{permissions: permissions} -> Map.get(permissions, key, :unlimited)
      nil -> 0
    end
  end

  @doc "`:ok` when the scope holds the flag `key`, else `{:error, :unauthorized}`."
  @spec authorize(t() | nil, String.t()) :: :ok | {:error, :unauthorized}
  def authorize(scope, key), do: if(can?(scope, key), do: :ok, else: {:error, :unauthorized})
end
