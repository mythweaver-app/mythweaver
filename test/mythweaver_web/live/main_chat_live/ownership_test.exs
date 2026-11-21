defmodule MythweaverWeb.MainChatLive.OwnershipTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Chats

  setup :register_and_log_in_user

  setup %{user: user} do
    other = register_user!(%{nickname: "Other"})
    %{mine: chat!(user, "Mine"), theirs: chat!(other, "Theirs")}
  end

  test "the picker lists only the viewer's chats, for an admin too", %{conn: conn, mine: mine, theirs: theirs} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ".chat-picker-list a[href='/chats/#{mine.id}']")
    refute has_element?(view, ".chat-picker-list a[href='/chats/#{theirs.id}']")
  end

  test "another user's chat does not open by URL", %{conn: conn, theirs: theirs} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{theirs.id}")

    refute has_element?(view, ".chat-picker-list a[href='/chats/#{theirs.id}']")
    refute render(view) =~ "Theirs"
  end

  defp chat!(user, name) do
    scope = Scope.for_user(user)

    [a, b] =
      for n <- ["A", "B"] do
        {:ok, c} = Characters.create_character(scope, %{name: "#{n}-#{System.unique_integer([:positive])}"})
        c
      end

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: name,
        participants: [%{character_id: a.id}, %{character_id: b.id}],
        player_character_id: a.id
      })

    chat
  end
end
