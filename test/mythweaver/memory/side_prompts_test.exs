defmodule Mythweaver.Memory.SidePromptsTest do
  # Not `async: true`: side prompt jobs run in scheduler-spawned tasks, which need the shared sandbox
  # and shared `Req.Test` stubs.
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Jobs.Scheduler
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.SidePromptCheckpoint
  alias Mythweaver.Memory.SidePrompts
  alias Mythweaver.Messages
  alias Mythweaver.Prompts

  @memory ~s({"title": "Title", "content": "They met at the inn.", "keywords": ["inn"]})

  setup context do
    scope = scope!()
    Req.Test.set_req_test_to_shared(context)
    on_exit(fn -> await_idle(100) end)
    :ok = Jobs.subscribe(scope)

    player = character!(scope, "Player")
    responder = character!(scope, "Responder")
    model = linked_model!(scope)
    chat = chat!(scope, [player, responder])
    profile!(scope, model)

    %{scope: scope, player: player, responder: responder, chat: chat}
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

  test "an after-memory side prompt runs once per saved memory, under the memory's job",
       %{scope: scope, chat: chat} = ctx do
    side_prompt!(scope, %{run_after_memory: true})
    messages!(ctx, 4)
    stub_replies()

    {:ok, first} = Memory.create_memory(scope, chat, 0, 1, review: false)
    %Job{status: :completed} = await_job(scope, first)
    # The job completes in the save's transaction; the after-memory run is queued just after commit.
    assert_receive {:job_changed, %{tag: :side_prompt, status: :queued}}
    assert [%Job{parent_id: parent, range_start: 0, range_end: 1} = side] = side_jobs()
    assert parent == first.id
    assert %Job{status: :completed, result: %{"record_id" => record_id}} = await_job(scope, side)

    {:ok, second} = Memory.create_memory(scope, chat, 2, 3, review: false)
    %Job{status: :completed} = await_job(scope, second)
    assert_receive {:job_changed, %{tag: :side_prompt, status: :queued}}
    second_id = second.id
    assert [_, %Job{parent_id: ^second_id} = side] = side_jobs()
    %Job{status: :completed, result: %{"record_id" => ^record_id}} = await_job(scope, side)

    record = Record |> Repo.get!(record_id) |> Repo.preload(:entry)
    assert %Record{kind: :side_prompt, range_start: 2, range_end: 3} = record
    assert record.entry.name == "Tracker"
    assert record.entry.content == "Plot so far."
    assert record.snapshot["existed"] and record.snapshot["range"] == [2, 3]
  end

  test "an after-memory run leaves out messages the user hid", %{scope: scope, chat: chat} = ctx do
    [m0, m1, m2, m3] = messages!(ctx, 4)
    {:ok, _} = Messages.set_visible_to_ai(scope, m1, false)

    {:ok, _} =
      Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), %{auto_hide: :last, leave_unhidden: 0})

    side_prompt!(scope, %{run_after_memory: true})
    stub_replies()

    {:ok, memory} = Memory.create_memory(scope, chat, 0, 3, review: false)
    %Job{status: :completed} = await_job(scope, memory)
    assert_receive {:job_changed, %{tag: :side_prompt, status: :queued, id: side_id}}

    side = Jobs.get_job(scope, side_id)
    assert side.parent_id == memory.id
    assert side.params["message_ids"] == [m0.id, m2.id, m3.id]
    assert %Job{status: :completed} = await_job(scope, side)
    assert Enum.map([m0, m2, m3], &Messages.get_message!(scope, &1.id).visible_to_ai) == [false, false, false]
  end

  test "a chat's book override receives the side prompt's new entry", %{scope: scope, chat: chat} = ctx do
    side_prompt = side_prompt!(scope)
    {:ok, book} = Lore.create_book(scope, %{name: "Trackers"})
    settings = Memory.chat_settings(scope, chat)

    assert {:error, changeset} =
             Memory.update_chat_settings(scope, settings, %{side_prompt_book_ids: %{"x" => book.id}})

    assert errors_on(changeset).side_prompt_book_ids == ["must map side prompts to books"]
    {:ok, _} = Memory.update_chat_settings(scope, settings, %{side_prompt_book_ids: %{side_prompt.id => book.id}})

    messages!(ctx, 2)
    stub_replies()

    {:ok, job} = SidePrompts.run(scope, chat, side_prompt, review: false)
    %Job{status: :completed, result: %{"record_id" => id}} = await_job(scope, job)
    assert Repo.get!(Record, id).lore_book_id == book.id
  end

  test "an interval side prompt fires at its threshold, and not again while it runs",
       %{scope: scope, chat: chat} = ctx do
    side_prompt = side_prompt!(scope, %{run_on_interval: true, interval: 3})
    test = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      send(test, {:blocked, self()})

      receive do
        :release -> reply(conn, "Plot so far.")
      end
    end)

    messages!(ctx, 2)
    assert side_jobs() == []

    messages!(ctx, 4)
    assert [%Job{origin: :background, range_start: 0, range_end: 2} = job] = side_jobs()
    assert_receive {:blocked, runner}
    send(runner, :release)
    %Job{status: :completed} = await_job(scope, job)
    assert SidePrompts.checkpoint(chat, side_prompt) == 2

    # Messages 4–6 arrived while it ran; past the checkpoint, the next one is due again.
    messages!(ctx, 1)
    assert [_, %Job{range_start: 3, range_end: 6}] = side_jobs()
    assert_receive {:blocked, runner}
    send(runner, :release)
  end

  test "versioning keeps numbered entries with only the newest enabled", %{scope: scope, chat: chat} = ctx do
    :ok = Mythweaver.Settings.put(scope, :site, "memory.side_prompt_versioning", true)
    side_prompt = side_prompt!(scope, %{save_versions: true})
    messages!(ctx, 2)
    stub_replies()

    for _run <- 1..3 do
      {:ok, job} = SidePrompts.run(scope, chat, side_prompt, start: 0, end: 1, review: false)
      %Job{status: :completed} = await_job(scope, job)
    end

    versions =
      Record
      |> where(kind: :side_prompt)
      |> Repo.all()
      |> Enum.map(&{Lore.get_entry!(&1.lore_entry_id).name, Memory.record_enabled?(&1)})
      |> Enum.sort()

    assert versions == [{"Tracker-001", false}, {"Tracker-002", false}, {"Tracker-003", true}]
  end

  test "regenerating after the user edited the entry is refused", %{scope: scope, chat: chat} = ctx do
    side_prompt = side_prompt!(scope)
    messages!(ctx, 2)
    stub_replies()

    {:ok, job} = SidePrompts.run(scope, chat, side_prompt, review: false)
    %Job{result: %{"record_id" => id}} = await_job(scope, job)
    record = Record |> Repo.get!(id) |> Repo.preload(:entry)

    # Edited while the regeneration waits in review: saving it would clobber the edit.
    {:ok, regenerate} = Memory.regenerate(scope, chat, record)
    %Job{status: :review} = regenerate = await_job(scope, regenerate)
    {:ok, _} = Lore.update_entry(scope, record.entry, %{content: "My own notes."})

    assert Memory.approve(scope, regenerate, %{"content" => "Rewritten."}) == {:error, :changed}
    assert Memory.regenerate(scope, chat, Repo.get!(Record, id)) == {:error, :changed}
    assert Lore.get_entry!(record.lore_entry_id).content == "My own notes."
  end

  test "retrying a regeneration after a later run rewrote the entry reads the record again, and saves",
       %{scope: scope, chat: chat} = ctx do
    side_prompt = side_prompt!(scope)
    messages!(ctx, 2)
    stub_replies()

    {:ok, job} = SidePrompts.run(scope, chat, side_prompt, review: false)
    %Job{result: %{"record_id" => id}} = await_job(scope, job)
    record = Record |> Repo.get!(id) |> Repo.preload(:entry)

    {:ok, regenerate} = Memory.regenerate(scope, chat, record)
    %Job{status: :review} = regenerate = await_job(scope, regenerate)

    # What a later run of the side prompt leaves: new content, and the record noting it wrote it.
    later = "Written by a later run."
    {:ok, _} = Lore.update_entry(scope, record.entry, %{content: later})
    record |> Ecto.Changeset.change(written_fingerprint: Scene.sha256(later)) |> Repo.update!()
    assert Memory.approve(scope, regenerate, %{"content" => "Rewritten."}) == {:error, :changed}

    {:ok, _} = Jobs.retry(scope, regenerate.id)
    %Job{status: :review} = retried = await_job(scope, regenerate)

    assert {:ok, _} = Memory.approve(scope, retried, %{"content" => "Rewritten."})
    assert Lore.get_entry!(record.lore_entry_id).content == "Rewritten."
  end

  describe "side prompt sets and runtime macros" do
    test "a set's rows run after a memory, each with its macros, entry and checkpoint",
         %{scope: scope, chat: chat} = ctx do
      npc = macro_side_prompt!(scope)
      set = set!(scope, npc)
      {:ok, _} = set_mode(scope, chat, %{side_prompt_set_mode: :set, side_prompt_set_id: set.id})
      messages!(ctx, 4)
      capture_bodies()

      {:ok, memory} = Memory.create_memory(scope, chat, 0, 3, review: false)
      %Job{status: :completed} = await_job(scope, memory)
      assert_receive {:job_changed, %{tag: :side_prompt, status: :queued}}
      assert_receive {:job_changed, %{tag: :side_prompt, status: :queued}}
      jobs = side_jobs()
      assert Enum.sort(Enum.map(jobs, & &1.label)) == ["Side prompt — NPC — Alice", "Side prompt — NPC — Bob"]

      assert Enum.map(jobs, &Map.take(await_job(scope, &1), [:status, :error])) == [
               %{status: :completed, error: nil},
               %{status: :completed, error: nil}
             ]

      bodies = side_bodies()
      assert Enum.any?(bodies, &(&1 =~ "Track Alice."))
      assert Enum.any?(bodies, &(&1 =~ "Track Bob."))

      [alice, bob] = Enum.map(Repo.preload(set, :rows, force: true).rows, & &1.id)

      records =
        Record
        |> where(kind: :side_prompt)
        |> preload(:entry)
        |> Repo.all()
        |> Enum.map(&{&1.entry.name, &1.side_prompt_set_row_id})
        |> Enum.sort()

      assert records == [{"Alice", alice}, {"Bob", bob}]

      checkpoints =
        SidePromptCheckpoint
        |> where(chat_id: ^chat.id)
        |> select([c], {c.side_prompt_set_row_id, c.last_position})
        |> Repo.all()
        |> Enum.sort()

      assert checkpoints == Enum.sort([{alice, 3}, {bob, 3}])
    end

    test "a side prompt with an unfilled macro does not run after a memory", %{scope: scope, chat: chat} = ctx do
      macro_side_prompt!(scope)
      {:ok, _} = set_mode(scope, chat, %{side_prompt_set_mode: :individual})
      messages!(ctx, 2)
      stub_replies()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, memory} = Memory.create_memory(scope, chat, 0, 1, review: false)
          %Job{status: :completed} = await_job(scope, memory)
          refute_receive {:job_changed, %{tag: :side_prompt}}, 200
        end)

      assert log =~ "no value for npc"
      assert side_jobs() == []
    end

    test "Default mode runs the group setting's set in a group chat and individual prompts solo",
         %{scope: scope, chat: solo, player: player, responder: responder} do
      npc = macro_side_prompt!(scope)
      plain = side_prompt!(scope, %{run_after_memory: true})
      set = set!(scope, npc)
      :ok = Mythweaver.Settings.put(scope, :user, "memory.side_prompt_set_group", set.id)
      group = chat!(scope, [player, responder, character!(scope, "Second")])

      ExUnit.CaptureLog.capture_log(fn ->
        assert [{%{id: npc_id}, %{label: "Alice"}}, {%{id: npc_id}, %{label: "Bob"}}] =
                 SidePrompts.automatic(scope, group, :after_memory)

        assert npc_id == npc.id
        # Solo: the individual prompts, less the one whose macro has no value.
        assert [{%{id: plain_id}, nil}] = SidePrompts.automatic(scope, solo, :after_memory)
        assert plain_id == plain.id
      end)
    end

    test "a chat on a set that was deleted runs nothing", %{scope: scope, chat: chat} do
      side_prompt!(scope, %{run_after_memory: true})
      set = set!(scope, macro_side_prompt!(scope))
      {:ok, _} = set_mode(scope, chat, %{side_prompt_set_mode: :set, side_prompt_set_id: set.id})
      {:ok, _} = Memory.delete_side_prompt_set(scope, set)

      log = ExUnit.CaptureLog.capture_log(fn -> assert SidePrompts.automatic(scope, chat, :after_memory) == [] end)
      assert log =~ "Side prompt set for chat #{chat.id} is missing"
    end

    test "a manual run takes its macros, and refuses without them", %{scope: scope, chat: chat} = ctx do
      npc = macro_side_prompt!(scope)
      messages!(ctx, 2)
      capture_bodies()

      assert SidePrompts.run(scope, chat, npc, review: false) == {:error, :missing_macros}
      assert SidePrompts.run(scope, chat, npc, review: false, macros: %{"npc" => ""}) == {:error, :missing_macros}

      {:ok, job} = SidePrompts.run(scope, chat, npc, review: false, macros: %{"npc" => "Zed"})
      assert %Job{status: :completed} = await_job(scope, job)
      assert [body] = side_bodies()
      assert body =~ "Track Zed."
    end

    test "macro names and row owners are checked", %{scope: scope} do
      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Side: Bad", purpose: :side_prompt})

      assert {:error, changeset} =
               Memory.create_side_prompt(scope, %{name: "Bad", prompt_id: prompt.id, macros: ["NPC name"]})

      assert errors_on(changeset).macros == ["must be lowercase letters, digits and underscores"]

      other = scope!(%{role: :user})
      {:ok, their_prompt} = Prompts.create_prompt(other, %{name: "Side: Theirs", purpose: :side_prompt})
      {:ok, theirs} = Memory.create_side_prompt(other, %{name: "Theirs", prompt_id: their_prompt.id})

      assert Memory.create_side_prompt_set(scope, %{name: "Mine", rows: [%{side_prompt_id: theirs.id}]}) ==
               {:error, :unauthorized}
    end
  end

  ## Helpers

  defp side_jobs, do: Repo.all(from(j in Job, where: j.tag == :side_prompt, order_by: [asc: j.inserted_at, asc: j.id]))

  defp await_job(scope, %Job{id: id}) do
    receive do
      {:job_changed, %{id: ^id, status: status}} when status in [:completed, :failed, :canceled, :review] ->
        Jobs.get_job(scope, id)
    after
      2000 -> flunk("job #{id} did not finish; now #{Jobs.get_job(scope, id).status}")
    end
  end

  # The memory prompt gets a JSON memory; the side prompt gets tracker text.
  defp stub_replies do
    Req.Test.stub(Mythweaver.AI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      memory? = body =~ "Summarize as JSON."
      reply(conn, if(memory?, do: @memory, else: "Plot so far."))
    end)
  end

  # Like `stub_replies/0`, also sending each side prompt request's body to the test.
  defp capture_bodies do
    test = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if body =~ "Summarize as JSON." do
        reply(conn, @memory)
      else
        send(test, {:side_body, body})
        reply(conn, "Plot so far.")
      end
    end)
  end

  defp side_bodies(acc \\ []) do
    receive do
      {:side_body, body} -> side_bodies([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp set_mode(scope, chat, attrs), do: Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), attrs)

  # An after-memory side prompt declaring the macro `npc`, whose prompt says "Track {{ npc }}.".
  defp macro_side_prompt!(scope) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Side: NPC", purpose: :side_prompt})
    {:ok, block} = Prompts.create_block(scope, %{name: "Track NPC", content: "Track {{ npc }}."})

    {:ok, scene} =
      Prompts.create_block(scope, %{name: "NPC scene", role: :user, content: "{{ anchors.memory.scene }}"})

    {:ok, _} = Prompts.add_block(scope, prompt, block)
    {:ok, _} = Prompts.add_block(scope, prompt, scene)

    {:ok, side_prompt} =
      Memory.create_side_prompt(scope, %{name: "NPC", prompt_id: prompt.id, macros: ["npc"], run_after_memory: true})

    side_prompt
  end

  defp set!(scope, side_prompt) do
    {:ok, set} =
      Memory.create_side_prompt_set(scope, %{
        name: "Cast",
        rows: [
          %{side_prompt_id: side_prompt.id, label: "Alice", macro_values: %{"npc" => "Alice"}},
          %{side_prompt_id: side_prompt.id, label: "Bob", macro_values: %{"npc" => "Bob"}}
        ]
      })

    set
  end

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
  defp messages!(%{scope: scope, chat: chat, player: player, responder: responder}, count) do
    for i <- 1..count do
      author = if rem(i, 2) == 1, do: responder, else: player
      {:ok, message} = Messages.send_message(scope, chat, author.id, "Line #{i}")
      message
    end
  end

  defp side_prompt!(scope, attrs \\ %{}) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Side: Test", purpose: :side_prompt})
    {:ok, block} = Prompts.create_block(scope, %{name: "Track", content: "Track the plot."})

    {:ok, scene} =
      Prompts.create_block(scope, %{name: "Side scene", role: :user, content: "{{ anchors.memory.scene }}"})

    {:ok, _} = Prompts.add_block(scope, prompt, block)
    {:ok, _} = Prompts.add_block(scope, prompt, scene)

    {:ok, side_prompt} = Memory.create_side_prompt(scope, Map.merge(%{name: "Tracker", prompt_id: prompt.id}, attrs))
    side_prompt
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp chat!(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Side chat",
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
