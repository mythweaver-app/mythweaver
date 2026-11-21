defmodule Mythweaver.Repo do
  use Ecto.Repo,
    otp_app: :mythweaver,
    adapter: Ecto.Adapters.Postgres

  import Ecto.Query, only: [from: 2]

  @doc "Unwraps `{:ok, value}` inside a transaction, rolling back with `reason` on `{:error, reason}`."
  def ok_or_rollback({:ok, value}), do: value
  def ok_or_rollback({:error, reason}), do: rollback(reason)

  @doc """
  Makes membership rows `existing` match `wanted` (a MapSet of `key` values), inside the caller's
  transaction: deletes the rows whose `key` is not wanted in one query, and inserts `build.(value)`
  (a struct or changeset) for each wanted value not present, rolling back on an invalid one. Kept
  rows are untouched (e.g. `enabled`).
  """
  @spec sync_rows!([struct()], atom(), MapSet.t(), (term() -> struct() | Ecto.Changeset.t())) :: :ok
  def sync_rows!(existing, key, wanted, build) do
    stale = Enum.reject(existing, &MapSet.member?(wanted, Map.fetch!(&1, key)))

    with [%schema{} | _] <- stale,
         do: delete_all(from(r in schema, where: r.id in ^Enum.map(stale, & &1.id)))

    wanted
    |> MapSet.difference(MapSet.new(existing, &Map.fetch!(&1, key)))
    |> Enum.each(&(&1 |> build.() |> insert() |> ok_or_rollback()))

    :ok
  end
end
