defmodule MythweaverWeb.UserLoginLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  @password "a long test password"

  for {remember, cookie?} <- [{"true", true}, {"false", false}] do
    test "remember me #{remember} logs in, cookie set: #{cookie?}", %{conn: conn} do
      user = register_user!()
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      form =
        form(view, "#login-form", user: %{email: user.email, password: @password, remember_me: unquote(remember)})

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      assert Map.has_key?(conn.resp_cookies, "_mythweaver_user_remember_me") == unquote(cookie?)
    end
  end
end
