defmodule MythweaverWeb.ModerationAccountLiveTest do
  use MythweaverWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Mythweaver.Moderation.Ban
  alias Mythweaver.Moderation.Fingerprints
  alias Mythweaver.Moderation.Warning
  alias Mythweaver.Repo

  setup %{conn: conn} do
    moderator = register_user!()
    user = register_user!(%{role: :user})
    %{conn: log_in_user(conn, moderator), moderator: moderator, user: user}
  end

  test "warning the account lists the warning", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/moderation/users/#{user.id}/record")
    assert has_element?(view, "#account-warnings-empty")

    view |> form("#warn-form", warn: %{reason: "Keep it civil"}) |> render_submit()

    [warning] = Repo.all(from(w in Warning, where: w.user_id == ^user.id))
    assert warning.reason == "Keep it civil"
    assert has_element?(view, "#account-warnings #warnings-#{warning.id}", "Keep it civil")
    refute has_element?(view, "#account-warnings-empty")
  end

  test "banning the account and a device lists both bans", %{conn: conn, user: user} do
    :ok = Fingerprints.record(user.id, %{device: "dev-abc"})

    {:ok, view, _html} = live(conn, ~p"/moderation/users/#{user.id}/record")
    assert has_element?(view, "#account-status", "Active")

    view
    |> form("#ban-form",
      ban: %{reason: "Spam", duration: "7d", account: "true", values: ["device:dev-abc"]}
    )
    |> render_submit()

    bans = Repo.all(from(b in Ban, where: b.user_id == ^user.id))
    assert bans |> Enum.map(& &1.kind) |> Enum.sort() == [:account, :device]

    for ban <- bans do
      assert has_element?(view, "#account-bans #bans-#{ban.id}")
      assert has_element?(view, "#bans-#{ban.id}-lift")
    end

    assert has_element?(view, "#account-status", "Suspended until")
  end

  test "lists another account sharing a browser fingerprint", %{conn: conn, user: user} do
    other = register_user!(%{role: :user})
    hash = String.duplicate("ab", 16)
    :ok = Fingerprints.record(user.id, %{fingerprint: hash})
    :ok = Fingerprints.record(other.id, %{fingerprint: hash})

    {:ok, view, _html} = live(conn, ~p"/moderation/users/#{user.id}/record")

    assert has_element?(view, "#account-linked #linked-#{other.id}", "@#{other.handle}")
    assert has_element?(view, "#account-fingerprints", hash)
  end

  test "an IP shows where GeoIP places it, with MaxMind's attribution", %{conn: conn, user: user} do
    :ok = Fingerprints.record(user.id, %{ip: "81.2.69.142"})
    [ip] = Fingerprints.for_user(user.id)

    {:ok, view, _html} = live(conn, ~p"/moderation/users/#{user.id}/record")

    assert has_element?(view, "#fingerprints-#{ip.id}-geo", "London, England, GB")
    assert has_element?(view, "#ban-form-values-#{ip.id}", "London, England, GB")
    assert has_element?(view, "#account-geoip-attribution", "MaxMind")
  end

  test "one's own record says why it has no warn or ban form", %{conn: conn, moderator: moderator} do
    :ok = Fingerprints.record(moderator.id, %{device: "dev-own"})
    {:ok, view, _html} = live(conn, ~p"/moderation/users/#{moderator.id}/record")

    assert has_element?(view, "#account-warnings-note", "your own account")
    assert has_element?(view, "#account-bans-note", "your own account")
    refute has_element?(view, "#warn-form")
    refute has_element?(view, "#ban-form")
  end

  test "a non-owner moderator can't open an owner's record", %{conn: conn} do
    owner = register_user!(%{role: :owner})

    assert {:error, {:live_redirect, %{to: "/moderation/lookup"}}} =
             live(conn, ~p"/moderation/users/#{owner.id}/record")
  end
end
