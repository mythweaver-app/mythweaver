defmodule Mythweaver.JobsTest do
  # Not `async: true`: queued work runs in scheduler-spawned tasks and generation servers, which need
  # the shared sandbox and shared `Req.Test` stubs.
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Completion
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.AI.Request
  alias Mythweaver.AI.StreamEvent
  alias Mythweaver.Analytics.GenerationStat
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Generation
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Jobs.LiveOutput
  alias Mythweaver.Jobs.Scheduler
  alias Mythweaver.Messages
  alias Mythweaver.Prompts

  @chat_frames [
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}],"model":"/models/gemma-4.gguf"}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":"The"}}]}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"po"}}]}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"ng"}}]}\n\n),
    ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
    ~s(data: {"choices":[],"usage":{"completion_tokens":31,"prompt_tokens":18,"total_tokens":49}}\n\n),
    "data: [DONE]\n\n"
  ]

  @input %{messages: [%Request.Message{role: :user, content: "ping"}]}

  setup context do
    Req.Test.set_req_test_to_shared(context)
    # Runs before the sandbox owner stops: every job this test started finishes its row writes (or is
    # canceled) while the connection is still there.
    earlier = scheduled_ids()
    on_exit(fn -> await_idle(earlier, 100) end)
    %{scope: scope!()}
  end

  defp scheduled_ids do
    %{running: running, queued: queued} = Scheduler.status()
    running ++ queued
  end

  defp await_idle(earlier, 0), do: Enum.each(scheduled_ids() -- earlier, &Scheduler.cancel/1)

  defp await_idle(earlier, tries) do
    if scheduled_ids() -- earlier == [] do
      :ok
    else
      Process.sleep(10)
      await_idle(earlier, tries - 1)
    end
  end

  defp send_frames(conn, frames) do
    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce(frames, conn, fn frame, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, frame)
      conn
    end)
  end

  defp stub_chat_stream, do: Req.Test.stub(Mythweaver.AI, &send_frames(&1, @chat_frames))

  defp session_stub do
    test_pid = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      send(test_pid, {:session, Plug.Conn.get_req_header(conn, "x-session-id")})
      send_frames(conn, @chat_frames)
    end)
  end

  # Each request reports `{:blocked, pid}` and waits for `:release` before answering.
  defp blocking_stub do
    test = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      send(test, {:blocked, self()})

      receive do
        :release -> send_frames(conn, @chat_frames)
      end
    end)
  end

  # Kills land mid-request only after the request is out: killing a task still holding the shared
  # sandbox connection would break the test's connection.
  defp hanging_stub do
    test = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      send(test, :request_hanging)
      Process.sleep(:infinity)
      conn
    end)
  end

  defp provider!(scope, attrs \\ %{}) do
    {:ok, provider} =
      AI.create_provider(
        scope,
        Map.merge(
          %{
            name: "Local-#{System.unique_integer([:positive])}",
            adapter: :openai_compatible,
            base_url: "http://localhost:8080/v1"
          },
          attrs
        )
      )

    provider
  end

  defp model!(scope) do
    {:ok, model} =
      AI.create_model(scope, %{name: "Gemma-#{System.unique_integer([:positive])}", api_model_id: "gemma-4"})

    model
  end

  defp linked_model!(scope, provider_attrs \\ %{}) do
    model = model!(scope)
    {:ok, _link} = AI.link_model(scope, provider!(scope, provider_attrs), model)
    model
  end

  defp stream!(scope, model, opts \\ []) do
    {:ok, ref, job_id} = Jobs.stream_async(scope, model, @input, self(), Keyword.put_new(opts, :tag, :reply))
    {ref, job_id}
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{System.unique_integer([:positive])}"})
    character
  end

  defp chat!(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{System.unique_integer([:positive])}",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end

  defp global_prompt!(scope) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Prompt-#{System.unique_integer([:positive])}"})

    {:ok, block} =
      Prompts.create_block(scope, %{name: "Sys-#{System.unique_integer([:positive])}", content: "Be brief."})

    {:ok, _} = Prompts.add_block(scope, prompt, block)
    {:ok, _binding} = Prompts.bind_prompt(scope, prompt, :global)
    prompt
  end

  # A call into the scheduler returns only after it has handled everything sent to it before, so the
  # row write that follows a stop has happened.
  defp settled_job(job_id) do
    Scheduler.status()
    Repo.get!(Job, job_id)
  end

  describe "limits/3" do
    test "a model's chat limits apply to chat tags only" do
      model = %Model{chat_first_token_seconds: 30}

      assert Jobs.limits(:reply, model)[:first_token_ms] == 30_000
      assert Jobs.limits(:memory, model)[:first_token_ms] == 300_000
    end

    test "0 lifts a limit and a blank field keeps the tag's default" do
      assert Jobs.limits(:caption, %Model{background_deadline_seconds: 0})[:deadline_ms] == nil
      assert Jobs.limits(:caption, %Model{})[:deadline_ms] == 600_000
    end

    test "per-job overrides beat the model's" do
      model = %Model{chat_first_token_seconds: 30}

      assert Jobs.limits(:reply, model, first_token_ms: 50)[:first_token_ms] == 50
    end
  end

  describe "stream_async/5" do
    test "delivers deltas and the terminal result to the owner and completes the row", %{scope: scope} do
      stub_chat_stream()
      :ok = Jobs.subscribe(scope)
      model = linked_model!(scope)

      {ref, job_id} = stream!(scope, model, label: "Reply — Bot")

      assert_receive {:ai_stream, ^ref, %StreamEvent.Request{}}
      assert_receive {:ai_stream, ^ref, %StreamEvent.Reasoning{text: "The"}}
      assert_receive {:ai_stream, ^ref, %StreamEvent.Delta{text: "po"}}
      assert_receive {:ai_stream, ^ref, %StreamEvent.Done{finish_reason: "stop"}}
      assert_receive {:ai_stream, ^ref, {:ok, %Completion{} = completion, %ProviderModel{} = link}}
      assert completion.text == "pong"
      assert link.use_count == 1

      assert_receive {:job_changed, %{id: ^job_id, status: :completed}}

      assert %Job{tag: :reply, origin: :interactive, status: :completed, label: "Reply — Bot"} =
               job = settled_job(job_id)

      assert job.provider_id == link.provider_id
      assert job.user_id == scope.user.id
      assert %DateTime{} = job.started_at
      assert %DateTime{} = job.finished_at
    end

    test "a chat-bound job sends <user id>:<chat id> as its session id", %{scope: scope} do
      session_stub()
      chat = chat!(scope, [character!(scope, "Player"), character!(scope, "Bot")])

      {ref, _job_id} = stream!(scope, linked_model!(scope), chat_id: chat.id)

      assert_receive {:ai_stream, ^ref, {:ok, _completion, _link}}
      assert_received {:session, [session]}
      assert session == "#{scope.user.id}:#{chat.id}"
    end

    test "a job without a chat sends no session id", %{scope: scope} do
      session_stub()

      {ref, _job_id} = stream!(scope, linked_model!(scope))

      assert_receive {:ai_stream, ^ref, {:ok, _completion, _link}}
      assert_received {:session, []}
    end

    test "reports a selection refusal as the terminal message", %{scope: scope} do
      {ref, job_id} = stream!(scope, model!(scope))

      assert_receive {:ai_stream, ^ref, {:error, :no_provider}}
      assert %Job{status: :failed} = settled_job(job_id)
    end

    test "reports a task that exits as a terminal error", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, fn _conn -> exit(:boom) end)

      {ref, _job_id} = stream!(scope, linked_model!(scope))

      assert_receive {:ai_stream, ^ref, {:error, {:exception, _message}}}
    end
  end

  describe "who hears about a job" do
    # Another user's topic, forwarded to the test as `{:other, message}`.
    defp listen_as!(scope) do
      test = self()

      spawn_link(fn ->
        :ok = Jobs.subscribe(scope)
        send(test, :listening)
        forward(test)
      end)

      assert_receive :listening
    end

    defp forward(test) do
      receive do
        message -> send(test, {:other, message})
      end

      forward(test)
    end

    test "status and progress reach the starter, never another user", %{scope: scope} do
      stub_chat_stream()
      :ok = Jobs.subscribe(scope)
      listen_as!(scope!(%{role: :user}))

      {_ref, job_id} = stream!(scope, linked_model!(scope))

      assert_receive {:job_progress, %{id: ^job_id}}
      assert_receive {:job_changed, %{id: ^job_id, status: :completed}}
      refute_receive {:other, _message}, 100
    end

    test "a queue move tells each user only their own positions", %{scope: admin} do
      hanging_stub()
      # A site model, so the other user runs it too; one slot, so later jobs queue.
      model = linked_model!(admin, %{max_concurrency: 1})
      user = scope!(%{role: :user})
      :ok = Jobs.subscribe(admin)
      listen_as!(user)

      {_ref, running} = stream!(admin, model)
      assert_receive :request_hanging

      {_ref, background} = stream!(user, model, origin: :background)
      assert_receive {:other, {:job_queue, positions}}
      assert positions == %{background => 1}

      # Interactive work goes first, pushing the user's job back without naming the admin's.
      {_ref, interactive} = stream!(admin, model)
      assert_receive {:other, {:job_queue, positions}}
      assert positions == %{background => 2}
      assert_receive {:job_queue, %{^interactive => 1} = mine}
      refute Map.has_key?(mine, background)
      refute_received {:other, {:job_changed, %{id: ^interactive}}}

      # Queued first, so the freed slot admits nothing; each cancel's row write lands before exit.
      for id <- [interactive, background, running], do: :ok = Scheduler.cancel(id)
      assert_receive {:job_changed, %{id: ^running, status: :canceled}}
    end
  end

  describe "progress" do
    test "the first token stamps the row and progress reports output tokens", %{scope: scope} do
      stub_chat_stream()
      :ok = Jobs.subscribe(scope)

      {ref, job_id} = stream!(scope, linked_model!(scope))

      assert_receive {:job_progress, %{id: ^job_id, tokens: tokens, prompt: nil}}
      assert tokens > 0
      assert_receive {:ai_stream, ^ref, {:ok, %Completion{}, _link}}
      assert %Job{first_token_at: %DateTime{}} = settled_job(job_id)
    end

    test "prompt progress reaches listeners and never the owner", %{scope: scope} do
      progress =
        ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}],"prompt_progress":{"total":4096,"cache":1024,"processed":2048,"time_ms":10}}\n\n)

      Req.Test.stub(Mythweaver.AI, &send_frames(&1, [progress | @chat_frames]))
      :ok = Jobs.subscribe(scope)

      {ref, job_id} = stream!(scope, linked_model!(scope))

      assert_receive {:job_progress, %{id: ^job_id, prompt: %{done: 1024, total: 3072}}}
      assert_receive {:ai_stream, ^ref, {:ok, %Completion{}, _link}}
      refute_received {:ai_stream, ^ref, %StreamEvent.PromptProgress{}}
    end

    test "the time to first token is estimated from the connection's history", %{scope: scope} do
      stub_chat_stream()
      provider = provider!(scope)
      model = model!(scope)
      {:ok, _link} = AI.link_model(scope, provider, model)
      # 1000 ms over 100 prompt tokens: 10 ms a token.
      for _ <- 1..3, do: history_job!(provider, model)

      {ref, job_id} = stream!(scope, model)

      assert_receive {:ai_stream, ^ref, {:ok, %Completion{}, _link}}
      # "ping" is 2 estimated tokens: the model has no tokenizer.
      assert %Job{expected_first_token_ms: 20} = settled_job(job_id)
    end

    test "fewer than three past jobs give no estimate", %{scope: scope} do
      stub_chat_stream()
      provider = provider!(scope)
      model = model!(scope)
      {:ok, _link} = AI.link_model(scope, provider, model)
      for _ <- 1..2, do: history_job!(provider, model)

      {ref, job_id} = stream!(scope, model)

      assert_receive {:ai_stream, ^ref, {:ok, %Completion{}, _link}}
      assert %Job{expected_first_token_ms: nil} = settled_job(job_id)
    end

    test "retry/3 clears the progress fields", %{scope: scope} do
      job =
        Repo.insert!(%Job{
          tag: :memory,
          origin: :background,
          label: "memory",
          status: :failed,
          ai_model_id: model!(scope).id,
          user_id: scope.user.id,
          params: %{},
          first_token_at: DateTime.utc_now(),
          expected_first_token_ms: 500
        })

      assert {:ok, %Job{first_token_at: nil, expected_first_token_ms: nil}} = Jobs.retry(scope, job.id)
    end
  end

  defp history_job!(provider, model) do
    started = DateTime.utc_now()

    Repo.insert!(%Job{
      tag: :reply,
      origin: :interactive,
      label: "reply",
      status: :completed,
      provider_id: provider.id,
      ai_model_id: model.id,
      started_at: started,
      first_token_at: DateTime.add(started, 1000, :millisecond),
      usage: %{"prompt_tokens" => 100}
    })
  end

  describe "admission" do
    test "a provider with max_concurrency 1 runs one job; the next waits for it", %{scope: scope} do
      blocking_stub()
      model = linked_model!(scope)

      {ref1, job1} = stream!(scope, model)
      {ref2, job2} = stream!(scope, model)

      assert_receive {:blocked, first}
      refute_receive {:blocked, _second}, 100
      assert Scheduler.status() == %{running: [job1], queued: [job2]}

      send(first, :release)
      assert_receive {:ai_stream, ^ref1, {:ok, _completion, _link}}

      assert_receive {:blocked, second}
      send(second, :release)
      assert_receive {:ai_stream, ^ref2, {:ok, _completion, _link}}
    end

    test "a waiting job costs no queries until something changes, and a raised limit admits it", %{scope: scope} do
      blocking_stub()
      model = linked_model!(scope)
      {ref1, _job1} = stream!(scope, model)
      {ref2, job2} = stream!(scope, model)
      assert_receive {:blocked, first}

      test = self()
      scheduler = Process.whereis(Scheduler)
      handler = "scheduler-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:mythweaver, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == scheduler, do: send(test, {:scheduler_query, meta.source})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # Many watchdog ticks (10 ms in test) pass while job2 waits on the full provider.
      refute_receive {:scheduler_query, _source}, 200
      assert %{queued: [^job2]} = Scheduler.status()

      # A second slot, with the first job still running, is enough to start job2.
      [provider] =
        Repo.all(from(p in AI.Provider, join: pm in assoc(p, :provider_models), where: pm.ai_model_id == ^model.id))

      {:ok, _} = AI.update_provider(scope, provider, %{max_concurrency: 2})
      assert_receive {:blocked, second}

      send(first, :release)
      send(second, :release)
      assert_receive {:ai_stream, ^ref1, {:ok, _completion, _link}}
      assert_receive {:ai_stream, ^ref2, {:ok, _completion, _link}}
    end

    test "max_concurrency 2 runs both at once", %{scope: scope} do
      blocking_stub()
      model = linked_model!(scope, %{max_concurrency: 2})

      {ref1, _job1} = stream!(scope, model)
      {ref2, _job2} = stream!(scope, model)

      assert_receive {:blocked, first}
      assert_receive {:blocked, second}

      send(first, :release)
      send(second, :release)
      assert_receive {:ai_stream, ^ref1, {:ok, _completion, _link}}
      assert_receive {:ai_stream, ^ref2, {:ok, _completion, _link}}
    end

    test "interactive work queued behind a running job is admitted before earlier background work", %{scope: scope} do
      blocking_stub()
      model = linked_model!(scope)

      {_ref, _running} = stream!(scope, model)
      assert_receive {:blocked, first}

      {_ref, background} = stream!(scope, model, origin: :background)
      {_ref, interactive} = stream!(scope, model)
      assert Scheduler.status().queued == [interactive, background]

      send(first, :release)
      assert_receive {:blocked, next}
      assert Scheduler.status() == %{running: [interactive], queued: [background]}

      send(next, :release)
      assert_receive {:blocked, last}
      send(last, :release)
    end
  end

  describe "stops" do
    test "a wall-clock deadline fails the job with :timeout", %{scope: scope} do
      hanging_stub()

      {ref, job_id} = stream!(scope, linked_model!(scope), deadline_ms: 50)

      assert_receive :request_hanging
      assert_receive {:ai_stream, ^ref, {:error, :timeout}}, 1_000
      assert %Job{status: :failed, error: "Timed out."} = settled_job(job_id)
      assert Scheduler.status() == %{running: [], queued: []}
    end

    test "a looping stream trips the repetition guard", %{scope: scope} do
      frame = ~s(data: {"choices":[{"index":0,"delta":{"content":"the same line again. "}}]}\n\n)
      Req.Test.stub(Mythweaver.AI, &send_frames(&1, List.duplicate(frame, 200)))

      {ref, job_id} = stream!(scope, linked_model!(scope), loop_guard: true)

      assert_receive {:ai_stream, ^ref, {:error, {:guard, :repetition}}}, 1_000
      refute_received {:ai_stream, ^ref, {:ok, _completion, _link}}
      assert %Job{status: :failed, error: "Stopped: the model kept repeating itself."} = settled_job(job_id)
    end

    test "no first token within first_token_ms stops the job with :no_tokens", %{scope: scope} do
      hanging_stub()

      {ref, job_id} = stream!(scope, linked_model!(scope), first_token_ms: 50)

      assert_receive :request_hanging
      assert_receive {:ai_stream, ^ref, {:error, :no_tokens}}, 1_000
      assert %Job{status: :failed} = settled_job(job_id)
    end

    test "the model's chat first-token limit stops a reply with :no_tokens", %{scope: scope} do
      model = linked_model!(scope)
      {:ok, model} = AI.update_model(scope, model, %{chat_first_token_seconds: 1})
      hanging_stub()

      {ref, job_id} = stream!(scope, model)

      assert_receive :request_hanging
      assert_receive {:ai_stream, ^ref, {:error, :no_tokens}}, 3_000
      assert %Job{status: :failed} = settled_job(job_id)
    end

    # A real server (Bandit), since `Req.Test` hands over a stub's chunks only once the plug returns:
    # the delta must reach the runner, and the watchdog, before the silence.
    test "silence after a streamed token for idle_ms stops the job with :stalled", %{scope: scope} do
      req_options = Application.get_env(:mythweaver, :ai_req_options)
      Application.put_env(:mythweaver, :ai_req_options, [])
      on_exit(fn -> Application.put_env(:mythweaver, :ai_req_options, req_options) end)

      pid =
        start_supervised!(
          {Bandit, plug: {Mythweaver.StallingPlug, test: self()}, port: 0, ip: :loopback, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      model = linked_model!(scope, %{base_url: "http://127.0.0.1:#{port}/v1"})

      {ref, job_id} = stream!(scope, model, first_token_ms: 60_000, idle_ms: 50)

      assert_receive {:chunk_sent, handler}, 1_000
      assert_receive {:ai_stream, ^ref, %StreamEvent.Delta{text: "Hi"}}, 1_000
      assert_receive {:ai_stream, ^ref, {:error, :stalled}}, 1_000
      assert %Job{status: :failed, error: "Stopped: the stream went silent."} = settled_job(job_id)
      send(handler, :release)
    end

    test "an owner that exits cancels its job", %{scope: scope} do
      hanging_stub()
      model = linked_model!(scope)
      test = self()
      :ok = Jobs.subscribe(scope)

      owner =
        spawn(fn ->
          {:ok, _ref, job_id} = Jobs.stream_async(scope, model, @input, self(), tag: :reply)
          send(test, {:job, job_id})
          Process.sleep(:infinity)
        end)

      assert_receive {:job, job_id}
      assert_receive :request_hanging
      Process.exit(owner, :kill)

      assert_receive {:job_changed, %{id: ^job_id, status: :canceled}}
      assert Scheduler.status() == %{running: [], queued: []}
    end

    test "cancel/2 stops a running job and refuses an unknown one", %{scope: scope} do
      hanging_stub()

      {ref, job_id} = stream!(scope, linked_model!(scope))
      assert_receive :request_hanging

      assert Jobs.cancel(scope, job_id) == :ok
      assert_receive {:ai_stream, ^ref, {:error, :canceled}}
      assert %Job{status: :canceled, error: "Stopped."} = Repo.get!(Job, job_id)
      assert Jobs.cancel(scope, job_id) == {:error, :not_found}
    end

    test "a finished run leaves a stat that outlives its job row", %{scope: scope} do
      stub_chat_stream()
      model = linked_model!(scope)

      {ref, job_id} = stream!(scope, model)
      assert_receive {:ai_stream, ^ref, {:ok, _completion, link}}
      settled_job(job_id)
      assert {:ok, _job} = Jobs.dismiss(scope, job_id)

      assert [stat] = Repo.all(GenerationStat)

      assert %GenerationStat{
               job_id: ^job_id,
               status: :completed,
               tag: :reply,
               prompt_tokens: 18,
               completion_tokens: 31,
               cost: nil
             } = stat

      assert stat.user_id == scope.user.id
      assert stat.ai_model_id == model.id
      assert stat.provider_id == link.provider_id
      assert %DateTime{} = stat.first_token_at
    end

    test "a stopped run is recorded once, as canceled", %{scope: scope} do
      hanging_stub()

      {ref, job_id} = stream!(scope, linked_model!(scope))
      assert_receive :request_hanging
      :ok = Jobs.cancel(scope, job_id)
      assert_receive {:ai_stream, ^ref, {:error, :canceled}}
      settled_job(job_id)

      assert [%GenerationStat{job_id: ^job_id, status: :canceled, prompt_tokens: nil}] = Repo.all(GenerationStat)
    end
  end

  describe "get_job/2" do
    test "returns the job to its initiator and nil to a scope that may not act on it", %{scope: scope} do
      {_ref, job_id} = stream!(scope, model!(scope))
      job = settled_job(job_id)

      assert Jobs.get_job(%Scope{}, job.id) == nil
      assert %Job{id: ^job_id} = Jobs.get_job(Jobs.initiator_scope(job), job.id)
    end

    test "a chat-less job is its starter's alone, even against another admin", %{scope: scope} do
      job =
        scope
        |> provider!()
        |> history_job!(model!(scope))
        |> Ecto.Changeset.change(user_id: scope.user.id)
        |> Repo.update!()

      other_admin = scope!()

      assert Jobs.authorize(other_admin, job) == {:error, :unauthorized}
      assert Jobs.get_job(other_admin, job.id) == nil
      assert Jobs.authorize(scope, job) == :ok
      assert %Job{} = Jobs.get_job(scope, job.id)
    end

    test "a chat job's initiator loses it once removed from the chat", %{scope: scope} do
      chat = chat!(scope, [character!(scope, "P"), character!(scope, "B")])
      editor = scope!(%{role: :user})
      {:ok, member} = Chats.invite(scope, chat, editor.user.handle, :editor)
      {:ok, _} = Chats.accept_invite(editor, member.id)

      job =
        scope
        |> provider!()
        |> history_job!(model!(scope))
        |> Ecto.Changeset.change(user_id: editor.user.id, chat_id: chat.id)
        |> Repo.update!()

      assert Jobs.authorize(editor, job) == :ok
      assert job.id in Enum.map(Jobs.list_jobs(editor), & &1.id)

      assert {:ok, _} = Chats.remove_member(scope, member.id)

      assert Jobs.authorize(editor, job) == {:error, :unauthorized}
      refute job.id in Enum.map(Jobs.list_jobs(editor), & &1.id)
      assert Jobs.get_job(editor, job.id) == nil
      assert Jobs.retry(editor, job.id) == {:error, :unauthorized}
    end
  end

  describe "live_output/2" do
    @secret "the riddle answer is fog"
    @label "[Hidden: Sphinx's description]"

    # The test process stands in for the runner: it owns the job's buffer, as a runner task would.
    test "scrubs the reasoning's protected values for a scope lacking site.hidden.view only" do
      plain = scope!(%{role: :user})
      viewer = %{plain | permissions: Map.put(plain.permissions, "site.hidden.view", true)}

      job =
        Repo.insert!(%Job{
          tag: :memory,
          origin: :interactive,
          status: :running,
          label: "Memory",
          user_id: plain.user.id
        })

      buffer = LiveOutput.open(job.id, [{@secret, @label, :site}])
      LiveOutput.append(buffer, :reasoning, "Recall: #{@secret}.")
      LiveOutput.append(buffer, :delta, "Says #{@secret}")

      assert Jobs.live_output(plain, job) == %{reasoning: "Recall: #{@label}.", content: "Says #{@secret}"}
      assert Jobs.live_output(viewer, job) == %{reasoning: "Recall: #{@secret}.", content: "Says #{@secret}"}
    end

    test "scrubs a share pair even for a site.hidden.view holder" do
      plain = scope!(%{role: :user})
      viewer = %{plain | permissions: Map.put(plain.permissions, "site.hidden.view", true)}

      job =
        Repo.insert!(%Job{
          tag: :memory,
          origin: :interactive,
          status: :running,
          label: "Memory",
          user_id: plain.user.id
        })

      buffer = LiveOutput.open(job.id, [{@secret, @label, :share}, {"site text", "[Site]", :site}])
      LiveOutput.append(buffer, :reasoning, "Recall: #{@secret}, site text.")

      assert Jobs.live_output(viewer, job).reasoning == "Recall: #{@label}, site text."
      assert Jobs.live_output(plain, job).reasoning == "Recall: #{@label}, [Site]."
    end

    test "stream_async/5's :protected reaches the running job's buffer", %{scope: scope} do
      blocking_stub()
      {_ref, job_id} = stream!(scope, linked_model!(scope), protected: [{@secret, @label, :site}])

      assert_receive {:blocked, pid}
      assert %{protected: [{@secret, @label, :site}]} = LiveOutput.read(job_id)
      send(pid, :release)
    end
  end

  describe "dismiss_all/2" do
    test "deletes the scope's finished jobs only, leaving active ones and other users'", %{scope: scope} do
      {_ref, failed} = stream!(scope, model!(scope))
      settled_job(failed)
      other = scope!()
      {_ref, others} = stream!(other, model!(other))
      settled_job(others)
      hanging_stub()
      {_ref, running} = stream!(scope, linked_model!(scope))
      assert_receive :request_hanging

      assert Jobs.dismiss_all(scope) == 1
      assert Repo.get(Job, failed) == nil
      assert %Job{status: :running} = Repo.get(Job, running)
      assert %Job{} = Repo.get(Job, others)
    end
  end

  describe "chat generations" do
    setup %{scope: scope} do
      player = character!(scope, "Player")
      bot = character!(scope, "Bot")
      chat = chat!(scope, [player, bot])
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()
      :ok = Messages.subscribe(chat)
      :ok = Jobs.subscribe(scope)

      %{chat: chat, bot: bot}
    end

    test "a regenerate and a continue are tagged as such", %{scope: scope, chat: chat, bot: bot} do
      {:ok, original} = Messages.send_message(scope, chat, bot.id, "first take")

      assert :ok = Generation.regenerate(scope, chat, original)
      assert_receive {:generation_finished, _message_id}

      assert :ok = Generation.continue(scope, chat, Messages.get_message!(scope, original.id))
      assert_receive {:generation_finished, _message_id}

      assert_receive {:job_changed, %{tag: :regenerate, status: :completed}}
      assert_receive {:job_changed, %{tag: :continue, status: :completed}}
      jobs = Jobs.list_jobs(scope, chat_id: chat.id)

      assert jobs |> Enum.map(& &1.tag) |> Enum.sort() == [:continue, :regenerate]
      assert Enum.all?(jobs, &(&1.status == :completed))
      assert Enum.find(jobs, &(&1.tag == :regenerate)).label == "Regenerate — #{bot.name}"
    end

    test "a new reply is tagged :reply", %{scope: scope, chat: chat, bot: bot} do
      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:generation_finished, _message_id}

      assert [%Job{tag: :reply, label: label}] = Jobs.list_jobs(scope, chat_id: chat.id)
      assert label == "Reply — #{bot.name}"
    end
  end

  test "AI.test_link/2 bypasses the queue and writes no job row", %{scope: scope} do
    Req.Test.stub(Mythweaver.AI, fn conn ->
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "Hello!"}, "finish_reason" => "stop"}]})
    end)

    {:ok, link} = AI.link_model(scope, provider!(scope), model!(scope))

    assert {:ok, %Completion{text: "Hello!"}} = AI.test_link(scope, AI.get_link(link.id))
    assert Repo.aggregate(Job, :count) == 0
  end
end
