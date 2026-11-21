defmodule Mythweaver.Memory.CharacterBooksTest do
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
  alias Mythweaver.Lore.Activation
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory
  alias Mythweaver.Memory.CharacterBook
  alias Mythweaver.Memory.CharacterBooks
  alias Mythweaver.Memory.Consolidation
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Messages
  alias Mythweaver.Prompts

  @memory ~s({"title": "Title", "content": "They met at the inn.", "keywords": ["inn", "meeting"]})

  setup context do
    scope = scope!()
    Req.Test.set_req_test_to_shared(context)
    on_exit(fn -> await_idle(100) end)
    :ok = Jobs.subscribe(scope)

    player = character!(scope, "Player")
    alice = character!(scope, "Alice")
    bob = character!(scope, "Bob")
    model = linked_model!(scope)
    profile = profile!(scope, model)
    chat = chat!(scope, "Group chat", [player, alice, bob])

    %{scope: scope, player: player, alice: alice, bob: bob, model: model, profile: profile, chat: chat}
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

  describe "copies" do
    test "a memory is copied into each present character's book, with the silent cast", %{scope: scope} = ctx do
      %{canonical: canonical, job: job, alice_book: alice_book, bob_book: bob_book} = copied!(ctx)

      assert job.params["participant_ids"] == [ctx.alice.id, ctx.bob.id]
      assert canonical.lore_book_id == Memory.chat_settings(scope, ctx.chat).memory_book_id
      assert is_nil(canonical.canonical_id)

      copies = copies(canonical)

      assert Enum.map(copies, &{&1.lore_book_id, filter(&1)}) ==
               Enum.sort([{alice_book.id, [ctx.alice.id]}, {bob_book.id, [ctx.bob.id]}])

      for copy <- copies do
        assert %Record{kind: :memory, tier: 0, sequence: 1, range_start: 0, range_end: 3} = copy
        assert copy.canonical_id == canonical.id
        assert copy.chat_id == ctx.chat.id
        assert copy.entry.character_filter_mode == :include
        assert copy.entry.content == "They met at the inn."
        assert copy.entry.name == "[001] - Title"
      end
    end

    test "characters sharing a book get one copy filtered to both", %{scope: scope, chat: chat} = ctx do
      shared = book!(scope, "Shared memories")
      settings!(scope, chat, %{"character_book_ids" => %{ctx.alice.id => shared.id, ctx.bob.id => shared.id}})
      settings!(scope, chat, %{"cast_ids" => [ctx.bob.id]})
      messages!(ctx, ctx.alice, 4)
      stub_reply(@memory)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 3, review: false)
      assert %Job{status: :completed, result: %{"record_id" => id}} = await_job(scope, job)

      assert [copy] = copies(Repo.get!(Record, id))
      assert copy.lore_book_id == shared.id
      assert filter(copy) == Enum.sort([ctx.alice.id, ctx.bob.id])
    end

    test "a character memory prompt writes each copy in its own job", %{scope: scope, chat: chat} = ctx do
      prompt = character_prompt!(scope)
      {:ok, _} = Memory.update_profile(scope, ctx.profile, %{character_memory_prompt_id: prompt.id})
      alice_book = book!(scope, "Alice's memories")
      bob_book = book!(scope, "Bob's memories")

      settings!(scope, chat, %{
        "character_book_ids" => %{ctx.alice.id => alice_book.id, ctx.bob.id => bob_book.id},
        "cast_ids" => [ctx.bob.id]
      })

      messages!(ctx, ctx.alice, 4)
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, body})
        reply(conn, @memory)
      end)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 3, review: false)
      assert %Job{status: :completed, result: %{"record_id" => id}} = await_job(scope, job)
      canonical = Repo.get!(Record, id)

      children = await_children(scope, job, 2)
      assert Enum.all?(children, &(&1.status == :completed and &1.tag == :memory))
      assert Enum.sort(Enum.map(children, & &1.label)) == ["Memory #1–#4 for Alice", "Memory #1–#4 for Bob"]

      bodies =
        for _ <- 1..3 do
          assert_receive {:request, body}
          body
        end

      assert Enum.count(bodies, &(&1 =~ "Perspective of Alice.")) == 1
      assert Enum.count(bodies, &(&1 =~ "Perspective of Bob.")) == 1

      copies = copies(canonical)

      assert Enum.map(copies, &{&1.lore_book_id, filter(&1)}) ==
               Enum.sort([{alice_book.id, [ctx.alice.id]}, {bob_book.id, [ctx.bob.id]}])

      assert Enum.all?(copies, &(&1.prompt_id == prompt.id and &1.canonical_id == canonical.id and &1.sequence == 1))
    end

    test "a regeneration rewrites the copies verbatim and writes no new ones", %{scope: scope} = ctx do
      %{canonical: canonical} = copied!(ctx)
      ids = Enum.map(copies(canonical), & &1.id)
      stub_reply(~s({"title": "Again", "content": "Rewritten.", "keywords": ["inn"]}))

      assert {:ok, job} = Memory.regenerate(scope, ctx.chat, canonical)
      assert %Job{status: :review} = job = await_job(scope, job)
      assert {:ok, _} = Memory.approve(scope, job, job.result)

      copies = copies(canonical)
      assert Enum.map(copies, & &1.id) == ids

      for copy <- copies do
        assert copy.entry.content == "Rewritten."
        assert copy.entry.name == "[001] - Again"
        assert copy.sequence == 1
        assert copy.written_fingerprint == Scene.sha256("Rewritten.")
      end
    end

    test "a regeneration with a character prompt rewrites each copy in place in its own job",
         %{scope: scope, chat: chat} = ctx do
      prompt = character_prompt!(scope)
      {:ok, _} = Memory.update_profile(scope, ctx.profile, %{character_memory_prompt_id: prompt.id})
      alice_book = book!(scope, "Alice's memories")
      bob_book = book!(scope, "Bob's memories")

      settings!(scope, chat, %{
        "character_book_ids" => %{ctx.alice.id => alice_book.id, ctx.bob.id => bob_book.id},
        "cast_ids" => [ctx.bob.id]
      })

      messages!(ctx, ctx.alice, 4)
      stub_reply(@memory)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 3, review: false)
      assert %Job{status: :completed, result: %{"record_id" => id}} = await_job(scope, job)
      canonical = Repo.get!(Record, id)
      await_children(scope, job, 2)
      ids = Enum.map(copies(canonical), & &1.id)

      stub_reply(~s({"title": "Again", "content": "Rewritten.", "keywords": ["inn"]}))
      assert {:ok, regeneration} = Memory.regenerate(scope, chat, canonical)
      assert %Job{status: :review} = regeneration = await_job(scope, regeneration)
      assert {:ok, _} = Memory.approve(scope, regeneration, regeneration.result)

      children = await_children(scope, regeneration, 2)
      assert Enum.all?(children, &(&1.status == :completed))
      assert children |> Enum.map(& &1.params["copy"]["record_id"]) |> Enum.sort() == Enum.sort(ids)

      copies = copies(canonical)
      assert Enum.map(copies, & &1.id) == ids
      assert Enum.all?(copies, &(&1.entry.content == "Rewritten." and &1.prompt_id == prompt.id))

      assert Enum.map(copies, &{&1.lore_book_id, filter(&1)}) ==
               Enum.sort([{alice_book.id, [ctx.alice.id]}, {bob_book.id, [ctx.bob.id]}])

      assert Repo.aggregate(from(r in Record, where: r.chat_id == ^chat.id), :count) == 3
    end

    test "a scene only the player speaks in is copied for every character with a book",
         %{scope: scope, chat: chat} = ctx do
      alice_book = book!(scope, "Alice's memories")
      bob_book = book!(scope, "Bob's memories")
      settings!(scope, chat, %{"character_book_ids" => %{ctx.alice.id => alice_book.id, ctx.bob.id => bob_book.id}})
      messages!(ctx, ctx.player, 4)
      stub_reply(@memory)

      {:ok, job} = Memory.create_memory(scope, chat, 0, 3, review: false)
      assert %Job{status: :completed, result: %{"record_id" => id}} = await_job(scope, job)

      assert Enum.map(copies(Repo.get!(Record, id)), &{&1.lore_book_id, filter(&1)}) ==
               Enum.sort([{alice_book.id, [ctx.alice.id]}, {bob_book.id, [ctx.bob.id]}])
    end
  end

  describe "the chat's own book as a character book" do
    test "holds a shared copy with the memory's sequence, counted once and consolidated with it",
         %{scope: scope, chat: chat} = ctx do
      book = Memory.ensure_book(scope, chat)
      settings!(scope, chat, %{"character_book_ids" => %{ctx.alice.id => book.id}})
      messages = messages!(ctx, ctx.alice, 8)
      stub_reply(@memory)
      one = memory!(scope, chat, 0, 3)
      two = memory!(scope, chat, 4, 7)

      assert [copy_one] = copies(one)
      assert [copy_two] = copies(two)

      for {copy, canonical, name} <- [{copy_one, one, "[001] - Title"}, {copy_two, two, "[002] - Title"}] do
        assert copy.lore_book_id == book.id
        assert copy.sequence == canonical.sequence
        assert copy.entry.name == name
        assert filter(copy) == [ctx.alice.id]
        assert copy.lore_entry_id != canonical.lore_entry_id
      end

      assert Enum.map(Consolidation.eligible(scope, book, 1), & &1.id) == [one.id, two.id]
      assert Memory.counts(chat)["tier0"] == 2

      stub_reply(
        Jason.encode!(%{
          summaries: [%{title: "The Arc", summary: "Both.", keywords: ["arc"], member_ids: ["001", "002"]}],
          unassigned_items: []
        })
      )

      {:ok, [job]} =
        Consolidation.consolidate(scope, chat, book, 1, [one.id, two.id],
          review: false,
          prompt_id: consolidation_prompt!(scope).id
        )

      assert %Job{status: :completed, result: %{"record_ids" => [arc_id]}} = await_job(scope, job)

      for copy <- [copy_one, copy_two] do
        copy = reload(copy)
        assert copy.consolidated_into_id == arc_id
        assert copy.disabled_by_consolidation
        refute Memory.record_enabled?(copy)
      end

      # Rolling back the second memory deletes the Arc; the first memory and its copy come back.
      :ok = Mythweaver.Settings.put(scope, :site, "memory.rollback_enabled", true)
      {:ok, _} = Messages.delete_message(scope, Enum.at(messages, 5))

      refute Repo.get(Record, arc_id)
      refute Repo.get(Record, copy_two.id)

      for record <- [one, copy_one] do
        record = reload(record)
        assert is_nil(record.consolidated_into_id)
        refute record.disabled_by_consolidation
        assert Memory.record_enabled?(record)
      end
    end
  end

  describe "activation" do
    test "a copy replaces the chat's memory on its character's turn", %{scope: scope, chat: chat} = ctx do
      bob_book = book!(scope, "Bob's memories")
      settings!(scope, chat, %{"character_book_ids" => %{ctx.bob.id => bob_book.id}, "cast_ids" => [ctx.bob.id]})
      messages!(ctx, ctx.alice, 4)
      stub_reply(@memory)
      canonical = memory!(scope, chat, 0, 3)
      assert [copy] = copies(canonical)
      {:ok, _} = Messages.send_message(scope, chat, ctx.alice.id, "Back at the inn.")

      bob_turn = activated(scope, chat, character: ctx.bob)
      assert copy.lore_entry_id in bob_turn
      refute canonical.lore_entry_id in bob_turn

      alice_turn = activated(scope, chat, character: ctx.alice)
      assert canonical.lore_entry_id in alice_turn
      refute copy.lore_entry_id in alice_turn

      preview = activated(scope, chat, [])
      assert canonical.lore_entry_id in preview
      refute copy.lore_entry_id in preview

      assert bob_book.id in Enum.map(Lore.books_for_chat(chat, [ctx.bob.id]), & &1.id)
      refute bob_book.id in Enum.map(Lore.books_for_chat(chat, [ctx.alice.id]), & &1.id)
      assert bob_book.id in Enum.map(Lore.books_for_chat(chat), & &1.id)
    end
  end

  describe "elsewhere" do
    test "regenerating the chat's memory is not an overlap with its copies; a copy is refused", %{scope: scope} = ctx do
      %{canonical: canonical} = copied!(ctx)
      stub_reply(@memory)

      assert {:ok, %Job{}} = Memory.regenerate(scope, ctx.chat, canonical)
      assert Memory.regenerate(scope, ctx.chat, hd(copies(canonical))) == {:error, :copy}
    end

    test "a locked book lives in the user's other chats; with no responder copies stay out of their own chat",
         %{scope: scope} = ctx do
      %{canonical: canonical, bob_book: bob_book} = copied!(ctx)
      bob_copy = Enum.find(copies(canonical), &(&1.lore_book_id == bob_book.id))
      other = chat!(scope, "Bob's other chat", [ctx.player, ctx.bob])

      assert bob_book.id in Enum.map(Lore.books_for_chat(other), & &1.id)
      assert bob_book.id in Enum.map(Lore.books_for_chat(other, [ctx.bob.id]), & &1.id)
      refute bob_book.id in Enum.map(Lore.books_for_chat(other, [ctx.player.id]), & &1.id)

      assert bob_copy.lore_entry_id in considered(scope, other)
      refute bob_copy.lore_entry_id in considered(scope, ctx.chat)
      assert canonical.lore_entry_id in considered(scope, ctx.chat)
    end

    test "rollback deletes the chat's memory and its copies", %{scope: scope} = ctx do
      %{canonical: canonical, messages: messages} = copied!(ctx)
      :ok = Mythweaver.Settings.put(scope, :site, "memory.rollback_enabled", true)

      {:ok, _} = Messages.delete_message(scope, Enum.at(messages, 1))

      refute Repo.get(Record, canonical.id)
      assert copies(canonical) == []
      assert Repo.all(from(r in Record, where: r.chat_id == ^ctx.chat.id)) == []
    end
  end

  describe "locks" do
    test "a solo chat with a locked character saves into the locked book", %{scope: scope} = ctx do
      solo = chat!(scope, "Solo", [ctx.player, ctx.alice])
      book = Memory.ensure_book(scope, solo)

      assert {:ok, %CharacterBook{lore_book_id: lore_book_id, book: %{id: lore_book_id}}} =
               CharacterBooks.lock_character_book(scope, solo, ctx.alice.id)

      assert lore_book_id == book.id
      other = chat!(scope, "Another solo", [ctx.player, ctx.alice])
      assert Memory.chat_settings(scope, other).memory_book_id == book.id
      assert Memory.ensure_book(scope, other).id == book.id

      assert CharacterBooks.unlock_character_book(scope, solo, ctx.alice.id) == :ok
      assert CharacterBooks.character_lock(scope, ctx.alice.id) == nil
      assert Memory.chat_settings(scope, chat!(scope, "Third solo", [ctx.player, ctx.alice])).memory_book_id == nil
    end

    test "a group chat locks a character to its book here", %{scope: scope, chat: chat} = ctx do
      assert CharacterBooks.lock_character_book(scope, chat, ctx.alice.id) == {:error, :no_book}
      assert CharacterBooks.lock_character_book(scope, chat, ctx.player.id) == {:error, :not_found}

      book = book!(scope, "Alice's memories")
      settings!(scope, chat, %{"character_book_ids" => %{ctx.alice.id => book.id}})

      assert {:ok, %CharacterBook{lore_book_id: lore_book_id}} =
               CharacterBooks.lock_character_book(scope, chat, ctx.alice.id)

      assert lore_book_id == book.id
      assert CharacterBooks.character_locks(scope, [ctx.alice.id, ctx.bob.id]) |> Map.keys() == [ctx.alice.id]

      # The lock wins over the chat's choice.
      other = book!(scope, "Other book")
      settings!(scope, chat, %{"character_book_ids" => %{ctx.alice.id => other.id}})
      assert CharacterBooks.character_book(scope, chat, ctx.alice.id).id == book.id
    end

    test "the present cast must be the chat's characters", %{scope: scope, chat: chat} = ctx do
      stranger = character!(scope, "Stranger")
      settings = Memory.chat_settings(scope, chat)

      assert Memory.update_chat_settings(scope, settings, %{"cast_ids" => [stranger.id]}) == {:error, :unauthorized}
      assert Memory.update_chat_settings(scope, settings, %{"cast_ids" => [ctx.player.id]}) == {:error, :unauthorized}
      assert {:ok, %{cast_ids: [bob_id]}} = Memory.update_chat_settings(scope, settings, %{"cast_ids" => [ctx.bob.id]})
      assert bob_id == ctx.bob.id
    end

    test "a character book must be one the user may edit", %{scope: scope, chat: chat} = ctx do
      {:ok, theirs} = Lore.create_book(scope!(%{role: :user}), %{name: "Theirs"})
      settings = Memory.chat_settings(scope, chat)

      assert Memory.update_chat_settings(scope, settings, %{"character_book_ids" => %{ctx.alice.id => theirs.id}}) ==
               {:error, :unauthorized}
    end

    test "a lock whose book is no longer editable is broken and gives no copies", %{scope: scope, chat: chat} = ctx do
      bob_book = book!(scope, "Bob's memories")
      settings!(scope, chat, %{"character_book_ids" => %{ctx.bob.id => bob_book.id}})
      {:ok, lock} = CharacterBooks.lock_character_book(scope, chat, ctx.bob.id)
      refute CharacterBooks.lock_broken?(scope, lock)

      other_user = scope!(%{role: :user}).user
      bob_book |> Ecto.Changeset.change(user_id: other_user.id) |> Repo.update!()
      assert CharacterBooks.lock_broken?(scope, CharacterBooks.character_lock(scope, ctx.bob.id))

      # A broken lock does not fall back to the chat's own choice.
      fallback = book!(scope, "Fallback")
      settings!(scope, chat, %{"character_book_ids" => %{ctx.bob.id => fallback.id}, "cast_ids" => [ctx.bob.id]})
      assert CharacterBooks.character_book(scope, chat, ctx.bob.id) == nil

      messages!(ctx, ctx.alice, 4)
      stub_reply(@memory)
      assert copies(memory!(scope, chat, 0, 3)) == []

      assert CharacterBooks.unlock_character_book(scope, chat, ctx.bob.id) == :ok
      assert CharacterBooks.character_book(scope, chat, ctx.bob.id).id == fallback.id
    end

    test "a chat assigns a character book, optionally locked, and removes the setup",
         %{scope: scope, chat: chat} = ctx do
      book = book!(scope, "Alice's memories")
      bob_book = book!(scope, "Bob's memories")
      theirs = book!(scope!(%{role: :user}), "Theirs")
      %{id: alice_id} = ctx.alice
      %{id: book_id} = book

      assert CharacterBooks.assign_character_book(scope, chat, ctx.player.id, book.id, false) == {:error, :not_found}
      assert CharacterBooks.assign_character_book(scope, chat, ctx.alice.id, theirs.id, true) == {:error, :unauthorized}
      assert Memory.chat_settings(scope, chat).character_book_ids == %{}
      assert CharacterBooks.character_lock(scope, ctx.alice.id) == nil

      assert {:ok, %{character_book_ids: %{^alice_id => ^book_id}}} =
               CharacterBooks.assign_character_book(scope, chat, ctx.alice.id, book.id, false)

      assert CharacterBooks.character_lock(scope, ctx.alice.id) == nil

      assert {:ok, _} = CharacterBooks.assign_character_book(scope, chat, ctx.bob.id, bob_book.id, true)
      assert CharacterBooks.character_lock(scope, ctx.bob.id).lore_book_id == bob_book.id

      assert CharacterBooks.remove_character_book(scope, chat, ctx.bob.id) == :ok
      assert Memory.chat_settings(scope, chat).character_book_ids == %{alice_id => book_id}
      assert CharacterBooks.character_lock(scope, ctx.bob.id) == nil
    end
  end

  ## Helpers

  # Alice speaks; Bob, locked to his book, is a silent witness; Alice has a book in this chat.
  defp copied!(%{scope: scope, chat: chat} = ctx) do
    alice_book = book!(scope, "Alice's memories")
    bob_book = book!(scope, "Bob's memories")
    settings!(scope, chat, %{"character_book_ids" => %{ctx.alice.id => alice_book.id, ctx.bob.id => bob_book.id}})
    {:ok, _lock} = CharacterBooks.lock_character_book(scope, chat, ctx.bob.id)
    settings!(scope, chat, %{"character_book_ids" => %{ctx.alice.id => alice_book.id}, "cast_ids" => [ctx.bob.id]})
    messages = messages!(ctx, ctx.alice, 4)
    stub_reply(@memory)

    {:ok, job} = Memory.create_memory(scope, chat, 0, 3, review: false)
    assert %Job{status: :completed, result: %{"record_id" => id}} = await_job(scope, job)

    %{canonical: Repo.get!(Record, id), job: job, alice_book: alice_book, bob_book: bob_book, messages: messages}
  end

  # A memory of `first..last`, saved without review.
  defp memory!(scope, chat, first, last) do
    {:ok, job} = Memory.create_memory(scope, chat, first, last, review: false)
    assert %Job{status: :completed, result: %{"record_id" => id}} = await_job(scope, job)
    Repo.get!(Record, id)
  end

  defp reload(%Record{id: id}), do: Record |> Repo.get!(id) |> Repo.preload(entry: :book_entries)

  # Entries activated in `chat` with `opts`.
  defp activated(scope, chat, opts) do
    result = Activation.resolve(scope, Chats.get_chat!(chat.id), opts)
    Enum.map(result.activated, & &1.entry.id)
  end

  defp consolidation_prompt!(scope) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Consolidation: Test", purpose: :consolidation})

    {:ok, block} =
      Prompts.create_block(scope, %{name: "Sources", role: :user, content: "{{ anchors.memory.sources_text }}"})

    {:ok, _} = Prompts.add_block(scope, prompt, block)
    prompt
  end

  defp copies(%Record{id: id}) do
    Repo.all(
      from(r in Record,
        where: r.canonical_id == ^id,
        order_by: [asc: r.lore_book_id],
        preload: [entry: :entry_characters]
      )
    )
  end

  defp filter(%Record{entry: %LoreEntry{entry_characters: characters}}),
    do: characters |> Enum.map(& &1.character_id) |> Enum.sort()

  # Entries the chat's activation considered: activated or rejected.
  defp considered(scope, chat) do
    result = Activation.resolve(scope, Chats.get_chat!(chat.id))
    Enum.map(result.activated ++ result.rejected, & &1.entry.id)
  end

  defp settings!(scope, chat, attrs) do
    {:ok, settings} = Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), attrs)
    settings
  end

  defp await_job(scope, %Job{id: id}) do
    receive do
      {:job_changed, %{id: ^id, status: status}} when status in [:completed, :failed, :canceled, :review] ->
        Jobs.get_job(scope, id)
    after
      2000 -> flunk("job #{id} did not finish; now #{Jobs.get_job(scope, id).status}")
    end
  end

  # `n` finished jobs queued by `parent`.
  defp await_children(scope, parent, n, done \\ [])
  defp await_children(_scope, _parent, n, done) when length(done) == n, do: done

  defp await_children(scope, %Job{id: parent_id} = parent, n, done) do
    receive do
      {:job_changed, %{id: id, status: status}} when status in [:completed, :failed, :canceled, :review] ->
        case Jobs.get_job(scope, id) do
          %Job{parent_id: ^parent_id} = job -> await_children(scope, parent, n, [job | done])
          _other -> await_children(scope, parent, n, done)
        end
    after
      2000 -> flunk("#{n - length(done)} child jobs of #{parent_id} did not finish")
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

  # `count` messages alternating `speaker` and the player, starting with the speaker.
  defp messages!(%{scope: scope, chat: chat, player: player}, speaker, count) do
    for i <- 1..count do
      author = if rem(i, 2) == 1, do: speaker, else: player
      {:ok, message} = Messages.send_message(scope, chat, author.id, "Line #{i}")
      message
    end
  end

  defp book!(scope, name) do
    {:ok, book} = Lore.create_book(scope, %{name: name})
    book
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp chat!(scope, name, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: name,
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

  defp character_prompt!(scope) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Memory: Character test", purpose: :memory})

    {:ok, block} =
      Prompts.create_block(scope, %{name: "Perspective", content: "Perspective of {{ anchors.memory.character }}."})

    {:ok, scene} =
      Prompts.create_block(scope, %{name: "Copy scene", role: :user, content: "{{ anchors.memory.scene }}"})

    {:ok, _} = Prompts.add_block(scope, prompt, block)
    {:ok, _} = Prompts.add_block(scope, prompt, scene)
    prompt
  end
end
