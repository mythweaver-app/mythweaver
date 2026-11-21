defmodule Mythweaver.SearchTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Messages
  alias Mythweaver.Search

  setup do
    %{scope: scope!(%{role: :user})}
  end

  defp character!(scope, name, attrs \\ %{}) do
    {:ok, character} = Characters.create_character(scope, Map.merge(%{name: name}, attrs))
    character
  end

  defp book!(scope, name) do
    {:ok, book} = Lore.create_book(scope, %{name: name})
    book
  end

  defp entry!(scope, name, content, book_ids \\ []) do
    {:ok, entry} = Lore.create_entry(scope, %{name: name, content: content, keywords: [name]}, book_ids)
    entry
  end

  defp chat!(scope, name) do
    player = character!(scope, "Hero")
    partner = character!(scope, "Sidekick")

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: name,
        participants: [%{character_id: player.id}, %{character_id: partner.id}],
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end

  defp message!(chat, content) do
    {:ok, message} =
      Messages.create_message(chat, %{
        author_is_character: true,
        author_character_id: hd(chat.participants).character_id,
        bodies: [%{content: content}]
      })

    message
  end

  defp hits(groups, kind) do
    case Enum.find(groups, &(&1.kind == kind)) do
      nil -> []
      group -> group.hits
    end
  end

  defp ids(groups, kind), do: groups |> hits(kind) |> Enum.map(& &1.id)

  test "prefix-matches as you type and highlights the match", %{scope: scope} do
    entry = entry!(scope, "Cave", "The dragons slept")

    assert [hit] = scope |> Search.search("drag") |> hits(:lore_entry)
    assert hit.id == entry.id
    assert {"dragons", true} in hit.snippet
  end

  test "the generated vector follows updates", %{scope: scope} do
    entry = entry!(scope, "Cave", "The dragons slept")
    {:ok, _} = Lore.update_entry(scope, entry, %{content: "The wolves slept"})

    assert scope |> Search.search("drag") |> ids(:lore_entry) == []
    assert scope |> Search.search("wolv") |> ids(:lore_entry) == [entry.id]
  end

  test "text without a positive term searches nothing", %{scope: scope} do
    entry!(scope, "Cave", "The dragons slept")
    assert Search.search(scope, "-dragons") == []
  end

  test "another user's personal rows never show", %{scope: scope} do
    other = scope!(%{role: :user})
    character!(other, "Zephyrine")
    mine = character!(scope, "Zephyra")

    assert scope |> Search.search("zephyr") |> ids(:character) == [mine.id]
  end

  describe "messages" do
    test "match only the active swipe of the user's own chats", %{scope: scope} do
      chat = chat!(scope, "Harbor")
      message = message!(chat, "The lighthouse keeper waved")
      {:ok, _} = Messages.add_body(message, %{content: "A quiet evening"})
      older = message!(chat, "The kraken surfaced")
      {:ok, _} = Messages.add_body(older, %{content: "Nothing surfaced"})
      kraken = message!(chat, "Another kraken")

      other = scope!(%{role: :user})
      other |> chat!("Elsewhere") |> message!("A kraken too")

      assert scope |> Search.search("lighthouse") |> ids(:message) == []
      assert scope |> Search.search("quiet") |> ids(:message) == [message.id]
      assert [hit] = scope |> Search.search("kraken") |> hits(:message)
      assert %{id: id, chat_id: chat_id, chat_title: "Harbor"} = hit
      assert {id, chat_id} == {kraken.id, chat.id}
    end

    test "chat_id limits to that chat, newest first, and skips chats", %{scope: scope} do
      chat = chat!(scope, "Storm chat")
      first = message!(chat, "storm rising")
      second = message!(chat, "storm breaking")
      chat!(scope, "Elsewhere") |> message!("storm far away")

      groups = Search.search(scope, "storm", chat_id: chat.id)

      assert ids(groups, :message) == [second.id, first.id]
      assert ids(groups, :chat) == []
      assert scope |> Search.search("storm") |> ids(:chat) == [chat.id]
    end

    test "chat_kind keeps only that kind's chats and messages", %{scope: scope} do
      roleplay = chat!(scope, "Kraken chat")
      message = message!(roleplay, "The kraken rose")
      {:ok, assistant} = Chats.create_assistant_chat(scope, %{name: "Kraken help"})
      {:ok, _} = Messages.post_assistant_user_message(scope, assistant, "Where is the kraken?")

      assert scope |> Search.search("kraken") |> ids(:chat) |> Enum.sort() == Enum.sort([roleplay.id, assistant.id])
      assert scope |> Search.search("kraken") |> ids(:message) |> length() == 2

      groups = Search.search(scope, "kraken", chat_kind: :roleplay)
      assert ids(groups, :chat) == [roleplay.id]
      assert ids(groups, :message) == [message.id]
    end
  end

  test "book_id keeps only entries linked to that book", %{scope: scope} do
    book = book!(scope, "Bestiary")
    inside = entry!(scope, "Griffin", "griffins nest", [book.id])
    entry!(scope, "Griffin lore", "griffins elsewhere")

    assert scope |> Search.search("griff", book_id: book.id) |> ids(:lore_entry) == [inside.id]
  end

  test "limit caps each kind and reports more", %{scope: scope} do
    character!(scope, "Moonwalker one")
    character!(scope, "Moonwalker two")

    assert [%{kind: :character, hits: [_], more?: true}] =
             Search.search(scope, "moonwalker", kinds: [:character], limit: 1)

    assert [%{hits: [_, _], more?: false}] = Search.search(scope, "moonwalker", kinds: [:character], limit: 2)
  end
end
