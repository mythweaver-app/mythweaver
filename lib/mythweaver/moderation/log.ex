defmodule Mythweaver.Moderation.Log do
  @moduledoc """
  The moderation log: every moderation action and every look at private content
  (`Mythweaver.Moderation.LogEntry`). Written by the action's own context after it succeeds; read on
  `/moderation/log` with `"moderation.log.view"`.
  """

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Moderation.LogEntry
  alias Mythweaver.Repo

  @doc "Records that `actor` did `action` to `subject_type`/`subject_id`, answerable to `target_user_id`."
  @spec record(Scope.t(), LogEntry.action(), atom() | nil, Ecto.UUID.t() | nil, Ecto.UUID.t() | nil, map()) :: :ok
  def record(%Scope{user: %User{id: actor_id}}, action, subject_type, subject_id, target_user_id, details \\ %{}),
    do: insert(actor_id, action, subject_type, subject_id, target_user_id, details)

  @doc "Records an automatic outcome (no actor): a held item the rules approved, rejected or expired."
  @spec record_system(LogEntry.action(), atom() | nil, Ecto.UUID.t() | nil, Ecto.UUID.t() | nil, map()) :: :ok
  def record_system(action, subject_type, subject_id, target_user_id, details \\ %{}),
    do: insert(nil, action, subject_type, subject_id, target_user_id, details)

  defp insert(actor_id, action, subject_type, subject_id, target_user_id, details) do
    Repo.insert!(%LogEntry{
      actor_id: actor_id,
      action: action,
      subject_type: subject_type,
      subject_id: subject_id,
      target_user_id: target_user_id,
      details: Map.new(details, fn {k, v} -> {to_string(k), v} end)
    })

    :ok
  end

  @doc """
  The newest 200 entries, with `:actor` and `:target_user`; `[]` without `"moderation.log.view"`.
  `opts[:user_id]` keeps entries that account did or that were about it.
  """
  @spec list(Scope.t(), keyword()) :: [LogEntry.t()]
  def list(%Scope{} = scope, opts \\ []) do
    if Scope.can?(scope, "moderation.log.view") do
      LogEntry
      |> filter_user(opts[:user_id])
      |> order_by([e], desc: e.inserted_at, desc: e.id)
      |> limit(200)
      |> preload([:actor, :target_user])
      |> Repo.all()
    else
      []
    end
  end

  defp filter_user(query, nil), do: query
  defp filter_user(query, id), do: where(query, [e], e.actor_id == ^id or e.target_user_id == ^id)
end
