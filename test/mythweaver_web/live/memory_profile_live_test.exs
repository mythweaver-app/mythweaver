defmodule MythweaverWeb.MemoryProfileLiveTest do
  use MythweaverWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Memory
  alias Mythweaver.Prompts

  setup :register_and_log_in_user

  defp prompt!(scope, name, purpose) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: name, purpose: purpose})
    prompt
  end

  defp profile!(scope, name) do
    {:ok, profile} = Memory.create_profile(scope, %{name: name})
    profile
  end

  test "index selects nothing and shows the placeholder", %{scope: scope, conn: conn} do
    profile = profile!(scope, "Terse")
    {:ok, view, _html} = live(conn, ~p"/memory/profiles")

    assert has_element?(view, "#memory-profile-placeholder")
    assert has_element?(view, "#memory-profiles-#{profile.id}", "Terse")
    refute has_element?(view, "#memory-profile-form")
  end

  test "creates a profile", %{scope: scope, conn: conn} do
    memory = prompt!(scope, "Memory: Short", :memory)
    {:ok, view, _html} = live(conn, ~p"/memory/profiles/new")

    view
    |> form("#memory-profile-form", profile: %{name: "Terse", memory_prompt_id: memory.id, max_tokens: "512"})
    |> render_submit()

    assert %{name: "Terse", max_tokens: 512} = profile = Enum.find(Memory.list_profiles(scope), &(&1.name == "Terse"))
    assert profile.memory_prompt_id == memory.id
    assert_patch(view, ~p"/memory/profiles/#{profile.id}/edit")
    assert has_element?(view, "#memory-profiles-#{profile.id}", "Terse")
  end

  test "makes a profile the default, leaving only one", %{scope: scope, conn: conn} do
    old = profile!(scope, "Old")
    {:ok, _} = Memory.set_default_profile(scope, old)
    new = profile!(scope, "New")

    {:ok, view, _html} = live(conn, ~p"/memory/profiles/#{new.id}/edit")
    view |> element("#memory-profile-default") |> render_click()

    assert Memory.default_profile(scope).id == new.id
    refute has_element?(view, "#memory-profile-default")
    assert has_element?(view, "#memory-profiles-#{new.id}", "Default")
    refute has_element?(view, "#memory-profiles-#{old.id}", "Default")
  end

  test "the form flags only renders of saved values", %{scope: scope, conn: conn} do
    profile = profile!(scope, "Plain")
    {:ok, view, _html} = live(conn, ~p"/memory/profiles/#{profile.id}/edit")

    guarded = "#memory-profile-form[phx-hook='UnsavedChanges']"
    assert has_element?(view, "#{guarded}[data-saved]")

    view |> form("#memory-profile-form", profile: %{name: "Renamed"}) |> render_change()
    assert has_element?(view, guarded)
    refute has_element?(view, "#{guarded}[data-saved]")

    view |> form("#memory-profile-form", profile: %{name: ""}) |> render_submit()
    refute has_element?(view, "#{guarded}[data-saved]")

    view |> form("#memory-profile-form", profile: %{name: "Renamed"}) |> render_submit()
    assert has_element?(view, "#{guarded}[data-saved]")
  end

  test "each prompt select lists only prompts of its purpose", %{scope: scope, conn: conn} do
    memory = prompt!(scope, "Memory: Summary", :memory)
    consolidation = prompt!(scope, "Consolidation", :consolidation)
    roleplay = prompt!(scope, "Roleplay", :roleplay)

    {:ok, view, _html} = live(conn, ~p"/memory/profiles/new")

    assert has_element?(view, "#memory-profile-form-memory-prompt option[value='#{memory.id}']")
    refute has_element?(view, "#memory-profile-form-memory-prompt option[value='#{consolidation.id}']")
    refute has_element?(view, "#memory-profile-form-memory-prompt option[value='#{roleplay.id}']")
    assert has_element?(view, "#memory-profile-form-consolidation-prompt option[value='#{consolidation.id}']")
    refute has_element?(view, "#memory-profile-form-consolidation-prompt option[value='#{memory.id}']")
  end

  test "a user lists and creates only their own profiles", %{scope: admin} do
    user = register_user!(%{role: :user})
    conn = log_in_user(Phoenix.ConnTest.build_conn(), user)
    site = profile!(admin, "Site")
    {:ok, view, _html} = live(conn, ~p"/memory/profiles/new")

    refute has_element?(view, "#memory-profiles-#{site.id}")

    view |> form("#memory-profile-form", profile: %{name: "Mine"}) |> render_submit()

    scope = Scope.for_user(user)
    assert [%{name: "Mine"} = own] = Memory.list_profiles(scope)
    assert own.user_id == user.id
    assert {:error, {:live_redirect, %{to: "/memory/profiles"}}} = live(conn, ~p"/memory/profiles/#{site.id}/edit")
  end
end
