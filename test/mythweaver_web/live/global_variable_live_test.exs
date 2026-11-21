defmodule MythweaverWeb.GlobalVariableLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Variables

  setup :register_and_log_in_user

  defp global!(scope, key, value) do
    {:ok, variable} = Variables.create_variable(scope, nil, %{key: key, value: value})
    variable
  end

  test "index selects nothing when there are no globals", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/variables")
    assert has_element?(view, "#variable-placeholder")
  end

  test "index selects nothing and lists only globals", %{scope: scope, conn: conn, user: user} do
    b = global!(scope, "b", 1)
    a = global!(scope, "a", 2)

    {:ok, c1} = Characters.create_character(scope, %{name: "A"})
    {:ok, c2} = Characters.create_character(scope, %{name: "B"})

    {:ok, chat} =
      Chats.create_chat(Scope.for_user(user), %{
        name: "chat",
        participants: [%{character_id: c1.id}, %{character_id: c2.id}],
        player_character_id: c1.id
      })

    {:ok, local} = Variables.create_variable(scope, chat.id, %{key: "local", value: 3})

    {:ok, view, _html} = live(conn, ~p"/variables")
    assert has_element?(view, "#variable-placeholder")
    refute has_element?(view, "#variables li a[aria-current='page']")
    assert has_element?(view, "#variables-#{a.id}")

    {:ok, view, _html} = live(conn, ~p"/variables/#{a.id}/edit")
    assert has_element?(view, "#variables-#{a.id} a[aria-current='page']")
    assert has_element?(view, "#variables-#{b.id}")
    refute has_element?(view, "#variables-#{local.id}")
    assert has_element?(view, ".top-bar-nav a[href='/variables']")

    # A chat variable's id is not editable here.
    assert {:error, {:live_redirect, %{to: "/variables"}}} = live(conn, ~p"/variables/#{local.id}/edit")
  end

  test "the search box narrows the list by key or value", %{scope: scope, conn: conn} do
    hp = global!(scope, "hp", 10)
    weather = global!(scope, "weather", "stormy")

    {:ok, view, _html} = live(conn, ~p"/variables/#{hp.id}/edit")

    view |> form("#variable-filter", %{"query" => "STORM"}) |> render_change()
    assert has_element?(view, "#variables-#{weather.id}")
    refute has_element?(view, "#variables-#{hp.id}")

    view |> form("#variable-filter", %{"query" => "hp"}) |> render_change()
    assert has_element?(view, "#variables-#{hp.id} a[aria-current='page']")
    refute has_element?(view, "#variables-#{weather.id}")

    view |> form("#variable-filter", %{"query" => "nothing"}) |> render_change()
    assert has_element?(view, "#variables-nav .pane-empty")
    refute has_element?(view, "#variables li[id]")
  end

  test "creates a global from the new form", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/variables/new")

    view |> form("#variable-form", variable: %{key: "hp", value: "10"}) |> render_submit()

    assert [created] = Variables.list_global_variables(scope)
    assert created.value == 10
    assert_patch(view, "/variables/#{created.id}/edit")
    assert has_element?(view, "#variables-#{created.id}")
  end

  test "an invalid key keeps the form open and creates nothing", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/variables/new")

    html = view |> form("#variable-form", variable: %{key: "bad key", value: "x"}) |> render_submit()

    assert html =~ "must start with a letter or underscore"
    assert Variables.list_global_variables(scope) == []
  end

  test "edits a global, showing a string that looks like JSON quoted", %{scope: scope, conn: conn} do
    variable = global!(scope, "code", "42")
    {:ok, view, _html} = live(conn, ~p"/variables/#{variable.id}/edit")

    assert has_element?(view, "#variable-form-value", ~s("42"))

    view |> form("#variable-form", variable: %{key: "code", value: "plain words"}) |> render_submit()

    assert Variables.get_variable!(variable.id).value == "plain words"
    assert_patch(view, "/variables/#{variable.id}/edit")
  end

  test "deletes a global", %{scope: scope, conn: conn} do
    variable = global!(scope, "gone", true)
    {:ok, view, _html} = live(conn, ~p"/variables/#{variable.id}/edit")

    view |> element("#delete-variable") |> render_click()

    assert_patch(view, ~p"/variables")
    assert has_element?(view, "#variable-placeholder")
    assert Variables.list_global_variables(scope) == []
  end

  test "a write from a generation appears in the list", %{scope: scope, conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/variables/new")

    {:ok, c1} = Characters.create_character(scope, %{name: "A"})
    {:ok, c2} = Characters.create_character(scope, %{name: "B"})

    {:ok, chat} =
      Chats.create_chat(Scope.for_user(user), %{
        name: "chat",
        participants: [%{character_id: c1.id}, %{character_id: c2.id}],
        player_character_id: c1.id
      })

    :ok = Variables.apply_writes(chat.id, [%{"scope" => "global", "key" => "weather", "value" => "rain"}])

    [variable] = Variables.list_global_variables(scope)
    _ = render(view)
    assert has_element?(view, "#variables-#{variable.id}", "weather")
  end

  describe "a user (not admin)" do
    setup %{conn: conn, scope: admin} do
      user = register_user!(%{role: :user})
      %{conn: log_in_user(conn, user), user_scope: Scope.for_user(user), admin: admin}
    end

    test "edits only their own globals", %{conn: conn, user_scope: user_scope, admin: admin} do
      site = global!(admin, "site_mood", 1)
      own = global!(user_scope, "mine", 2)

      {:ok, view, _html} = live(conn, ~p"/variables")
      assert has_element?(view, "#variable-placeholder")
      assert has_element?(view, "#variables-#{own.id}")

      {:ok, view, _html} = live(conn, ~p"/variables/#{own.id}/edit")
      assert has_element?(view, "#variables-#{own.id}")
      refute has_element?(view, "#variables-#{site.id}")
    end
  end
end
