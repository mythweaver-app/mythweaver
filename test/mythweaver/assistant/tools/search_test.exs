defmodule Mythweaver.Assistant.Tools.SearchTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Messages

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp chat!(scope) do
    {:ok, a} = Characters.create_character(scope, %{name: "Hero", description: "d"})
    {:ok, b} = Characters.create_character(scope, %{name: "Sidekick", description: "d"})

    {:ok, chat} =
      Chats.create_chat(scope, %{"participants" => [%{"character_id" => a.id}, %{"character_id" => b.id}]})

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

  setup do
    %{scope: scope!(%{role: :user})}
  end

  test "a lore entry hit carries plain snippet text and its path", %{scope: scope} do
    {:ok, entry} = Lore.create_entry(scope, %{name: "Cave", content: "The dragons slept", keywords: ["Cave"]}, [])

    assert {:ok, %{"groups" => groups}} = run!(scope, "search", %{"text" => "drag"})
    assert %{"hits" => [hit], "more" => false} = Enum.find(groups, &(&1["kind"] == "lore_entry"))
    assert %{"id" => id, "snippet" => snippet, "path" => path} = hit
    assert id == entry.id
    assert snippet =~ "dragons"
    assert path == "/lore/entries/#{entry.id}/edit"
  end

  test "a message hit carries the #N read_chat_messages takes", %{scope: scope} do
    chat = chat!(scope)
    message!(chat, "first words")
    message = message!(chat, "the kraken surfaced")

    assert {:ok, %{"groups" => groups}} = run!(scope, "search", %{"text" => "kraken", "kinds" => ["message"]})
    assert [%{"kind" => "message", "hits" => [hit]}] = groups
    assert hit["number"] == message.position + 1
    assert hit["chat_id"] == chat.id
    assert hit["path"] == "/chats/#{chat.id}"
  end

  test "an unknown kind is refused", %{scope: scope} do
    assert {:error, %{"error" => "unknown kind: bogus"}} = run!(scope, "search", %{"text" => "x", "kinds" => ["bogus"]})
  end

  test "another user's chat id is not found", %{scope: scope} do
    other_chat = chat!(scope!(%{role: :user}))

    assert {:error, %{"error" => "Not found."}} =
             run!(scope, "search", %{"text" => "x", "chat_id" => other_chat.id})
  end
end
