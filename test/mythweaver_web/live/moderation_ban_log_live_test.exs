defmodule MythweaverWeb.ModerationBanLogLiveTest do
  use MythweaverWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Moderation.Ban
  alias Mythweaver.Moderation.Fingerprints
  alias Mythweaver.Moderation.Log
  alias Mythweaver.Moderation.LogEntry
  alias Mythweaver.Moderation.Sanctions
  alias Mythweaver.Repo

  defp moderator!, do: register_user!()

  defp sudo_scope!(user), do: Mythweaver.DataCase.sudo(Scope.for_user(user))

  defp device_ban!(moderator, target) do
    device = "device-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = Fingerprints.record(target.id, %{device: device})

    {:ok, %{bans: [ban]}} =
      Sanctions.ban(sudo_scope!(moderator), target, %{
        "reason" => "Ban evasion",
        "duration" => "7d",
        "values" => ["device:#{device}"]
      })

    ban
  end

  describe "/moderation/bans" do
    test "lists an active device ban and lifts it", %{conn: conn} do
      moderator = moderator!()
      target = register_user!(%{role: :user})
      ban = device_ban!(moderator, target)

      {:ok, view, _html} = live(log_in_user(conn, moderator), ~p"/moderation/bans?kind=device")

      assert has_element?(view, "#bans-#{ban.id}", "Ban evasion")
      assert has_element?(view, "#bans-#{ban.id}-user", "@#{target.handle}")
      assert has_element?(view, "#bans-tab-device[aria-selected=true]")

      view |> element("#bans-#{ban.id}-lift") |> render_click()

      refute has_element?(view, "#bans-#{ban.id}")
      assert has_element?(view, "#bans-empty")
      assert Repo.get!(Ban, ban.id).lifted_at

      view |> element("#bans-state") |> render_click()
      assert has_element?(view, "#bans-#{ban.id}-status", "Lifted")
      refute has_element?(view, "#bans-#{ban.id}-lift")
    end

    test "redirects an account without ban permissions", %{conn: conn} do
      user = register_user!(%{role: :user})

      assert {:error, {:redirect, %{to: "/"}}} = live(log_in_user(conn, user), ~p"/moderation/bans")
    end
  end

  describe "/moderation/log" do
    test "lists entries and filters them to one account", %{conn: conn} do
      moderator = moderator!()
      target = register_user!(%{role: :user})
      other = register_user!(%{role: :user})
      scope = Scope.for_user(moderator)

      :ok = Log.record(scope, :viewed, :user, target.id, target.id, %{"page" => "record"})
      :ok = Log.record(scope, :warned, :user, other.id, other.id, %{"reason" => "Be kind"})

      about_target = Repo.get_by!(LogEntry, target_user_id: target.id)
      about_other = Repo.get_by!(LogEntry, target_user_id: other.id)

      {:ok, view, _html} = live(log_in_user(conn, moderator), ~p"/moderation/log")

      assert has_element?(view, "#log-#{about_target.id}", "Viewed")
      assert has_element?(view, "#log-#{about_target.id}-target", "@#{target.handle}")
      assert has_element?(view, "#log-#{about_other.id}", "Be kind")
      refute has_element?(view, "#log-filter-clear")

      {:ok, view, _html} = live(log_in_user(conn, moderator), ~p"/moderation/log?user=#{target.id}")

      assert has_element?(view, "#log-#{about_target.id}")
      refute has_element?(view, "#log-#{about_other.id}")

      view |> element("#log-filter-clear") |> render_click()
      assert_patch(view, ~p"/moderation/log")
      assert has_element?(view, "#log-#{about_other.id}")
    end

    test "redirects an account without the log permission", %{conn: conn} do
      user = register_user!(%{role: :user})

      assert {:error, {:redirect, %{to: "/"}}} = live(log_in_user(conn, user), ~p"/moderation/log")
    end
  end
end
