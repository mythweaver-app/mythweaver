defmodule MythweaverWeb.JobLiveTest do
  # Not `async: true`: jobs run in scheduler-spawned tasks, which need the shared sandbox and shared
  # `Req.Test` stubs.
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Request.Message
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Jobs.LiveOutput
  alias Mythweaver.Jobs.Scheduler

  @input %{messages: [%Message{role: :user, content: "ping"}]}

  setup :register_and_log_in_user

  setup %{scope: scope} = context do
    Req.Test.set_req_test_to_shared(context)
    on_exit(fn -> await_idle(100) end)
    :ok = Jobs.subscribe(scope)
    :ok
  end

  defp await_idle(0) do
    %{running: running, queued: queued} = Scheduler.status()
    Enum.each(running ++ queued, &Scheduler.cancel/1)
  end

  defp await_idle(tries) do
    case Scheduler.status() do
      %{running: [], queued: []} -> :ok
      _busy -> Process.sleep(10) && await_idle(tries - 1)
    end
  end

  # The first request reports in and never answers, holding the provider's only slot.
  defp hanging_stub do
    test = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      send(test, :request_hanging)
      Process.sleep(:infinity)
      conn
    end)
  end

  defp model!(scope, linked?) do
    {:ok, model} =
      AI.create_model(scope, %{name: "Gemma-#{System.unique_integer([:positive])}", api_model_id: "gemma-4"})

    if linked? do
      {:ok, provider} =
        AI.create_provider(scope, %{
          name: "Local-#{System.unique_integer([:positive])}",
          adapter: :openai_compatible,
          base_url: "http://localhost:8080/v1"
        })

      {:ok, _link} = AI.link_model(scope, provider, model)
    end

    model
  end

  defp stream!(scope, model, label, opts \\ []) do
    {:ok, _ref, job_id} = Jobs.stream_async(scope, model, @input, self(), [tag: :reply, label: label] ++ opts)
    job_id
  end

  defp chat!(scope, user) do
    [player, bot] =
      for name <- ["Geralt", "Ciri"] do
        {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{System.unique_integer([:positive])}"})
        character
      end

    {:ok, chat} =
      Chats.create_chat(Scope.for_user(user), %{
        name: "chat-#{System.unique_integer([:positive])}",
        participants: [%{character_id: player.id}, %{character_id: bot.id}],
        player_character_id: player.id
      })

    chat
  end

  test "rows render and a queued job can be canceled", %{scope: scope, conn: conn} do
    hanging_stub()
    model = model!(scope, true)
    running = stream!(scope, model, "Reply — First")
    assert_receive :request_hanging
    queued = stream!(scope, model, "Reply — Second")

    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#jobs-#{queued}", "Reply — Second")
    assert has_element?(view, "#jobs-#{queued} .jobs-status", "Pending")
    assert has_element?(view, "#job-progress-#{running}[data-status='running']")
    assert has_element?(view, "#job-progress-#{queued}[data-status='queued'][data-position='1']")

    view |> element("#job-cancel-#{queued}") |> render_click()

    assert_receive {:job_changed, %{id: ^queued, status: :canceled}}
    assert has_element?(view, "#jobs-#{queued} .jobs-status", "Canceled")
  end

  test "a failed job can be dismissed", %{scope: scope, conn: conn} do
    failed = stream!(scope, model!(scope, false), "Reply — Nowhere")
    assert_receive {:job_changed, %{id: ^failed, status: :failed}}

    {:ok, view, _html} = live(conn, ~p"/jobs")
    assert has_element?(view, "#jobs-#{failed} .jobs-status", "Failed")

    view |> element("#job-dismiss-#{failed}") |> render_click()

    refute has_element?(view, "#jobs-#{failed}")
    assert Jobs.get_job(scope, failed) == nil
  end

  test "a job names the prompt that built it", %{scope: scope, conn: conn} do
    named = stream!(scope, model!(scope, false), "Reply — Named", prompt_name: "Story prompt")
    plain = stream!(scope, model!(scope, false), "Reply — Plain")
    assert_receive {:job_changed, %{id: ^named, status: :failed}}
    assert_receive {:job_changed, %{id: ^plain, status: :failed}}

    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#job-prompt-#{named}", "Story prompt")
    refute has_element?(view, "#job-prompt-#{plain}")
  end

  test "Dismiss all removes finished jobs and keeps active ones", %{scope: scope, conn: conn} do
    failed = stream!(scope, model!(scope, false), "Reply — Nowhere")
    assert_receive {:job_changed, %{id: ^failed, status: :failed}}
    hanging_stub()
    running = stream!(scope, model!(scope, true), "Reply — Busy")
    assert_receive :request_hanging

    {:ok, view, _html} = live(conn, ~p"/jobs")

    view |> element("#jobs-dismiss-all") |> render_click()

    refute has_element?(view, "#jobs-#{failed}")
    assert has_element?(view, "#jobs-#{running}")
    refute has_element?(view, "#jobs-dismiss-all")
    assert Jobs.get_job(scope, failed) == nil
  end

  test "a chat's scope lists only its jobs and Stop all stops only those", %{scope: scope, conn: conn, user: user} do
    hanging_stub()
    model = model!(scope, true)
    [busy, idle] = [chat!(scope, user), chat!(scope, user)]
    running = stream!(scope, model, "Reply — Busy", chat_id: busy.id)
    assert_receive :request_hanging
    queued = stream!(scope, model, "Reply — Idle", chat_id: idle.id)

    {:ok, view, _html} = live(conn, ~p"/jobs?chat=#{idle.id}")

    assert has_element?(view, "#job-chats-#{idle.id} a[aria-current='page']")
    assert has_element?(view, "#jobs-#{queued}")
    refute has_element?(view, "#jobs-#{running}")

    view |> element("#jobs-stop-all") |> render_click()

    assert_receive {:job_changed, %{id: ^queued, status: :canceled}}
    assert Jobs.get_job(scope, running).status == :running
  end

  test "the status filter and the memory-only toggle narrow the list", %{scope: scope, conn: conn} do
    # Failed first: while a provider is full, a model with no link waits instead of failing.
    failed = stream!(scope, model!(scope, false), "Reply — Nowhere")
    assert_receive {:job_changed, %{id: ^failed, status: :failed}}
    hanging_stub()
    model = model!(scope, true)
    running = stream!(scope, model, "Reply — Running")
    assert_receive :request_hanging

    {:ok, view, _html} = live(conn, ~p"/jobs")
    assert has_element?(view, "#jobs-#{running}")

    view |> form("#jobs-filter-form", filter: %{status: "failed"}) |> render_change()

    assert_patch(view, "/jobs?status=failed")
    assert has_element?(view, "#jobs-#{failed}")
    refute has_element?(view, "#jobs-#{running}")

    view |> element("#jobs-kind-memory") |> render_click()

    assert_patch(view, "/jobs?kind=memory&status=failed")
    refute has_element?(view, "#jobs-#{failed}")
    assert has_element?(view, "#jobs-empty")
  end

  test "a failed memory's raw output can be corrected into a review", %{scope: scope, conn: conn, user: user} do
    model = model!(scope, true)
    {:ok, prompt} = Mythweaver.Prompts.create_prompt(scope, %{name: "Memory: Test", purpose: :memory})

    {:ok, block} =
      Mythweaver.Prompts.create_block(scope, %{name: "Scene", role: :user, content: "{{ anchors.memory.scene }}"})

    {:ok, _} = Mythweaver.Prompts.add_block(scope, prompt, block)

    {:ok, profile} =
      Mythweaver.Memory.create_profile(scope, %{name: "Default", ai_model_id: model.id, memory_prompt_id: prompt.id})

    {:ok, _} = Mythweaver.Memory.set_default_profile(scope, profile)

    chat = Chats.get_chat!(chat!(scope, user).id)

    for text <- ["One", "Two"],
        do: {:ok, _} = Mythweaver.Messages.send_message(scope, chat, chat.player_character_id, text)

    Req.Test.stub(Mythweaver.AI, fn conn ->
      frame = Jason.encode!(%{choices: [%{index: 0, delta: %{content: "not json"}, finish_reason: nil}]})
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, "data: #{frame}\n\ndata: [DONE]\n\n")
      conn
    end)

    {:ok, job} = Mythweaver.Memory.create_memory(scope, chat, 0, 1, review: false)
    id = job.id
    assert_receive {:job_changed, %{id: ^id, status: :failed}}, 2_000

    {:ok, view, _html} = live(conn, ~p"/jobs")
    view |> element("#job-raw-#{id}") |> render_click()

    corrected = ~s({"title": "Fixed", "content": "They met.", "keywords": ["inn"]})

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> form("#job-correct-form-#{id}", correct: %{text: corrected}) |> render_submit()

    assert to == ~p"/chats/#{chat.id}/memory?tab=reviews"
    assert %{status: :review, result: %{"title" => "Fixed"}} = Jobs.get_job(scope, id)
  end

  # The test process stands in for the runner: it owns the job's buffer, as a runner task would.
  test "a running job's live output shows the text received so far, refreshed, until it ends",
       %{scope: scope, conn: conn} do
    job =
      Mythweaver.Repo.insert!(%Job{
        tag: :memory,
        origin: :interactive,
        status: :running,
        label: "Stuck memory",
        user_id: scope.user.id
      })

    buffer = LiveOutput.open(job.id)
    LiveOutput.append(buffer, :reasoning, "Thinking")
    LiveOutput.append(buffer, :delta, "Hel")

    {:ok, view, _html} = live(conn, ~p"/jobs")
    view |> element("#job-live-#{job.id}") |> render_click()

    assert has_element?(view, "#job-live-output-#{job.id}-reasoning", "Thinking")
    assert has_element?(view, "#job-live-output-#{job.id}-content", "Hel")

    LiveOutput.append(buffer, :delta, "lo")
    send(view.pid, :refresh_live)
    # The tick's `send_update/2` is a message to the LiveView itself: let it queue before rendering.
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#job-live-output-#{job.id}-content", "Hello")

    Jobs.finish(job.id, :completed, %{})
    refute has_element?(view, "#job-live-output-#{job.id}")
    refute has_element?(view, "#job-live-#{job.id}")
  end
end
