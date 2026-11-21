defmodule Mythweaver.Permissions.Quota do
  @moduledoc """
  Enforces the `quota.*` limits of `Mythweaver.Permissions.Catalog`. Each check is `:ok` or
  `{:error, :quota_exceeded}`, and `:ok` whenever the scope's limit is `:unlimited` (owners always).

    * Spending (`quota.spend_per_day`, in cents) sums `GenerationStat.cost` (the provider's
      reported charge, else the estimate at the model's prices, else nothing) over runs and
      embedding calls on the site's connections finished in the last 24 hours. A run on the user's
      own connection is never limited; one on a model owner's connection through an `:owner_key`
      share counts its tokens against the share's `token_limit_per_day`. A run in flight can
      overshoot.
    * Counts (`quota.characters`, …) count the rows the user owns; callers check only when the new
      row would be the user's own, never a site row.
    * Pending invites (`quota.pending_invites`) count the `:pending` shares and chat invites
      (`Mythweaver.Chats.Member`) the user sent.
    * Upload storage (`quota.upload_bytes`) counts the user's `:ready` uploads; generated images are
      never counted.
  """

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Provider
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.Analytics.GenerationStat
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Chats.Member
  alias Mythweaver.Repo
  alias Mythweaver.Sharing.Share

  @type result :: :ok | {:error, :quota_exceeded}

  @doc """
  Whether `scope` may start another run of `model` for `run_owner` today, charged to the link
  selection would pick now (`Mythweaver.AI.peek_provider_model/2`, then `check_spend/2`). `:ok` when
  no link serves the run: selection fails it with its own error.
  """
  @spec check_spend(Scope.t(), Model.t(), Ecto.UUID.t() | nil) :: result()
  def check_spend(%Scope{} = scope, %Model{} = model, run_owner) do
    case AI.peek_provider_model(model, run_owner) do
      {:ok, link} -> check_spend(scope, link)
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Whether `scope` may start another run on `link` (`:provider` and `:model` loaded) today, by whose
  connection it spends: a site connection counts against `quota.spend_per_day`; the model owner's,
  for a run on a model shared with `scope` in `:owner_key` mode, against that share's
  `token_limit_per_day`; any other (the user's own) is never limited.
  """
  @spec check_spend(Scope.t(), ProviderModel.t()) :: result()
  def check_spend(%Scope{} = scope, %ProviderModel{provider: %Provider{user_id: nil}}) do
    with_limit(scope, "quota.spend_per_day", fn uid, limit ->
      used =
        Repo.one(
          from(s in GenerationStat,
            join: p in Provider,
            on: p.id == s.provider_id,
            where: s.user_id == ^uid and is_nil(p.user_id) and s.finished_at > ago(24, "hour"),
            select: type(coalesce(sum(s.cost), 0), :decimal)
          )
        )

      Decimal.lt?(Decimal.mult(used, 100), limit)
    end)
  end

  def check_spend(%Scope{user: %{id: uid}}, %ProviderModel{
        provider: %Provider{user_id: owner},
        model: %Model{user_id: owner} = model
      })
      when owner != uid do
    limit =
      Repo.one(
        from(s in Share,
          where:
            s.item_type == :ai_model and s.item_id == ^model.id and s.user_id == ^uid and s.status == :accepted and
              s.ai_mode == :owner_key,
          select: s.token_limit_per_day
        )
      )

    if is_nil(limit) or owner_key_tokens(uid, model.id, owner) < limit, do: :ok, else: {:error, :quota_exceeded}
  end

  def check_spend(%Scope{}, %ProviderModel{}), do: :ok

  # `user_id`'s tokens on `model_id` over `owner`'s connections in the last 24 hours.
  defp owner_key_tokens(user_id, model_id, owner) do
    Repo.one(
      from(s in GenerationStat,
        join: p in Provider,
        on: p.id == s.provider_id,
        where: s.user_id == ^user_id and s.ai_model_id == ^model_id and p.user_id == ^owner,
        where: s.finished_at > ago(24, "hour"),
        select: type(coalesce(sum(coalesce(s.prompt_tokens, 0) + coalesce(s.completion_tokens, 0)), 0), :integer)
      )
    )
  end

  @doc "Whether `scope` may own one more `schema` row under limit `key` (catalog mirrors don't count)."
  @spec check_count(Scope.t(), String.t(), module()) :: result()
  def check_count(%Scope{} = scope, key, schema) do
    with_limit(scope, key, fn uid, limit ->
      Repo.aggregate(Mythweaver.Ownership.owned_exactly(schema, uid), :count) < limit
    end)
  end

  @doc "`check_count/3` for a row `scope` creates owned by `owner_id`: a site row (nil) is never limited."
  @spec check_new_row(Scope.t(), Ecto.UUID.t() | nil, String.t(), module()) :: result()
  def check_new_row(_scope, nil, _key, _schema), do: :ok
  def check_new_row(%Scope{} = scope, _owner_id, key, schema), do: check_count(scope, key, schema)

  @doc "Whether `scope` may send one more share or chat invite while its others wait for an answer."
  @spec check_pending_invites(Scope.t()) :: result()
  def check_pending_invites(%Scope{} = scope) do
    with_limit(scope, "quota.pending_invites", fn uid, limit ->
      shares = Repo.aggregate(from(s in Share, where: s.invited_by_id == ^uid and s.status == :pending), :count)
      members = Repo.aggregate(from(m in Member, where: m.invited_by_id == ^uid and m.status == :pending), :count)
      shares + members < limit
    end)
  end

  @doc "Whether `scope` may store `bytes` more."
  @spec check_upload(Scope.t() | nil, non_neg_integer()) :: result()
  def check_upload(nil, _bytes), do: :ok

  def check_upload(%Scope{} = scope, bytes) do
    with_limit(scope, "quota.upload_bytes", fn uid, limit ->
      used =
        Repo.one(
          from(a in Attachment,
            where: a.uploaded_by_id == ^uid and a.status == :ready,
            select: type(coalesce(sum(a.byte_size), 0), :integer)
          )
        )

      used + bytes <= limit
    end)
  end

  defp with_limit(%Scope{user: %{id: uid}} = scope, key, within?) do
    case Scope.limit(scope, key) do
      :unlimited -> :ok
      limit -> if within?.(uid, limit), do: :ok, else: {:error, :quota_exceeded}
    end
  end

  defp with_limit(%Scope{}, _key, _within?), do: :ok
end
