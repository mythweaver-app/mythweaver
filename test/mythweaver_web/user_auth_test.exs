defmodule MythweaverWeb.UserAuthTest do
  # Not async: tests flip the global `:auto_login` app env.
  use MythweaverWeb.ConnCase

  alias Mythweaver.Accounts

  defp put_auto_login(value) do
    previous = Application.get_env(:mythweaver, :auto_login)
    Application.put_env(:mythweaver, :auto_login, value)
    on_exit(fn -> Application.put_env(:mythweaver, :auto_login, previous) end)
  end

  describe "require_authenticated_user" do
    test "no accounts and no auto-login: sends to setup", %{conn: conn} do
      put_auto_login(false)
      assert redirected_to(get(conn, ~p"/characters")) == ~p"/setup"
    end

    test "an account but no session: sends to login and remembers the page", %{conn: conn} do
      put_auto_login(false)
      register_user!()

      conn = get(conn, ~p"/characters")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :user_return_to) == "/characters"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "You must log in to access this page."
    end

    test "auto-login with one account signs it in", %{conn: conn} do
      put_auto_login(true)
      user = register_user!()

      # `/settings` renders on mount; list pages patch to their first item.
      conn = get(conn, ~p"/settings")

      assert html_response(conn, 200)
      assert {%{id: id}, _, _, _} = Accounts.get_user_by_session_token(get_session(conn, :user_token))
      assert id == user.id
    end

    test "auto-login with no accounts creates the passwordless admin", %{conn: conn} do
      put_auto_login(true)

      conn = get(conn, ~p"/settings")

      assert html_response(conn, 200)
      assert [%{email: "admin@localhost", hashed_password: nil}] = Accounts.list_users()
    end

    test "auto-login stops at two accounts", %{conn: conn} do
      put_auto_login(true)
      register_user!()
      register_user!()

      assert redirected_to(get(conn, ~p"/characters")) == ~p"/users/log-in"
    end
  end
end
