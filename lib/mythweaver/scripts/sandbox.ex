defmodule Mythweaver.Scripts.Sandbox do
  @moduledoc """
  Runs one Lua chunk under all three sandbox layers: the library's function deny-list (plus
  `Mythweaver.Scripts.Guards`), a fresh VM per run with a call-depth cap and a string-size
  ceiling, and a separate process with a heap cap, a CPU-time budget and a wall-clock deadline.

  CPU time is measured as time on a scheduler, from OTP `:trace` `running` events, so a script
  blocked on the database or another process is not charged for the wait; the wall-clock deadline
  bounds those waits instead.

  `print` does not reach the server's stdout: its lines come back with the run's result, at most
  20 lines of 500 characters each.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Lua.AST.Chunk
  alias Mythweaver.Scripts.Guards
  alias Mythweaver.Scripts.TaskSupervisor

  @defaults [max_call_depth: 128, max_memory_bytes: 32 * 1024 * 1024, max_cpu_ms: 5_000, max_wall_ms: 10_000]

  # Passed explicitly so a `lua` upgrade can't widen the sandbox; the test lists every name. A
  # literal copy of `lua` 1.0.2's default, so `Lua.new/1` still hits its memoized template.
  @sandboxed [
    [:io, :stdin],
    [:io, :stdout],
    [:io, :stderr],
    [:io, :read],
    [:io, :write],
    [:io, :open],
    [:io, :close],
    [:io, :lines],
    [:io, :popen],
    [:io, :tmpfile],
    [:io, :output],
    [:io, :input],
    [:io, :flush],
    [:io, :type],
    [:file],
    [:os, :execute],
    [:os, :exit],
    [:os, :getenv],
    [:os, :remove],
    [:os, :rename],
    [:os, :tmpname],
    [:package],
    [:load],
    [:loadfile],
    [:require],
    [:dofile],
    [:loadstring]
  ]

  @max_lines 20
  @max_line_chars 500

  @type limits :: [
          max_call_depth: pos_integer() | :infinity,
          max_memory_bytes: pos_integer() | :infinity,
          max_cpu_ms: pos_integer() | :infinity,
          max_wall_ms: pos_integer() | :infinity
        ]

  @doc "The configured limits (`config :mythweaver, Mythweaver.Scripts`), read at call time."
  @spec limits() :: limits()
  def limits, do: Keyword.merge(@defaults, Application.get_env(:mythweaver, Mythweaver.Scripts, []))

  @doc """
  Evaluates `source` in a fresh VM after `setup` installs the event and host API into it. Returns
  the chunk's return values, decoded, or an error message, plus the lines it printed (also kept
  when it fails). Limits missing from `limits` take the defaults, not the app config.
  """
  @spec run(String.t(), (Lua.t() -> Lua.t()), keyword()) ::
          {:ok, [term()], [String.t()]} | {:error, String.t(), [String.t()]}
  def run(source, setup, limits) when is_binary(source) and is_function(setup, 1) do
    limits = Keyword.merge(@defaults, limits)
    depth = Keyword.fetch!(limits, :max_call_depth)
    bytes = Keyword.fetch!(limits, :max_memory_bytes)
    cpu_ms = Keyword.fetch!(limits, :max_cpu_ms)
    wall_ms = Keyword.fetch!(limits, :max_wall_ms)
    output = {self(), make_ref()}

    # Monitored, not linked, so a trap-exit caller (the generation server) gets no stray `EXIT`;
    # `$callers` keeps the Ecto sandbox reachable from inside.
    task =
      Task.Supervisor.async_nolink(
        TaskSupervisor,
        Mythweaver.Locale.carry(fn ->
          receive do
            :go -> :ok
          end

          evaluate(source, setup, depth, bytes, output)
        end)
      )

    session = if cpu_ms != :infinity, do: trace(task.pid)
    send(task.pid, :go)

    acc = %{
      budget_ns: if(cpu_ms != :infinity, do: to_ns(cpu_ms)),
      deadline: if(wall_ms != :infinity, do: System.monotonic_time(:millisecond) + wall_ms),
      cpu_ms: cpu_ms,
      wall_ms: wall_ms,
      bytes: bytes,
      used: 0,
      since: nil,
      output: elem(output, 1),
      lines: []
    }

    try do
      {result, acc} = await(task, acc)
      lines = acc |> flush_lines() |> Enum.reverse()

      case result do
        {:ok, values} -> {:ok, values, lines}
        {:error, message} -> {:error, message, lines}
      end
    after
      if session, do: untrace(session, task.pid)
    end
  end

  @doc """
  Parses and compiles `source` without running it, in a capped process like a run, so a
  pathological body cannot exhaust the caller. On success returns `inspect` applied to the syntax
  tree, computed in that process so the tree never crosses to the caller; otherwise the parser's
  errors.
  """
  @spec parse(String.t(), (Chunk.t() -> result)) :: {:ok, result} | {:error, [String.t()]} when result: term()
  def parse(source, inspect \\ fn _ast -> nil end) when is_binary(source) and is_function(inspect, 1) do
    limits = limits()
    bytes = Keyword.fetch!(limits, :max_memory_bytes)

    task =
      Task.Supervisor.async_nolink(TaskSupervisor, fn ->
        cap_heap(bytes)

        # `parse_chunk` compiles too, so it reports compile errors the bare parser would miss; the
        # second, parse-only pass is for the tree it does not return.
        with {:ok, _chunk} <- Lua.parse_chunk(source),
             {:ok, ast} <- Lua.Parser.parse_structured(source) do
          {:ok, inspect.(ast)}
        else
          {:error, %Lua.CompilerException{errors: errors}} -> {:error, errors}
        end
      end)

    case Task.yield(task, Keyword.fetch!(limits, :max_wall_ms)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, :killed} ->
        {:error, [dgettext("scripts", "Script is too complex to parse within the memory limit.")]}

      {:exit, reason} ->
        gettext_comment("Shown in the script editor; the placeholder is the raw Erlang exit reason, untranslated.")

        {:error,
         [
           dpgettext("scripts", "status: the Lua parser crashed", "Parser crashed: %{exit_reason}",
             exit_reason: Exception.format_exit(reason)
           )
         ]}

      nil ->
        {:error, [dgettext("scripts", "Script took too long to parse.")]}
    end
  end

  defp evaluate(source, setup, depth, bytes, output) do
    cap_heap(bytes)

    # Well below the heap cap, so an oversized string is refused before it is built rather than
    # killing the process mid-allocation.
    string_bytes = if bytes == :infinity, do: :infinity, else: div(bytes, 4)

    lua_opts =
      if bytes == :infinity,
        do: [sandboxed: @sandboxed, max_call_depth: depth],
        else: [sandboxed: @sandboxed, max_call_depth: depth, max_string_bytes: string_bytes]

    {results, _lua} =
      lua_opts
      |> Lua.new()
      |> Guards.install(string_bytes)
      |> install_print(output)
      |> setup.()
      |> Lua.eval!(source, source: "script")

    {:ok, results}
  rescue
    e -> {:error, clean_message(Exception.message(e))}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  defp cap_heap(:infinity), do: :ok

  defp cap_heap(bytes) do
    Process.flag(:max_heap_size, %{
      size: div(bytes, :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    })
  end

  # A raise through nested host calls (a `regex.replace` callback recursing) gains one
  # `(at script:N)` per level; repeats of the same location say nothing new, and positions inside
  # the guard prelude say nothing at all.
  defp clean_message(message) do
    message |> Guards.strip_locations() |> then(&Regex.replace(~r/( \(at [^()]+\))\1+/, &1, "\\1"))
  end

  # Lines go to the caller as they are printed, so a script that later fails or is killed keeps
  # them. Past the cap one notice is sent and the rest dropped.
  defp install_print(lua, {parent, ref}) do
    Lua.set!(lua, [:print], fn args, state ->
      count = Process.get(:script_print_count, 0)
      Process.put(:script_print_count, count + 1)

      cond do
        count < @max_lines ->
          {strings, state} =
            Enum.map_reduce(args, state, fn arg, state ->
              {[string | _], state} = Lua.call_function!(state, [:tostring], [arg])
              {string, state}
            end)

          send(parent, {:script_print, ref, strings |> Enum.join("\t") |> truncate()})
          {[], state}

        count == @max_lines ->
          send(
            parent,
            {:script_print, ref,
             dpgettext(
               "scripts",
               "status: a Lua script printed more lines than are kept",
               "(further print output omitted)"
             )}
          )

          {[], state}

        true ->
          {[], state}
      end
    end)
  end

  defp truncate(line) do
    line = String.replace_invalid(line)
    if String.length(line) <= @max_line_chars, do: line, else: String.slice(line, 0, @max_line_chars) <> "…"
  end

  defp flush_lines(%{output: ref} = acc) do
    receive do
      {:script_print, ^ref, line} -> flush_lines(%{acc | lines: [line | acc.lines]})
    after
      0 -> acc.lines
    end
  end

  defp trace(pid) do
    session = :trace.session_create(:mythweaver_script, self(), [])
    1 = :trace.process(session, pid, true, [:running, :monotonic_timestamp])
    session
  end

  # `:trace.delivered/2` answers once every trace message for `pid` is in our mailbox, so draining
  # up to that reply leaves none behind for the calling LiveView or GenServer.
  defp untrace(session, pid) do
    ref = :trace.delivered(session, pid)
    drain(pid, ref)
    :trace.session_destroy(session)
  catch
    _, _ ->
      :trace.session_destroy(session)
      drain(pid, nil)
  end

  defp drain(pid, ref) do
    timeout = if ref, do: 5_000, else: 0

    receive do
      {:trace_ts, ^pid, _, _, _} -> drain(pid, ref)
      {:trace_delivered, ^pid, ^ref} -> :ok
    after
      timeout -> :ok
    end
  end

  # `ts` values are `erlang:monotonic_time(nanosecond)`, the `monotonic_timestamp` trace unit.
  defp await(%Task{ref: ref, pid: pid} = task, %{output: output} = acc) do
    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        {result, acc}

      {:DOWN, ^ref, :process, _, :killed} when acc.bytes != :infinity ->
        {{:error,
          dgettext("scripts", "Script exceeded its memory limit of %{memory_limit}.",
            memory_limit: Mythweaver.Format.megabytes(div(acc.bytes, 1024 * 1024))
          )}, acc}

      {:DOWN, ^ref, :process, _, reason} ->
        gettext_comment(
          "Shown when a Lua script run crashes; the placeholder is the raw Erlang exit reason, untranslated."
        )

        {{:error,
          dpgettext("scripts", "status: a Lua script run crashed", "Script crashed: %{exit_reason}",
            exit_reason: Exception.format_exit(reason)
          )}, acc}

      {:script_print, ^output, line} ->
        await(task, %{acc | lines: [line | acc.lines]})

      {:trace_ts, ^pid, ev, _, ts} when ev in [:in, :in_exiting] ->
        await(task, %{acc | since: ts})

      {:trace_ts, ^pid, ev, _, ts} when ev in [:out, :out_exiting, :out_exited] ->
        used = if acc.since, do: acc.used + ts - acc.since, else: acc.used
        await(task, %{acc | used: used, since: nil})
    after
      # Integers sort before atoms, so `min` keeps whichever limit is finite and nearer.
      min(cpu_remaining_ms(acc), wall_remaining_ms(acc)) ->
        case Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> {result, acc}
          _ -> {{:error, limit_message(acc)}, acc}
        end
    end
  end

  defp limit_message(acc) do
    if wall_remaining_ms(acc) == 0,
      do:
        dgettext("scripts", "Script exceeded its time limit of %{time_limit_ms} ms.",
          time_limit_ms: Mythweaver.Format.number(acc.wall_ms)
        ),
      else:
        dgettext("scripts", "Script exceeded its CPU time limit of %{time_limit_ms} ms.",
          time_limit_ms: Mythweaver.Format.number(acc.cpu_ms)
        )
  end

  defp cpu_remaining_ms(%{since: nil}), do: :infinity
  defp cpu_remaining_ms(%{budget_ns: nil}), do: :infinity

  defp cpu_remaining_ms(%{budget_ns: budget, used: used, since: since}) do
    running = :erlang.monotonic_time(:nanosecond) - since
    max(System.convert_time_unit(budget - used - running, :nanosecond, :millisecond), 0)
  end

  defp wall_remaining_ms(%{deadline: nil}), do: :infinity
  defp wall_remaining_ms(%{deadline: deadline}), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp to_ns(ms), do: System.convert_time_unit(ms, :millisecond, :nanosecond)
end
