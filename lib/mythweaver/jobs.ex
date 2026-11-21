defmodule Mythweaver.Jobs do
  @moduledoc """
  The generation job queue. Every generation, chat replies included, is a `Job` row and a ticket
  in `Mythweaver.Jobs.Scheduler`, which grants provider slots (`Provider.max_concurrency`), admits
  interactive work before background work, and enforces each job's clock and output guards.

  Two kinds of job:

    * **Chat generations** (`chat_tags/0`: `:reply`, `:regenerate`, `:continue`, `:refine`) are started by
      `Generation.Server` through `stream_async/5`, which streams events back to its owner.
    * **Worker jobs** (`worker_tags/0`: the memory tags plus `:caption` and `:expression`) are started
      with `enqueue/3`; a `Mythweaver.Jobs.Worker` module builds the input and saves the result. A
      chat's memory jobs run one at a time, in order; captions and expression classifications skip
      that lane, since a reply may be waiting on a caption and a portrait should not wait on memory.

  `Mythweaver.AI.test_link/1` (the "Test Message" button) is deliberately outside the queue.

  Per-tag limits come from `tag_options/1`; override the defaults with
  `config :mythweaver, Mythweaver.Jobs, tags: [memory: [deadline_ms: …]]`. A model can override
  the first-token, stall and deadline limits for its chat and background jobs (`limits/3`).

  A job belongs to its initiator (`Scope.initiator_id/1` of the scope that started it: a chat
  member's reply runs as the chat's owner, `Mythweaver.Chats.run_scope/2`, yet stays the member's).
  Events go only to a job's audience (`audience/1`): the user who started it and the owner of its
  chat, the same people `list_jobs/2` shows it to. Each audience member's topic (`topic/1`,
  `subscribe/1`) carries:

    * `{:job_changed, %{id:, chat_id:, tag:, status:}}` on every status write;
    * `{:job_progress, payload}` (shape in `broadcast_progress/2`) while running, at most every
      500 ms and on every prompt-progress chunk;
    * `{:job_queue, %{job_id => position}}` from `Mythweaver.Jobs.Scheduler` whenever the global
      admission order changes, holding only that user's own queued jobs (`queue_positions/1`'s
      value). Positions are global, so this is sent even when another user's job moved the queue;
      it names none of their jobs.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.Analytics
  alias Mythweaver.Attachments.Workers.Caption
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Member
  alias Mythweaver.Expressions.Workers.Classify
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Jobs.LiveOutput
  alias Mythweaver.Jobs.Scheduler
  alias Mythweaver.Jobs.Ticket
  alias Mythweaver.Jobs.Worker
  alias Mythweaver.Memory.Workers.Assistance
  alias Mythweaver.Memory.Workers.Compaction
  alias Mythweaver.Memory.Workers.Consolidation
  alias Mythweaver.Memory.Workers.Scene
  alias Mythweaver.Memory.Workers.SidePrompt
  alias Mythweaver.Memory.Workers.TopicalClip
  alias Mythweaver.Notifications
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Repo
  alias Mythweaver.Sharing.Protected
  alias Mythweaver.Sharing.Visibility

  @chat_tags [:reply, :regenerate, :continue, :refine, :assistant]
  @memory_tags [:memory, :side_prompt, :consolidation, :compaction, :topical_clip, :memory_assistance]
  @worker_tags @memory_tags ++ [:caption, :expression]
  @active [:queued, :running]
  @terminal [:completed, :failed, :canceled, :interrupted]
  @retryable [:failed, :canceled, :interrupted, :review]
  # Statuses that still need something: queued, running, or awaiting review.
  @open [:queued, :running, :review]
  @option_keys [:deadline_ms, :first_token_ms, :idle_ms, :loop_guard, :max_chars]

  # Memory tags, like chat, have no wall-clock deadline: the first-token, stall, loop and output-cap
  # guards (or a manual stop) end them. They wait longer for the first token: their prompts can be
  # large and slow to process locally.
  @chat_defaults [deadline_ms: nil, first_token_ms: 180_000, idle_ms: 120_000, loop_guard: false, max_chars: nil]
  @memory_defaults [
    deadline_ms: nil,
    first_token_ms: 300_000,
    idle_ms: 120_000,
    loop_guard: true,
    max_chars: 80_000
  ]

  # A caption is not memory work: it keeps a wall-clock limit.
  @caption_defaults Keyword.put(@memory_defaults, :deadline_ms, 600_000)

  # An expression classification is one short JSON answer: a tight clock and output cap.
  @expression_defaults Keyword.merge(@memory_defaults, deadline_ms: 120_000, first_token_ms: 120_000, max_chars: 8_000)

  # Tag => `Mythweaver.Jobs.Worker` module.
  @workers %{
    memory: Scene,
    side_prompt: SidePrompt,
    consolidation: Consolidation,
    compaction: Compaction,
    topical_clip: TopicalClip,
    memory_assistance: Assistance,
    caption: Caption,
    expression: Classify
  }

  @doc "The tags `stream_async/5` serves: chat generations, streamed to `Generation.Server`."
  def chat_tags, do: @chat_tags

  @doc "The memory-book tags: background memory work driven by a `Jobs.Worker`."
  def memory_tags, do: @memory_tags

  @doc "Every tag `enqueue/3` serves: the memory tags plus `:caption` and `:expression`."
  def worker_tags, do: @worker_tags

  @doc "Terminal statuses: a job in one of these is finished and may be dismissed."
  def terminal_statuses, do: @terminal

  @doc """
  The limits a job of `tag` runs under: `deadline_ms` (wall clock, nil = none), `first_token_ms`,
  `idle_ms` (nil = none), `loop_guard` and `max_chars` (nil = none). App config overrides the defaults.
  """
  def tag_options(tag) when tag in @chat_tags, do: Keyword.merge(@chat_defaults, configured_options(tag))
  def tag_options(:caption), do: Keyword.merge(@caption_defaults, configured_options(:caption))
  def tag_options(:expression), do: Keyword.merge(@expression_defaults, configured_options(:expression))
  def tag_options(tag) when tag in @memory_tags, do: Keyword.merge(@memory_defaults, configured_options(tag))

  defp configured_options(tag) do
    :mythweaver |> Application.get_env(__MODULE__, []) |> Keyword.get(:tags, []) |> Keyword.get(tag, [])
  end

  @doc """
  The limits a job of `tag` on `model` runs under: `tag_options/1`, then the model's overrides
  (`Mythweaver.AI.Model.job_limits/2`, chat values for `chat_tags/0` and background values for the
  rest), then `overrides` (any of `tag_options/1`'s keys).
  """
  def limits(tag, %Model{} = model, overrides \\ []) do
    tag
    |> tag_options()
    |> Keyword.merge(Model.job_limits(model, if(tag in @chat_tags, do: :chat, else: :background)))
    |> Keyword.merge(Keyword.take(overrides, @option_keys))
  end

  @doc "The worker module for a worker tag."
  def worker_for(tag) when tag in @worker_tags, do: Map.fetch!(@workers, tag)

  ## Starting jobs

  @doc """
  Queues one streamed chat generation for `model`, attributed to `scope`'s user, and returns
  `{:ok, ref, job_id}` immediately.

  `owner` receives, in order, once the job is admitted:

    * `{:ai_stream, ref, %Mythweaver.AI.StreamEvent.Request{}}`, once, before the HTTP request
    * `{:ai_stream, ref, %StreamEvent.Delta{text: binary()}}` / `{:ai_stream, ref, %StreamEvent.Reasoning{text: binary()}}`
    * `{:ai_stream, ref, %StreamEvent.Done{finish_reason: binary() | nil}}`
    * `{:ai_stream, ref, {:ok, %Completion{}, %ProviderModel{}}}` or `{:ai_stream, ref, {:error, term()}}`

  The terminal error is also how the queue reports its own stops: `:canceled`, `:timeout`,
  `:no_tokens`, `:stalled`, `{:guard, :repetition | :output_cap}`, `:no_provider`. The owner is
  monitored: if it exits, the job is canceled.

  `opts`: `:tag` (required, one of `chat_tags/0`), `:origin` (default `:interactive`), `:chat_id`,
  `:label`, `:prompt_name` (the name of the prompt that built `input`), `:protected` (the build's
  `{secret, label, source}` triples, `Mythweaver.Sharing.Protected.pairs/1`, which `live_output/2`
  scrubs from the reasoning a viewer may not read; default `[]`), and per-job overrides of
  `tag_options/1`'s keys, which beat the model's own limits too.
  """
  def stream_async(%Scope{} = scope, %Model{} = model, input, owner, opts) when is_map(input) and is_pid(owner) do
    tag = Keyword.fetch!(opts, :tag)
    true = tag in @chat_tags

    job =
      insert!(%{
        tag: tag,
        origin: Keyword.get(opts, :origin, :interactive),
        label: Keyword.get(opts, :label) || to_string(tag),
        prompt_name: Keyword.get(opts, :prompt_name),
        chat_id: Keyword.get(opts, :chat_id),
        ai_model_id: model.id,
        user_id: Scope.initiator_id(scope)
      })

    ref = make_ref()
    ticket = ticket(scope, job, model, :stream, opts)

    :ok =
      Scheduler.submit(%{ticket | owner: owner, ref: ref, input: input, protected: Keyword.get(opts, :protected, [])})

    # After the submit, so a listener reading `queue_positions/1` on this broadcast finds the job.
    broadcast(job)
    {:ok, ref, job.id}
  end

  @doc """
  Queues one worker job, attributed to `scope`'s user. `attrs`: `:ai_model_id` (required), `:origin` (default `:background`),
  `:chat_id`, `:label`, `:params` (string keys), `:range_start`, `:range_end`, `:parent_id`.

  `{:ok, %Job{}}`, `{:error, :no_model}` when the model id resolves to nothing, or
  `{:error, :quota_exceeded}` when `scope` has spent its daily budget on the site's models.
  """
  def enqueue(%Scope{} = scope, tag, attrs) when tag in @worker_tags do
    attrs = Map.new(attrs)
    worker = worker_for(tag)

    with %Model{} = model <- (attrs[:ai_model_id] && AI.get_model(scope, attrs.ai_model_id)) || {:error, :no_model},
         :ok <- Quota.check_spend(scope, model, AI.run_owner(scope, attrs[:chat_id])) do
      job =
        attrs
        |> Map.take([:chat_id, :label, :params, :range_start, :range_end, :parent_id, :ai_model_id])
        |> Map.merge(%{tag: tag, origin: Map.get(attrs, :origin, :background), user_id: Scope.initiator_id(scope)})
        |> Map.put_new(:label, to_string(tag))
        |> insert!()

      :ok = Scheduler.submit(%{ticket(scope, job, model, :worker, []) | worker: worker})
      broadcast(job)
      {:ok, job}
    end
  end

  defp insert!(attrs) do
    %Job{} |> Job.create_changeset(Map.put(attrs, :status, :queued)) |> Repo.insert!()
  end

  defp ticket(scope, %Job{} = job, %Model{} = model, kind, opts) do
    options = limits(job.tag, model, opts)

    %Ticket{
      job_id: job.id,
      scope: scope,
      run_owner: AI.run_owner(scope, job.chat_id),
      tag: job.tag,
      origin: job.origin,
      chat_id: job.chat_id,
      model: model,
      kind: kind,
      # Neither a caption (a reply may wait on it) nor a classification queues behind a chat's memory jobs.
      lane: if(kind == :worker and job.tag not in [:caption, :expression], do: job.chat_id),
      deadline_ms: options[:deadline_ms],
      first_token_ms: options[:first_token_ms],
      idle_ms: options[:idle_ms],
      loop_guard?: options[:loop_guard],
      max_chars: options[:max_chars],
      audience: audience(job),
      callers: [self() | Process.get(:"$callers", [])]
    }
  end

  ## Controlling jobs

  @doc """
  Stops a job: drops it from the queue, kills it while running, or discards a `:review` result.
  `{:error, :not_found}` when there is nothing to stop.
  """
  @spec cancel(Scope.t(), Ecto.UUID.t()) :: :ok | {:error, :not_found | :unauthorized}
  def cancel(%Scope{} = scope, job_id) do
    with :ok <- authorize_id(scope, job_id), do: do_cancel(job_id)
  end

  defp do_cancel(job_id) do
    case Scheduler.cancel(job_id) do
      :ok ->
        :ok

      {:error, :not_found} ->
        canceled = dpgettext("jobs", "status: error text of a job canceled while it waited for review", "Canceled.")

        case update_where(job_id, [:review], %{status: :canceled, error: canceled}) do
          [_job] -> :ok
          [] -> {:error, :not_found}
        end
    end
  end

  @doc """
  Tells the scheduler a provider or link changed, so queued jobs are admitted again: one waiting
  on a full provider may now fit, and one whose model lost its last link fails `:no_provider`.
  """
  @spec providers_changed() :: :ok
  def providers_changed, do: Scheduler.reconsider()

  @doc """
  Cancels every queued and running job with one of `tags` (STMB's "stop"), only `chat_id`'s when
  that option is given. Returns how many it canceled. Raises `Mythweaver.UnauthorizedError` when
  `scope` may not act on that chat; without `:chat_id`, only the jobs `scope` may see are canceled.
  """
  def cancel_all(%Scope{} = scope, tags, opts \\ []) when is_list(tags) do
    if opts[:chat_id], do: authorize_chat!(scope, opts[:chat_id])

    from(j in Job, where: j.tag in ^tags and j.status in ^@active, select: j.id)
    |> filter(:chat_id, opts[:chat_id])
    |> visible_to(scope)
    |> Repo.all()
    |> Enum.count(&(do_cancel(&1) == :ok))
  end

  @doc """
  Runs a finished memory job again, with `params_overrides` merged into its params. Only memory tags
  in `#{inspect(@retryable)}` are retryable; a chat generation is retried by regenerating it.
  The resubmitted job is attributed to `scope`'s user, who initiated the retry, and a chat job runs
  as the chat's owner (`Mythweaver.Chats.run_scope/2`), a caption as `Mythweaver.Chats.spend_scope/2`'s. Its sources are read
  again first (`Worker.retry_params/3`), so a source that changed since the first run does not
  refuse every retry's save.
  """
  def retry(%Scope{} = scope, job_id, params_overrides \\ %{}) do
    with :ok <- authorize_id(scope, job_id),
         %Job{tag: tag, status: status} = job when tag in @worker_tags and status in @retryable <-
           get_job(scope, job_id),
         scope = retry_scope(scope, job),
         %Model{} = model <- (job.ai_model_id && AI.get_model(scope, job.ai_model_id)) || {:error, :no_model},
         :ok <- Quota.check_spend(scope, model, AI.run_owner(scope, job.chat_id)),
         [job] <-
           update_where(job.id, @retryable, %{
             status: :queued,
             attempts: job.attempts + 1,
             error: nil,
             result: nil,
             raw_output: nil,
             started_at: nil,
             finished_at: nil,
             first_token_at: nil,
             expected_first_token_ms: nil,
             prompt_name: nil,
             params:
               job.params
               |> Map.merge(Worker.retry_params(worker_for(job.tag), scope, job))
               |> Map.merge(params_overrides),
             user_id: Scope.initiator_id(scope)
           }) do
      :ok = Scheduler.submit(%{ticket(scope, job, model, :worker, []) | worker: worker_for(job.tag)})
      broadcast(job)
      {:ok, job}
    else
      {:error, :no_model} -> {:error, :no_model}
      {:error, :quota_exceeded} -> {:error, :quota_exceeded}
      {:error, :unauthorized} -> {:error, :unauthorized}
      _other -> {:error, :not_retryable}
    end
  end

  # A caption spends whoever `Chats.spend_scope/2` names; other chat jobs run as the chat's owner.
  defp retry_scope(scope, %Job{chat_id: nil}), do: scope
  defp retry_scope(scope, %Job{tag: :caption, chat_id: chat_id}), do: Chats.spend_scope(scope, chat_id)
  defp retry_scope(scope, %Job{chat_id: chat_id}), do: Chats.run_scope(scope, chat_id)

  @doc "Deletes a finished job's row. `{:error, :not_found}` unless it is in a terminal status."
  @spec dismiss(Scope.t(), Ecto.UUID.t()) :: {:ok, Job.t()} | {:error, :not_found | :unauthorized}
  def dismiss(%Scope{} = scope, job_id) do
    with :ok <- authorize_id(scope, job_id) do
      case get_job(scope, job_id) do
        %Job{status: status} = job when status in @terminal ->
          Repo.delete!(job)
          broadcast(job)
          {:ok, job}

        _other ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Dismisses every finished job `scope` may see, in one delete, broadcasting each. `opts` narrow it
  like `list_jobs/2`: `:chat_id`, `:statuses`, `:tags`. Returns how many it dismissed.
  """
  @spec dismiss_all(Scope.t(), keyword()) :: non_neg_integer()
  def dismiss_all(%Scope{} = scope, opts \\ []) do
    {count, jobs} =
      from(j in Job, where: j.status in ^@terminal, select: j)
      |> filter(:chat_id, opts[:chat_id])
      |> filter(:statuses, opts[:statuses])
      |> filter(:tags, opts[:tags])
      |> visible_to(scope)
      |> Repo.delete_all()

    Enum.each(jobs, &broadcast/1)
    count
  end

  ## Reading jobs

  @doc "One job with its chat and provider, or nil (an invalid id, or one `scope` may not act on, included)."
  def get_job(%Scope{} = scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Job{} = job <- Repo.get(Job, id),
         :ok <- authorize(scope, job) do
      Repo.preload(job, [:chat, :provider])
    else
      _missing -> nil
    end
  end

  @doc """
  What running `job` has received so far (`Mythweaver.Jobs.LiveOutput`): its reply and reasoning
  text, in arrival order. nil once it is not running, or when `scope` may not act on it. The
  reasoning has the job's share-protected values replaced by their labels, and its site-protected
  ones too for a scope lacking `site.hidden.view` (`Mythweaver.Sharing.Protected.hidden_pairs/2`);
  the reply text is unchanged. `job` is a row the caller already holds (the Jobs page's stream
  row); its initiator is authorized without a query, anyone else through `Chats.authorize/3`.
  """
  @spec live_output(Scope.t(), Job.t()) :: %{content: String.t(), reasoning: String.t()} | nil
  def live_output(%Scope{} = scope, %Job{id: id} = job) do
    with :ok <- authorize(scope, job),
         %{} = output <- LiveOutput.read(id) do
      {protected, output} = Map.pop(output, :protected)
      pairs = Protected.hidden_pairs(protected, Visibility.view_hidden?(scope))
      %{output | reasoning: Protected.scrub(output.reasoning, pairs)}
    else
      _missing -> nil
    end
  end

  @doc "The scope of the user who started `job`, or nil when there is none (deleted user)."
  @spec initiator_scope(Job.t()) :: Scope.t() | nil
  def initiator_scope(%Job{user_id: nil}), do: nil
  def initiator_scope(%Job{user_id: id}), do: id |> Mythweaver.Accounts.get_user() |> Scope.for_user()

  @doc """
  The scope `job`'s work runs as: for a chat job, its chat owner's carrying the initiator
  (`Mythweaver.Chats.run_scope/2`), so a member's caption or classification reads the owner's
  models and settings; otherwise `initiator_scope/1`. nil when the initiator is gone.
  """
  @spec run_scope(Job.t()) :: Scope.t() | nil
  def run_scope(%Job{chat_id: chat_id} = job) do
    with %Scope{} = scope <- initiator_scope(job),
         do: if(chat_id, do: Chats.run_scope(scope, chat_id), else: scope)
  end

  @doc """
  The scope whose models, keys and quota `job` spends: for a chat caption, the initiator's
  `Mythweaver.Chats.spend_scope/2` (their own for an `:own` member); otherwise `run_scope/1`.
  nil when the initiator is gone.
  """
  @spec spend_scope(Job.t()) :: Scope.t() | nil
  def spend_scope(%Job{tag: :caption, chat_id: chat_id} = job) when is_binary(chat_id) do
    with %Scope{} = scope <- initiator_scope(job), do: Chats.spend_scope(scope, chat_id)
  end

  def spend_scope(%Job{} = job), do: run_scope(job)

  @doc """
  `:ok` for the job's initiator while they are still the chat's owner or an accepted member, or
  whoever may inspect its chat (`Chats.authorize/3`'s `:inspect`: its owner and chat editors). A
  chat-less job is its initiator's alone.
  """
  @spec authorize(Scope.t(), Job.t()) :: :ok | {:error, :unauthorized}
  def authorize(%Scope{user: %{id: id}}, %Job{user_id: id, chat_id: nil}), do: :ok

  def authorize(%Scope{user: %{id: id}} = scope, %Job{user_id: id, chat_id: chat_id}),
    do: if(Chats.role(scope, chat_id), do: :ok, else: {:error, :unauthorized})

  def authorize(%Scope{}, %Job{chat_id: nil}), do: {:error, :unauthorized}
  def authorize(%Scope{} = scope, %Job{chat_id: chat_id}), do: Chats.authorize(scope, chat_id, :inspect)

  # `authorize/2` by id. A missing job passes, so the caller reports `:not_found` as before.
  defp authorize_id(scope, job_id) do
    with {:ok, id} <- Ecto.UUID.cast(job_id),
         %Job{} = job <- Repo.get(Job, id) do
      authorize(scope, job)
    else
      _missing -> :ok
    end
  end

  defp authorize_chat!(scope, chat_id) do
    if Chats.authorize(scope, chat_id, :inspect) != :ok, do: raise(Mythweaver.UnauthorizedError)
  end

  # Everyone, admins included, sees the jobs on chats they own and the jobs they started, a chat's
  # only while they are still an accepted member of it.
  defp visible_to(query, %Scope{user: nil}), do: where(query, false)

  defp visible_to(query, %Scope{user: %{id: uid}}) do
    owned = from(c in Chat, where: c.user_id == ^uid, select: c.id)
    member = from(m in Member, where: m.user_id == ^uid and m.status == :accepted, select: m.chat_id)

    where(
      query,
      [j],
      j.chat_id in subquery(owned) or
        (j.user_id == ^uid and (is_nil(j.chat_id) or j.chat_id in subquery(member)))
    )
  end

  @doc """
  The newest 200 jobs `scope` may see. `opts`: `:chat_id` (every job of that chat, `[]` unless
  `scope` may inspect it), `:statuses`, `:tags`.
  """
  def list_jobs(%Scope{} = scope, opts \\ []) do
    chat_id = opts[:chat_id]

    if chat_id && Chats.authorize(scope, chat_id, :inspect) != :ok do
      []
    else
      Job
      |> filter(:chat_id, chat_id)
      |> then(&if(chat_id, do: &1, else: visible_to(&1, scope)))
      |> filter(:statuses, opts[:statuses])
      |> filter(:tags, opts[:tags])
      |> order_by([j], desc: j.inserted_at)
      |> limit(200)
      |> preload([:chat, :provider])
      |> Repo.all()
    end
  end

  defp filter(query, _key, nil), do: query
  defp filter(query, :chat_id, chat_id), do: where(query, [j], j.chat_id == ^chat_id)
  defp filter(query, :statuses, statuses), do: where(query, [j], j.status in ^statuses)
  defp filter(query, :tags, tags), do: where(query, [j], j.tag in ^tags)

  @doc "The chat's jobs that still need something: queued, running, or awaiting review."
  def active_count(%Scope{} = scope, chat_id) do
    authorize_chat!(scope, chat_id)
    Repo.aggregate(from(j in Job, where: j.chat_id == ^chat_id and j.status in ^@open), :count)
  end

  @doc "`active_count/2` for every chat with such jobs `scope` may see: `%{chat_id => count}`."
  def active_counts(%Scope{} = scope) do
    from(j in Job,
      where: not is_nil(j.chat_id) and j.status in ^@open,
      group_by: j.chat_id,
      select: {j.chat_id, count()}
    )
    |> visible_to(scope)
    |> Repo.all()
    |> Map.new()
  end

  @doc "The chat's memory jobs awaiting review."
  def review_count(%Scope{} = scope, chat_id) do
    authorize_chat!(scope, chat_id)

    Repo.aggregate(
      from(j in Job, where: j.chat_id == ^chat_id and j.status == :review and j.tag in ^@memory_tags),
      :count
    )
  end

  @doc "One user's job topic: every event for the jobs they started or whose chat they own."
  def topic(user_id), do: "user:#{user_id}:jobs"

  @doc "Subscribes the caller to the scope user's `topic/1`."
  def subscribe(%Scope{user: %{id: user_id}}), do: Phoenix.PubSub.subscribe(Mythweaver.PubSub, topic(user_id))

  @doc """
  The users told about `job`: its initiator and its chat's owner, without duplicates or nils.
  """
  @spec audience(Job.t()) :: [Ecto.UUID.t()]
  def audience(%Job{user_id: user_id, chat_id: chat_id}) do
    owner = chat_id && Chats.owner_id(chat_id)
    Enum.uniq(for id <- [user_id, owner], id != nil, do: id)
  end

  @doc """
  Every queued job's 1-based position in the scheduler's global admission order:
  `%{job_id => position}`, keeping only the jobs `scope` may see.
  """
  @spec queue_positions(Scope.t()) :: %{Ecto.UUID.t() => pos_integer()}
  def queue_positions(%Scope{} = scope) do
    positions = Scheduler.status().queued |> Enum.with_index(1) |> Map.new()

    if positions == %{} do
      positions
    else
      ids = Map.keys(positions)
      visible = from(j in Job, where: j.id in ^ids, select: j.id) |> visible_to(scope) |> Repo.all()
      Map.take(positions, visible)
    end
  end

  @history_size 20
  @history_min 3

  @doc """
  How long `prompt_tokens` should take to reach the first token, in ms, judged from the last
  #{@history_size} completed jobs with the same provider, model and tag: their median
  ms-per-prompt-token times `prompt_tokens`. `nil` with fewer than #{@history_min} usable jobs or no
  prompt tokens.
  """
  @spec expected_first_token_ms(Ecto.UUID.t(), Ecto.UUID.t(), atom(), non_neg_integer()) :: non_neg_integer() | nil
  def expected_first_token_ms(provider_id, model_id, tag, prompt_tokens) when prompt_tokens > 0 do
    rates =
      from(j in Job,
        where:
          j.provider_id == ^provider_id and j.ai_model_id == ^model_id and j.tag == ^tag and
            j.status in [:completed, :review] and not is_nil(j.started_at) and not is_nil(j.first_token_at),
        order_by: [desc: j.started_at],
        limit: @history_size,
        select: {j.started_at, j.first_token_at, j.usage}
      )
      |> Repo.all()
      |> Enum.flat_map(fn
        {started, first, %{"prompt_tokens" => tokens}} when is_integer(tokens) and tokens > 0 ->
          [DateTime.diff(first, started, :millisecond) / tokens]

        _row ->
          []
      end)

    if length(rates) >= @history_min, do: round(median(rates) * prompt_tokens)
  end

  def expected_first_token_ms(_provider_id, _model_id, _tag, _prompt_tokens), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    mid = div(count, 2)

    if rem(count, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  ## Row writes (scheduler and runner)

  @doc false
  def mark_running(job_id, provider_id) do
    update_where(job_id, [:queued], %{status: :running, started_at: DateTime.utc_now(), provider_id: provider_id})
    :ok
  end

  @doc false
  # Written once per job: a repair retry's first token leaves the original time.
  def mark_first_token(job_id) do
    now = DateTime.utc_now()

    {_count, jobs} =
      from(j in Job, where: j.id == ^job_id and j.status == :running and is_nil(j.first_token_at), select: j)
      |> Repo.update_all(set: [first_token_at: now, updated_at: now])

    Enum.each(jobs, &broadcast/1)
  end

  @doc false
  def put_expected_first_token(job_id, ms) do
    update_where(job_id, [:running], %{expected_first_token_ms: ms})
    :ok
  end

  @doc false
  # The runner's write once a worker has built its request. A retry clears it, so a rebuild that
  # fails before naming a prompt does not show the previous run's.
  def put_prompt_name(_job_id, nil), do: :ok

  def put_prompt_name(job_id, name) do
    update_where(job_id, [:running], %{prompt_name: name})
    :ok
  end

  @doc """
  Broadcasts a running job's live progress as `{:job_progress, payload}` to `audience` (the
  ticket's, so a tick reads no row). The payload:

      %{id: Ecto.UUID.t(), chat_id: Ecto.UUID.t() | nil, tokens: non_neg_integer() | nil,
        tokens_per_second: float() | nil, prompt: %{done: non_neg_integer(), total: non_neg_integer()} | nil}

  `tokens` is the estimated output so far, `prompt` the backend's prompt-processing report.
  """
  def broadcast_progress(audience, %{id: _, chat_id: _, tokens: _, tokens_per_second: _, prompt: _} = payload) do
    send_to(audience, {:job_progress, payload})
  end

  @doc false
  # The scheduler's queue announcement: `user_id`'s own queued jobs and their global positions.
  def broadcast_queue(user_id, positions), do: send_to([user_id], {:job_queue, positions})

  @doc false
  # The runner's write. Only a row still queued or running is touched, so a job the scheduler already
  # stopped keeps its stop reason. A memory draft parked for review notifies its initiator.
  def finish(job_id, status, attrs) do
    job_id
    |> end_run(Map.put(attrs, :status, status))
    |> Enum.each(fn
      %Job{status: :review, tag: tag} = job when tag in @memory_tags -> Notifications.memory_review(job)
      _job -> :ok
    end)
  end

  @doc false
  # The scheduler's write when it stops a job (cancel, deadline, token watchdog, guard, crash); never
  # overwrites a row the runner already finished. The runner never reaches its own failure path for
  # a stopped job, so the worker's `failed/1` runs here instead, in its own task: this runs inside
  # the scheduler, and a hook may call back into it (`Jobs.cancel/2`).
  def finish_by_scheduler(job_id, status, error) do
    job_id
    |> end_run(%{status: status, error: error})
    |> Enum.each(fn job -> Task.Supervisor.start_child(__MODULE__.TaskSupervisor, fn -> run_failed_hook(job) end) end)
  end

  # Ends a queued or running job's run. Every write that ends one (this, a worker's save in
  # `complete_in_transaction/2`, `interrupt_stale/0`) records its `Mythweaver.Analytics` stat
  # before broadcasting, so whoever hears the job finish can already read the stat.
  defp end_run(job_id, attrs) do
    jobs = update_rows(job_id, @active, Map.put(attrs, :finished_at, DateTime.utc_now()))
    Analytics.record_runs(jobs)
    Enum.each(jobs, &broadcast/1)
    jobs
  end

  @doc """
  Runs `fun` in one transaction that also completes `job`. The job row is locked first and must still
  be `job.status` (`:running` for a worker's own save, `:review` for an approval), else
  `{:error, :not_found}` and `fun` never runs. `fun` returns `{value, result}`; the row becomes
  `:completed` with `result` and `finished_at` in the same transaction, and `{:job_changed, …}` is
  broadcast after commit. `Repo.rollback/1` inside `fun` aborts both.
  """
  @spec complete_in_transaction(Job.t(), (-> {term(), map()})) :: {:ok, term()} | {:error, term()}
  def complete_in_transaction(%Job{id: id, status: status}, fun) when status in [:running, :review] do
    result =
      Repo.transaction(fn ->
        Repo.one(from(j in Job, where: j.id == ^id and j.status == ^status, lock: "FOR UPDATE", select: j.id)) ||
          Repo.rollback(:not_found)

        {value, result} = fun.()
        now = DateTime.utc_now()

        {1, [job]} =
          Repo.update_all(from(j in Job, where: j.id == ^id, select: j),
            set: [status: :completed, result: result, finished_at: now, updated_at: now]
          )

        # A worker's own save ends its run; an approval only resolves a run already recorded as
        # `:review`.
        if status == :running, do: Analytics.record_runs([job])

        {value, job}
      end)

    with {:ok, {value, job}} <- result do
      broadcast(job)
      {:ok, value}
    end
  end

  def complete_in_transaction(%Job{}, _fun), do: {:error, :not_found}

  @doc "Inside a transaction: replaces a `:review` job's result with `fun.(result)`; rolls back `:changed` unless the job is still in review."
  def update_review_result(job_id, fun) do
    job =
      Repo.one(from(j in Job, where: j.id == ^job_id and j.status == :review, lock: "FOR UPDATE")) ||
        Repo.rollback(:changed)

    job |> Ecto.Changeset.change(result: fun.(job.result)) |> Repo.update!()
  end

  @doc false
  # The runner's write of a worker's raw reply, before the worker saves it: no status filter, no
  # broadcast.
  def put_output(job_id, %AI.Completion{} = completion) do
    from(j in Job, where: j.id == ^job_id)
    |> Repo.update_all(set: [raw_output: completion.text, usage: completion.raw, updated_at: DateTime.utc_now()])

    :ok
  end

  @doc """
  Closes a `:review` job as `:canceled` (its draft discarded) with `attrs`. `{:error, :not_found}`
  unless the job is still in review. An approval completes the job through
  `complete_in_transaction/2` instead.
  """
  def resolve_review(job_id, status, attrs \\ %{}) when status == :canceled do
    job_id
    |> update_where([:review], Map.merge(attrs, %{status: status, finished_at: DateTime.utc_now()}))
    |> only_job()
  end

  @doc """
  Puts a `:failed` job back in `:review` with a hand-corrected `result` and `raw_output`.
  `{:error, :not_found}` unless the job is still failed.
  """
  def reopen_for_review(job_id, result, raw_output) do
    job_id
    |> update_where([:failed], %{status: :review, result: result, raw_output: raw_output, error: nil, finished_at: nil})
    |> only_job()
  end

  defp only_job([job]), do: {:ok, job}
  defp only_job([]), do: {:error, :not_found}

  @doc """
  Marks every job left queued or running by a previous boot `:interrupted`, and runs each worker
  job's `failed/1`, so what it was holding (a caption's `:pending` image) is released.
  """
  def interrupt_stale do
    now = DateTime.utc_now()

    {_count, jobs} =
      from(j in Job, where: j.status in ^@active, select: j)
      |> Repo.update_all(
        set: [
          status: :interrupted,
          error: dpgettext("jobs", "status: error text of a job cut off by a server restart", "Interrupted."),
          finished_at: now,
          updated_at: now
        ]
      )

    Analytics.record_runs(jobs)

    Enum.each(jobs, fn job ->
      broadcast(job)
      run_failed_hook(job)
    end)
  end

  # `job` carries its terminal status (`:canceled`, `:failed`, `:interrupted`), so a worker can tell
  # a person's cancel from a failure.
  defp run_failed_hook(%Job{tag: tag} = job) when tag in @worker_tags, do: Worker.run_failed(worker_for(tag), job)

  defp run_failed_hook(_job), do: :ok

  @doc "Deletes finished chat generations older than a day and other finished jobs older than 30 days."
  def prune do
    now = DateTime.utc_now()
    day_ago = DateTime.add(now, -1, :day)
    month_ago = DateTime.add(now, -30, :day)

    from(j in Job,
      where: j.status in ^@terminal,
      where:
        (j.tag in ^@chat_tags and j.updated_at < ^day_ago) or
          (j.tag not in ^@chat_tags and j.updated_at < ^month_ago)
    )
    |> Repo.delete_all()

    :ok
  end

  defp update_where(job_id, statuses, attrs) do
    jobs = update_rows(job_id, statuses, attrs)
    Enum.each(jobs, &broadcast/1)
    jobs
  end

  defp update_rows(job_id, statuses, attrs) do
    attrs = Map.put(attrs, :updated_at, DateTime.utc_now())

    {_count, jobs} =
      from(j in Job, where: j.id == ^job_id and j.status in ^statuses, select: j)
      |> Repo.update_all(set: Enum.to_list(attrs))

    jobs
  end

  defp broadcast(%Job{} = job) do
    if job.status != :review and job.tag in @memory_tags, do: Notifications.clear_review(job.id)
    send_to(audience(job), {:job_changed, %{id: job.id, chat_id: job.chat_id, tag: job.tag, status: job.status}})
  end

  defp send_to(user_ids, message) do
    Enum.each(user_ids, &Phoenix.PubSub.broadcast(Mythweaver.PubSub, topic(&1), message))
  end

  @doc "A short, human sentence for a job's failure reason."
  def error_message(:canceled), do: dpgettext("jobs", "status: error text of a job that was stopped", "Stopped.")
  def error_message(:timeout), do: dpgettext("jobs", "status: error text of a job that timed out", "Timed out.")

  def error_message(:no_tokens), do: dgettext("jobs", "Stopped: no tokens arrived before the first-token timeout.")

  def error_message(:stalled), do: dgettext("jobs", "Stopped: the stream went silent.")
  def error_message({:guard, :repetition}), do: dgettext("jobs", "Stopped: the model kept repeating itself.")
  def error_message({:guard, :output_cap}), do: dgettext("jobs", "Stopped: the reply exceeded the output cap.")
  def error_message(:no_provider), do: dgettext("jobs", "No enabled connection serves this model.")

  def error_message({:owner_key_withdrawn, model}),
    do: dgettext("jobs", "The owner no longer shares their connection for %{model_name}.", model_name: model)

  def error_message(:quota_exceeded), do: dgettext("jobs", "Today's AI budget is spent.")

  def error_message({:http_error, status, body}) do
    case http_detail(body) do
      nil ->
        dgettext("jobs", "The connection returned HTTP %{http_status}.", http_status: status)

      detail ->
        gettext_comment("The provider's own error text (English, verbatim) follows the colon.")

        dgettext("jobs", "The connection returned HTTP %{http_status}: %{provider_error}",
          http_status: status,
          provider_error: detail
        )
    end
  end

  def error_message({:transport_error, _reason}), do: dgettext("jobs", "Could not reach the connection.")

  def error_message({:exception, message}) do
    gettext_comment("The crash's technical error text (English, verbatim) follows the colon.")

    dpgettext("jobs", "status: error text of a job that crashed", "Generation crashed: %{error_detail}",
      error_detail: message
    )
  end

  def error_message(:changed), do: dgettext("jobs", "Not saved: the source changed after this was queued.")
  def error_message(:not_found), do: dgettext("jobs", "Not saved: the job was no longer running.")
  def error_message(:no_initiator), do: dgettext("jobs", "The user who started this job no longer exists.")
  def error_message(:no_text), do: dgettext("jobs", "The document has no readable text to summarize.")

  def error_message(other) do
    gettext_comment("An internal error term (Elixir syntax, verbatim) follows the colon.")

    dpgettext(
      "jobs",
      "status: error text of a job that failed with an internal error",
      "Generation failed: %{error_detail}",
      error_detail: inspect(other)
    )
  end

  @http_detail_max 300

  # The provider's own explanation: an OpenAI-style `error.message` (plus OpenRouter's upstream
  # `error.metadata.raw` when it adds one), else a bare `error`, `message` or `detail` string, else
  # the raw text. An HTML error page says nothing useful and is dropped.
  defp http_detail(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> http_detail(decoded)
      _not_json -> if !String.starts_with?(String.trim_leading(body), "<"), do: clip(body)
    end
  end

  defp http_detail(%{"error" => %{"message" => message} = error}) when is_binary(message) do
    raw =
      case error["metadata"] do
        %{"raw" => raw} -> raw
        _other -> nil
      end

    parts = for text <- [message, raw], is_binary(text), text = String.trim(text), text != "", uniq: true, do: text
    parts |> Enum.join(" — ") |> clip()
  end

  defp http_detail(%{"error" => message}) when is_binary(message), do: clip(message)
  defp http_detail(%{"message" => message}) when is_binary(message), do: clip(message)
  defp http_detail(%{"detail" => message}) when is_binary(message), do: clip(message)
  defp http_detail(_body), do: nil

  defp clip(text) do
    text = String.trim(text)

    cond do
      text == "" -> nil
      String.length(text) > @http_detail_max -> String.slice(text, 0, @http_detail_max) <> "…"
      true -> text
    end
  end
end
