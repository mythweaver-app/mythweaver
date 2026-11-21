defmodule MythweaverWeb.ModerationGateTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Moderation.Fingerprints
  alias Mythweaver.Moderation.Sanctions

  setup %{conn: conn} do
    moderator = Mythweaver.DataCase.sudo(Scope.for_user(register_user!()))
    user = register_user!(%{role: :user})
    %{conn: log_in_user(conn, user), moderator: moderator, user: user}
  end

  describe "warnings" do
    test "a pending warning sends every page to /warnings until acknowledged", %{
      conn: conn,
      moderator: moderator,
      user: user
    } do
      {:ok, _warning} = Sanctions.warn(moderator, user, "Keep it civil")

      assert {:error, {:redirect, %{to: "/warnings"}}} = live(conn, ~p"/")

      {:ok, view, _html} = live(conn, ~p"/warnings")
      assert has_element?(view, "#warnings", "Keep it civil")

      {:ok, _view, _html} =
        view
        |> element("#acknowledge-warnings")
        |> render_click()
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _view, _html} = live(conn, ~p"/")
    end
  end

  describe "bans" do
    test "a banned device cookie logs the socket out", %{conn: conn, moderator: moderator, user: user} do
      conn = get(conn, ~p"/")
      device = conn.assigns.device_id
      :ok = Fingerprints.record(user.id, %{device: device})
      ban!(moderator, user, "device:#{device}")

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn)
      refute Accounts.get_user_by_session_token(get_session(conn, :user_token))
    end

    test "a banned connect-info IP logs the socket out", %{conn: conn, moderator: moderator, user: user} do
      :ok = Fingerprints.record(user.id, %{ip: "203.0.113.9"})
      ban!(moderator, user, "ip:203.0.113.9")
      token = get_session(conn, :user_token)

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               conn
               |> put_private(:live_view_connect_info, %{
                 peer_data: %{address: {203, 0, 113, 9}, port: 1, ssl_cert: nil}
               })
               |> live(~p"/")

      refute Accounts.get_user_by_session_token(token)
    end

    test "a banned forwarded IP behind a trusted proxy logs the socket out", %{
      conn: conn,
      moderator: moderator,
      user: user
    } do
      :ok = Fingerprints.record(user.id, %{ip: "203.0.113.9"})
      ban!(moderator, user, "ip:203.0.113.9")

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               conn
               |> put_private(:live_view_connect_info, %{
                 peer_data: %{address: {127, 0, 0, 1}, port: 1, ssl_cert: nil},
                 x_headers: [{"x-forwarded-for", "203.0.113.9"}]
               })
               |> live(~p"/")
    end
  end

  defp ban!(moderator, user, value) do
    {:ok, _} = Sanctions.ban(moderator, user, %{"reason" => "Spam", "duration" => "7d", "values" => [value]})
  end
end
