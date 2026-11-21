defmodule MythweaverWeb.UserSettingsLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.User
  alias Mythweaver.MCP
  alias Mythweaver.Permissions
  alias Mythweaver.Repo

  describe "a user with a password" do
    setup :register_and_log_in_user

    test "changing email without the current password is refused", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")
      assert has_element?(view, "#profile-form[phx-hook='UnsavedChanges'][data-saved]")

      view
      |> form("#profile-form", user: %{email: "changed@example.com", current_password: ""})
      |> render_submit()

      assert has_element?(view, "#profile-form .input-error")
      # A refused save still shows the edits, so they stay flagged as unsaved.
      refute has_element?(view, "#profile-form[data-saved]")
      assert Accounts.get_user(user.id).email == user.email
    end

    test "a nickname change needs no password and updates the header", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> form("#profile-form", user: %{email: user.email, handle: "renamed_h", nickname: "Renamed"})
      |> render_submit()

      assert %{nickname: "Renamed", handle: "renamed_h"} = Accounts.get_user(user.id)
      assert has_element?(view, "#nav-account-toggle", "Renamed")
      assert has_element?(view, "#profile-form[data-saved]")
    end

    test "the password form triggers the controller post when valid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      form =
        form(view, "#password-form",
          user: %{
            current_password: "a long test password",
            password: "a brand new password",
            password_confirmation: "a brand new password"
          }
        )

      render_submit(form)
      assert has_element?(view, "#password-form[phx-trigger-action]")

      conn = follow_trigger_action(form, conn)
      assert redirected_to(conn) == ~p"/users/settings"
    end
  end

  test "a passwordless user sets a first password without a current one", %{conn: conn} do
    admin = Repo.insert!(User.auto_login_changeset())
    conn = log_in_user(conn, admin)
    {:ok, view, _html} = live(conn, ~p"/users/settings")

    refute has_element?(view, "#password-form-current_password")

    form =
      form(view, "#password-form",
        user: %{password: "a first long password", password_confirmation: "a first long password"}
      )

    render_submit(form)
    follow_trigger_action(form, conn)

    assert Accounts.get_user_by_email_and_password(admin.email, "a first long password")
  end

  describe "MCP access" do
    setup :register_and_log_in_user

    test "creating a token shows its secret once, and revoking removes it", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")
      assert has_element?(view, "#mcp-tokens-empty")

      view
      |> form("#mcp-token-form", token: %{name: "Laptop", access: "read_only"})
      |> render_submit()

      assert has_element?(view, "#mcp-token-secret-value")
      assert [%{access: :read_only} = token] = MCP.list_tokens(scope)
      assert has_element?(view, "#mcp-tokens-#{token.id}")
      refute has_element?(view, "#mcp-tokens-empty")

      view |> element("#mcp-token-secret-done") |> render_click()
      refute has_element?(view, "#mcp-token-secret-value")

      view |> element("#revoke-mcp-tokens-#{token.id}") |> render_click()
      refute has_element?(view, "#mcp-tokens-#{token.id}")
      assert has_element?(view, "#mcp-tokens-empty")
      assert MCP.list_tokens(scope) == []
    end

    test "creating a token outside sudo asks for the password, then creates it", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      # A second account, so the install is not an always-sudo auto-login one.
      register_user!(%{role: :user})
      {:ok, view, _html} = live(log_in_user(conn, user, sudo: false), ~p"/users/settings")

      view
      |> form("#mcp-token-form", token: %{name: "Laptop", access: "full"})
      |> render_submit()

      assert has_element?(view, "#sudo-form")
      assert MCP.list_tokens(scope) == []

      view |> form("#sudo-form", sudo: %{password: "a long test password"}) |> render_submit()
      assert [%{name: "Laptop", access: :full}] = MCP.list_tokens(scope)
      assert has_element?(view, "#mcp-token-secret-value")
    end

    test "with mcp.use denied the form is replaced by a notice", %{conn: conn, user: user} do
      Permissions.put_grant!(user, "mcp.use", :deny)
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#mcp-disabled")
      refute has_element?(view, "#mcp-token-form")
    end
  end
end
