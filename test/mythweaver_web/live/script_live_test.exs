defmodule MythweaverWeb.ScriptLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Scripts

  setup :register_and_log_in_user

  defp script!(scope, attrs) do
    {:ok, script} =
      attrs
      |> Map.new()
      |> Map.put_new(:name, "Script-#{System.unique_integer([:positive])}")
      |> then(&Scripts.create_script(scope, &1))

    script
  end

  test "index selects nothing when there are no scripts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/scripts")
    assert has_element?(view, "#script-placeholder")
  end

  test "creates a script from the new form", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/scripts/new")
    assert has_element?(view, ".top-bar-nav a[href='/scripts']")

    view
    |> form("#script-form", script: %{name: "Shout", trigger: "user_message", priority: "2", body: "return event.text"})
    |> render_submit()

    assert [created] = Scripts.list_scripts(scope)
    assert %{name: "Shout", trigger: :user_message, priority: 2, body: "return event.text"} = created
    assert_patch(view, "/scripts/#{created.id}/edit")
    assert has_element?(view, "#scripts-#{created.id}")
  end

  test "a body that does not parse keeps the form open and creates nothing", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/scripts/new")

    view |> form("#script-form", script: %{name: "Bad", body: "local x ="}) |> render_submit()

    assert has_element?(view, "#script-form")
    assert has_element?(view, "#flash-error")
    assert Scripts.list_scripts(scope) == []
  end

  test "dependency options list only scripts of the same trigger", %{scope: scope, conn: conn} do
    same = script!(scope, trigger: :user_message)
    other = script!(scope, trigger: :ai_generation)
    script = script!(scope, trigger: :user_message)

    {:ok, view, _html} = live(conn, ~p"/scripts/#{script.id}/edit")

    assert has_element?(view, "#script-form-dependency_ids-option-#{same.id}")
    refute has_element?(view, "#script-form-dependency_ids-option-#{other.id}")
    refute has_element?(view, "#script-form-dependency_ids-option-#{script.id}")

    view |> form("#script-form", script: %{trigger: "ai_generation"}) |> render_change()
    assert has_element?(view, "#script-form-dependency_ids-option-#{other.id}")
    refute has_element?(view, "#script-form-dependency_ids-option-#{same.id}")
  end

  test "deletes a script", %{scope: scope, conn: conn} do
    script = script!(scope, trigger: :user_message)
    {:ok, view, _html} = live(conn, ~p"/scripts/#{script.id}/edit")

    view |> element("#delete-script") |> render_click()

    assert_patch(view, ~p"/scripts")
    assert has_element?(view, "#script-placeholder")
    assert Scripts.list_scripts(scope) == []
  end

  test "a recorded failure shows without a reload", %{scope: scope, conn: conn} do
    script = script!(scope, trigger: :user_message)
    {:ok, view, _html} = live(conn, ~p"/scripts/#{script.id}/edit")
    refute has_element?(view, "#script-last-error")

    Scripts.record_results(scope, [{script, {:error, "Lua runtime error: boom"}}])

    assert has_element?(view, "#script-last-error", "boom")
    assert has_element?(view, "#scripts-#{script.id} [aria-label='Last run failed']")
  end

  test "Validate reports no problems, a compile error, or a missing closing return", %{scope: scope, conn: conn} do
    script = script!(scope, trigger: :user_message, body: "return event.text")
    {:ok, view, _html} = live(conn, ~p"/scripts/#{script.id}/edit")
    refute has_element?(view, "#script-check")

    view |> element("#validate-script") |> render_click()
    assert has_element?(view, "#script-check-ok")

    view |> form("#script-form", script: %{body: "goto nowhere"}) |> render_change()
    refute has_element?(view, "#script-check-ok")
    view |> element("#validate-script") |> render_click()
    assert has_element?(view, "#script-check .script-check-error", "no visible label")

    # The warning shows as soon as the body changes, without Validate.
    view |> form("#script-form", script: %{body: "local x = event.text"}) |> render_change()
    assert has_element?(view, "#script-check .script-check-warning", "does not end with return")

    view |> form("#script-form", script: %{trigger: "lore_activated"}) |> render_change()
    refute has_element?(view, "#script-check")
  end

  test "Run test runs the unsaved body against the sample text", %{scope: scope, conn: conn} do
    script = script!(scope, trigger: :user_message, body: "return event.text")
    {:ok, view, _html} = live(conn, ~p"/scripts/#{script.id}/edit")

    view
    |> form("#script-form", script: %{body: ~S|print("len", #event.text) return event.text .. "!"|})
    |> render_change()

    view |> form("#script-test-form", test: %{text: "hey"}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#script-test-output", "hey!")
    assert has_element?(view, "#script-test-printed", ~r/len\s+3/)
    assert Scripts.get_script!(scope, script.id).body == "return event.text"

    view |> form("#script-form", script: %{body: ~S|error("boom")|}) |> render_change()
    view |> form("#script-test-form", test: %{text: "hey"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#script-test-error", "boom")
  end

  test "Run test shows a command script's notice", %{scope: scope, conn: conn} do
    script = script!(scope, trigger: :command, body: ~S|return "hi"|)
    {:ok, view, _html} = live(conn, ~p"/scripts/#{script.id}/edit")

    view |> form("#script-test-form", test: %{text: ""}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#script-test-notice", "hi")
  end

  describe "a user (not admin)" do
    setup %{conn: conn, scope: admin} do
      user = register_user!(%{role: :user})
      %{conn: log_in_user(conn, user), user_scope: Scope.for_user(user), admin: admin}
    end

    test "creates their own script and sees only theirs", %{conn: conn, user_scope: user_scope, admin: admin} do
      site = script!(admin, name: "SiteScript", body: "return nil")
      {:ok, view, _html} = live(conn, ~p"/scripts/new")
      refute has_element?(view, "#scripts-#{site.id}")

      view
      |> form("#script-form", script: %{name: "Mine", trigger: "user_message", body: "return nil"})
      |> render_submit()

      assert [%{name: "Mine", user_id: user_id}] = Scripts.list_scripts(user_scope)
      assert user_id == user_scope.user.id
      refute Enum.any?(Scripts.list_scripts(admin), &(&1.name == "Mine"))
    end
  end
end
