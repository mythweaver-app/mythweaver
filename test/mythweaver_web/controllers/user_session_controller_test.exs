defmodule MythweaverWeb.UserSessionControllerTest do
  use MythweaverWeb.ConnCase

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.Throttle
  alias Mythweaver.Moderation.Fingerprints
  alias Mythweaver.Moderation.Sanctions

  @password "a long test password"

  describe "POST /users/log-in" do
    test "right credentials with remember-me log in and set the cookie", %{conn: conn} do
      user = register_user!()

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => @password, "remember_me" => "true"}
        })

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      assert conn.resp_cookies["_mythweaver_user_remember_me"]
    end

    test "a wrong password goes back to login", %{conn: conn} do
      user = register_user!()

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"email" => user.email, "password" => "not the password"}})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      refute get_session(conn, :user_token)
    end

    test "repeated wrong passwords throttle the email", %{conn: conn} do
      user = register_user!()
      Throttle.clear({:login_email, String.downcase(user.email)})
      on_exit(fn -> Throttle.clear({:login_email, String.downcase(user.email)}) end)

      for _ <- 1..5 do
        post(conn, ~p"/users/log-in", %{"user" => %{"email" => user.email, "password" => "not the password"}})
      end

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"email" => user.email, "password" => @password}})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert "Too many sign-in attempts" <> _ = Phoenix.Flash.get(conn.assigns.flash, :error)
      refute get_session(conn, :user_token)
    end

    test "a suspended account is refused with the suspension reason", %{conn: conn} do
      user = register_user!(%{role: :user})

      {:ok, _} =
        Sanctions.ban(moderator!(), user, %{"reason" => "Spamming", "duration" => "permanent", "account" => "true"})

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"email" => user.email, "password" => @password}})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Your account is suspended: Spamming"
      refute get_session(conn, :user_token)
    end

    test "a login from a banned IP address is refused", %{conn: conn} do
      banned = register_user!(%{role: :user})
      :ok = Fingerprints.record(banned.id, %{ip: "203.0.113.9"})

      {:ok, _} =
        Sanctions.ban(moderator!(), banned, %{
          "reason" => "Ban evasion",
          "duration" => "7d",
          "values" => ["ip:203.0.113.9"]
        })

      user = register_user!(%{role: :user})

      conn =
        post(%{conn | remote_ip: {203, 0, 113, 9}}, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => @password}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Logins from this device or network are blocked."
      refute get_session(conn, :user_token)
    end

    test "a login records the client's IP address and user agent", %{conn: conn} do
      user = register_user!(%{role: :user})

      conn =
        %{conn | remote_ip: {198, 51, 100, 4}}
        |> put_req_header("user-agent", "TestBrowser/1.0")
        |> post(~p"/users/log-in", %{"user" => %{"email" => user.email, "password" => @password}})

      assert get_session(conn, :user_token)
      recorded = user.id |> Fingerprints.for_user() |> Enum.map(&{&1.kind, &1.value})
      assert {:ip, "198.51.100.4"} in recorded
      assert {:user_agent, "TestBrowser/1.0"} in recorded
    end
  end

  test "DELETE /users/log-out deletes the session token", %{conn: conn} do
    user = register_user!()
    conn = log_in_user(conn, user)
    token = get_session(conn, :user_token)

    conn = delete(conn, ~p"/users/log-out")

    assert redirected_to(conn) == ~p"/users/log-in"
    refute get_session(conn, :user_token)
    refute Accounts.get_user_by_session_token(token)
  end

  describe "POST /users/update-password" do
    setup :register_and_log_in_user

    test "updates the password and logs back in with a new token", %{conn: conn, user: user} do
      old_token = get_session(conn, :user_token)

      conn =
        post(conn, ~p"/users/update-password", %{
          "user" => %{
            "current_password" => @password,
            "password" => "a brand new password",
            "password_confirmation" => "a brand new password"
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      refute Accounts.get_user_by_session_token(old_token)
      assert Accounts.get_user_by_session_token(get_session(conn, :user_token))
      assert Accounts.get_user_by_email_and_password(user.email, "a brand new password")
    end

    test "a wrong current password changes nothing", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/update-password", %{
          "user" => %{
            "current_password" => "not the password",
            "password" => "a brand new password",
            "password_confirmation" => "a brand new password"
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Could not update password"
      assert Accounts.get_user_by_email_and_password(user.email, @password)
    end
  end

  defp moderator!, do: Mythweaver.DataCase.sudo(Scope.for_user(register_user!()))
end
