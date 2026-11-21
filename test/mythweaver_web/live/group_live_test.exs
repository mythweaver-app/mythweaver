defmodule MythweaverWeb.GroupLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Permissions
  alias Mythweaver.Permissions.Group
  alias Mythweaver.Repo

  setup :register_and_log_in_user

  test "index selects nothing and shows a placeholder", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/moderation/groups")

    assert has_element?(view, "#group-placeholder")
    refute has_element?(view, "#group-form")
    refute has_element?(view, "#group-grants")
  end

  test "creates a group, denies a permission and adds a member", %{conn: conn} do
    member = register_user!(%{role: :user})
    assert Scope.can?(Scope.for_user(member), "content.scripts.create")

    {:ok, view, _html} = live(conn, ~p"/moderation/groups/new")

    view |> form("#group-form", group: %{name: "Players"}) |> render_submit()
    group = Repo.get_by!(Group, name: "Players")
    assert_patch(view, ~p"/moderation/groups/#{group.id}/edit")

    view
    |> form("#group-grants", grants: %{"content.scripts.create" => "deny"})
    |> render_submit()

    view
    |> form("#group-members-form", members: [member.id])
    |> render_submit()

    refute Scope.can?(Scope.for_user(member), "content.scripts.create")
  end

  test "lists the system groups and offers no delete for them", %{conn: conn} do
    everyone = Permissions.system_group!(:everyone)
    {:ok, view, _html} = live(conn, ~p"/moderation/groups/#{everyone.id}/edit")

    assert has_element?(view, "#groups-#{everyone.id}")
    assert has_element?(view, "#groups-#{Permissions.system_group!(:administrators).id}")
    refute has_element?(view, "#delete-group")
    refute has_element?(view, "#group-members-form")
  end

  test "a user without groups.manage is redirected" do
    user = register_user!(%{role: :user})

    assert {:error, {:redirect, %{to: "/"}}} = live(log_in_user(build_conn(), user), ~p"/moderation/groups")
  end

  test "the moderation tabs link users and groups", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/moderation/users/#{user.id}/edit")
    assert has_element?(view, "#moderation-tab-users")

    assert {:error, {:live_redirect, %{to: "/moderation/groups"}}} =
             view |> element("#moderation-tab-groups") |> render_click()
  end

  test "a groups-only manager's nav entry opens groups, with no users tab" do
    user = register_user!(%{role: :user})
    :ok = Permissions.put_grant!(user, "groups.manage", :allow)
    everyone = Permissions.system_group!(:everyone)
    {:ok, view, _html} = live(log_in_user(build_conn(), user), ~p"/moderation/groups/#{everyone.id}/edit")

    assert has_element?(view, "#nav-moderation[href='/moderation/groups']")
    refute has_element?(view, "#moderation-tab-users")
  end
end
