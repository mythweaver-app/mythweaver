defmodule Mythweaver.Jobs.Worker do
  @moduledoc """
  A background generation that builds its own input and saves its own result (memory, side prompt,
  consolidation, compaction, topical clip). `Mythweaver.Jobs.Runner` drives it on a provider slot the
  scheduler granted:

    1. `build/1` turns the job row into the AI `input` (`Mythweaver.AI.stream/3`'s shape) and names
       the prompt that built it (nil for none); the runner records the name on the row. An input
       built with `Mythweaver.Prompts.Builder` may carry `:protected`, the build's protected
       triples (`Mythweaver.Sharing.Protected.pairs/1`); the runner hands them to the job's
       `Mythweaver.Jobs.LiveOutput` buffer and drops the key before sending.
    2. The input is streamed; the completion carries the whole text.
    3. `finish/3` parses and saves it. `retried?` is false on the first call. `{:retry, input}` asks
       for one more stream on the same slot (a repair prompt); a second `:retry` counts as
       `{:error, :unparseable}`. `{:ok, :review, result}` parks the job for a person to approve.
    4. `failed/1`, when defined, runs after any failure: the runner's own, a scheduler stop (cancel,
       deadline, token watchdog, guard), or a restart that interrupted the job. The job's `status`
       (`:failed`, `:canceled`, `:interrupted`) says which.

  `retry_params/2`, when defined, re-reads the job's sources for `Mythweaver.Jobs.retry/3`: it
  returns the params that record what the sources were when queued (fingerprints, versions) as they
  are now, so a retry judges its save against what it will actually read, not against the first
  run's snapshot.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Completion
  alias Mythweaver.Jobs.Job

  @callback build(%Job{}) :: {:ok, input :: map(), prompt_name :: String.t() | nil} | {:error, term()}
  @callback finish(%Job{}, %Completion{}, retried? :: boolean()) ::
              {:ok, :completed | :review, map()} | {:retry, map()} | {:error, term()}
  @callback failed(%Job{}) :: any()
  @callback retry_params(Scope.t(), %Job{}) :: map()

  @optional_callbacks failed: 1, retry_params: 2

  @doc "Runs `worker`'s optional `failed/1` for `job`, if it defines one."
  def run_failed(worker, %Job{} = job) do
    if Code.ensure_loaded?(worker) and function_exported?(worker, :failed, 1), do: worker.failed(job)
    :ok
  end

  @doc "`worker`'s `retry_params/2` for `job` as `scope` retries it; `%{}` when it defines none."
  @spec retry_params(module(), Scope.t(), Job.t()) :: map()
  def retry_params(worker, %Scope{} = scope, %Job{} = job) do
    if Code.ensure_loaded?(worker) and function_exported?(worker, :retry_params, 2),
      do: worker.retry_params(scope, job),
      else: %{}
  end
end
