defmodule MythweaverWeb.ModerationLookupLiveTest do
  use MythweaverWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Moderation.LogEntry
  alias Mythweaver.Repo

  defp unique, do: System.unique_integer([:positive])

  defp character!(scope) do
    {:ok, character} = Characters.create_character(scope, %{name: "C-#{unique()}"})
    character
  end

  defp chat!(scope) do
    player = character!(scope)
    bot = character!(scope)

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Their chat",
        participants: [%{character_id: player.id}, %{character_id: bot.id}],
        player_character_id: player.id
      })

    {Chats.get_chat!(chat.id), player}
  end

  defp message!(scope, chat, player, text) do
    {:ok, message} = Messages.send_message(scope, chat, player.id, text)
    message
  end

  setup %{conn: conn} do
    admin = register_user!()
    user = register_user!(%{role: :user})
    scope = Scope.for_user(user)
    {chat, player} = chat!(scope)
    message = message!(scope, chat, player, "A secret plan")

    %{
      conn: log_in_user(conn, admin),
      admin: admin,
      user: user,
      scope: scope,
      chat: chat,
      player: player,
      message: message
    }
  end

  test "an @handle opens the account's record", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/moderation/lookup")

    view |> form("#lookup-form", lookup: %{q: "@#{user.handle}"}) |> render_submit()
    assert_redirect(view, "/moderation/users/#{user.id}/record")
  end

  test "a chat link opens its transcript and logs the look", %{conn: conn, chat: chat, message: message} do
    {:ok, view, _html} = live(conn, ~p"/moderation/lookup")

    view |> form("#lookup-form", lookup: %{q: "https://example.com/chats/#{chat.id}"}) |> render_submit()
    assert_redirect(view, "/moderation/lookup/chat/#{chat.id}")

    {:ok, view, _html} = live(conn, ~p"/moderation/lookup/chat/#{chat.id}")
    assert has_element?(view, "#lookup-message-#{message.id}", "A secret plan")

    assert [%LogEntry{action: :viewed, subject_type: :chat}] =
             Repo.all(from(e in LogEntry, where: e.subject_id == ^chat.id))
  end

  test "an unknown lookup says nothing was found", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/moderation/lookup")

    html = view |> form("#lookup-form", lookup: %{q: "@nobody-#{unique()}"}) |> render_submit()
    assert html =~ "Nothing found for that"
  end

  test "a message's view marks it and deletes it", ctx do
    other = message!(ctx.scope, ctx.chat, ctx.player, "Another line")
    {:ok, view, _html} = live(ctx.conn, ~p"/moderation/lookup/message/#{ctx.message.id}")

    assert has_element?(view, "#lookup-message-#{ctx.message.id}[aria-current='true']")
    refute has_element?(view, "#lookup-message-#{other.id}[aria-current]")

    view |> element("#lookup-delete-message-#{other.id}") |> render_click()
    refute Repo.get(Message, other.id)
    refute has_element?(view, "#lookup-message-#{other.id}")
    assert has_element?(view, "#lookup-message-#{ctx.message.id}")
  end

  test "deleting a character asks for the password, then deletes it", ctx do
    character = character!(ctx.scope)
    conn = log_in_user(build_conn(), ctx.admin, sudo: false)
    {:ok, view, _html} = live(conn, ~p"/moderation/lookup/character/#{character.id}")
    assert has_element?(view, "#lookup-card-description")

    view |> element("#lookup-delete") |> render_click()
    assert has_element?(view, "#sudo-modal")
    assert Repo.get(Character, character.id)

    view |> form("#sudo-form", sudo: %{password: "a long test password"}) |> render_submit()
    assert_redirect(view, "/moderation/lookup")
    refute Repo.get(Character, character.id)
  end

  test "an account without any moderation key is redirected", %{chat: chat} do
    conn = log_in_user(build_conn(), register_user!(%{role: :user}))

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/moderation/lookup/chat/#{chat.id}")
  end

  test "the first, unconnected render shows nothing and logs nothing", %{conn: conn, chat: chat} do
    html = conn |> get(~p"/moderation/lookup/chat/#{chat.id}") |> html_response(200)

    refute html =~ "A secret plan"
    assert Repo.all(LogEntry) == []

    {:ok, _view, _html} = live(conn, ~p"/moderation/lookup/chat/#{chat.id}")
    assert [%LogEntry{action: :viewed}] = Repo.all(LogEntry)
  end

  test "a readable AI model card shows its sampler", %{conn: conn, scope: scope} do
    {:ok, model} =
      Mythweaver.AI.create_model(scope, %{name: "Gemma", api_model_id: "gemma-4", sampler: %{temperature: 0.7}})

    {:ok, view, _html} = live(conn, ~p"/moderation/lookup/ai_model/#{model.id}")
    assert has_element?(view, "#lookup-card-sampler")
  end
end
