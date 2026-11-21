defmodule Mythweaver.MessagesSplitTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Record
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message

  setup do
    scope = scope!()
    player = character!(scope, "Player")
    other = character!(scope, "Other")

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Split chat",
        participants: [%{character_id: player.id}, %{character_id: other.id}],
        player_character_id: player.id
      })

    chat = Chats.get_chat!(chat.id)
    book = Memory.ensure_book(scope, chat)

    {:ok, m0} = Messages.send_message(scope, chat, other.id, "A")
    {:ok, m1} = Messages.send_message(scope, chat, player.id, "P1\n\nP2\n\nP3")
    {:ok, m2} = Messages.send_message(scope, chat, other.id, "C")

    r1 = memory!(scope, chat, book, 1, 1, 1)
    r2 = memory!(scope, chat, book, 2, 2, 2)
    {:ok, _} = Memory.set_highest_processed(scope, chat, 2)

    job =
      Repo.insert!(%Job{
        tag: :memory,
        origin: :background,
        status: :completed,
        label: "m",
        chat_id: chat.id,
        params: %{"start" => 2, "end" => 2},
        range_start: 2,
        range_end: 2
      })

    %{scope: scope, chat: chat, player: player, other: other, messages: [m0, m1, m2], records: [r1, r2], job: job}
  end

  describe "split_message/4" do
    test "splits into pieces, renumbers later messages and shifts memory positions", %{scope: scope} = ctx do
      %{chat: chat, other: other, messages: [_m0, m1, _m2]} = ctx
      Messages.subscribe(chat)

      assert {:ok, split} =
               Messages.split_message(scope, chat, m1, "P1\n\nP2\n\nP3", [
                 %{boundary: 1, author_id: nil},
                 %{boundary: 2, author_id: other.id}
               ])

      assert_receive {:messages_split, %{position: 1, shift: 2}}

      transcript = Messages.list_messages(chat)
      assert Enum.map(transcript, &Message.active_content/1) == ["A", "P1", "P2", "P3", "C"]
      assert Enum.map(transcript, & &1.position) == [0, 1, 2, 3, 4]

      [_, _, piece1, piece2, _] = transcript
      assert piece1.author_character_id == m1.author_character_id
      assert piece1.author_is_player
      assert piece2.author_character_id == other.id
      refute piece2.author_is_player

      [original, active] = split.bodies
      assert active.active and active.origin == :split
      assert active.source_body_id == original.id

      assert ranges(chat) == [{1, 3}, {4, 4}]
      assert Memory.chat_settings(scope, chat).highest_processed == 4

      job = Repo.get!(Job, ctx.job.id)
      assert {job.range_start, job.range_end} == {4, 4}
      assert job.params == %{"start" => 4, "end" => 4}
    end

    test "a piece marked :scratchpad becomes a scratchpad and moves no position for itself", %{scope: scope} = ctx do
      %{chat: chat, messages: [_m0, m1, _m2]} = ctx
      Messages.subscribe(chat)

      assert {:ok, _} =
               Messages.split_message(scope, chat, m1, "P1\n\nP2\n\nP3", [
                 %{boundary: 1, author_id: nil},
                 %{boundary: 2, author_id: :scratchpad}
               ])

      assert_receive {:messages_split, %{position: 1, shift: 1}}
      assert chat |> Messages.list_messages() |> Enum.map(&Message.active_content/1) == ["A", "P1", "P2", "C"]
      assert [%{content: "P3", message_id: id}] = Messages.list_scratchpads(scope, chat)
      assert id == m1.id
      assert ranges(chat) == [{1, 2}, {3, 3}]
    end

    test "refuses text that changed since it was planned", %{scope: scope} = ctx do
      %{chat: chat, messages: [_m0, m1, _m2]} = ctx

      assert Messages.split_message(scope, chat, m1, "P1\n\nP2", [%{boundary: 1, author_id: nil}]) == {:error, :stale}
      assert chat |> Messages.list_messages() |> Enum.map(& &1.position) == [0, 1, 2]
      assert ranges(chat) == [{1, 1}, {2, 2}]
    end
  end

  describe "merge_messages/2" do
    test "joins a run into its first message without rolling back memories", %{scope: scope} = ctx do
      %{chat: chat, messages: [_m0, m1, m2]} = ctx
      :ok = Mythweaver.Settings.put(scope, :site, "memory.rollback_enabled", true)
      :ok = Mythweaver.Settings.put(scope, :site, "memory.rollback_delete_memories", true)

      assert {:ok, merged} = Messages.merge_messages(scope, chat, [m2.id, m1.id])
      assert merged.id == m1.id
      assert Message.active_content(merged) == "P1\n\nP2\n\nP3\n\nC"
      assert Message.active_body(merged).origin == :merge
      refute Messages.get_message(scope, m2.id)
      assert ranges(chat) == [{1, 1}, {2, 2}]
    end

    test "refuses a non-contiguous run", %{scope: scope} = ctx do
      %{chat: chat, messages: [m0, _m1, m2]} = ctx
      assert Messages.merge_messages(scope, chat, [m0.id, m2.id]) == {:error, :not_contiguous}
    end
  end

  describe "scratchpads" do
    test "split the newest message's tail to a scratchpad, then append it back", %{scope: scope} = ctx do
      %{chat: chat, player: player} = ctx
      {:ok, last} = Messages.send_message(scope, chat, player.id, "H1\n\nH2\n\nT")

      assert {:ok, head} = Messages.split_to_scratchpad(scope, chat, last, "H1\n\nH2\n\nT", 2)
      assert Message.active_content(head) == "H1\n\nH2"
      assert [%{content: "T"} = scratchpad] = Messages.list_scratchpads(scope, chat)

      assert {:ok, appended} = Messages.append_scratchpad(scope, scratchpad)
      assert Message.active_content(appended) == "H1\n\nH2\n\nT"
      assert Message.active_body(appended).origin == :append
      assert Messages.list_scratchpads(scope, chat) == []
    end

    test "only the newest message can be split to a scratchpad", %{scope: scope} = ctx do
      %{chat: chat, messages: [_m0, m1, _m2]} = ctx
      assert Messages.split_to_scratchpad(scope, chat, m1, "P1\n\nP2\n\nP3", 1) == {:error, :not_last}
    end

    test "a scratchpad whose message was deleted cannot be appended", %{scope: scope} = ctx do
      %{chat: chat, player: player} = ctx
      {:ok, last} = Messages.send_message(scope, chat, player.id, "H\n\nT")
      {:ok, _} = Messages.split_to_scratchpad(scope, chat, last, "H\n\nT", 1)
      {:ok, _} = Messages.delete_message(scope, last)

      assert [scratchpad] = Messages.list_scratchpads(scope, chat)
      assert Messages.append_scratchpad(scope, scratchpad) == {:error, :orphaned}
    end
  end

  defp ranges(chat) do
    Repo.all(
      from(r in Record,
        where: r.chat_id == ^chat.id and r.kind == :memory,
        order_by: r.sequence,
        select: {r.range_start, r.range_end}
      )
    )
  end

  defp memory!(scope, chat, book, i, first, last) do
    {:ok, entry} =
      Lore.create_entry(scope, %{name: "[#{i}] Memory", content: "Memory #{i}.", keywords: ["m#{i}"]}, [book.id])

    Repo.insert!(%Record{
      lore_entry_id: entry.id,
      lore_book_id: book.id,
      chat_id: chat.id,
      kind: :memory,
      tier: 0,
      sequence: i,
      range_start: first,
      range_end: last
    })
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end
end
