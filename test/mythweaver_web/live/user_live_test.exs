defmodule MythweaverWeb.UserLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.User
  alias Mythweaver.Repo

  describe "a user with a password" do
    setup :register_and_log_in_user

    test "index selects nothing and shows a placeholder", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/moderation/users")

      assert has_element?(view, "#user-placeholder")
      refute has_element?(view, "#user-form")
    end

    test "adds a user", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/moderation/users/new")

      view
      |> form("#user-form",
        user: %{
          email: "new@example.com",
          handle: "newbie",
          nickname: "Newbie",
          password: "a long test password",
          password_confirmation: "a long test password"
        }
      )
      |> render_submit()

      assert %User{id: id} = Accounts.get_user_by_email_and_password("new@example.com", "a long test password")
      assert_patch(view, ~p"/moderation/users/#{id}/edit")
      assert has_element?(view, "#users-#{id}")
    end

    test "deletes another user", %{conn: conn} do
      other = register_user!()
      {:ok, view, _html} = live(conn, ~p"/moderation/users/#{other.id}/edit")

      view |> element("#delete-user") |> render_click()

      refute has_element?(view, "#users-#{other.id}")
      refute Accounts.get_user(other.id)
    end

    test "cannot delete themselves", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/moderation/users/#{user.id}/edit")

      refute has_element?(view, "#delete-user")
      refute has_element?(view, "#user-password-form")

      render_click(view, "delete", %{"id" => user.id})
      assert Accounts.get_user(user.id)
    end

    test "resets another user's password and ends their sessions", %{conn: conn} do
      other = register_user!()
      token = Accounts.generate_user_session_token(other)
      {:ok, view, _html} = live(conn, ~p"/moderation/users/#{other.id}/edit")

      view
      |> form("#user-password-form",
        user: %{password: "a reset long password", password_confirmation: "a reset long password"}
      )
      |> render_submit()

      assert Accounts.get_user_by_email_and_password(other.email, "a reset long password")
      refute Accounts.get_user_by_session_token(token)
    end

    test "an owner adds a user with a role" do
      owner = register_user!(%{role: :owner})
      {:ok, view, _html} = live(log_in_user(build_conn(), owner), ~p"/moderation/users/new")

      view
      |> form("#user-form",
        user: %{
          email: "owner2@example.com",
          handle: "owner2",
          password: "a long test password",
          password_confirmation: "a long test password",
          role: "owner"
        }
      )
      |> render_submit()

      assert %User{role: :owner} = Accounts.get_user_by_email_and_password("owner2@example.com", "a long test password")
    end

    test "an admin sees an owner's account as read-only", %{conn: conn} do
      owner = register_user!(%{role: :owner})
      {:ok, view, _html} = live(conn, ~p"/moderation/users/#{owner.id}/edit")

      assert has_element?(view, "#user-owner-notice")
      refute has_element?(view, "#delete-user")
      refute has_element?(view, "#user-form")
      refute has_element?(view, "#user-password-form")
    end

    test "cannot change their own role", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/moderation/users/#{user.id}/edit")

      assert has_element?(view, "#user-role-self")
      refute has_element?(view, "#user-form-role")
    end

    test "links an account to its lookup and ban form, but offers no ban of oneself", %{conn: conn, user: user} do
      other = register_user!(%{role: :user})
      {:ok, view, _html} = live(conn, ~p"/moderation/users/#{other.id}/edit")

      assert has_element?(view, "#user-lookup[href='/moderation/users/#{other.id}/record']")
      assert has_element?(view, "#user-ban[href='/moderation/users/#{other.id}/record#account-bans']")

      {:ok, view, _html} = live(conn, ~p"/moderation/users/#{user.id}/edit")
      assert has_element?(view, "#user-lookup")
      refute has_element?(view, "#user-ban")
    end
  end

  describe "bulk select" do
    setup :register_and_log_in_user

    test "deletes other users but not themselves", %{conn: conn, user: user} do
      other = register_user!()
      {:ok, view, _html} = live(conn, ~p"/moderation/users/#{user.id}/edit")

      view |> element("#users-bulk-toggle") |> render_click()
      view |> element("#bulk-users-#{other.id}") |> render_click()
      view |> element("#bulk-users-#{user.id}") |> render_click()
      html = view |> element("#users-bulk-delete") |> render_click()

      refute Accounts.get_user(other.id)
      assert Accounts.get_user(user.id)
      assert html =~ "Your own account"
    end

    test "an owner changes the role of selected users" do
      owner = register_user!(%{role: :owner})
      other = register_user!()
      {:ok, view, _html} = live(log_in_user(build_conn(), owner), ~p"/moderation/users/#{owner.id}/edit")

      view |> element("#users-bulk-toggle") |> render_click()
      view |> element("#bulk-users-#{other.id}") |> render_click()
      view |> element("#users-bulk-edit-users") |> render_click()

      view
      |> form("#bulk-edit-form", bulk: %{apply_role: "true", role: "owner"})
      |> render_submit()

      assert Accounts.get_user(other.id).role == :owner
    end
  end

  test "deleting a user asks for the password, then deletes" do
    admin = register_user!()
    other = register_user!()
    {:ok, view, _html} = live(log_in_user(build_conn(), admin, sudo: false), ~p"/moderation/users/#{other.id}/edit")

    view |> element("#delete-user") |> render_click()
    assert has_element?(view, "#sudo-modal")
    assert Accounts.get_user(other.id)

    view |> form("#sudo-form", sudo: %{password: "wrong password"}) |> render_submit()
    assert has_element?(view, "#sudo-error")
    assert Accounts.get_user(other.id)

    view |> form("#sudo-form", sudo: %{password: "a long test password"}) |> render_submit()
    refute has_element?(view, "#sudo-modal")
    refute Accounts.get_user(other.id)
  end

  test "a passwordless user is told to set a password before adding users", %{conn: conn} do
    admin = Repo.insert!(User.auto_login_changeset())
    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/moderation/users/new")

    assert has_element?(view, "#users-passwordless-notice")
    refute has_element?(view, "#user-form")
  end
end
