defmodule Mythweaver.Jobs.Runner do
  @moduledoc """
  Runs one admitted job inside its `Mythweaver.Jobs.TaskSupervisor` task, on the link the scheduler
  picked. A job with a chat sends `"<user id>:<chat id>"` as its requests' session id.

  Every content or reasoning token is fed to `Mythweaver.Jobs.Guard` and reported to the scheduler's
  watchdog (`Scheduler.progress/1`, at most every 500 ms). A guard trip is reported once, and
  nothing further is forwarded or written: the scheduler kills this task and finishes the job.

  Progress for the UI: the first token of a job stamps `first_token_at` on its row, and on the same
  500 ms gate (and on every `StreamEvent.PromptProgress`, which is never forwarded) the runner
  broadcasts `{:job_progress, …}` (`Mythweaver.Jobs.broadcast_progress/1`) with the estimated output
  tokens, tokens/sec and prompt progress. Before the first request it estimates the time to first
  token from history (`Mythweaver.Jobs.expected_first_token_ms/4`). None of these writes can fail
  the job.

  Every content and reasoning chunk is also appended to the job's `Mythweaver.Jobs.LiveOutput`
  buffer, before the guard sees it (so a tripping chunk shows too), for the Jobs page to read. The
  buffer holds the job's protected triples too: a `:stream` ticket's `protected`, or the `:protected` key
  a worker's `build/1` puts on its input (popped before the input is sent).

  A `:stream` ticket forwards every event to its owner as `{:ai_stream, ref, event}`, then the terminal
  result the same way (`Mythweaver.Jobs.stream_async/5`'s contract). A `:worker` ticket drives its
  `Mythweaver.Jobs.Worker` module through build, stream, finish and at most one repair retry.

  A worker request whose `response_format` (structured output) the provider rejects with a 400, 415
  or 422 naming it is sent once more without it, and every later request of the job (the repair
  retry included) leaves it out; the worker still validates the JSON itself. That resend does not use
  up the repair retry.
  """

  alias Mythweaver.AI
  alias Mythweaver.AI.Request
  alias Mythweaver.AI.StreamEvent
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Guard
  alias Mythweaver.Jobs.LiveOutput
  alias Mythweaver.Jobs.Scheduler
  alias Mythweaver.Jobs.Ticket
  alias Mythweaver.Jobs.Worker
  alias Mythweaver.Tokenizer

  require Logger

  @progress_ms 500

  def run(%Ticket{} = ticket, link) do
    # Ownership lookups (the Ecto sandbox, `Req.Test` stubs) resolve through `$callers`; this task was
    # spawned by the scheduler, but it runs on the submitter's behalf.
    if ticket.callers != [], do: Process.put(:"$callers", ticket.callers)

    :ok = Jobs.mark_running(ticket.job_id, link.provider_id)
    Process.put(:jobs_live, LiveOutput.open(ticket.job_id, ticket.protected))
    reset_guard(ticket)

    case ticket.kind do
      :stream -> run_stream(ticket, link)
      :worker -> run_worker(ticket, link)
    end
  end

  defp run_stream(ticket, link) do
    result = guarded_stream(ticket, link, ticket.input, &send(ticket.owner, {:ai_stream, ticket.ref, &1}))

    # The row is written before the owner hears the result, so an owner that reacts by exiting (and
    # so canceling this job) never kills the task mid-write, and the row is final when it is told.
    if !tripped?() do
      case result do
        {:ok, completion, _link} ->
          Jobs.finish(ticket.job_id, :completed, %{usage: completion.raw})

        {:error, reason} ->
          error = Mythweaver.Locale.with_user_locale(ticket.scope, fn -> Jobs.error_message(reason) end)
          Jobs.finish(ticket.job_id, :failed, %{error: error})
      end

      send(ticket.owner, {:ai_stream, ticket.ref, result})
    end
  end

  defp run_worker(ticket, link) do
    job = Jobs.get_job(ticket.scope, ticket.job_id)

    outcome =
      try do
        case ticket.worker.build(job) do
          {:ok, input, prompt_name} ->
            Jobs.put_prompt_name(job.id, prompt_name)
            {protected, input} = Map.pop(input, :protected, [])
            LiveOutput.protect(ticket.job_id, protected)
            work(ticket, link, job, input, false)

          {:error, reason} ->
            {:error, reason, nil}
        end
      catch
        kind, reason -> {:error, {:exception, Exception.format_banner(kind, reason, __STACKTRACE__)}, nil}
      end

    record(ticket, job, outcome)
  end

  defp work(ticket, link, job, input, retried?) do
    input = if Process.get(:jobs_schema_dropped), do: drop_schema(input), else: input
    result = guarded_stream(ticket, link, input, fn _event -> :ok end)

    case {tripped?(), result} do
      {true, _result} ->
        :tripped

      {false, {:ok, completion, _link}} ->
        finish(ticket, link, job, completion, retried?)

      {false, {:error, {:http_error, status, body} = reason}} ->
        if !Process.get(:jobs_schema_dropped) and schema_rejected?(status, body, input) do
          Logger.warning("Job #{job.id}: the provider rejected response_format; retrying without it")
          Process.put(:jobs_schema_dropped, true)
          Scheduler.reset_clock(job.id)
          reset_guard(ticket)
          work(ticket, link, job, input, retried?)
        else
          {:error, reason, nil}
        end

      {false, {:error, reason}} ->
        {:error, reason, nil}
    end
  end

  defp schema_rejected?(status, body, input) do
    status in [400, 415, 422] and get_in(input, [:extra_body, "response_format"]) != nil and
      String.contains?(body_text(body), ["response_format", "json_schema", "structured output", "structured_output"])
  end

  defp body_text(body) when is_binary(body), do: String.downcase(body)

  defp body_text(body) do
    case Jason.encode(body) do
      {:ok, text} -> String.downcase(text)
      {:error, _reason} -> body |> inspect() |> String.downcase()
    end
  end

  defp drop_schema(%{extra_body: extra} = input) do
    case Map.delete(extra, "response_format") do
      empty when map_size(empty) == 0 -> Map.delete(input, :extra_body)
      extra -> %{input | extra_body: extra}
    end
  end

  defp drop_schema(input), do: input

  defp finish(ticket, link, job, completion, retried?) do
    # Written first: a save completes the row in its own transaction, so the reply must already be on it.
    Jobs.put_output(job.id, completion)

    case ticket.worker.finish(job, completion, retried?) do
      {:ok, status, result} when status in [:completed, :review] ->
        {:ok, status, result, completion}

      {:retry, input} when not retried? ->
        Scheduler.reset_clock(job.id)
        reset_guard(ticket)
        work(ticket, link, job, input, true)

      {:retry, _input} ->
        {:error, :unparseable, completion}

      {:error, reason} ->
        {:error, reason, completion}
    end
  end

  defp record(_ticket, _job, :tripped), do: :ok

  # A save already completed the row in its transaction (`Jobs.complete_in_transaction/2`), so for
  # `:completed` this matches nothing; a `:review` result is written here.
  defp record(ticket, _job, {:ok, status, result, _completion}) do
    Jobs.finish(ticket.job_id, status, %{result: result})
  end

  defp record(ticket, job, {:error, reason, completion}) do
    Jobs.finish(ticket.job_id, :failed, %{
      error: Mythweaver.Locale.with_user_locale(ticket.scope, fn -> Jobs.error_message(reason) end),
      raw_output: completion && completion.text,
      usage: completion && completion.raw
    })

    Worker.run_failed(ticket.worker, job)
    :ok
  end

  # `stream_async/5`'s contract: anything raised or exited inside the request is a terminal
  # `{:exception, banner}` error rather than a silent task death.
  defp guarded_stream(ticket, link, input, forward) do
    # Once per job: the schema-drop resend and the repair retry keep the first estimate.
    if !Process.get(:jobs_estimated) do
      Process.put(:jobs_estimated, true)
      safely(fn -> estimate_first_token(ticket, link, input) end)
    end

    on_event = fn
      # Never forwarded and not a watchdog token: prompt processing is not output.
      %StreamEvent.PromptProgress{} = event -> note_prompt(ticket, event)
      event -> if observe(ticket, event) == :ok, do: forward.(event)
    end

    AI.stream_link(link, ticket.model, with_session(input, ticket), on_event)
  catch
    kind, reason -> {:error, {:exception, Exception.format_banner(kind, reason, __STACKTRACE__)}}
  end

  # A chat-bound job's requests share one session id, so a backend can group or pin them
  # (`Mythweaver.AI.Request.session_id`).
  defp with_session(input, %Ticket{chat_id: chat_id, scope: %{user: %{id: user_id}}}) when is_binary(chat_id),
    do: Map.put(input, :session_id, "#{user_id}:#{chat_id}")

  defp with_session(input, _ticket), do: input

  # Always estimated, whatever `prompt_progress` says: the flag is a request, not a guarantee, and the
  # UI prefers exact prompt progress whenever it arrives.
  defp estimate_first_token(ticket, link, input) do
    {tokens, _kind} = Tokenizer.count(ticket.model, prompt_text(input))

    case Jobs.expected_first_token_ms(link.provider_id, ticket.model.id, ticket.tag, tokens) do
      nil -> :ok
      ms -> Jobs.put_expected_first_token(ticket.job_id, ms)
    end
  end

  defp prompt_text(%{messages: messages}) when is_list(messages),
    do: Enum.map_join(messages, "\n", &content_text(&1.content))

  defp prompt_text(%{prompt: prompt}) when is_binary(prompt), do: prompt
  defp prompt_text(_input), do: ""

  defp content_text(content) when is_binary(content), do: content

  defp content_text(parts) when is_list(parts),
    do: Enum.join(for(%Request.Text{text: text} <- parts, text != nil, do: text), "\n")

  defp observe(ticket, %StreamEvent.Delta{text: text}), do: observe_token(ticket, :delta, text)
  defp observe(ticket, %StreamEvent.Reasoning{text: text}), do: observe_token(ticket, :reasoning, text)
  defp observe(_ticket, _event), do: if(tripped?(), do: :tripped, else: :ok)

  defp observe_token(ticket, type, text) do
    if tripped?() do
      :tripped
    else
      Process.put(:jobs_chars, Process.get(:jobs_chars, 0) + String.length(text))
      LiveOutput.append(Process.get(:jobs_live), type, text)

      if Process.get(:jobs_first_token_at) == nil do
        Process.put(:jobs_first_token_at, System.monotonic_time(:millisecond))
        safely(fn -> Jobs.mark_first_token(ticket.job_id) end)
      end

      note_progress(ticket)

      case Guard.feed(Process.get(:jobs_guard), type, text) do
        {:ok, guard} ->
          Process.put(:jobs_guard, guard)
          :ok

        {:error, reason} ->
          Process.put(:jobs_tripped, true)
          Scheduler.guard_tripped(ticket.job_id, reason)
          :tripped
      end
    end
  end

  defp note_progress(ticket) do
    now = System.monotonic_time(:millisecond)
    last = Process.get(:jobs_progress_at)

    if last == nil or now - last >= @progress_ms do
      Process.put(:jobs_progress_at, now)
      Scheduler.progress(ticket.job_id)
      broadcast_progress(ticket)
    end
  end

  # Unthrottled: adapters emit at most one per prompt batch, and the values are already normalized.
  defp note_prompt(ticket, %StreamEvent.PromptProgress{done: done, total: total}) do
    if !tripped?() do
      Process.put(:jobs_prompt, %{done: done, total: total})
      broadcast_progress(ticket)
    end
  end

  defp broadcast_progress(ticket) do
    tokens = if chars = Process.get(:jobs_chars), do: Tokenizer.estimate_length(chars)

    safely(fn ->
      Jobs.broadcast_progress(ticket.audience, %{
        id: ticket.job_id,
        chat_id: ticket.chat_id,
        tokens: tokens,
        tokens_per_second: tokens_per_second(tokens),
        prompt: Process.get(:jobs_prompt)
      })
    end)
  end

  defp tokens_per_second(nil), do: nil

  defp tokens_per_second(tokens) do
    with first when is_integer(first) <- Process.get(:jobs_first_token_at),
         elapsed when elapsed >= 1000 <- System.monotonic_time(:millisecond) - first do
      Float.round(tokens * 1000 / elapsed, 1)
    else
      _early -> nil
    end
  end

  # A progress write must never fail a generation; `guarded_stream/4`'s catch would turn it into a
  # job error. Mirrors `Scheduler.safely/2`.
  defp safely(fun) do
    fun.()
    :ok
  catch
    kind, reason ->
      Logger.warning("Job progress: " <> Exception.format_banner(kind, reason, __STACKTRACE__))
      :ok
  end

  # `:jobs_estimated` survives: the estimate is once per job, not per attempt.
  defp reset_guard(ticket) do
    Process.put(:jobs_guard, Guard.new(max_chars: ticket.max_chars, loop_guard?: ticket.loop_guard?))
    LiveOutput.clear(Process.get(:jobs_live))
    Process.delete(:jobs_progress_at)
    Process.delete(:jobs_chars)
    Process.delete(:jobs_first_token_at)
    Process.delete(:jobs_prompt)
  end

  defp tripped?, do: Process.get(:jobs_tripped, false)
end
