defmodule MythweaverWeb.SearchTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Messages

  setup :register_and_log_in_user

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{System.unique_integer([:positive])}"})
    character
  end

  defp chat!(scope) do
    [player, bot] = [character!(scope, "Player"), character!(scope, "Bot")]

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Tavern",
        participants: [%{character_id: player.id}, %{character_id: bot.id}],
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end

  defp message!(chat, content) do
    {:ok, message} =
      Messages.create_message(chat, %{
        author_is_character: true,
        author_character_id: chat.player_character_id,
        bodies: [%{content: content}]
      })

    message
  end

  defp entry!(scope, name, content) do
    {:ok, entry} = Lore.create_entry(scope, %{name: name, content: content, keywords: [name]}, [])
    entry
  end

  defp open(view, mode), do: view |> element("#search") |> render_hook("open", %{"mode" => mode})
  defp query(view, text), do: view |> form("#search-form", %{"query" => text}) |> render_change()
  defp key(view, key), do: view |> element("#search-dialog") |> render_hook("key", %{"key" => key})

  test "global search finds lore from any page and opens the hit", %{scope: scope, conn: conn} do
    entry = entry!(scope, "Moonwell", "A spring under the hill")
    {:ok, view, _html} = live(conn, ~p"/characters")

    open(view, "global")
    query(view, "moonw")

    assert has_element?(view, "#search-hit-lore_entry-#{entry.id} mark", "Moonwell")
    assert {:error, {:live_redirect, %{to: to}}} = key(view, "Enter")
    assert to == "/lore/entries/#{entry.id}/edit"
  end

  test "local search in a chat lists its messages and jumps in place", %{scope: scope, conn: conn} do
    chat = chat!(scope)
    message = message!(chat, "The lanterns flickered")
    entry!(scope, "Lanterns", "lanterns of the old road")
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat}")

    open(view, "local")
    query(view, "lantern")

    assert has_element?(view, "#search-scope")
    assert has_element?(view, "#search-hit-message-#{message.id}")
    refute has_element?(view, "[id^='search-hit-lore_entry-']")

    key(view, "Enter")
    assert_push_event(view, "scroll_to_message", %{id: id})
    assert id == "messages-#{message.id}"
    refute has_element?(view, "#search-dialog")
  end

  test "Backspace on an empty local search widens it to everything", %{scope: scope, conn: conn} do
    chat = chat!(scope)
    message!(chat, "The lanterns flickered")
    entry = entry!(scope, "Lanterns", "lanterns of the old road")
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat}")

    open(view, "local")
    query(view, "lantern")
    key(view, "Backspace")

    refute has_element?(view, "#search-scope")
    assert has_element?(view, "#search-hit-lore_entry-#{entry.id}")
  end

  test "?message= opens the chat around that message", %{scope: scope, conn: conn} do
    chat = chat!(scope)
    [first | _] = for i <- 1..60, do: message!(chat, "message #{i}")
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat}?#{[message: first.id]}")

    assert_push_event(view, "scroll_to_message", %{id: id})
    assert id == "messages-#{first.id}"
    assert has_element?(view, "#messages-#{first.id}")
  end

  test "a page without a local scope leaves Mod-F to the browser", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#search")
    refute has_element?(view, "#search[data-local]")

    open(view, "local")
    refute has_element?(view, "#search-scope")
    assert has_element?(view, "#search-input[placeholder='Search everything…']")
  end
end
