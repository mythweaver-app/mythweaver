defmodule Mythweaver.Moderation.Store do
  @moduledoc """
  The only place held content lives (`Mythweaver.Moderation.Hold`), with the scans still waiting on a
  webhook callback (`Mythweaver.Moderation.Scan`). Memory only, no DB work: holds die with the
  process, by design.

  `take_hold/1` and `take_scan/1` remove atomically, so whichever caller takes an item (a moderator
  approve, an automatic release, a withdraw, a sweep) is the only one to act on it. `put_hold/1`
  drops the submitter's older hold of the same row first, then enforces `max_hold_bytes`,
  `max_user_holds` and `max_user_hold_bytes` (`Mythweaver.Moderation.config/1`).

  Every minute `sweep/1` removes holds older than `hold_ttl_hours` and scans whose callback
  deadlines passed, and hands them to `Mythweaver.Moderation.Scanner.expired/3` outside this
  process (which the Scanner calls back into): in a task, or in `sweep/1`'s caller when
  `:moderation_in_background` is false.
  """

  use GenServer

  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Hold
  alias Mythweaver.Moderation.Scan
  alias Mythweaver.Moderation.Scanner
  alias Mythweaver.Moderation.TaskSupervisor

  @name {:global, __MODULE__}
  @sweep_ms 60_000

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: @name)

  @doc "Stores `hold`, replacing the submitter's older hold of the same row."
  @spec put_hold(Hold.t()) :: :ok | {:error, :hold_limit}
  def put_hold(%Hold{} = hold), do: GenServer.call(@name, {:put_hold, hold})

  @doc "The hold `id`, or nil."
  @spec get_hold(String.t()) :: Hold.t() | nil
  def get_hold(id), do: GenServer.call(@name, {:get_hold, id})

  @doc "Every hold, oldest first."
  @spec list_holds() :: [Hold.t()]
  def list_holds, do: GenServer.call(@name, :list_holds)

  @doc "`user_id`'s holds, oldest first."
  @spec list_user_holds(Ecto.UUID.t()) :: [Hold.t()]
  def list_user_holds(user_id), do: Enum.filter(list_holds(), &(&1.user_id == user_id))

  @doc "Removes and returns the hold `id`: only its taker acts on it."
  @spec take_hold(String.t()) :: {:ok, Hold.t()} | :error
  def take_hold(id), do: GenServer.call(@name, {:take, :holds, id})

  @doc "Replaces the hold `id` with `fun.(hold)`; `:error` when it is gone."
  @spec update_hold(String.t(), (Hold.t() -> Hold.t())) :: :ok | :error
  def update_hold(id, fun), do: GenServer.call(@name, {:update, :holds, id, fun})

  @doc "Stores a scan waiting on callbacks."
  @spec put_scan(Scan.t()) :: :ok
  def put_scan(%Scan{} = scan), do: GenServer.call(@name, {:put_scan, scan})

  @doc "Removes and returns the waiting scan `id`."
  @spec take_scan(String.t()) :: {:ok, Scan.t()} | :error
  def take_scan(id), do: GenServer.call(@name, {:take, :scans, id})

  @doc "Replaces the waiting scan `id` with `fun.(scan)`; `:error` when it is gone."
  @spec update_scan(String.t(), (Scan.t() -> Scan.t())) :: :ok | :error
  def update_scan(id, fun), do: GenServer.call(@name, {:update, :scans, id, fun})

  @doc "Expires what is overdue at `now_ms` (system time, milliseconds)."
  @spec sweep(integer()) :: :ok
  def sweep(now_ms) do
    {holds, scans} = GenServer.call(@name, {:sweep, now_ms})

    cond do
      holds == [] and scans == [] -> :ok
      Application.get_env(:mythweaver, :moderation_in_background, true) -> expire_later(holds, scans, now_ms)
      true -> Scanner.expired(holds, scans, now_ms)
    end
  end

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{holds: %{}, scans: %{}}}
  end

  @impl true
  def handle_call({:put_hold, hold}, _from, state) do
    holds =
      if hold.target_id,
        do:
          Map.reject(state.holds, fn {_id, h} ->
            h.user_id == hold.user_id and h.kind == hold.kind and h.target_id == hold.target_id
          end),
        else: state.holds

    own = holds |> Map.values() |> Enum.filter(&(&1.user_id == hold.user_id))

    if hold.bytes <= Moderation.config(:max_hold_bytes) and length(own) < Moderation.config(:max_user_holds) and
         Enum.sum_by(own, & &1.bytes) + hold.bytes <= Moderation.config(:max_user_hold_bytes) do
      {:reply, :ok, %{state | holds: Map.put(holds, hold.id, hold)}}
    else
      {:reply, {:error, :hold_limit}, state}
    end
  end

  def handle_call({:get_hold, id}, _from, state), do: {:reply, Map.get(state.holds, id), state}

  def handle_call(:list_holds, _from, state) do
    {:reply, state.holds |> Map.values() |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}),
     state}
  end

  def handle_call({:take, table, id}, _from, state) do
    case Map.pop(Map.fetch!(state, table), id) do
      {nil, _} -> {:reply, :error, state}
      {item, rest} -> {:reply, {:ok, item}, Map.put(state, table, rest)}
    end
  end

  def handle_call({:update, table, id, fun}, _from, state) do
    items = Map.fetch!(state, table)

    case items do
      %{^id => item} -> {:reply, :ok, Map.put(state, table, Map.put(items, id, fun.(item)))}
      _ -> {:reply, :error, state}
    end
  end

  def handle_call({:put_scan, scan}, _from, state), do: {:reply, :ok, put_in(state.scans[scan.id], scan)}

  def handle_call({:sweep, now_ms}, _from, state) do
    {expired, state} = pull_expired(state, now_ms)
    {:reply, expired, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now_ms = System.system_time(:millisecond)
    {{holds, scans}, state} = pull_expired(state, now_ms)
    if holds != [] or scans != [], do: expire_later(holds, scans, now_ms)
    schedule()
    {:noreply, state}
  end

  defp pull_expired(state, now_ms) do
    ttl_ms = Moderation.config(:hold_ttl_hours) * 3_600_000

    {expired_holds, holds} =
      Map.split_with(state.holds, fn {_id, h} -> DateTime.to_unix(h.inserted_at, :millisecond) + ttl_ms <= now_ms end)

    {expired_scans, scans} =
      Map.split_with(state.scans, fn {_id, scan} ->
        Enum.any?(scan.awaiting, fn {_rule, {deadline, _name}} -> deadline <= now_ms end)
      end)

    expired_holds = Map.values(expired_holds)
    # A scan of an expired hold has nothing left to decide.
    expired_ids = MapSet.new(expired_holds, & &1.id)
    expired_scans = expired_scans |> Map.values() |> Enum.reject(&MapSet.member?(expired_ids, &1.hold_id))
    scans = Map.reject(scans, fn {_id, scan} -> MapSet.member?(expired_ids, scan.hold_id) end)

    {{expired_holds, expired_scans}, %{state | holds: holds, scans: scans}}
  end

  defp expire_later(holds, scans, now_ms) do
    {:ok, _pid} =
      Task.Supervisor.start_child(TaskSupervisor, fn ->
        Scanner.expired(holds, scans, now_ms)
      end)

    :ok
  end

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)
end
