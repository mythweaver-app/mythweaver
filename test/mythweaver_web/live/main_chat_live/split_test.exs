defmodule MythweaverWeb.MainChatLive.SplitTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message

  setup :register_and_log_in_user

  setup %{user: user, scope: scope} do
    c1 = character(scope, "Alice")
    c2 = character(scope, "Bob")
    chat = create_chat(user, "Split Chat", c1, c2, c1.id)
    %{chat: chat, c1: c1, c2: c2}
  end

  test "splits a message into two by moving the divider", %{conn: conn, chat: chat, c2: c2} do
    message = add_message(chat, c2, "One\n\nTwo\n\nThree")
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    view |> element("#message-split-open-#{message.id}") |> render_click()
    assert has_element?(view, "#message-split-editor-#{message.id}")

    render_hook(view, "move_split_divider", %{"index" => 0, "boundary" => 2})
    view |> form("#message-split-form-#{message.id}") |> render_submit()

    assert view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("li.chat-message") |> Enum.count() == 2
    assert contents(chat) == ["One\n\nTwo", "Three"]
    refute has_element?(view, "#message-split-editor-#{message.id}")
  end

  test "splits the newest message's end to a scratchpad and appends it back", %{
    conn: conn,
    chat: chat,
    c2: c2,
    scope: scope
  } do
    message = add_message(chat, c2, "Head\n\nTail")
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    view |> element("#split-scratchpad-#{message.id}") |> render_click()
    view |> form("#message-split-form-#{message.id}") |> render_submit()

    assert contents(chat) == ["Head"]
    [scratchpad] = Messages.list_scratchpads(scope, chat)
    assert has_element?(view, "#scratchpads #scratchpad-#{scratchpad.id}")

    view |> element("#scratchpad-append-#{scratchpad.id}") |> render_click()
    refute has_element?(view, "#scratchpads")
    assert contents(chat) == ["Head\n\nTail"]
  end

  test "bulk merge folds the selected rows into the first", %{conn: conn, chat: chat, c1: c1, c2: c2} do
    first = add_message(chat, c1, "Hi")
    second = add_message(chat, c2, "Hello")
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    view |> element("#message-select-#{first.id}") |> render_click()
    view |> element("#message-select-#{second.id}") |> render_click()
    view |> element("#bulk-merge-messages") |> render_click()

    refute has_element?(view, "#messages-#{second.id}")
    assert has_element?(view, "#messages-#{first.id}")
    assert contents(chat) == ["Hi\n\nHello"]
  end

  test "merging the first message has nothing to merge into", %{conn: conn, chat: chat, c2: c2} do
    first = add_message(chat, c2, "Alone")
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert view |> element("#message-merge-#{first.id}") |> render_click() =~ "No previous message to merge into."
  end

  defp contents(chat), do: chat |> Messages.list_messages() |> Enum.map(&Message.active_content/1)

  defp character(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp create_chat(user, name, c1, c2, player_id) do
    {:ok, chat} =
      Chats.create_chat(Scope.for_user(user), %{
        name: name,
        participants: [%{character_id: c1.id}, %{character_id: c2.id}],
        player_character_id: player_id
      })

    chat
  end

  defp add_message(chat, character, content) do
    {:ok, message} =
      Messages.create_message(chat, %{
        author_is_character: true,
        author_character_id: character.id,
        bodies: [%{content: content}]
      })

    message
  end
end
