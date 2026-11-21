defmodule Mythweaver.Jobs.Scheduler do
  @moduledoc """
  Decides when a queued generation gets a provider slot, and enforces every running job's clock.

  The queue and the running slots live only in this process; `generation_jobs` rows are the durable
  record and are written by `Mythweaver.Jobs`.

  **Admission** runs after every submit, task exit, cancel or kill, and on `reconsider/0` when a
  provider or link changed; nothing else frees a slot or adds a link, so a waiting ticket costs no
  queries in between. The queue is scanned in `{background?, seq}` order, so interactive work goes
  first and each class is FIFO. A ticket whose
  lane is taken (running, or held by an earlier ticket still waiting in this pass) is skipped. Every
  other ticket asks `Mythweaver.AI.next_provider_model/3` for a link on a provider with a free slot
  (`Provider.max_concurrency`); one that gets none waits, and the scan continues, so a reply for an
  idle provider is never stuck behind a memory job for a busy one. Only connections the ticket's
  `run_owner` may spend are candidates. A ticket that gets no link while no provider is full can
  never run and fails with `:no_provider`; one whose owner-key share lost its connection fails
  `{:owner_key_withdrawn, model}`, and one past the initiator's quota on the chosen link
  (`Mythweaver.Permissions.Quota.check_spend/2`) fails `:quota_exceeded`.

  **Termination.** A job ends when its task exits, or when this process kills it: the wall-clock
  deadline (`:timeout`), the token watchdog (`:no_tokens` before the first token, `:stalled` after a
  silent gap), a guard trip from the runner (`{:guard, reason}`), or a cancel (`:canceled`, including
  the owner process exiting). A kill is the only abort: Req's streaming fold has no cooperative stop.
  Every kill tells the owner `{:ai_stream, ref, {:error, reason}}` and finishes the row through
  `Jobs.finish_by_scheduler/3`, which leaves a row the runner already finished untouched.

  **Queue announcements.** Whenever the admission order changes, every user with a ticket in the
  old or the new queue gets `Jobs.broadcast_queue/2` with their own tickets' positions (an empty map
  once they have none), so position badges stay current without anyone learning of other users' jobs.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Provider
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Runner
  alias Mythweaver.Jobs.Ticket
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Repo

  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Queues `ticket` and runs admission. Monitors `ticket.owner` when set."
  def submit(%Ticket{} = ticket), do: GenServer.call(__MODULE__, {:submit, ticket})

  @doc "Drops a queued job or kills a running one, finishing it `:canceled`."
  @spec cancel(Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def cancel(job_id), do: GenServer.call(__MODULE__, {:cancel, job_id})

  @doc "The runner's guard tripped: kill the job and finish it `{:guard, reason}`."
  def guard_tripped(job_id, reason), do: GenServer.cast(__MODULE__, {:guard_tripped, job_id, reason})

  @doc "A token (content or reasoning) arrived. The runner throttles this to one per 500 ms."
  def progress(job_id), do: GenServer.cast(__MODULE__, {:progress, job_id})

  @doc "A worker is about to stream its repair retry: restart the first-token clock."
  def reset_clock(job_id), do: GenServer.cast(__MODULE__, {:reset_clock, job_id})

  @doc """
  Re-runs admission: a provider or link changed (a raised `max_concurrency`, a link added or
  enabled, one removed), so a waiting job may now run, or never can.
  """
  def reconsider, do: GenServer.cast(__MODULE__, :reconsider)

  @doc "Queued and running job ids, queued in admission order."
  @spec status() :: %{queued: [Ecto.UUID.t()], running: [Ecto.UUID.t()]}
  def status, do: GenServer.call(__MODULE__, :status)

  ## Server

  @impl true
  def init(:ok) do
    {:ok,
     %{
       queue: [],
       # job_id => %{ticket, pid, admitted_at, last_token_at, deadline, provider_id}
       running: %{},
       # monitor ref => {:task | :owner, job_id}
       monitors: %{},
       seq: 0,
       watchdog: nil
     }}
  end

  @impl true
  def handle_call({:submit, %Ticket{} = ticket}, _from, old) do
    ticket = %{ticket | seq: old.seq}
    state = %{old | seq: old.seq + 1, queue: old.queue ++ [ticket]}

    state =
      if is_pid(ticket.owner),
        do: put_in(state.monitors[Process.monitor(ticket.owner)], {:owner, ticket.job_id}),
        else: state

    {:reply, :ok, state |> admit() |> announce(old)}
  end

  def handle_call({:cancel, job_id}, _from, state) do
    case cancel_job(state, job_id) do
      {:ok, canceled} -> {:reply, :ok, announce(canceled, state)}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, %{queued: Enum.map(admission_order(state.queue), & &1.job_id), running: Map.keys(state.running)}, state}
  end

  @impl true
  def handle_cast({:guard_tripped, job_id, reason}, state) do
    if Map.has_key?(state.running, job_id),
      do: {:noreply, state |> kill(job_id, {:guard, reason}) |> admit() |> announce(state)},
      else: {:noreply, state}
  end

  def handle_cast({:progress, job_id}, state), do: {:noreply, update_slot(state, job_id, &%{&1 | last_token_at: now()})}

  def handle_cast({:reset_clock, job_id}, state),
    do: {:noreply, update_slot(state, job_id, &%{&1 | last_token_at: nil, admitted_at: now()})}

  def handle_cast(:reconsider, state), do: {:noreply, state |> admit() |> announce(state)}

  @impl true
  def handle_info({:DOWN, mon, :process, _pid, reason}, old) do
    {entry, monitors} = Map.pop(old.monitors, mon)
    state = %{old | monitors: monitors}

    case entry do
      {:task, job_id} -> {:noreply, state |> task_exited(job_id, reason) |> admit() |> announce(old)}
      {:owner, job_id} -> {:noreply, state |> owner_exited(job_id) |> announce(old)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:deadline, job_id}, state) do
    if Map.has_key?(state.running, job_id),
      do: {:noreply, state |> kill(job_id, :timeout) |> admit() |> announce(state)},
      else: {:noreply, state}
  end

  # A tick that kills nothing frees no slot, so it does not admit: admission reads every provider and
  # runs a selection transaction per waiting ticket.
  def handle_info(:watchdog, old) do
    now = now()

    {state, killed?} =
      Enum.reduce(old.running, {%{old | watchdog: nil}, false}, fn {job_id, slot}, {acc, killed?} ->
        case watchdog_verdict(slot, now) do
          nil -> {acc, killed?}
          reason -> {kill(acc, job_id, reason), true}
        end
      end)

    state = if killed?, do: admit(state), else: state
    {:noreply, state |> arm_watchdog() |> announce(old)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Admission

  defp admit(%{queue: []} = state), do: state

  defp admit(state) do
    limits = safely(fn -> Repo.all(from(p in Provider, select: {p.id, p.max_concurrency})) end, [])
    counts = state.running |> Map.values() |> Enum.frequencies_by(& &1.provider_id)
    lanes = for {_id, %{ticket: %{lane: lane}}} <- state.running, lane != nil, into: %{}, do: {lane, true}

    {state, _counts, _lanes} =
      state.queue
      |> admission_order()
      |> Enum.reduce({state, counts, lanes}, &consider(&1, &2, limits))

    arm_watchdog(state)
  end

  # A lane already taken this pass (running, or held by an earlier ticket that is waiting) keeps the
  # ticket queued, so a chat's worker jobs run strictly in submit order.
  defp consider(%Ticket{lane: lane} = _ticket, {state, counts, lanes}, _limits)
       when lane != nil and is_map_key(lanes, lane), do: {state, counts, lanes}

  defp consider(%Ticket{} = ticket, {state, counts, lanes}, limits) do
    full = full_providers(limits, counts)
    lanes = if ticket.lane, do: Map.put(lanes, ticket.lane, true), else: lanes

    case safely(fn -> select_link(ticket, full) end, {:error, :db}) do
      {:ok, link} ->
        {start(state, ticket, link), Map.update(counts, link.provider_id, 1, &(&1 + 1)), lanes}

      {:error, :no_provider} when full == [] ->
        {drop_queued(state, ticket, :no_provider), counts, lanes}

      {:error, :quota_exceeded} ->
        {drop_queued(state, ticket, :quota_exceeded), counts, lanes}

      {:error, {:owner_key_withdrawn, _model} = reason} ->
        {drop_queued(state, ticket, reason), counts, lanes}

      {:error, _waiting} ->
        {state, counts, lanes}
    end
  end

  # The link the ticket's run owner may spend, charged to the initiator's quota on that connection
  # (`Quota.check_spend/2`): the check at submit saw the link selection would have picked then.
  defp select_link(%Ticket{} = ticket, full) do
    with {:ok, link} <- AI.next_provider_model(ticket.model, ticket.run_owner, except_provider_ids: full),
         :ok <- spend_check(ticket.scope, link),
         do: {:ok, link}
  end

  defp spend_check(%Scope{} = scope, link), do: Quota.check_spend(scope, link)
  defp spend_check(_scope, _link), do: :ok

  defp admission_order(queue), do: Enum.sort_by(queue, &{&1.origin == :background, &1.seq})

  ## Queue announcements

  # Tells every user with a ticket queued before or after the change their own positions, when the
  # admission order changed. Returns `state`.
  defp announce(state, old) do
    before = admission_order(old.queue)
    current = admission_order(state.queue)

    if Enum.map(before, & &1.job_id) != Enum.map(current, & &1.job_id) do
      positions =
        for {ticket, position} <- Enum.with_index(current, 1), user_id <- ticket.audience, reduce: %{} do
          acc -> Map.update(acc, user_id, %{ticket.job_id => position}, &Map.put(&1, ticket.job_id, position))
        end

      for user_id <- Enum.uniq(for ticket <- before ++ current, user_id <- ticket.audience, do: user_id) do
        safely(fn -> Jobs.broadcast_queue(user_id, Map.get(positions, user_id, %{})) end, :ok)
      end
    end

    state
  end

  defp full_providers(limits, counts) do
    for {id, max} <- limits, Map.get(counts, id, 0) >= max, do: id
  end

  defp start(state, ticket, link) do
    {:ok, pid} = Task.Supervisor.start_child(Jobs.TaskSupervisor, fn -> Runner.run(ticket, link) end)
    mon = Process.monitor(pid)
    deadline = if ticket.deadline_ms, do: Process.send_after(self(), {:deadline, ticket.job_id}, ticket.deadline_ms)

    slot = %{
      ticket: ticket,
      pid: pid,
      monitor: mon,
      admitted_at: now(),
      last_token_at: nil,
      deadline: deadline,
      provider_id: link.provider_id
    }

    %{
      state
      | queue: List.delete(state.queue, ticket),
        running: Map.put(state.running, ticket.job_id, slot),
        monitors: Map.put(state.monitors, mon, {:task, ticket.job_id})
    }
  end

  ## Watchdog

  defp arm_watchdog(%{watchdog: nil, running: running} = state) when map_size(running) > 0,
    do: %{state | watchdog: Process.send_after(self(), :watchdog, watchdog_ms())}

  defp arm_watchdog(state), do: state

  defp watchdog_verdict(%{last_token_at: nil, ticket: %{first_token_ms: limit}} = slot, now)
       when is_integer(limit) and now - slot.admitted_at > limit, do: :no_tokens

  defp watchdog_verdict(%{last_token_at: last, ticket: %{idle_ms: limit}}, now)
       when is_integer(last) and is_integer(limit) and now - last > limit, do: :stalled

  defp watchdog_verdict(_slot, _now), do: nil

  defp watchdog_ms, do: Application.get_env(:mythweaver, :jobs_watchdog_ms, 1000)

  ## Termination

  defp kill(state, job_id, reason) do
    {slot, running} = Map.pop(state.running, job_id)
    Process.exit(slot.pid, :kill)
    Process.demonitor(slot.monitor, [:flush])
    if slot.deadline, do: Process.cancel_timer(slot.deadline)

    terminate_ticket(
      %{state | running: running, monitors: Map.delete(state.monitors, slot.monitor)},
      slot.ticket,
      reason
    )
  end

  # A runner that returns has already reported to its owner and finished its row. One that died any
  # other way (a crash outside its own rescue, an external kill) has not, so it is finished here.
  defp task_exited(state, job_id, reason) do
    case Map.pop(state.running, job_id) do
      {nil, _running} ->
        state

      {slot, running} ->
        if slot.deadline, do: Process.cancel_timer(slot.deadline)
        state = %{state | running: running}

        if reason == :normal,
          do: drop_owner_monitor(state, job_id),
          else: terminate_ticket(state, slot.ticket, {:exception, Exception.format_exit(reason)})
    end
  end

  defp owner_exited(state, job_id) do
    case cancel_job(state, job_id) do
      {:ok, canceled} -> canceled
      :error -> state
    end
  end

  # Kills a running job or drops a queued one, finishing it `:canceled`; `:error` when it is neither.
  defp cancel_job(state, job_id) do
    cond do
      Map.has_key?(state.running, job_id) ->
        {:ok, state |> kill(job_id, :canceled) |> admit()}

      ticket = Enum.find(state.queue, &(&1.job_id == job_id)) ->
        {:ok, state |> drop_queued(ticket, :canceled) |> admit()}

      true ->
        :error
    end
  end

  defp drop_queued(state, %Ticket{} = ticket, reason) do
    terminate_ticket(%{state | queue: List.delete(state.queue, ticket)}, ticket, reason)
  end

  defp terminate_ticket(state, %Ticket{} = ticket, reason) do
    if is_pid(ticket.owner), do: send(ticket.owner, {:ai_stream, ticket.ref, {:error, reason}})

    status = if reason == :canceled, do: :canceled, else: :failed

    safely(
      fn ->
        error = Mythweaver.Locale.with_user_locale(ticket.scope, fn -> Jobs.error_message(reason) end)
        Jobs.finish_by_scheduler(ticket.job_id, status, error)
      end,
      :ok
    )

    drop_owner_monitor(state, ticket.job_id)
  end

  defp drop_owner_monitor(state, job_id) do
    case Enum.find(state.monitors, fn {_mon, entry} -> entry == {:owner, job_id} end) do
      nil ->
        state

      {mon, _entry} ->
        Process.demonitor(mon, [:flush])
        %{state | monitors: Map.delete(state.monitors, mon)}
    end
  end

  defp update_slot(state, job_id, fun) do
    case state.running do
      %{^job_id => slot} -> put_in(state.running[job_id], fun.(slot))
      _other -> state
    end
  end

  # The scheduler outlives every request, so a failed read or write (a raise, or an exit from the
  # connection pool) is logged and the queue keeps running: a crash would drop every queued ticket
  # and orphan every running task.
  defp safely(fun, fallback) do
    fun.()
  catch
    kind, reason ->
      Logger.warning("Mythweaver.Jobs.Scheduler: " <> Exception.format_banner(kind, reason, __STACKTRACE__))
      fallback
  end

  defp now, do: System.monotonic_time(:millisecond)
end
