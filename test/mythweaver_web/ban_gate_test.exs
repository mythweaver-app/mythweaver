defmodule MythweaverWeb.BanGateTest do
  use MythweaverWeb.ConnCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Moderation.Fingerprints
  alias Mythweaver.Moderation.Sanctions

  test "a banned device is logged out of every request", %{conn: conn} do
    moderator = Mythweaver.DataCase.sudo(Scope.for_user(register_user!()))
    user = register_user!(%{role: :user})

    conn = conn |> log_in_user(user) |> get(~p"/characters")
    device = conn.assigns.device_id
    :ok = Fingerprints.record(user.id, %{device: device})

    {:ok, _} =
      Sanctions.ban(moderator, user, %{"reason" => "Spam", "duration" => "7d", "values" => ["device:#{device}"]})

    conn = get(recycle(conn), ~p"/characters")
    assert redirected_to(conn) == ~p"/users/log-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Logins from this device or network are blocked."
  end
end
