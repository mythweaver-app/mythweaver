defmodule Mythweaver.Memory.AdoptionTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Consolidation
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.RecordSource

  setup do
    scope = scope!()
    {:ok, book} = Lore.create_book(scope, %{name: "Saga"})
    %{scope: scope, book: book}
  end

  defp entry!(scope, name, book_ids) do
    {:ok, entry} = Lore.create_entry(scope, %{name: name, content: "#{name} text", keywords: ["k"]}, book_ids)
    entry
  end

  defp record!(entry, book, attrs) do
    Repo.insert!(struct(Record, Map.merge(%{lore_entry_id: entry.id, lore_book_id: book.id}, attrs)))
  end

  defp records(book) do
    Repo.all(from r in Record, where: r.lore_book_id == ^book.id, order_by: r.sequence, preload: :entry)
  end

  describe "mark_as_memories/3" do
    test "numbers new memories after the book's last, in name order, skipping recorded entries and non-members",
         %{scope: scope, book: book} do
      second = entry!(scope, "02 - Second", [book.id])
      first = entry!(scope, "01 - First", [book.id])
      existing = entry!(scope, "00 - Existing", [book.id])
      clip = entry!(scope, "Clip", [book.id])
      {:ok, other} = Lore.create_book(scope, %{name: "Other"})
      outsider = entry!(scope, "Outsider", [other.id])

      record!(existing, book, %{kind: :memory, tier: 0, sequence: 4})
      record!(clip, book, %{kind: :clip})

      ids = [second.id, first.id, existing.id, clip.id, outsider.id, "not-a-uuid"]
      assert {:ok, %{marked: 2, skipped: 2}} = Memory.mark_as_memories(scope, book, ids)

      memories = Enum.filter(records(book), &(&1.kind == :memory))

      assert Enum.map(memories, &{&1.entry.name, &1.sequence}) == [
               {"00 - Existing", 4},
               {"01 - First", 5},
               {"02 - Second", 6}
             ]

      assert Enum.all?(memories, &(&1.tier == 0))

      adopted = Enum.reject(memories, &(&1.entry.id == existing.id))
      assert Enum.all?(adopted, &(is_nil(&1.chat_id) and is_nil(&1.range_start) and is_nil(&1.range_end)))
      refute Repo.exists?(from r in Record, where: r.lore_entry_id == ^outsider.id)

      assert Memory.memory_kinds([first.id, clip.id, outsider.id]) == %{first.id => :memory, clip.id => :clip}
    end

    test "refuses a book the scope can't edit", %{book: book, scope: scope} do
      entry = entry!(scope, "Site entry", [book.id])
      user = scope!(%{role: :user})

      assert Memory.mark_as_memories(user, book, [entry.id]) == {:error, :unauthorized}
      assert Memory.unmark_memories(user, book, [entry.id]) == {:error, :unauthorized}
      assert records(book) == []
    end

    test "tells open memory panels of chats writing into the book", %{scope: scope, book: book} do
      {:ok, a} = Characters.create_character(scope, %{name: "A"})
      {:ok, b} = Characters.create_character(scope, %{name: "B"})

      {:ok, chat} =
        Chats.create_chat(scope, %{
          name: "Tale",
          player_character_id: a.id,
          participants: [%{character_id: a.id}, %{character_id: b.id}]
        })

      {:ok, _settings} =
        Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), %{memory_book_id: book.id})

      Phoenix.PubSub.subscribe(Mythweaver.PubSub, Memory.topic(chat.id))
      entry = entry!(scope, "Scene", [book.id])

      assert {:ok, %{marked: 1}} = Memory.mark_as_memories(scope, book, [entry.id])
      assert_receive {:memory_changed, chat_id}
      assert chat_id == chat.id
    end
  end

  describe "unmark_memories/3" do
    test "deletes plain memories and keeps consolidated ones, their sources' consolidations and other kinds",
         %{scope: scope, book: book} do
      plain = entry!(scope, "Plain", [book.id])
      source = entry!(scope, "Source", [book.id])
      arc = entry!(scope, "Arc", [book.id])
      clip = entry!(scope, "Clip", [book.id])

      record!(plain, book, %{kind: :memory, tier: 0, sequence: 1})
      arc_record = record!(arc, book, %{kind: :consolidation, tier: 1, sequence: 1})
      source_record = record!(source, book, %{kind: :memory, tier: 0, sequence: 2, consolidated_into_id: arc_record.id})
      Repo.insert!(%RecordSource{record_id: arc_record.id, source_id: source_record.id})
      record!(clip, book, %{kind: :clip})

      ids = [plain.id, source.id, arc.id, clip.id]
      assert {:ok, %{unmarked: 1, skipped: 3}} = Memory.unmark_memories(scope, book, ids)

      assert Enum.map(records(book), & &1.entry.name) |> Enum.sort() == ["Arc", "Clip", "Source"]
      # The lore entry itself stays.
      assert Lore.get_entry(scope, plain.id)
    end

    test "keeps a memory that is a consolidation's source even when not marked consolidated",
         %{scope: scope, book: book} do
      source = entry!(scope, "Source", [book.id])
      arc = entry!(scope, "Arc", [book.id])
      arc_record = record!(arc, book, %{kind: :consolidation, tier: 1, sequence: 1})
      source_record = record!(source, book, %{kind: :memory, tier: 0, sequence: 1})
      Repo.insert!(%RecordSource{record_id: arc_record.id, source_id: source_record.id})

      assert {:ok, %{unmarked: 0, skipped: 1}} = Memory.unmark_memories(scope, book, [source.id])
      assert Repo.get(Record, source_record.id)
    end
  end

  describe "set_entry_memory/4" do
    setup %{scope: scope, book: book} do
      memories = for i <- 1..3, do: entry!(scope, "00#{i} - Memory", [book.id])
      {:ok, _} = Memory.mark_as_memories(scope, book, Enum.map(memories, & &1.id))
      arc = entry!(scope, "[ARC 001] - Arc", [book.id])
      {:ok, %{marked: 1}} = Memory.mark_as_memories(scope, book, [arc.id])
      by_entry = Map.new(records(book), &{&1.lore_entry_id, &1})
      %{memories: Enum.map(memories, &by_entry[&1.id]), arc: arc, arc_record: by_entry[arc.id]}
    end

    test "turns a mis-filed memory into an Arc consolidated from the picked memories",
         %{scope: scope, book: book, arc: arc, memories: [one, two, three]} do
      assert {:ok, record} =
               Memory.set_entry_memory(scope, arc, book, %{tier: 1, sequence: nil, source_ids: [one.id, two.id]})

      assert %Record{kind: :consolidation, tier: 1, sequence: 1} = record
      assert record.snapshot["source_ids"] == [one.id, two.id]

      for source <- [one, two], do: assert(Repo.get!(Record, source.id).consolidated_into_id == record.id)
      assert Repo.get!(Record, three.id).consolidated_into_id == nil
      assert Repo.aggregate(from(s in RecordSource, where: s.record_id == ^record.id), :count) == 2

      assert Enum.map(Consolidation.eligible(scope, book, 1), & &1.id) == [three.id]
      assert Enum.map(Consolidation.eligible(scope, book, 2), & &1.id) == [record.id]
    end

    test "a dropped source is released and switched back on; clearing the type releases the rest",
         %{scope: scope, book: book, arc: arc, memories: [one, two, _three]} do
      {:ok, record} = Memory.set_entry_memory(scope, arc, book, %{tier: 1, sequence: nil, source_ids: [one.id, two.id]})
      Repo.update_all(from(r in Record, where: r.id == ^one.id), set: [disabled_by_consolidation: true])
      Lore.set_memberships_enabled([{book.id, one.lore_entry_id}], false)

      assert {:ok, _} = Memory.set_entry_memory(scope, arc, book, %{tier: 1, sequence: nil, source_ids: [two.id]})
      assert %Record{consolidated_into_id: nil, disabled_by_consolidation: false} = Repo.get!(Record, one.id)
      assert Repo.get_by!(Lore.BookEntry, lore_book_id: book.id, lore_entry_id: one.lore_entry_id).enabled
      assert Repo.get!(Record, two.id).consolidated_into_id == record.id

      assert Memory.set_entry_memory(scope, arc, book, %{tier: nil, sequence: nil, source_ids: []}) == {:ok, nil}
      assert Repo.get(Record, record.id) == nil
      assert Repo.get!(Record, two.id).consolidated_into_id == nil
    end

    test "refuses to move a source out of its tier, or to rewrite a clip",
         %{scope: scope, book: book, arc: arc, memories: [one | _]} do
      {:ok, _} = Memory.set_entry_memory(scope, arc, book, %{tier: 1, sequence: nil, source_ids: [one.id]})
      source_entry = Lore.get_entry!(one.lore_entry_id)

      assert Memory.set_entry_memory(scope, source_entry, book, %{tier: nil, sequence: nil, source_ids: []}) ==
               {:error, :consolidated}

      assert {:ok, %Record{sequence: 9}} =
               Memory.set_entry_memory(scope, source_entry, book, %{tier: 0, sequence: 9, source_ids: []})

      clip = entry!(scope, "Clip", [book.id])
      record!(clip, book, %{kind: :clip})
      assert Memory.set_entry_memory(scope, clip, book, %{tier: 0, sequence: nil, source_ids: []}) == {:error, :managed}
    end
  end
end
