defmodule MythweaverWeb.AnalyticsLiveTest do
  use MythweaverWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Analytics
  alias Mythweaver.Jobs.Job

  setup :register_and_log_in_user

  defp model!(scope) do
    {:ok, model} =
      AI.create_model(scope, %{name: "Gemma-#{System.unique_integer([:positive])}", api_model_id: "gemma-4"})

    model
  end

  defp run!(scope, usage) do
    now = DateTime.utc_now()

    :ok =
      Analytics.record_runs([
        %Job{
          id: Mythweaver.Schema.generate_id(),
          user_id: scope.user.id,
          ai_model_id: model!(scope).id,
          tag: :reply,
          origin: :interactive,
          status: :completed,
          usage: usage,
          started_at: DateTime.add(now, -3, :second),
          first_token_at: DateTime.add(now, -2, :second),
          finished_at: now
        }
      ])
  end

  defp chart_spec(view, id) do
    view
    |> element("##{id}")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-chart")
    |> hd()
    |> JSON.decode!()
  end

  test "charts the reader's own runs", %{conn: conn, scope: scope} do
    run!(scope, %{"prompt_tokens" => 1200, "completion_tokens" => 34})
    [model] = AI.list_models(scope)

    {:ok, view, _html} = live(conn, ~p"/analytics")

    assert has_element?(view, "#analytics-total-prompt", "1,200")
    assert has_element?(view, "#analytics-model-#{model.id}")

    assert %{"points" => [%{"series" => series, "value" => 1234}]} = chart_spec(view, "analytics-tokens-chart")
    assert series == model.id
    assert has_element?(view, "#analytics-ttft-chart")
    assert has_element?(view, "#analytics-spend-chart-empty")
  end

  test "splits prompt tokens into cached and uncached, per model and per day", %{
    conn: conn,
    scope: scope
  } do
    run!(scope, %{"prompt_tokens" => 100, "completion_tokens" => 7, "prompt_tokens_details" => %{"cached_tokens" => 60}})

    {:ok, view, _html} = live(conn, ~p"/analytics")

    assert %{"series" => series, "points" => points} = chart_spec(view, "analytics-by-model-chart")
    assert Enum.map(series, & &1["key"]) == ["cached", "uncached", "completion"]
    assert Enum.map(points, &{&1["series"], &1["value"]}) == [{"cached", 60}, {"uncached", 40}, {"completion", 7}]
    assert has_element?(view, "#analytics-total-cached", "60 · 60%")

    today = Date.to_iso8601(Date.utc_today())

    assert %{"series" => caching_series, "points" => caching_points} = chart_spec(view, "analytics-caching-chart")
    assert Enum.map(caching_series, & &1["key"]) == ["uncached", "cached"]

    assert Enum.sort(Enum.map(caching_points, &{&1["category"], &1["series"], &1["value"]})) ==
             [{today, "cached", 60}, {today, "uncached", 40}]
  end

  test "the range comes from the URL", %{conn: conn, scope: scope} do
    run!(scope, %{"prompt_tokens" => 1})

    {:ok, view, _html} = live(conn, ~p"/analytics?days=7")
    assert length(chart_spec(view, "analytics-tokens-chart")["categories"]) == 7

    view |> element("#analytics-days-90") |> render_click()
    assert_patch(view, ~p"/analytics?days=90")
    assert length(chart_spec(view, "analytics-tokens-chart")["categories"]) == 90
    assert has_element?(view, "#analytics-days-90[aria-pressed=true]")
  end

  test "an admin can switch to every user's runs", %{conn: conn} do
    run!(Scope.for_user(register_user!(%{role: :user})), %{"prompt_tokens" => 5})

    {:ok, view, _html} = live(conn, ~p"/analytics")
    assert has_element?(view, "#analytics-total-runs", "0")

    view |> element("#analytics-all-users") |> render_click()
    assert_patch(view, ~p"/analytics?all=true&days=30")
    assert has_element?(view, "#analytics-total-runs", "1")
  end

  test "a non-admin gets no switch and only their own runs, whatever the URL says", %{scope: admin} do
    run!(admin, %{"prompt_tokens" => 5})
    user = register_user!(%{role: :user})
    refute Scope.can?(Scope.for_user(user), "analytics.all.view")

    {:ok, view, _html} = live(log_in_user(build_conn(), user), ~p"/analytics?all=true")

    refute has_element?(view, "#analytics-all-users")
    assert has_element?(view, "#analytics-total-runs", "0")
  end

  test "reloads when one of the reader's jobs finishes", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/analytics")
    assert has_element?(view, "#analytics-tokens-chart-empty")

    run!(scope, %{"prompt_tokens" => 10, "completion_tokens" => 2})
    send(view.pid, {:job_changed, %{id: nil, chat_id: nil, tag: :reply, status: :completed}})

    assert has_element?(view, "#analytics-tokens-chart")
  end
end
