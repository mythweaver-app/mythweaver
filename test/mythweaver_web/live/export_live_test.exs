defmodule MythweaverWeb.ExportLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Characters
  alias Mythweaver.Prompts

  setup :register_and_log_in_user

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp prompt!(scope, name) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: name})
    prompt
  end

  test "kind tabs patch and the filter narrows the list", %{scope: scope, conn: conn} do
    aqua = character!(scope, "Aqua")
    kazuma = character!(scope, "Kazuma")
    prompt = prompt!(scope, "Story")

    {:ok, view, _html} = live(conn, ~p"/export")
    assert has_element?(view, "#export-check-#{aqua.id}")
    assert has_element?(view, "#export-check-#{kazuma.id}")

    view |> form("#export-filter-form", query: "aq") |> render_change()
    assert has_element?(view, "#export-check-#{aqua.id}")
    refute has_element?(view, "#export-check-#{kazuma.id}")

    view |> element("#export-kind-prompt") |> render_click()
    assert_patch(view, ~p"/export?kind=prompt")
    view |> form("#export-filter-form", query: "") |> render_change()
    assert has_element?(view, "#export-check-#{prompt.id}")
    refute has_element?(view, "#export-check-#{kazuma.id}")
  end

  test "toggling and range-selecting update the selection and summary", %{scope: scope, conn: conn} do
    aqua = character!(scope, "Aqua")
    kazuma = character!(scope, "Kazuma")
    darkness = character!(scope, "Darkness")

    {:ok, view, _html} = live(conn, ~p"/export")
    assert has_element?(view, "#export-submit[disabled]")

    view |> element("#export-check-#{aqua.id}") |> render_click()
    assert has_element?(view, "#export-selected-#{aqua.id}")
    assert has_element?(view, "#export-counts", "1 character")
    assert has_element?(view, "#export-kind-character", "(1)")
    refute has_element?(view, "#export-submit[disabled]")

    view |> element("#export-check-#{aqua.id}") |> render_click()
    refute has_element?(view, "#export-selected-#{aqua.id}")

    render_hook(view, "select_range", %{"ids" => [kazuma.id, darkness.id, Ecto.UUID.generate()]})
    assert has_element?(view, "#export-selected-#{kazuma.id}")
    assert has_element?(view, "#export-selected-#{darkness.id}")
    assert has_element?(view, "#export-counts", "2 characters")
  end

  test "submitting the form triggers the download post", %{scope: scope, conn: conn} do
    aqua = character!(scope, "Aqua")

    {:ok, view, _html} = live(conn, ~p"/export")
    view |> element("#export-check-#{aqua.id}") |> render_click()

    html = view |> form("#export-form") |> render_submit()
    assert html =~ ~s(phx-trigger-action)
    assert has_element?(view, ~s(#export-form input[name="export[items][]"][value="character:#{aqua.id}"]))
  end

  test "the format select offers only available formats; samplers only for presets", %{
    scope: scope,
    conn: conn
  } do
    aqua = character!(scope, "Aqua")
    prompt = prompt!(scope, "Story")

    {:ok, view, _html} = live(conn, ~p"/export")
    assert has_element?(view, ~s(#export-form-format option[value="native"]))
    refute has_element?(view, ~s(#export-form-format option[value="card_json"]))

    view |> element("#export-check-#{aqua.id}") |> render_click()
    assert has_element?(view, ~s(#export-form-format option[value="card_json"]))
    assert has_element?(view, ~s(#export-form-format option[value="charx"]))
    assert has_element?(view, ~s(#export-form-format option[value="card_png"]))
    refute has_element?(view, ~s(#export-form-format option[value="st_preset"]))

    view |> form("#export-form", export: %{format: "card_json"}) |> render_change()
    refute has_element?(view, "#export-form-sampler_model_id")

    view |> element("#export-check-#{aqua.id}") |> render_click()
    view |> element("#export-kind-prompt") |> render_click()
    view |> element("#export-check-#{prompt.id}") |> render_click()
    assert has_element?(view, ~s(#export-form-format option[value="st_preset"]))
    refute has_element?(view, ~s(#export-form-format option[value="card_json"]))
    refute has_element?(view, "#export-form-sampler_model_id")

    view |> form("#export-form", export: %{format: "st_preset"}) |> render_change()
    assert has_element?(view, "#export-form-sampler_model_id")
  end

  describe "?item= preselects" do
    test "that item on its kind's tab, without downloading", %{scope: scope, conn: conn} do
      aqua = character!(scope, "Aqua")
      _kazuma = character!(scope, "Kazuma")

      {:ok, view, _html} = live(conn, ~p"/export?kind=character&item=#{aqua.id}")
      assert has_element?(view, "#export-selected-#{aqua.id}")
      assert has_element?(view, "#export-check-#{aqua.id}[checked]")
      assert has_element?(view, "#export-kind-character", "(1)")
      refute has_element?(view, "#export-submit[disabled]")
      assert has_element?(view, ~s(#export-form-format option[value="card_json"]))
      refute has_element?(view, "#export-form[phx-trigger-action]")
    end

    test "on another kind's tab", %{scope: scope, conn: conn} do
      prompt = prompt!(scope, "Story")

      {:ok, view, _html} = live(conn, ~p"/export?kind=prompt&item=#{prompt.id}")
      assert has_element?(view, "#export-check-#{prompt.id}[checked]")
      assert has_element?(view, "#export-selected-#{prompt.id}")
    end

    test "an unknown or foreign item flashes and selects nothing", %{conn: conn} do
      foreign = character!(Mythweaver.DataCase.scope!(%{role: :user}), "Megumin")

      for id <- [Mythweaver.Schema.generate_id(), foreign.id, "not-a-uuid"] do
        {:ok, view, _html} = live(conn, ~p"/export?kind=character&item=#{id}")
        assert has_element?(view, "#flash-error", "That item can't be exported.")
        assert has_element?(view, "#export-submit[disabled]")
      end
    end
  end
end
