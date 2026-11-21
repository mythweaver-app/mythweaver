defmodule Mythweaver.Memory.ClipTest do
  # Not `async: true`: topical clips run in scheduler-spawned tasks, which need the shared sandbox and
  # shared `Req.Test` stubs.
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Jobs.Scheduler
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Clips
  alias Mythweaver.Memory.Record
  alias Mythweaver.Prompts

  setup context do
    scope = scope!()
    Req.Test.set_req_test_to_shared(context)
    on_exit(fn -> await_idle(100) end)
    :ok = Jobs.subscribe(scope)

    player = character!(scope, "Player")
    chat = chat!(scope, [player, character!(scope, "Responder")])
    profile = profile!(scope, linked_model!(scope))

    %{scope: scope, chat: chat, profile: profile, book: Memory.ensure_book(scope, chat)}
  end

  describe "save_clip/3" do
    test "creates a wrapped clip, then adds lines inside the wrapper", %{scope: scope, chat: chat, book: book} do
      assert {:ok, %Record{kind: :clip} = record} =
               Clips.save_clip(scope, chat, "  The key is\n under the mat. ", {:new, "Secrets", :keyword})

      record = Repo.preload(record, :entry)
      assert record.lore_book_id == book.id
      assert record.chat_id == chat.id
      assert record.entry.keywords == ["Secrets"]
      assert record.entry.content == "=== Secrets ===\n\n- The key is under the mat.\n\n=== END Secrets ==="

      assert {:ok, _record} = Clips.save_clip(scope, chat, "The door sticks.", {:existing, record.id})

      entry = Lore.get_entry!(record.lore_entry_id)

      assert entry.content ==
               "=== Secrets ===\n\n- The key is under the mat.\n- The door sticks.\n\n=== END Secrets ==="

      assert Repo.get!(Record, record.id).written_fingerprint == Memory.Scene.sha256(entry.content)
    end

    test "appends when the END marker is gone, and refuses blank text", %{scope: scope, chat: chat} do
      {:ok, record} = Clips.save_clip(scope, chat, "One.", {:new, "Notes", :constant})
      record = Repo.preload(record, :entry)
      assert record.entry.activation == :constant
      {:ok, _entry} = Lore.update_entry(scope, record.entry, %{content: "Hand-written notes.\n"})

      assert {:ok, _record} = Clips.save_clip(scope, chat, "Two.", {:existing, record.id})
      assert Lore.get_entry!(record.lore_entry_id).content == "Hand-written notes.\n- Two."

      assert Clips.save_clip(scope, chat, " \n ", {:existing, record.id}) == {:error, :empty}
      assert Clips.save_clip(scope, chat, "Text", {:new, " ", :keyword}) == {:error, :no_title}
    end
  end

  describe "topical_clip/2" do
    test "an update sends only the sources that are new or changed since the clip", %{scope: scope} = ctx do
      [one, two] = for i <- 1..2, do: memory!(ctx, i, "Memory #{i} mentions the sword.")
      test = self()
      stub_reply("The sword is old.", test)

      assert {:ok, job} = Clips.topical_clip(scope, ctx.chat, topic: "The sword")
      assert job.label == "Topical clip — The sword"
      assert_receive {:request, body}, 2000
      assert body =~ "Memory 1 mentions" and body =~ "Memory 2 mentions"
      assert %Job{status: :review} = job = await_job(scope, job)

      assert {:ok, %Record{kind: :topical_clip} = clip} =
               Memory.approve(scope, job, %{"content" => "The sword is old."})

      clip = Repo.preload(clip, :entry)
      assert clip.entry.name == "The sword"
      assert clip.entry.keywords == ["The sword"]
      assert clip.entry.activation == :keyword
      assert Map.keys(clip.snapshot["sources"]) |> Enum.sort() == Enum.sort([one.id, two.id])

      {:ok, _entry} = Lore.update_entry(scope, two.entry, %{content: "Memory 2 says the sword is cursed."})
      three = memory!(ctx, 3, "Memory 3 finds the sword's sheath.")
      stub_reply("The sword is old, cursed, and sheathed.", test)

      assert {:ok, job} = Clips.topical_clip(scope, ctx.chat, topic: "The sword", target_record_id: clip.id)
      assert_receive {:request, body}, 2000
      refute body =~ "Memory 1 mentions"
      assert body =~ "Memory 2 says the sword is cursed."
      assert body =~ "Memory 3 finds"
      assert body =~ "The sword is old."
      assert job.params["source_ids"] == [two.id, three.id]

      job = await_job(scope, job)
      assert {:ok, updated} = Memory.approve(scope, job, %{"content" => "The sword is old, cursed, and sheathed."})
      assert updated.id == clip.id
      assert Lore.get_entry!(clip.lore_entry_id).content == "The sword is old, cursed, and sheathed."
      assert map_size(Repo.get!(Record, clip.id).snapshot["sources"]) == 3

      assert Clips.topical_clip(scope, ctx.chat, topic: "The sword", target_record_id: clip.id) ==
               {:error, :no_sources}
    end

    test "picked messages send only those, hidden ones included", %{scope: scope, chat: chat} = ctx do
      [player | _] = chat.participants
      a = message!(chat, player.character_id, "Alpha mentions the lantern.", visible_to_ai: false)
      _b = message!(chat, player.character_id, "Bravo skips it.")
      c = message!(chat, player.character_id, "Charlie lights the lantern.")
      stub_reply("The lantern.", self())

      assert {:ok, job} =
               Clips.topical_clip(scope, ctx.chat,
                 topic: "x",
                 include_memories: false,
                 include_messages: true,
                 message_ids: [a.id, c.id]
               )

      assert_receive {:request, body}, 2000
      assert body =~ "Alpha mentions" and body =~ "Charlie lights"
      refute body =~ "Bravo"
      assert job.params["messages"]["message_ids"] == [a.id, c.id]
      assert job.params["messages"]["start"] == a.position
      assert job.params["messages"]["end"] == c.position
      assert %Job{status: :review} = await_job(scope, job)
    end
  end

  describe "combine_clips/3" do
    test "combines two clips into one reviewed clip and disables the originals", %{scope: scope} = ctx do
      one = topical!(ctx, "Tea", ["a", "b"], "Kai drinks tea.")
      two = topical!(ctx, "Cups", ["b", " c ", ""], "Kai owns cups.")
      stub_reply("Kai drinks tea from his cups.", self())

      assert {:ok, job} =
               Clips.combine_clips(scope, ctx.chat, book_id: ctx.book.id, record_ids: [one.id, two.id], title: "Kai")

      assert job.label == "Combine clips — Kai"
      assert_receive {:request, body}, 2000
      assert body =~ "=== SNIPPET 1: Tea ===" and body =~ "Kai drinks tea."
      assert body =~ "=== SNIPPET 2: Cups ===" and body =~ "Kai owns cups."
      assert %Job{status: :review} = job = await_job(scope, job)

      assert {:ok, %Record{kind: :topical_clip} = clip} =
               Memory.approve(scope, job, %{"content" => "Kai drinks tea from his cups."})

      clip = Repo.preload(clip, :entry)
      assert clip.entry.name == "Kai"
      assert clip.entry.keywords == ["a", "b", "c"]
      assert clip.snapshot["combined_from"] == [one.id, two.id]
      assert Map.keys(clip.snapshot["sources"]) |> Enum.sort() == ["src-Cups", "src-Tea"]
      refute Memory.record_enabled?(Repo.get!(Record, one.id))
      refute Memory.record_enabled?(Repo.get!(Record, two.id))
      assert Repo.get(Record, one.id) && Lore.get_entry!(one.lore_entry_id)
    end

    test "an original edited before approval refuses the save", %{scope: scope} = ctx do
      one = topical!(ctx, "Tea", ["a"], "Kai drinks tea.")
      two = topical!(ctx, "Cups", ["c"], "Kai owns cups.")
      stub_reply("Combined.", self())

      {:ok, job} =
        Clips.combine_clips(scope, ctx.chat, book_id: ctx.book.id, record_ids: [one.id, two.id], title: "Kai")

      job = await_job(scope, job)
      {:ok, _entry} = Lore.update_entry(scope, one.entry, %{content: "Kai hates tea."})

      assert Memory.approve(scope, job, %{"content" => "Combined."}) == {:error, :changed}
      assert Memory.record_enabled?(Repo.get!(Record, two.id))
    end

    test "retrying after an original was edited combines the clips as they are now, and saves", %{scope: scope} = ctx do
      one = topical!(ctx, "Tea", ["a"], "Kai drinks tea.")
      two = topical!(ctx, "Cups", ["c"], "Kai owns cups.")
      stub_reply("Combined.", self())

      {:ok, job} =
        Clips.combine_clips(scope, ctx.chat, book_id: ctx.book.id, record_ids: [one.id, two.id], title: "Kai")

      job = await_job(scope, job)
      {:ok, _entry} = Lore.update_entry(scope, one.entry, %{content: "Kai hates tea."})
      assert Memory.approve(scope, job, %{"content" => "Combined."}) == {:error, :changed}

      {:ok, _} = Jobs.retry(scope, job.id)
      retried = await_job(scope, job)

      assert {:ok, %Record{kind: :topical_clip}} = Memory.approve(scope, retried, %{"content" => "Combined."})
      refute Memory.record_enabled?(Repo.get!(Record, one.id))
    end

    test "refuses one clip, a blank title and a clip of another kind", %{scope: scope} = ctx do
      one = topical!(ctx, "Tea", ["a"], "Kai drinks tea.")
      memory = memory!(ctx, 1, "A memory.")
      opts = [book_id: ctx.book.id, title: "Kai"]

      assert Clips.combine_clips(scope, ctx.chat, [record_ids: [one.id]] ++ opts) == {:error, :too_few}

      assert Clips.combine_clips(scope, ctx.chat, book_id: ctx.book.id, record_ids: [one.id, memory.id], title: " ") ==
               {:error, :no_title}

      assert Clips.combine_clips(scope, ctx.chat, [record_ids: [one.id, memory.id]] ++ opts) == {:error, :not_found}
    end
  end

  ## Helpers

  defp memory!(%{scope: scope, book: book, chat: chat}, i, content) do
    {:ok, entry} =
      Lore.create_entry(scope, %{name: "[#{i}] Memory", content: content, keywords: ["memory#{i}"]}, [book.id])

    {:ok, record} =
      %Record{}
      |> Record.changeset(%{
        lore_entry_id: entry.id,
        lore_book_id: book.id,
        chat_id: chat.id,
        kind: :memory,
        tier: 0,
        sequence: i,
        range_start: 2 * i - 2,
        range_end: 2 * i - 1
      })
      |> Repo.insert()

    Repo.preload(record, :entry)
  end

  defp message!(chat, character_id, content, opts \\ []) do
    {:ok, message} =
      Mythweaver.Messages.create_message(chat, %{
        author_is_character: true,
        author_character_id: character_id,
        visible_to_ai: Keyword.get(opts, :visible_to_ai, true),
        bodies: [%{content: content}]
      })

    message
  end

  defp topical!(%{scope: scope, book: book, chat: chat}, name, keywords, content) do
    {:ok, entry} = Lore.create_entry(scope, %{name: name, content: content, keywords: keywords}, [book.id])

    {:ok, record} =
      %Record{}
      |> Record.changeset(%{
        lore_entry_id: entry.id,
        lore_book_id: book.id,
        chat_id: chat.id,
        kind: :topical_clip,
        snapshot: %{"topic" => name, "sources" => %{"src-#{name}" => "fp"}}
      })
      |> Repo.insert()

    Repo.preload(record, :entry)
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

  defp await_job(scope, %Job{id: id}) do
    receive do
      {:job_changed, %{id: ^id, status: status}} when status in [:completed, :failed, :canceled, :review] ->
        Jobs.get_job(scope, id)
    after
      2000 -> flunk("job #{id} did not finish; now #{Jobs.get_job(scope, id).status}")
    end
  end

  # Replies with `text` and sends the test each request body it receives.
  defp stub_reply(text, test) do
    Req.Test.stub(Mythweaver.AI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, body})

      frames = [
        "data: #{Jason.encode!(%{choices: [%{index: 0, delta: %{content: text}, finish_reason: nil}]})}\n\n",
        ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
        "data: [DONE]\n\n"
      ]

      Enum.reduce(frames, Plug.Conn.send_chunked(conn, 200), fn frame, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, frame)
        conn
      end)
    end)
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp chat!(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Clip chat",
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
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Test topical clip", purpose: :topical_clip})

    {:ok, block} =
      Prompts.create_block(scope, %{
        name: "Topical material",
        role: :user,
        content:
          "{{ anchors.memory.topic }}\n{{ anchors.memory.entry.content }}\n{{ anchors.memory.sources_text }}\n{{ anchors.memory.scene }}"
      })

    {:ok, _} = Prompts.add_block(scope, prompt, block)
    {:ok, combine} = Prompts.create_prompt(scope, %{name: "Test combine clips", purpose: :combine_clips})

    {:ok, combine_block} =
      Prompts.create_block(scope, %{
        name: "Combine material",
        role: :user,
        content: """
        Title: {{ anchors.memory.topic }}
        {% for clip in anchors.memory.sources %}=== SNIPPET {{ forloop.index }}: {{ clip.title }} ===
        {{ clip.content }}
        === END SNIPPET {{ forloop.index }} ===

        {% endfor %}
        """
      })

    {:ok, _} = Prompts.add_block(scope, combine, combine_block)

    {:ok, profile} =
      Memory.create_profile(scope, %{
        name: "Default",
        ai_model_id: model.id,
        topical_clip_prompt_id: prompt.id,
        combine_clips_prompt_id: combine.id
      })

    {:ok, profile} = Memory.set_default_profile(scope, profile)
    profile
  end
end
