defmodule MythweaverWeb.ModerationRuleLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Moderation.Rule
  alias Mythweaver.Repo

  setup :register_and_log_in_user

  test "creates a regex rule", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/moderation/rules/new")

    view
    |> form("#moderation-rule-form",
      rule: %{name: "Slurs", kind: "regex", content_types: ["characters", "lore"], pattern: "bad\\w+"}
    )
    |> render_submit()

    rule = Repo.get_by!(Rule, name: "Slurs")
    assert rule.content_types == [:characters, :lore]
    assert_patch(view, ~p"/moderation/rules/#{rule.id}/edit")
    assert has_element?(view, "#moderation-rules-#{rule.id}")
  end

  test "is refused without moderation.rules.manage", %{conn: conn} do
    user = register_user!(%{role: :user})
    assert {:error, {:redirect, _}} = live(log_in_user(conn, user), ~p"/moderation/rules")
  end
end
