defmodule Mythweaver.Moderation.Fingerprints do
  @moduledoc """
  The signals each account was seen with (`Mythweaver.Moderation.Fingerprint`): client IP, user
  agent, Accept-Language, device cookie and browser fingerprint hash, recorded on login, on every
  connected LiveView mount (`MythweaverWeb.ModerationGate`) and on MCP calls. Rows go a year after
  they were last seen (`prune/1`, daily by `Mythweaver.Moderation.Pruner`).

  IP, device and browser fingerprint link accounts (`linked_accounts/1`) and can be banned; a user
  agent or language is shared by too many people to mean anything on its own.
  """

  import Ecto.Query

  alias Mythweaver.Accounts.User
  alias Mythweaver.Moderation.Fingerprint
  alias Mythweaver.Moderation.GeoIP
  alias Mythweaver.Repo

  @kinds [:ip, :user_agent, :language, :device, :fingerprint]
  @linking_kinds [:ip, :device, :fingerprint]
  @retention_days 365

  @type signals :: %{optional(Fingerprint.kind()) => String.t() | nil}

  @doc "The kinds that link accounts and can be banned."
  @spec linking_kinds() :: [Fingerprint.kind()]
  def linking_kinds, do: @linking_kinds

  @doc "Records every non-nil signal for `user_id`: a new row, or one more sighting of a known one."
  @spec record(Ecto.UUID.t(), signals()) :: :ok
  def record(user_id, signals) when is_binary(user_id) and is_map(signals) do
    now = DateTime.utc_now(:second)

    rows =
      for kind <- @kinds, value = signals[kind], is_binary(value) and value != "" do
        %{
          id: Mythweaver.Schema.generate_id(),
          user_id: user_id,
          kind: kind,
          value: value,
          first_seen_at: now,
          last_seen_at: now,
          seen_count: 1,
          geo: if(kind == :ip, do: GeoIP.lookup(value))
        }
      end

    if rows != [] do
      # A sighting with a GeoIP database refreshes `geo`; one without keeps what was stored.
      Repo.insert_all(Fingerprint, rows,
        on_conflict:
          from(f in Fingerprint,
            update: [
              set: [last_seen_at: ^now, geo: fragment("COALESCE(EXCLUDED.geo, ?)", f.geo)],
              inc: [seen_count: 1]
            ]
          ),
        conflict_target: [:user_id, :kind, :value]
      )
    end

    :ok
  end

  @doc "Every signal `user_id` was seen with, by kind, most recent first."
  @spec for_user(Ecto.UUID.t()) :: [Fingerprint.t()]
  def for_user(user_id) do
    Repo.all(from(f in Fingerprint, where: f.user_id == ^user_id, order_by: [asc: f.kind, desc: f.last_seen_at]))
  end

  @doc "`user_id`'s IPs, devices and browser fingerprints seen in the last `days` (the bannable ones)."
  @spec recent(Ecto.UUID.t(), pos_integer()) :: [Fingerprint.t()]
  def recent(user_id, days \\ 30) do
    since = DateTime.add(DateTime.utc_now(:second), -days, :day)

    Repo.all(
      from(f in Fingerprint,
        where: f.user_id == ^user_id and f.kind in ^@linking_kinds and f.last_seen_at >= ^since,
        order_by: [asc: f.kind, desc: f.last_seen_at]
      )
    )
  end

  @doc "Whether `user_id` was ever seen with `kind` `value` (and the row is still kept)."
  @spec owns_value?(Ecto.UUID.t(), Fingerprint.kind(), String.t()) :: boolean()
  def owns_value?(user_id, kind, value) do
    Repo.exists?(from(f in Fingerprint, where: f.user_id == ^user_id and f.kind == ^kind and f.value == ^value))
  end

  @doc "Every account seen with any of `values` (`{kind, value}`)."
  @spec user_ids_with([{Fingerprint.kind(), String.t()}]) :: [Ecto.UUID.t()]
  def user_ids_with([]), do: []

  def user_ids_with(values) do
    matches =
      Enum.reduce(values, dynamic(false), fn {kind, value}, acc ->
        dynamic([f], ^acc or (f.kind == ^kind and f.value == ^value))
      end)

    Repo.all(from(f in Fingerprint, where: ^matches, distinct: true, select: f.user_id))
  end

  @doc """
  Other accounts seen with any of `user_id`'s IPs, devices or browser fingerprints, each with the
  shared values. A shared device counts ten times a shared IP or browser fingerprint; ties go to the most
  recent shared sighting. At most 50.
  """
  @spec linked_accounts(Ecto.UUID.t()) :: [
          %{
            user: User.t(),
            matches: [
              %{kind: Fingerprint.kind(), value: String.t(), last_seen_at: DateTime.t(), geo: map() | nil}
            ]
          }
        ]
  def linked_accounts(user_id) do
    matches =
      Repo.all(
        from(mine in Fingerprint,
          join: other in Fingerprint,
          on: other.kind == mine.kind and other.value == mine.value and other.user_id != ^user_id,
          where: mine.user_id == ^user_id and mine.kind in ^@linking_kinds,
          select:
            {other.user_id, %{kind: other.kind, value: other.value, last_seen_at: other.last_seen_at, geo: other.geo}}
        )
      )

    ranked =
      matches
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {id, matches} ->
        score = Enum.reduce(matches, 0, fn m, acc -> acc + if(m.kind == :device, do: 10, else: 1) end)
        latest = matches |> Enum.map(& &1.last_seen_at) |> Enum.max(DateTime)
        {id, Enum.sort_by(matches, & &1.last_seen_at, {:desc, DateTime}), score, latest}
      end)
      |> Enum.sort(fn {_, _, s1, l1}, {_, _, s2, l2} ->
        s1 > s2 or (s1 == s2 and DateTime.compare(l1, l2) != :lt)
      end)
      |> Enum.take(50)

    users = Map.new(Repo.all(from(u in User, where: u.id in ^Enum.map(ranked, &elem(&1, 0)))), &{&1.id, &1})

    for {id, matches, _, _} <- ranked, user = users[id], do: %{user: user, matches: matches}
  end

  @doc "Deletes rows last seen more than a year before `now`; the count deleted."
  @spec prune(DateTime.t()) :: non_neg_integer()
  def prune(now \\ DateTime.utc_now(:second)) do
    cutoff = DateTime.add(now, -@retention_days, :day)
    {count, _} = Repo.delete_all(from(f in Fingerprint, where: f.last_seen_at < ^cutoff))
    count
  end
end
