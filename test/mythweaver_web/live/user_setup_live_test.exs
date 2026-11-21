defmodule MythweaverWeb.UserSetupLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  @attrs %{
    "email" => "first@example.com",
    "handle" => "first",
    "nickname" => "First",
    "password" => "a long test password",
    "password_confirmation" => "a long test password"
  }

  test "creates the first account and logs it in", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    form = form(view, "#setup-form", user: @attrs)
    render_submit(form)

    assert has_element?(view, "#setup-form[phx-trigger-action]")

    conn = follow_trigger_action(form, conn)
    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_token)

    assert {:error, {:live_redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/setup")
  end

  test "an invalid form creates nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    view
    |> form("#setup-form", user: %{@attrs | "password_confirmation" => "something else"})
    |> render_submit()

    refute has_element?(view, "#setup-form[phx-trigger-action]")
    assert has_element?(view, "#setup-form .input-error")
    refute Mythweaver.Accounts.any_users?()
  end
end
