defmodule Mythweaver.Memory.RollbackTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Messages

  setup do
    scope = scope!()
    player = character!(scope, "Player")
    responder = character!(scope, "Responder")

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Rollback chat",
        participants: [%{character_id: player.id}, %{character_id: responder.id}],
        player_character_id: player.id
      })

    chat = Chats.get_chat!(chat.id)
    book = Memory.ensure_book(scope, chat)

    messages =
      for i <- 1..6 do
        {:ok, message} = Messages.send_message(scope, chat, responder.id, "Line #{i}")
        message
      end

    # Memories 1..3 cover positions 0–1, 2–3, 4–5.
    memories = for i <- 1..3, do: memory!(scope, chat, book, i)
    {:ok, _} = Memory.set_highest_processed(scope, chat, 5)

    %{scope: scope, chat: chat, book: book, messages: messages, memories: memories}
  end

  defp rollback_on!(scope, attrs \\ %{}) do
    Enum.each(Map.merge(%{rollback_enabled: true}, attrs), fn {k, v} ->
      :ok = Mythweaver.Settings.put(scope, :site, "memory.#{k}", v)
    end)
  end

  test "affected scope deletes only the memory covering the message", %{scope: scope} = ctx do
    rollback_on!(scope)
    [m1, m2, m3] = ctx.memories
    {:ok, _} = Messages.delete_message(scope, Enum.at(ctx.messages, 2))

    assert surviving(ctx) == [m1.id, m3.id]
    refute Repo.get(LoreEntry, m2.lore_entry_id)
  end

  test "full scope deletes every memory ending at or after the message, and moves the boundary back",
       %{scope: scope} = ctx do
    rollback_on!(scope, %{rollback_scope: :full})
    [m1, _m2, _m3] = ctx.memories
    {:ok, _} = Messages.delete_message(scope, Enum.at(ctx.messages, 2))

    assert surviving(ctx) == [m1.id]
    assert Memory.chat_settings(scope, ctx.chat).highest_processed == 1
  end

  test "deleting a consolidated memory deletes its Arc and re-enables the Arc's other sources", %{scope: scope} = ctx do
    rollback_on!(scope)
    [m1, m2, _m3] = ctx.memories
    {:ok, arc_entry} = Lore.create_entry(scope, %{name: "Arc", content: "Arc.", keywords: ["arc"]}, [ctx.book.id])

    arc =
      Repo.insert!(%Record{
        lore_entry_id: arc_entry.id,
        lore_book_id: ctx.book.id,
        chat_id: ctx.chat.id,
        kind: :consolidation,
        tier: 1
      })

    for m <- [m1, m2] do
      Lore.set_memberships_enabled([{m.lore_book_id, m.lore_entry_id}], false)
      m |> Ecto.Changeset.change(consolidated_into_id: arc.id, disabled_by_consolidation: true) |> Repo.update!()
    end

    {:ok, _} = Messages.delete_message(scope, Enum.at(ctx.messages, 2))

    refute Repo.get(LoreEntry, arc_entry.id)
    refute Repo.get(Record, m2.id)
    restored = Repo.get!(Record, m1.id)
    assert %Record{consolidated_into_id: nil, disabled_by_consolidation: false} = restored
    assert Memory.record_enabled?(restored)
    assert Memory.chat_settings(scope, ctx.chat).highest_processed == 5
  end

  test "deletes only this chat's records in books the scope may edit", %{scope: scope} = ctx do
    rollback_on!(scope)
    [_m1, m2, _m3] = ctx.memories

    # A record of this chat pointing at another user's entry, as a rewritten regeneration once left.
    other = scope!(%{role: :user})
    {:ok, their_book} = Lore.create_book(other, %{name: "Theirs"})

    {:ok, their_entry} =
      Lore.create_entry(other, %{name: "Theirs", content: "Not yours.", keywords: ["t"]}, [their_book.id])

    Repo.insert!(%Record{
      lore_entry_id: their_entry.id,
      lore_book_id: their_book.id,
      chat_id: ctx.chat.id,
      kind: :memory,
      tier: 0,
      sequence: 9,
      range_start: 2,
      range_end: 3
    })

    # An Arc another chat built on this chat's memory.
    {:ok, other_chat} =
      Chats.create_chat(scope, %{
        name: "Other chat",
        participants: Enum.map(ctx.chat.participants, &%{character_id: &1.character_id}),
        player_character_id: ctx.chat.player_character_id
      })

    {:ok, arc_entry} = Lore.create_entry(scope, %{name: "Arc", content: "Arc.", keywords: ["arc"]}, [ctx.book.id])

    arc =
      Repo.insert!(%Record{
        lore_entry_id: arc_entry.id,
        lore_book_id: ctx.book.id,
        chat_id: other_chat.id,
        kind: :consolidation,
        tier: 1
      })

    m2 |> Ecto.Changeset.change(consolidated_into_id: arc.id) |> Repo.update!()

    {:ok, _} = Messages.delete_message(scope, Enum.at(ctx.messages, 2))

    refute Repo.get(Record, m2.id)
    assert Repo.get(LoreEntry, their_entry.id)
    assert Repo.get(LoreEntry, arc_entry.id)
  end

  test "side prompts are restored only while the entry is as the side prompt wrote it", %{scope: scope} = ctx do
    rollback_on!(scope)
    created = side_prompt_record!(ctx, "Created", %{"existed" => false, "prior" => nil, "range" => [2, 3]})

    prior = %{"name" => "Tracker", "content" => "Before.", "keywords" => ["t"], "enabled" => true}
    updated = side_prompt_record!(ctx, "Updated", %{"existed" => true, "prior" => prior, "range" => [0, 3]})

    edited = side_prompt_record!(ctx, "Edited", %{"existed" => false, "prior" => nil, "range" => [2, 3]})
    {:ok, _} = Lore.update_entry(scope, edited.entry, %{content: "User edit."})

    {:ok, _} = Messages.delete_message(scope, Enum.at(ctx.messages, 3))

    refute Repo.get(LoreEntry, created.lore_entry_id)
    assert %LoreEntry{name: "Tracker", content: "Before."} = Repo.get!(LoreEntry, updated.lore_entry_id)
    assert Repo.get!(Record, updated.id).snapshot == %{}
    assert %LoreEntry{content: "User edit."} = Repo.get!(LoreEntry, edited.lore_entry_id)
  end

  test "with rollback off nothing changes", %{scope: scope} = ctx do
    {:ok, _} = Messages.delete_message(scope, Enum.at(ctx.messages, 2))

    assert length(surviving(ctx)) == 3
    assert Memory.chat_settings(scope, ctx.chat).highest_processed == 5
  end

  describe "preview/2" do
    test "lists the covering memory and its consolidation and deletes nothing", %{scope: scope} = ctx do
      rollback_on!(scope)
      [m1, m2, _m3] = ctx.memories
      {:ok, arc_entry} = Lore.create_entry(scope, %{name: "Arc", content: "Arc.", keywords: ["arc"]}, [ctx.book.id])

      arc =
        Repo.insert!(%Record{
          lore_entry_id: arc_entry.id,
          lore_book_id: ctx.book.id,
          chat_id: ctx.chat.id,
          kind: :consolidation,
          tier: 1
        })

      for m <- [m1, m2], do: m |> Ecto.Changeset.change(consolidated_into_id: arc.id) |> Repo.update!()
      count = Repo.aggregate(Record, :count)

      preview = Memory.Rollback.preview(scope, ctx.chat.id, [2])

      assert Enum.map(preview.memories, & &1.id) == [m2.id]
      assert [%Record{id: arc_id, entry: %LoreEntry{name: "Arc"}}] = preview.consolidations
      assert arc_id == arc.id
      assert Repo.aggregate(Record, :count) == count
    end

    test "is empty with rollback off", %{scope: scope} = ctx do
      assert Memory.Rollback.preview(scope, ctx.chat.id, [2]) == %{memories: [], consolidations: [], side_prompts: []}
    end

    test "unions the memories covering each position, skipping one between them", %{scope: scope} = ctx do
      rollback_on!(scope)
      [m1, _m2, m3] = ctx.memories

      preview = Memory.Rollback.preview(scope, ctx.chat.id, [0, 4])

      assert Enum.map(preview.memories, & &1.id) == [m1.id, m3.id]
    end

    test "full scope lists every memory from the earliest position on", %{scope: scope} = ctx do
      rollback_on!(scope, %{rollback_scope: :full})
      [_m1, m2, m3] = ctx.memories

      preview = Memory.Rollback.preview(scope, ctx.chat.id, [4, 2])

      assert Enum.map(preview.memories, & &1.id) == [m2.id, m3.id]
    end
  end

  defp surviving(%{chat: chat}) do
    Repo.all(from(r in Record, where: r.chat_id == ^chat.id and r.kind == :memory, order_by: r.sequence, select: r.id))
  end

  defp memory!(scope, chat, book, i) do
    {:ok, entry} =
      Lore.create_entry(scope, %{name: "[#{i}] Memory", content: "Memory #{i}.", keywords: ["m#{i}"]}, [book.id])

    record =
      Repo.insert!(%Record{
        lore_entry_id: entry.id,
        lore_book_id: book.id,
        chat_id: chat.id,
        kind: :memory,
        tier: 0,
        sequence: i,
        range_start: 2 * i - 2,
        range_end: 2 * i - 1
      })

    Repo.preload(record, :entry)
  end

  defp side_prompt_record!(%{scope: scope, chat: chat, book: book}, content, snapshot) do
    {:ok, entry} = Lore.create_entry(scope, %{name: "Tracker", content: content, keywords: ["t"]}, [book.id])

    %Record{
      lore_entry_id: entry.id,
      lore_book_id: book.id,
      chat_id: chat.id,
      kind: :side_prompt,
      written_fingerprint: Scene.sha256(content),
      snapshot: snapshot
    }
    |> Repo.insert!()
    |> Repo.preload(:entry)
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end
end
