defmodule Mythweaver.Jobs.Ticket do
  @moduledoc """
  What `Mythweaver.Jobs.Scheduler` holds for one job while it is queued or running. The row in
  `generation_jobs` is the durable record; the ticket is everything the scheduler and runner need
  without reading it back.

    * `kind`: `:stream` (a chat generation: events go to `owner` under `ref`, `input` is prebuilt) or
      `:worker` (a memory job: `worker` builds the input and saves the result).
    * `lane`: jobs sharing a non-nil lane never run at once (worker jobs use the chat id, so a chat's
      memory work is serial); `:stream` tickets have none.
    * `seq`: the scheduler's monotonic admission order, set on submit.
    * `chat_id`: the job's chat, or nil; carried so progress broadcasts need no row read.
    * `audience`: the user ids told about the job (`Mythweaver.Jobs.audience/1`), resolved once at
      submit so progress ticks and queue announcements need no row read either.
    * `callers`: the submitting process and its `$callers`, installed in the runner task so ownership
      lookups (Ecto sandbox, `Req.Test` stubs) resolve as if the submitter had spawned it.
    * `run_owner`: whose run it is (`Mythweaver.AI.run_owner/2`: the chat's owner, else the
      initiator): only connections they may spend serve it (`Mythweaver.AI.next_provider_model/3`).
    * `protected`: a `:stream` job's `{secret, label, source}` triples (`Mythweaver.Jobs.stream_async/5`'s
      `:protected`), handed to its `Mythweaver.Jobs.LiveOutput` buffer; a worker sets its own at build.
  """

  @enforce_keys [:job_id, :tag, :origin, :model, :kind]
  defstruct [
    :job_id,
    :tag,
    :origin,
    :chat_id,
    :seq,
    :lane,
    :model,
    :kind,
    :owner,
    :ref,
    :worker,
    :input,
    :deadline_ms,
    :first_token_ms,
    :idle_ms,
    :max_chars,
    :scope,
    :run_owner,
    audience: [],
    loop_guard?: false,
    callers: [],
    protected: []
  ]
end
