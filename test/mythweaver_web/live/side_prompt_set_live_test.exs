defmodule MythweaverWeb.SidePromptSetLiveTest do
  use MythweaverWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mythweaver.Memory
  alias Mythweaver.Memory.SidePromptSet
  alias Mythweaver.Prompts

  setup :register_and_log_in_user

  defp side_prompt!(scope, name, macros) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Side: #{name}", purpose: :side_prompt})
    {:ok, side_prompt} = Memory.create_side_prompt(scope, %{name: name, prompt_id: prompt.id, macros: macros})
    side_prompt
  end

  test "index selects nothing and shows the placeholder", %{scope: scope, conn: conn} do
    {:ok, set} = Memory.create_side_prompt_set(scope, %{name: "Default rows"})
    {:ok, view, _html} = live(conn, ~p"/memory/side-prompt-sets")

    assert has_element?(view, "#side-prompt-set-placeholder")
    assert has_element?(view, "#side-prompt-sets-#{set.id}", "Default rows")
  end

  test "creates a set with two rows through the form, in form order", %{scope: scope, conn: conn} do
    npc = side_prompt!(scope, "NPC tracker", ["npc"])
    plot = side_prompt!(scope, "Plot", [])
    {:ok, view, _html} = live(conn, ~p"/memory/side-prompt-sets/new")

    # "Add row" posts `rows_sort[]=new` with the form.
    view
    |> form("#side-prompt-set-form", side_prompt_set: %{name: "Cast"})
    |> render_change(%{"side_prompt_set" => %{"rows_sort" => ["new"]}})

    view
    |> form("#side-prompt-set-form", side_prompt_set: %{name: "Cast"})
    |> render_change(%{"side_prompt_set" => %{"rows_sort" => ["0", "new"]}})

    assert has_element?(view, "#side-prompt-set-row-1-side-prompt")
    refute has_element?(view, "#side-prompt-set-row-0-macro-npc")

    view
    |> form("#side-prompt-set-form",
      side_prompt_set: %{rows: %{"0" => %{side_prompt_id: npc.id, label: "Alice"}, "1" => %{side_prompt_id: plot.id}}}
    )
    |> render_change()

    # The selected side prompt's macros get an input each.
    assert has_element?(view, "#side-prompt-set-row-0-macro-npc")
    refute has_element?(view, "#side-prompt-set-row-1-macro-npc")

    view
    |> form("#side-prompt-set-form", side_prompt_set: %{rows: %{"0" => %{macro_values: %{npc: " Alice "}}}})
    |> render_submit()

    assert [%SidePromptSet{name: "Cast"} = set] = Memory.list_side_prompt_sets(scope)
    set = Memory.get_editable_side_prompt_set(scope, set.id)
    assert_patch(view, ~p"/memory/side-prompt-sets/#{set.id}/edit")
    assert has_element?(view, "#side-prompt-sets-#{set.id}", "Cast")

    assert [
             %{position: 0, side_prompt_id: npc_id, label: "Alice", macro_values: %{"npc" => "Alice"}},
             %{position: 1, side_prompt_id: plot_id, macro_values: %{}}
           ] = set.rows

    assert npc_id == npc.id and plot_id == plot.id
  end

  test "moving a row down swaps the saved positions", %{scope: scope, conn: conn} do
    npc = side_prompt!(scope, "NPC tracker", ["npc"])
    plot = side_prompt!(scope, "Plot", [])

    {:ok, set} =
      Memory.create_side_prompt_set(scope, %{
        name: "Cast",
        rows: [
          %{side_prompt_id: npc.id, label: "Alice", macro_values: %{"npc" => "Alice"}},
          %{side_prompt_id: plot.id, label: "Plot"}
        ]
      })

    {:ok, view, _html} = live(conn, ~p"/memory/side-prompt-sets/#{set.id}/edit")
    view |> element("#side-prompt-set-row-0-down") |> render_click()
    assert view |> element("#side-prompt-set-row-0-label") |> render() =~ ~s(value="Plot")

    view |> form("#side-prompt-set-form") |> render_submit()

    assert [%{label: "Plot", position: 0}, %{label: "Alice", position: 1, macro_values: %{"npc" => "Alice"}}] =
             Memory.get_editable_side_prompt_set(scope, set.id).rows
  end
end
