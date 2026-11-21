defmodule MythweaverWeb.SubmissionLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Moderation.Holds
  alias Mythweaver.Moderation.Rules

  setup :register_and_log_in_user

  test "the submitter sees their held item and withdraws it", %{conn: conn, user: user} do
    {:ok, _rule} =
      Rules.create_rule(Scope.for_user(register_user!()), %{
        "name" => "Words",
        "kind" => "regex",
        "content_types" => ["characters"],
        "pattern" => "forbidden"
      })

    :ok = Mythweaver.Permissions.put_grant!(user, "moderation.characters.restrictive", :allow)
    scope = Scope.for_user(user)
    {:held, hold} = Characters.create_character(scope, %{"name" => "Ada", "description" => "forbidden"})

    {:ok, view, _html} = live(conn, ~p"/submissions")
    assert has_element?(view, "#submissions-#{hold.id}", "Ada")

    view |> element("#submissions-#{hold.id}-withdraw") |> render_click()
    refute has_element?(view, "#submissions-#{hold.id}")
    assert has_element?(view, "#submissions-empty")
    assert Holds.list_own(scope) == []
  end
end
