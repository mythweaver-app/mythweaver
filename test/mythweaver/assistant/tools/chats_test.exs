defmodule Mythweaver.Assistant.Tools.ChatsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Messages

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{System.unique_integer([:positive])}"})
    character
  end

  test "create_chat then update_chat with only a name keeps the participants" do
    scope = scope!()
    c1 = character!(scope, "A")
    c2 = character!(scope, "B")

    assert {:ok, %{"id" => id, "path" => "/chats/" <> _}} =
             run!(scope, "create_chat", %{"name" => "Tavern", "character_ids" => [c1.id, c2.id]})

    assert {:ok, %{"title" => "Renamed"}} = run!(scope, "update_chat", %{"id" => id, "name" => "Renamed"})

    chat = Chats.get_chat(scope, id)
    assert chat.name == "Renamed"
    assert chat.participants |> Enum.map(& &1.character_id) |> Enum.sort() == Enum.sort([c1.id, c2.id])
  end

  test "an assistant chat is not found by update and delete" do
    scope = scope!()
    {:ok, chat} = Chats.create_assistant_chat(scope)

    assert {:error, %{"error" => "Not found."}} = run!(scope, "update_chat", %{"id" => chat.id, "name" => "X"})
    assert {:error, %{"failed" => [%{"error" => "Not found."}]}} = run!(scope, "delete_chats", %{"ids" => [chat.id]})
    assert Chats.get_chat(scope, chat.id)
  end

  test "delete_chats removes a role-play chat" do
    scope = scope!()
    c1 = character!(scope, "A")
    c2 = character!(scope, "B")
    {:ok, %{"id" => id}} = run!(scope, "create_chat", %{"character_ids" => [c1.id, c2.id]})

    assert {:ok, %{"done" => [%{"deleted" => true}]}} = run!(scope, "delete_chats", %{"ids" => [id]})
    refute Chats.get_chat(scope, id)
  end

  test "a non-UUID id is an error map" do
    assert {:error, %{"error" => "id is not a valid id"}} = run!(scope!(), "update_chat", %{"id" => "nope"})
  end

  describe "read_chat_messages" do
    setup do
      scope = scope!()
      c1 = character!(scope, "A")
      c2 = character!(scope, "B")
      {:ok, %{"id" => id}} = run!(scope, "create_chat", %{"character_ids" => [c1.id, c2.id]})
      chat = Chats.get_chat(scope, id)

      for {author, text} <- [{c1, "one"}, {c2, "two"}, {c1, "three"}] do
        {:ok, _} = Messages.post_message(scope, chat, {:character, author.id}, text)
      end

      %{scope: scope, chat: chat, c2: c2}
    end

    test "reads numbers and ranges by the number shown in the chat, once each and in order", ctx do
      %{scope: scope, chat: chat, c2: c2} = ctx

      assert {:ok, %{"last_number" => 3, "omitted_from" => nil, "messages" => [%{"number" => 2} = row]}} =
               run!(scope, "read_chat_messages", %{"chat_id" => chat.id, "messages" => ["2"]})

      assert %{"content" => "two", "author" => author} = row
      assert author == c2.name

      assert {:ok, %{"messages" => rows}} =
               run!(scope, "read_chat_messages", %{"chat_id" => chat.id, "messages" => ["2-9", 1, " 2 - 3 "]})

      assert Enum.map(rows, & &1["number"]) == [1, 2, 3]
    end

    test "negative numbers count back from the newest message", %{scope: scope, chat: chat} do
      read = fn messages ->
        assert {:ok, %{"messages" => rows}} =
                 run!(scope, "read_chat_messages", %{"chat_id" => chat.id, "messages" => messages})

        Enum.map(rows, & &1["number"])
      end

      assert read.(["-1"]) == [3]
      assert read.(["-2--1"]) == [2, 3]
      assert read.(["2--1"]) == [2, 3]
      assert read.([-1]) == [3]
      # Before the first message: names nothing rather than clamping to #1.
      assert read.(["-9"]) == []
    end

    test "max_chars leaves out what runs past it and says where to resume", %{scope: scope, chat: chat} do
      long = String.duplicate("x", 40_000)
      [c | _] = chat.participants
      for _ <- 1..2, do: {:ok, _} = Messages.post_message(scope, chat, {:character, c.character_id}, long)

      assert {:ok, %{"omitted_from" => nil, "messages" => rows}} =
               run!(scope, "read_chat_messages", %{"chat_id" => chat.id, "messages" => ["1-5"]})

      assert Enum.map(rows, & &1["number"]) == [1, 2, 3, 4, 5]

      assert {:ok, %{"omitted_from" => 5, "messages" => rows}} =
               run!(scope, "read_chat_messages", %{"chat_id" => chat.id, "messages" => ["1-5"], "max_chars" => 50_000})

      assert Enum.map(rows, & &1["number"]) == [1, 2, 3, 4]

      assert {:error, %{"error" => "max_chars must be a positive integer."}} =
               run!(scope, "read_chat_messages", %{"chat_id" => chat.id, "messages" => ["1-5"], "max_chars" => 0})
    end

    test "refuses a reversed, malformed or oversized request", %{scope: scope, chat: chat} do
      for messages <- [["3-2"], ["-1--3"], ["two"], [0], []] do
        assert {:error, %{"error" => _}} =
                 run!(scope, "read_chat_messages", %{"chat_id" => chat.id, "messages" => messages})
      end

      assert {:error, %{"error" => "At most " <> _}} =
               run!(scope, "read_chat_messages", %{"chat_id" => chat.id, "messages" => ["1-150", "200-260"]})
    end

    test "never reads an assistant thread", %{scope: scope} do
      {:ok, thread} = Chats.create_assistant_chat(scope)

      assert {:error, %{"error" => "Not found."}} =
               run!(scope, "read_chat_messages", %{"chat_id" => thread.id, "messages" => ["1"]})
    end
  end

  describe "participants" do
    setup do
      scope = scope!()
      [a, b, c] = for name <- ~w(A B C), do: character!(scope, name)
      {:ok, %{"id" => id}} = run!(scope, "create_chat", %{"character_ids" => [a.id, b.id]})
      %{scope: scope, chat_id: id, a: a, b: b, c: c}
    end

    defp seats(scope, chat_id), do: Chats.get_chat(scope, chat_id).participants

    test "update_chat sets the turn-taking fields and rejects a bad enum", %{scope: scope, chat_id: id} do
      assert {:ok, _} =
               run!(scope, "update_chat", %{
                 "id" => id,
                 "allow_self_responses" => true,
                 "max_turns" => 3,
                 "auto_mode_delay" => 10,
                 "group_cards" => "join"
               })

      assert %{allow_self_responses: true, max_turns: 3, auto_mode_delay: 10, group_cards: :join} =
               Chats.get_chat(scope, id)

      assert {:error, %{"error" => "invalid", "fields" => %{group_cards: _}}} =
               run!(scope, "update_chat", %{"id" => id, "group_cards" => "nope"})
    end

    test "list_chats returns seat objects", %{scope: scope, chat_id: id, a: a} do
      assert {:ok, %{"chats" => [row]}} = run!(scope, "list_chats", %{})
      assert %{"id" => ^id, "player_character_id" => nil, "participants" => [seat, _]} = row
      assert %{"id" => _, "character_id" => character_id, "name" => _, "position" => 0, "muted" => false} = seat
      assert character_id == a.id
    end

    test "add_participants seats new characters and reports a duplicate", %{scope: scope, chat_id: id, a: a, c: c} do
      assert {:ok, %{"done" => [%{"character_id" => added, "chat_id" => ^id}], "failed" => [failed]}} =
               run!(scope, "add_participants", %{"chat_id" => id, "character_ids" => [a.id, c.id]})

      assert added == c.id
      assert %{"error" => "invalid", "fields" => %{chat_id: ["is already a participant of this chat"]}} = failed
      assert length(seats(scope, id)) == 3
    end

    test "remove_participants removes a seat but keeps two", %{scope: scope, chat_id: id, c: c} do
      {:ok, _} = run!(scope, "add_participants", %{"chat_id" => id, "character_ids" => [c.id]})
      [first, second, _] = seats(scope, id)

      assert {:ok, %{"done" => [%{"removed" => true}]}} =
               run!(scope, "remove_participants", %{"ids" => [first.id]})

      assert {:error, %{"failed" => [%{"error" => "A chat must keep at least two participants."}]}} =
               run!(scope, "remove_participants", %{"ids" => [second.id]})

      assert length(seats(scope, id)) == 2
    end

    test "reorder_participants persists order and refuses a bad list", %{scope: scope, chat_id: id, c: c} do
      {:ok, _} = run!(scope, "add_participants", %{"chat_id" => id, "character_ids" => [c.id]})
      [pa, pb, pc] = seats(scope, id)

      assert {:ok, _} =
               run!(scope, "reorder_participants", %{"chat_id" => id, "participant_ids" => [pc.id, pa.id, pb.id]})

      assert Enum.map(seats(scope, id), & &1.id) == [pc.id, pa.id, pb.id]

      assert {:error, %{"error" => "The ids must list every current item exactly once, in the new order."}} =
               run!(scope, "reorder_participants", %{"chat_id" => id, "participant_ids" => [pc.id, pa.id]})

      assert {:error, %{"error" => "participant_ids must be a list of at least 2 ids."}} =
               run!(scope, "reorder_participants", %{"chat_id" => id, "participant_ids" => [pc.id]})
    end

    test "update_participants changes several seats and refuses another character's outfit",
         %{scope: scope, chat_id: id, c: c} do
      [pa, pb] = seats(scope, id)

      assert {:ok, %{"done" => [%{"muted" => true, "talkativeness" => 0.2}, %{"muted" => true}]}} =
               run!(scope, "update_participants", %{
                 "items" => [
                   %{"id" => pa.id, "muted" => true, "talkativeness" => 0.2},
                   %{"id" => pb.id, "muted" => true}
                 ]
               })

      assert Enum.all?(seats(scope, id), & &1.muted)

      {:ok, outfit} = Mythweaver.Expressions.create_outfit(scope, c, "Armor")

      assert {:error,
              %{"failed" => [%{"error" => "invalid", "fields" => %{outfit_id: ["is not this character's outfit"]}}]}} =
               run!(scope, "update_participants", %{"items" => [%{"id" => pa.id, "outfit_id" => outfit.id}]})
    end

    test "another user's seats and an assistant chat are refused", %{scope: scope, chat_id: id, c: c} do
      [pa, _] = seats(scope, id)
      other = scope!(%{role: :user})

      assert {:error, %{"failed" => [%{"error" => "You are not allowed to do that."}]}} =
               run!(other, "update_participants", %{"items" => [%{"id" => pa.id, "muted" => true}]})

      assert {:error, %{"failed" => [%{"error" => "You are not allowed to do that."}]}} =
               run!(other, "remove_participants", %{"ids" => [pa.id]})

      {:ok, assistant} = Chats.create_assistant_chat(scope)

      assert {:error, %{"error" => "Not found."}} =
               run!(scope, "add_participants", %{"chat_id" => assistant.id, "character_ids" => [c.id]})

      assert {:error, %{"error" => "Not found."}} =
               run!(scope, "reorder_participants", %{"chat_id" => assistant.id, "participant_ids" => [pa.id, pa.id]})
    end
  end
end
