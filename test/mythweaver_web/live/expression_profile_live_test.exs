defmodule MythweaverWeb.ExpressionProfileLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Expressions

  setup :register_and_log_in_user

  @rule %{
    "name" => "elated",
    "kind" => "combination",
    "max_difference" => "25",
    "enabled" => "true",
    "conditions" => %{"0" => %{"label" => "excitement"}, "1" => %{"label" => "joy"}}
  }

  test "creates a profile with a combination rule", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/characters/expression-profiles/new")

    view
    |> form("#expression-profile-form")
    |> render_submit(%{"expression_profile" => %{"name" => "Mine", "rules" => %{"0" => @rule}}})

    assert [%{name: "Mine", rules: [rule]} = profile] = Expressions.list_editable_profiles(scope)
    assert %{name: "elated", kind: :combination, max_difference: 25} = rule
    assert Enum.map(rule.conditions, & &1.label) == ~w(excitement joy)
    assert_patch(view, ~p"/characters/expression-profiles/#{profile.id}/edit")
    assert has_element?(view, "#expression-profiles-#{profile.id}")
  end

  test "a combination of one emotion is refused", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/characters/expression-profiles/new")
    rule = %{@rule | "conditions" => %{"0" => %{"label" => "joy"}}}

    view
    |> form("#expression-profile-form")
    |> render_submit(%{"expression_profile" => %{"name" => "Mine", "rules" => %{"0" => rule}}})

    assert has_element?(view, "#expression-profile-form .expression-profile-errors", "two different emotions")
    assert Expressions.list_editable_profiles(scope) == []
  end

  test "Add rule and Add emotion grow the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/characters/expression-profiles/new")

    view
    |> form("#expression-profile-form")
    |> render_change(%{"expression_profile" => %{"name" => "Mine", "rules_sort" => ["new"]}})

    assert has_element?(view, "#expression-profile-rule-0-name")
    refute has_element?(view, "#expression-profile-rule-0-condition-0-label")

    view
    |> form("#expression-profile-form")
    |> render_change(%{
      "expression_profile" => %{
        "name" => "Mine",
        "rules_sort" => ["0"],
        "rules" => %{"0" => %{"name" => "x", "conditions_sort" => ["new"]}}
      }
    })

    assert has_element?(view, "#expression-profile-rule-0-condition-0-label")
  end
end
