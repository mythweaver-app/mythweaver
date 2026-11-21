defmodule Mythweaver.Memory.SceneTest do
  # Not `async: true`: memory jobs run in scheduler-spawned tasks, which need the shared sandbox and
  # shared `Req.Test` stubs.
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Jobs.Scheduler
  alias Mythweaver.Lore
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Record
  alias Mythweaver.Messages
  alias Mythweaver.Notifications
  alias Mythweaver.Notifications.Notification
  alias Mythweaver.Prompts

  @memory ~s({"title": "Title", "content": "They met at the inn.", "keywords": ["inn", "meeting"]})

  setup context do
    scope = scope!()
    Req.Test.set_req_test_to_shared(context)
    on_exit(fn -> await_idle(100) end)
    :ok = Jobs.subscribe(scope)

    player = character!(scope, "Player")
    responder = character!(scope, "Responder")
    model = linked_model!(scope)
    profile = profile!(scope, model)
    chat = chat!(scope, [player, responder])

    %{scope: scope, player: player, responder: responder, model: model, profile: profile, chat: chat}
  end

  defp await_idle(0) do
    %{running: running, queued: queued} = Scheduler.status()
    Enum.each(running ++ queued, &Scheduler.cancel/1)
  end

  defp await_idle(tries) do
    case Scheduler.status() do
      %{running: [], queued: []} ->
        :ok

      _busy ->
        Process.sleep(10)
        await_idle(tries - 1)
    end
  end

  describe "create_memory/4" do
    test "saves an entry in an auto-created book bound to the chat", %{scope: scope, chat: chat} = ctx do
      messages!(ctx, 6)
      stub_reply(@memory)

      assert {:ok, job} = Memory.create_memory(scope, chat, 0, 4, review: false)
      assert %Job{status: :completed, result: %{"record_id" => record_id}} = await_job(scope, job)

      record = Repo.get!(Record, record_id) |> Repo.preload(:entry)
      assert %Record{kind: :memory, tier: 0, sequence: 1, range_start: 0, range_end: 4} = record
      assert record.entry.name == "[001] - Title"
      assert record.entry.content == "They met at the inn."
      assert record.entry.keywords == ["inn", "meeting"]

      settings = Memory.chat_settings(scope, chat)
      assert settings.highest_processed == 4
      assert settings.memory_book_id == record.lore_book_id
      assert record.lore_book_id in Lore.chat_book_ids(chat)
      assert Lore.get_book!(record.lore_book_id).name == "Memory chat Memories"
    end

    test "repairs fenced JSON with a trailing comma", %{scope: scope, chat: chat} = ctx do
      messages!(ctx, 2)
      stub_reply(~s(Sure:\n```json\n{"title": "Fenced", "content": "C", "keywords": ["a",],}\n```))

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
      assert %Job{status: :completed, result: %{"record_id" => id}} = await_job(scope, job)
      assert Repo.get!(Record, id) |> Repo.preload(:entry) |> then(& &1.entry.name) == "[001] - Fenced"
    end

    test "fails with the raw output after a second invalid reply", %{scope: scope, chat: chat} = ctx do
      messages!(ctx, 2)
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, Jason.decode!(body)})
        reply(conn, "not json at all")
      end)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
      assert %Job{status: :failed, raw_output: "not json at all"} = await_job(scope, job)

      assert_received {:request, first}
      assert_received {:request, second}
      assert length(second["messages"]) == length(first["messages"]) + 1
      assert List.last(second["messages"])["content"] =~ "not valid JSON"
    end

    test "a reply with its keywords outside the JSON object is retried, not saved without them",
         %{scope: scope, chat: chat} = ctx do
      messages!(ctx, 2)
      test = self()
      {:ok, replies} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, Jason.decode!(body)})

        case Agent.get_and_update(replies, &{&1, &1 + 1}) do
          0 -> reply(conn, ~s({"title": "T", "content": "C"}\n\n**Keywords**: ["inn"]))
          _ -> reply(conn, ~s({"title": "T", "content": "C", "keywords": ["inn"]}))
        end
      end)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
      assert %Job{status: :completed, result: %{"record_id" => id}} = await_job(scope, job)
      assert Repo.get!(Record, id) |> Repo.preload(:entry) |> then(& &1.entry.keywords) == ["inn"]

      assert_received {:request, _first}
      assert_received {:request, second}
      assert List.last(second["messages"])["content"] =~ "every required field"
    end

    test "a correction that is still not JSON leaves the job failed", %{scope: scope, chat: chat} = ctx do
      messages!(ctx, 2)
      stub_reply("not json at all")

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
      assert %Job{status: :failed} = job = await_job(scope, job)

      assert Memory.correct(scope, job, "still not json") == {:error, :unparseable}
      assert Jobs.get_job(scope, job.id).status == :failed
    end

    test "review leaves a draft that approve saves with the edits", %{scope: scope, chat: chat} = ctx do
      messages!(ctx, 2)
      stub_reply(@memory)
      :ok = Mythweaver.Notifications.subscribe(scope)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: true)

      assert %Job{status: :review, result: %{"title" => "Title", "content" => _, "keywords" => _}} =
               job = await_job(scope, job)

      chat_id = chat.id

      assert_receive {Mythweaver.Notifications, :in_app,
                      %{kind: :memory_review, chat_id: ^chat_id, title: "Memory to review — " <> _, body: body}, _}

      assert body == "#{job.label} is waiting for your review."

      assert {:ok, record} = Memory.approve(scope, job, %{job.result | "title" => "Edited"})
      assert Lore.get_entry!(record.lore_entry_id).name == "[001] - Edited"
      assert Jobs.get_job(scope, job.id).status == :completed
      # Approving is the user's own act: nothing more to tell them.
      refute_receive {Mythweaver.Notifications, _, _, _}, 100
    end

    test "a memory saved without review sends no notification", %{scope: scope, chat: chat} = ctx do
      messages!(ctx, 2)
      stub_reply(@memory)
      :ok = Mythweaver.Notifications.subscribe(scope)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
      assert %Job{status: :completed} = await_job(scope, job)
      refute_receive {Mythweaver.Notifications, _, _, _}, 100
    end

    test "refuses an overlapping range and asks to confirm a large prompt", %{scope: scope, chat: chat} = ctx do
      messages!(ctx, 4, String.duplicate("word ", 1000))
      stub_reply(@memory)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false, confirm_tokens: true)
      assert %Job{status: :completed} = await_job(scope, job)
      assert Memory.create_memory(scope, chat, 1, 2) == {:error, :overlap}

      :ok = Mythweaver.Settings.put(scope, :site, "memory.token_warning_threshold", 1000)
      assert {:confirm, tokens} = Memory.create_memory(scope, chat, 2, 3)
      assert tokens > 1000
    end

    test "filters a character-aware entry to the scene's speakers",
         %{scope: scope, chat: chat, responder: responder} = ctx do
      messages!(ctx, 2)
      stub_reply(@memory)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
      %Job{result: %{"record_id" => id}} = await_job(scope, job)

      entry = Lore.get_entry!(Repo.get!(Record, id).lore_entry_id)
      assert entry.character_filter_mode == :include
      assert Enum.map(entry.filter_characters, & &1.id) == [responder.id]
    end

    test "a participant override replaces detected speakers",
         %{scope: scope, player: player, responder: responder} = ctx do
      other = character!(scope, "Other")
      chat = chat!(scope, [player, responder, other])
      messages!(%{ctx | chat: chat}, 2)
      stub_reply(@memory)

      stranger = character!(scope, "Stranger")
      assert Memory.create_memory(scope, chat, 0, 1, participant_ids: [stranger.id]) == {:error, :invalid_participants}

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false, participant_ids: [player.id, other.id])
      %Job{status: :completed, result: %{"record_id" => id}} = await_job(scope, job)

      record = Repo.get!(Record, id)
      entry = Lore.get_entry!(record.lore_entry_id)
      assert Enum.map(entry.filter_characters, & &1.id) |> Enum.sort() == Enum.sort([player.id, other.id])
      assert record.snapshot["participant_ids"] == [player.id, other.id]
    end

    test "a scene with two speakers uses the group prompt",
         %{scope: scope, player: player, responder: responder} = ctx do
      {:ok, group} = Prompts.create_prompt(scope, %{name: "Memory: Group test", purpose: :memory})
      {:ok, block} = Prompts.create_block(scope, %{name: "Group", content: "GROUP PROMPT"})

      {:ok, scene} =
        Prompts.create_block(scope, %{name: "Group scene", role: :user, content: "{{ anchors.memory.scene }}"})

      {:ok, _} = Prompts.add_block(scope, group, block)
      {:ok, _} = Prompts.add_block(scope, group, scene)
      {:ok, _} = Memory.update_profile(scope, ctx.profile, %{group_memory_prompt_id: group.id})

      other = character!(scope, "Other")
      chat = chat!(scope, [player, responder, other])
      {:ok, _} = Messages.send_message(scope, chat, responder.id, "Hello")
      {:ok, _} = Messages.send_message(scope, chat, player.id, "Hi")
      {:ok, _} = Messages.send_message(scope, chat, other.id, "Hey")
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, body})
        reply(conn, @memory)
      end)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: true)
      %Job{status: :review} = await_job(scope, job)
      assert_received {:request, solo}
      refute solo =~ "GROUP PROMPT"

      {:ok, job} = Memory.create_memory(scope, chat, 0, 2, review: true)
      %Job{status: :review} = await_job(scope, job)
      assert_received {:request, pair}
      assert pair =~ "GROUP PROMPT"
    end

    @tag :capture_log
    test "a rejected response_format is retried once without it", %{scope: scope, chat: chat, profile: profile} = ctx do
      {:ok, _} = Memory.update_profile(scope, profile, %{structured_output: true})
      messages!(ctx, 2)
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(body)
        send(test, {:request, body})

        if Map.has_key?(body, "response_format"),
          do: Plug.Conn.send_resp(conn, 400, ~s({"error":{"message":"response_format json_schema is not supported"}})),
          else: reply(conn, @memory)
      end)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
      assert %Job{status: :completed} = await_job(scope, job)

      assert_received {:request, first}
      assert_received {:request, second}
      refute_received {:request, _third}
      assert Map.has_key?(first, "response_format")
      refute Map.has_key?(second, "response_format")
    end

    test "a profile max_tokens of 0 leaves the model's own response limit",
         %{scope: scope, chat: chat, model: model, profile: profile} = ctx do
      {:ok, _} = AI.update_model(scope, model, %{sampler: %{max_tokens: 777}})
      {:ok, _} = Memory.update_profile(scope, profile, %{max_tokens: 0})
      messages!(ctx, 2)
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, Jason.decode!(body)})
        reply(conn, @memory)
      end)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
      assert %Job{status: :completed} = await_job(scope, job)
      assert_received {:request, body}
      assert body["max_tokens"] == 777
    end

    test "a response limit past the model's context window is cut to what fits",
         %{scope: scope, chat: chat, model: model, profile: profile} = ctx do
      {:ok, _} = AI.update_model(scope, model, %{context_window: 4000})
      {:ok, _} = Memory.update_profile(scope, profile, %{max_tokens: 40_000})
      messages!(ctx, 2)
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, Jason.decode!(body)})
        reply(conn, @memory)
      end)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
      assert %Job{status: :completed} = await_job(scope, job)
      assert_received {:request, body}
      assert body["max_tokens"] > 0
      assert body["max_tokens"] <= 4000 - 128
    end

    test "an HTTP error keeps the provider's message", %{scope: scope, chat: chat} = ctx do
      messages!(ctx, 2)

      Req.Test.stub(Mythweaver.AI, fn conn ->
        Plug.Conn.send_resp(
          conn,
          400,
          ~s({"error":{"message":"This endpoint's maximum context length is 32768 tokens.","code":400}})
        )
      end)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)

      assert %Job{
               status: :failed,
               error: "The connection returned HTTP 400: This endpoint's maximum context length is 32768 tokens."
             } = await_job(scope, job)
    end
  end

  test "auto-hide :all leaves the newest unhidden", %{scope: scope, chat: chat} = ctx do
    messages = messages!(ctx, 4)

    {:ok, _} =
      Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), %{auto_hide: :all, leave_unhidden: 1})

    stub_reply(@memory)

    {:ok, job} = Memory.create_memory(scope, chat, 0, 2, review: false)
    %Job{status: :completed} = await_job(scope, job)
    # Auto-hide runs after the save commits, which is when the job reports completed.
    await_idle(100)

    assert Enum.map(messages, &Messages.get_message!(scope, &1.id).visible_to_ai) == [false, false, true, true]
  end

  test "automatic memories fire past the interval plus buffer", %{scope: scope, chat: chat} = ctx do
    {:ok, _} =
      Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), %{
        auto_enabled: true,
        auto_interval: 5,
        auto_buffer: 2
      })

    stub_reply(@memory)
    messages!(ctx, 6)
    assert Repo.all(Job) == []

    messages!(ctx, 1)
    assert [%Job{tag: :memory, origin: :background, range_start: 0, range_end: 4}] = Repo.all(Job)
  end

  test "a chat's blank automatic-memory settings follow memory.auto_*", %{scope: scope, chat: chat} = ctx do
    messages!(ctx, 6)

    {:ok, settings} =
      Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), %{auto_enabled: true})

    assert %{auto_trigger: nil, auto_interval: nil, auto_buffer: nil, auto_token_threshold: nil} = settings
    stub_reply(@memory)
    # The defaults: 30 messages past a buffer of 2.
    assert Memory.Auto.check(scope, chat.id) == :waiting

    :ok = Mythweaver.Settings.put(scope, :user, "memory.auto_interval", 5)
    :ok = Mythweaver.Settings.put(scope, :user, "memory.auto_buffer", 1)

    assert Memory.auto_settings(scope, settings) ==
             %{auto_trigger: :messages, auto_interval: 5, auto_buffer: 1, auto_token_threshold: 8000}

    assert Memory.Auto.check(scope, chat.id) == :fired
    assert [%Job{tag: :memory, origin: :background, range_start: 0, range_end: 4}] = Repo.all(Job)
  end

  test "a chat's own automatic-memory settings override memory.auto_*", %{scope: scope, chat: chat} = ctx do
    :ok = Mythweaver.Settings.put(scope, :user, "memory.auto_interval", 5)
    :ok = Mythweaver.Settings.put(scope, :user, "memory.auto_buffer", 1)
    messages!(ctx, 6)

    {:ok, settings} =
      Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), %{auto_enabled: true, auto_interval: 10})

    stub_reply(@memory)
    assert Memory.Auto.check(scope, chat.id) == :waiting

    {:ok, _} = Memory.update_chat_settings(scope, settings, %{auto_trigger: :tokens, auto_token_threshold: 1})
    assert Memory.Auto.check(scope, chat.id) == :fired
    # The buffer still follows the setting: the newest message stays out.
    assert [%Job{tag: :memory, origin: :background, range_start: 0, range_end: 4}] = Repo.all(Job)
  end

  test "progress counts toward the next automatic memory, past the buffer", %{scope: scope, chat: chat} = ctx do
    messages!(ctx, 4)
    assert Memory.Auto.progress(scope, chat) == nil

    {:ok, settings} =
      Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), %{
        auto_enabled: true,
        auto_interval: 5,
        auto_buffer: 1
      })

    assert Memory.Auto.progress(scope, chat) == %{unit: :messages, done: 3, total: 5}

    # Only messages past the processed boundary count, and never below zero.
    {:ok, _} = Memory.set_highest_processed(scope, chat, 2)
    assert Memory.Auto.progress(scope, chat) == %{unit: :messages, done: 0, total: 5}

    {:ok, _} = Memory.update_chat_settings(scope, settings, %{auto_trigger: :tokens, auto_token_threshold: 100_000})
    assert %{unit: :tokens, done: 0, total: 100_000} = Memory.Auto.progress(scope, chat)

    {:ok, _} = Memory.set_highest_processed(scope, chat, nil)
    assert %{unit: :tokens, done: done} = Memory.Auto.progress(scope, chat)
    assert done > 0
  end

  test "regenerating after the scene was edited is refused", %{scope: scope, chat: chat} = ctx do
    [first | _] = messages!(ctx, 2)
    stub_reply(@memory)

    {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
    %Job{result: %{"record_id" => id}} = await_job(scope, job)
    record = Repo.get!(Record, id)

    {:ok, regenerate} = Memory.regenerate(scope, chat, record)
    %Job{status: :review, result: draft} = regenerate = await_job(scope, regenerate)
    {:ok, _} = Messages.add_edited_body(scope, first, %{content: "Something else happened."})

    assert Memory.approve(scope, regenerate, draft) == {:error, :changed}
    assert Lore.get_entry!(record.lore_entry_id).content == "They met at the inn."
  end

  test "regenerating another chat's record is refused, when queued and when saved", %{scope: scope, chat: chat} = ctx do
    messages!(ctx, 2)
    stub_reply(@memory)

    {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
    %Job{result: %{"record_id" => id}} = await_job(scope, job)
    theirs = their_record!(ctx)

    assert Memory.regenerate(scope, chat, theirs) == {:error, :unauthorized}

    {:ok, regenerate} = Memory.regenerate(scope, chat, Repo.get!(Record, id))
    %Job{status: :review, result: draft} = regenerate = await_job(scope, regenerate)
    # The queued job retargeted at their record: the save checks the record again.
    params = Map.put(regenerate.params, "record_id", theirs.id)
    forged = regenerate |> Ecto.Changeset.change(params: params) |> Repo.update!()

    assert Memory.approve(scope, forged, draft) == {:error, :unauthorized}
    assert Repo.get!(LoreEntry, theirs.lore_entry_id).content == "Their memory."
    assert %Record{chat_id: their_chat_id} = Repo.get!(Record, theirs.id)
    assert their_chat_id == theirs.chat_id
  end

  test "a new memory is refused when its scene changed before approval", %{scope: scope, chat: chat} = ctx do
    [first | _] = messages!(ctx, 2)
    stub_reply(@memory)

    {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: true)
    %Job{status: :review} = job = await_job(scope, job)
    {:ok, _} = Messages.add_edited_body(scope, first, %{content: "Something else happened."})

    assert Memory.approve(scope, job, job.result) == {:error, :changed}
    assert Repo.all(Record) == []
    assert Jobs.get_job(scope, job.id).status == :review
  end

  test "a review refused for a changed scene saves anyway when asked, over the scene as it is now",
       %{scope: scope, chat: chat} = ctx do
    [first | _] = messages!(ctx, 2)
    stub_reply(@memory)

    {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: true)
    %Job{status: :review} = job = await_job(scope, job)
    {:ok, _} = Messages.add_edited_body(scope, first, %{content: "Something else happened."})

    assert Memory.approve(scope, job, job.result) == {:error, :changed}
    assert {:ok, %Record{} = record} = Memory.approve(scope, job, job.result, ignore_changes: true)
    assert Lore.get_entry!(record.lore_entry_id).content == "They met at the inn."
    # The record holds the scene it now sits over, so a later regeneration checks against that.
    assert record.scene_fingerprint != job.params["scene_fingerprint"]
    assert Jobs.get_job(scope, job.id).status == :completed
  end

  test "retrying a review whose scene changed reads the scene again, so its save goes through",
       %{scope: scope, chat: chat} = ctx do
    [first | _] = messages!(ctx, 2)
    stub_reply(@memory)

    {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: true)
    %Job{status: :review} = job = await_job(scope, job)
    {:ok, _} = Messages.add_edited_body(scope, first, %{content: "Something else happened."})
    assert Memory.approve(scope, job, job.result) == {:error, :changed}

    {:ok, _} = Jobs.retry(scope, job.id)
    %Job{status: :review} = retried = await_job(scope, job)

    assert {:ok, %Record{}} = Memory.approve(scope, retried, retried.result)
  end

  test "retrying a regeneration after the memory was edited by hand rewrites the entry as it is now",
       %{scope: scope, chat: chat} = ctx do
    messages!(ctx, 2)
    stub_reply(@memory)

    {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
    %Job{result: %{"record_id" => id}} = await_job(scope, job)
    record = Repo.get!(Record, id) |> Repo.preload(:entry)

    {:ok, regenerate} = Memory.regenerate(scope, chat, record)
    %Job{status: :review} = regenerate = await_job(scope, regenerate)
    {:ok, edited} = Lore.update_entry(scope, record.entry, %{content: "Edited by hand."})
    # `updated_at` has second precision: move the edit past the regeneration's snapshot of it.
    later = DateTime.add(edited.updated_at, 5)
    Repo.update_all(from(e in LoreEntry, where: e.id == ^edited.id), set: [updated_at: later])
    assert Memory.approve(scope, regenerate, regenerate.result) == {:error, :changed}

    {:ok, _} = Jobs.retry(scope, regenerate.id)
    %Job{status: :review} = retried = await_job(scope, regenerate)

    assert {:ok, %Record{}} = Memory.approve(scope, retried, retried.result)
    assert Lore.get_entry!(record.lore_entry_id).content == "They met at the inn."
  end

  test "a stale review approved twice saves once", %{scope: scope, chat: chat} = ctx do
    messages!(ctx, 2)
    stub_reply(@memory)

    {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: true)
    %Job{status: :review} = job = await_job(scope, job)

    assert {:ok, _record} = Memory.approve(scope, job, job.result)
    assert Memory.approve(scope, job, job.result) == {:error, :not_found}
    assert Repo.aggregate(Record, :count) == 1
  end

  test "a review lists in the inbox until it is resolved", %{scope: scope, chat: chat} = ctx do
    messages!(ctx, 2)
    stub_reply(@memory)
    :ok = Notifications.subscribe(scope)

    {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: true)
    %Job{status: :review} = job = await_job(scope, job)
    # The review notification is stored just after the job's own broadcast.
    assert_receive {Notifications, :inbox_changed}
    assert Repo.get_by(Notification, job_id: job.id, kind: :memory_review)

    {:ok, _} = Memory.discard(scope, job)
    refute Repo.get_by(Notification, job_id: job.id)
  end

  test "a save for a job no longer running writes nothing", %{scope: scope, chat: chat} = ctx do
    messages!(ctx, 2)
    stub_reply(@memory)

    {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
    %Job{status: :completed} = job = await_job(scope, job)

    draft = %{"title" => "Again", "content" => "Saved twice.", "keywords" => ["again"]}
    assert Memory.save_scene(scope, %{job | status: :running}, draft) == {:error, :not_found}
    assert Repo.aggregate(Record, :count) == 1
  end

  test "catch-up stops after a failed chunk", %{scope: scope, chat: chat} = ctx do
    messages!(ctx, 15)
    stub_reply("not json")

    assert {:ok, [first, second, third]} = Memory.catch_up(scope, chat, 0, 14, 5)
    assert {first.range_start, first.range_end, third.range_start} == {0, 4, 10}
    assert %Job{status: :failed} = await_job(scope, first)
    assert %Job{status: :canceled} = await_job(scope, second)
    assert %Job{status: :canceled} = await_job(scope, third)
  end

  ## Helpers

  defp await_job(scope, %Job{id: id}) do
    receive do
      {:job_changed, %{id: ^id, status: status}} when status in [:completed, :failed, :canceled, :review] ->
        Jobs.get_job(scope, id)
    after
      2000 -> flunk("job #{id} did not finish; now #{Jobs.get_job(scope, id).status}")
    end
  end

  defp stub_reply(text), do: Req.Test.stub(Mythweaver.AI, &reply(&1, text))

  defp reply(conn, text) do
    frames = [
      "data: #{Jason.encode!(%{choices: [%{index: 0, delta: %{content: text}, finish_reason: nil}]})}\n\n",
      ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
      "data: [DONE]\n\n"
    ]

    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce(frames, conn, fn frame, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, frame)
      conn
    end)
  end

  # `count` messages alternating player and responder, starting with the responder.
  defp messages!(%{scope: scope, chat: chat, player: player, responder: responder}, count, text \\ "Line") do
    for i <- 1..count do
      author = if rem(i, 2) == 1, do: responder, else: player
      {:ok, message} = Messages.send_message(scope, chat, author.id, "#{text} #{i}")
      message
    end
  end

  # A memory record in another user's chat (with their own characters) and book.
  defp their_record!(_ctx) do
    owner = scope!(%{role: :user})
    [player, responder] = [character!(owner, "Their player"), character!(owner, "Their responder")]

    {:ok, chat} =
      Chats.create_chat(owner, %{
        name: "Their chat",
        participants: [%{character_id: player.id}, %{character_id: responder.id}],
        player_character_id: player.id
      })

    {:ok, book} = Lore.create_book(owner, %{name: "Their memories"})

    {:ok, entry} =
      Lore.create_entry(owner, %{name: "Theirs", content: "Their memory.", keywords: ["theirs"]}, [book.id])

    Repo.insert!(%Record{
      lore_entry_id: entry.id,
      lore_book_id: book.id,
      chat_id: chat.id,
      kind: :memory,
      tier: 0,
      sequence: 1,
      range_start: 0,
      range_end: 1
    })
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp chat!(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Memory chat",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end

  defp linked_model!(scope) do
    {:ok, provider} =
      AI.create_provider(scope, %{
        name: "Local-#{System.unique_integer([:positive])}",
        adapter: :openai_compatible,
        base_url: "http://localhost:8080/v1"
      })

    {:ok, model} =
      AI.create_model(scope, %{name: "Gemma-#{System.unique_integer([:positive])}", api_model_id: "gemma-4"})

    {:ok, _link} = AI.link_model(scope, provider, model)
    model
  end

  defp profile!(scope, model) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Memory: Test", purpose: :memory})
    {:ok, block} = Prompts.create_block(scope, %{name: "Summarize", content: "Summarize as JSON."})
    {:ok, scene} = Prompts.create_block(scope, %{name: "Scene", role: :user, content: "{{ anchors.memory.scene }}"})
    {:ok, _} = Prompts.add_block(scope, prompt, block)
    {:ok, _} = Prompts.add_block(scope, prompt, scene)

    {:ok, profile} =
      Memory.create_profile(scope, %{name: "Default", ai_model_id: model.id, memory_prompt_id: prompt.id})

    {:ok, profile} = Memory.set_default_profile(scope, profile)
    profile
  end
end
