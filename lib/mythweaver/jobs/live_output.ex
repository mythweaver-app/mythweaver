defmodule Mythweaver.Jobs.LiveOutput do
  @moduledoc """
  The text a running job has received so far, for watching (or diagnosing a stuck) job from the
  Jobs page.

  The job's runner task (`Mythweaver.Jobs.Runner`) owns one `:protected` ETS table and registers it
  in the `Registry` named after this module (started in `Mythweaver.Application`) under the job id.
  Every content and reasoning chunk is one row, keyed by a monotonic integer in an `:ordered_set`,
  so an append never copies the text before it. The table and its registration die with the task
  (a normal finish, a crash or the scheduler's kill), so nothing outlives the run and nothing has
  to clean up after it. A retry within the run (a repair or a schema-less resend) clears it, so it
  holds the reply being written now.

  Every write is a no-op without a table, so a failed `open/2` (the job id already registered, or
  no registry running) never fails the job.

  The registration also holds the job's protected values as `{secret, label, source}` triples
  (`Mythweaver.Sharing.Protected.pairs/1`): what its prompt revealed that a viewer may not read in
  its reasoning. `Mythweaver.Jobs.live_output/2` applies them.
  """

  alias Mythweaver.Sharing.Protected

  @registry __MODULE__

  @doc """
  Opens the calling process's buffer for `job_id`, with the job's `protected` scrub pairs; nil when
  it cannot be registered.
  """
  @spec open(Ecto.UUID.t(), [Protected.source_pair()]) :: :ets.tid() | nil
  def open(job_id, protected \\ []) do
    tid = :ets.new(__MODULE__, [:ordered_set, :protected])

    case register(job_id, {tid, protected}) do
      :ok ->
        tid

      :error ->
        :ets.delete(tid)
        nil
    end
  end

  defp register(job_id, value) do
    case Registry.register(@registry, job_id, value) do
      {:ok, _owner} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    # No registry: a node whose supervision tree predates it (a code reload without a restart).
    ArgumentError -> :error
  end

  @doc """
  Replaces the scrub pairs of the calling process's buffer for `job_id`: a worker learns them only
  once it has built its prompt. A no-op without a buffer.
  """
  @spec protect(Ecto.UUID.t(), [Protected.source_pair()]) :: :ok
  def protect(job_id, protected) do
    Registry.update_value(@registry, job_id, fn {tid, _old} -> {tid, protected} end)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Appends one received chunk."
  @spec append(:ets.tid() | nil, :delta | :reasoning, String.t()) :: :ok
  def append(nil, _type, _text), do: :ok

  def append(tid, type, text) do
    :ets.insert(tid, {System.unique_integer([:monotonic]), type, text})
    :ok
  end

  @doc "Drops everything received so far."
  @spec clear(:ets.tid() | nil) :: :ok
  def clear(nil), do: :ok

  def clear(tid) do
    :ets.delete_all_objects(tid)
    :ok
  end

  @doc """
  What the job's runner has received, in order, with its scrub pairs (unapplied); nil when no runner
  holds a buffer for it.
  """
  @spec read(Ecto.UUID.t()) ::
          %{content: String.t(), reasoning: String.t(), protected: [Protected.source_pair()]} | nil
  def read(job_id) do
    case Registry.lookup(@registry, job_id) do
      [{_owner, {tid, protected}}] -> Map.put(collect(tid), :protected, protected)
      [] -> nil
    end
  rescue
    # No registry (see `register/2`), or the runner exited between the lookup and the read, taking
    # its table with it.
    ArgumentError -> nil
  end

  # From the last row back, so prepending leaves each list in arrival order.
  defp collect(tid) do
    {content, reasoning} =
      :ets.foldr(
        fn
          {_seq, :delta, text}, {content, reasoning} -> {[text | content], reasoning}
          {_seq, :reasoning, text}, {content, reasoning} -> {content, [text | reasoning]}
        end,
        {[], []},
        tid
      )

    %{content: IO.iodata_to_binary(content), reasoning: IO.iodata_to_binary(reasoning)}
  end
end
