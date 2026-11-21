defmodule MythweaverWeb.UserDataLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.UserData
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Messages

  defp unique, do: System.unique_integer([:positive])

  defp character!(scope) do
    {:ok, character} = Characters.create_character(scope, %{name: "C-#{unique()}"})
    character
  end

  setup %{conn: conn} do
    admin = register_user!()
    user = register_user!(%{role: :user})
    scope = Scope.for_user(user)
    player = character!(scope)
    bot = character!(scope)

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Their chat",
        participants: [%{character_id: player.id}, %{character_id: bot.id}],
        player_character_id: player.id
      })

    {:ok, _} = Messages.send_message(scope, Chats.get_chat!(chat.id), player.id, "A secret plan")

    %{conn: conn, admin: admin, user: user, chat: chat}
  end

  test "lists a user's chats, each opening its lookup view", %{conn: conn, admin: admin, user: user, chat: chat} do
    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/moderation/users/#{user.id}/data")
    assert has_element?(view, "#user-data-chats-#{chat.id} a[href='/moderation/lookup/chat/#{chat.id}']")
  end

  test "a user without moderation.content.view is redirected", %{conn: conn, user: user} do
    other = register_user!(%{role: :user})

    assert {:error, {:redirect, %{to: "/"}}} =
             live(log_in_user(conn, other), ~p"/moderation/users/#{user.id}/data")
  end

  describe "moving a lore book to the site" do
    setup %{user: user} do
      {:ok, book} = Mythweaver.Lore.create_book(Scope.for_user(user), %{name: "Their lore"})
      %{book: book}
    end

    test "a sudo admin moves it", %{conn: conn, admin: admin, user: user, book: book} do
      {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/moderation/users/#{user.id}/data")

      view |> element("#user-data-move-#{book.id}") |> render_click()

      assert Mythweaver.Lore.get_book!(book.id).user_id == nil
      assert render(view) =~ "Their lore is now a site book"
      refute has_element?(view, "#user-data-move-#{book.id}")
    end

    test "without sudo, the click asks for the password", %{conn: conn, admin: admin, user: user, book: book} do
      {:ok, view, _html} = live(log_in_user(conn, admin, sudo: false), ~p"/moderation/users/#{user.id}/data")

      view |> element("#user-data-move-#{book.id}") |> render_click()

      assert has_element?(view, "#sudo-modal")
      assert Mythweaver.Lore.get_book!(book.id).user_id == user.id
    end

    test "a viewer who may not move it sees no button", %{conn: conn, user: user, book: book} do
      viewer = register_user!(%{role: :user})
      :ok = Mythweaver.Permissions.put_grant!(viewer, "moderation.content.view", :allow)

      {:ok, view, _html} = live(log_in_user(conn, viewer), ~p"/moderation/users/#{user.id}/data")

      assert has_element?(view, "#user-data-lore_book-#{book.id}")
      refute has_element?(view, "#user-data-move-#{book.id}")
    end

    test "another user's book is not found", %{admin: admin, user: user} do
      other = register_user!(%{role: :user})
      {:ok, book} = Mythweaver.Lore.create_book(Scope.for_user(other), %{name: "Other lore"})

      assert UserData.move_book_to_site(Mythweaver.DataCase.sudo(Scope.for_user(admin)), user, book.id) ==
               {:error, :not_found}
    end
  end
end
