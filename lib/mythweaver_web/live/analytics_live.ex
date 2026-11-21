defmodule MythweaverWeb.AnalyticsLive do
  @moduledoc """
  Usage charts over `Mythweaver.Analytics`: tokens and spend per local day by model, time to first
  token and generation speed by model, and how each kind of job ended.

  `?days=` picks the range (`Analytics.ranges/0`), and `?all=true` shows every user's runs, honored
  for admins only. The browser's time zone arrives as the `timezone` connect param, so nothing is
  queried until the socket connects. The page reloads when one of the reader's jobs finishes.

  Each chart is a `Chart` hook (`assets/js/hooks/chart.ts`) drawing the spec this module builds;
  a chart with nothing to show renders a note instead of the hook.
  """
  use MythweaverWeb, :live_view

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Analytics
  alias Mythweaver.Format
  alias Mythweaver.Jobs

  @finished [:completed, :review, :failed, :canceled, :interrupted]

  # Display order, labels and colors of a run's end status.
  defp statuses,
    do: [
      completed: {dpgettext("ai", "status: how a job run ended, in the outcomes chart", "Completed"), "var(--chart-1)"},
      review:
        {dpgettext("ai", "status: how a job run ended, in the outcomes chart", "Awaiting review"), "var(--chart-3)"},
      failed: {dpgettext("ai", "status: how a job run ended, in the outcomes chart", "Failed"), "var(--destructive)"},
      canceled:
        {dpgettext("ai", "status: how a job run ended, in the outcomes chart", "Canceled"), "var(--muted-foreground)"},
      interrupted:
        {dpgettext("ai", "status: how a job run ended, in the outcomes chart", "Interrupted"), "var(--chart-6)"}
    ]

  # Display order of the tokens-by-model chart's kinds; `token_kind/1` has their labels and colors.
  @token_kinds [:cached, :uncached, :unreported, :completion]

  defp token_kind(:cached),
    do: {dpgettext("ai", "option: kind of tokens in a usage chart", "Cached prompt"), "var(--chart-5)"}

  defp token_kind(:uncached),
    do: {dpgettext("ai", "option: kind of tokens in a usage chart", "Uncached prompt"), "var(--chart-1)"}

  defp token_kind(:unreported),
    do:
      {dpgettext("ai", "option: kind of tokens in a usage chart", "Prompt, cache not reported"),
       "var(--muted-foreground)"}

  defp token_kind(:completion),
    do: {dpgettext("ai", "option: kind of tokens in a usage chart", "Completion"), "var(--chart-3)"}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    timezone =
      if connected?(socket) do
        Jobs.subscribe(scope)
        Analytics.timezone(get_connect_params(socket)["timezone"])
      else
        "UTC"
      end

    {:ok,
     assign(socket,
       page_title: dpgettext("ai", "page title: usage analytics", "Analytics"),
       timezone: timezone,
       see_all?: Scope.can?(scope, "analytics.all.view"),
       overview: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    days = Enum.find(Analytics.ranges(), Analytics.default_range(), &(Integer.to_string(&1) == params["days"]))
    all_users = socket.assigns.see_all? and params["all"] == "true"

    {:noreply, socket |> assign(days: days, all_users: all_users) |> load()}
  end

  @impl true
  def handle_info({:job_changed, %{status: status}}, socket) when status in @finished, do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    if connected?(socket) do
      %{current_scope: scope, days: days, timezone: tz, all_users: all_users} = socket.assigns
      overview = Analytics.overview(scope, days: days, timezone: tz, all_users: all_users)
      assign(socket, overview: overview, charts: charts(overview))
    else
      socket
    end
  end

  defp analytics_path(days, all_users) do
    query = if all_users, do: [days: days, all: true], else: [days: days]
    ~p"/analytics?#{query}"
  end

  ## Chart specs (the `Chart` hook's `Spec`)

  defp charts(overview) do
    series = Enum.map(overview.models, &%{key: &1.key, name: &1.name, color: "var(--chart-#{&1.color})"})
    order = overview.models |> Enum.with_index() |> Map.new(fn {model, i} -> {model.key, i} end)
    latency = Enum.sort_by(overview.latency, &order[&1.model])
    days = Enum.map(overview.days, &%{key: Date.to_iso8601(&1)})

    %{
      tokens:
        days_chart(
          "tokens",
          days,
          series,
          for row <- overview.daily, row.prompt_tokens + row.completion_tokens > 0 do
            %{
              category: Date.to_iso8601(row.day),
              series: row.model,
              value: row.prompt_tokens + row.completion_tokens,
              parts:
                [[part_name(:prompt), row.prompt_tokens]] ++
                  if(row.cache_reported_tokens > 0, do: [[part_name(:cached), row.cached_tokens]], else: []) ++
                  [[part_name(:completion), row.completion_tokens]]
            }
          end
        ),
      by_model: by_model_chart(overview.models),
      caching: caching_chart(days, overview.daily),
      spend:
        days_chart(
          "usd",
          days,
          series,
          for(
            row <- overview.daily,
            row.cost,
            do: %{category: Date.to_iso8601(row.day), series: row.model, value: row.cost}
          )
        ),
      ttft: %{
        type: "range",
        unit: "ms",
        series: series,
        points: for(row <- latency, do: %{series: row.model, value: row.ttft_p50, high: row.ttft_p95})
      },
      speed: %{
        type: "range",
        unit: "tps",
        series: series,
        points: for(row <- latency, row.tps_p50, do: %{series: row.model, value: row.tps_p50})
      },
      outcomes: outcomes_chart(overview.outcomes)
    }
  end

  defp days_chart(unit, days, series, points),
    do: %{
      type: "stacked",
      orientation: "vertical",
      unit: unit,
      dates: true,
      categories: days,
      series: series,
      points: points
    }

  # Each model's tokens split by kind, bar by bar.
  defp by_model_chart(models) do
    points =
      for model <- models,
          {kind, value} <- token_split(model),
          value > 0,
          do: %{category: model.key, series: Atom.to_string(kind), value: value}

    %{
      type: "stacked",
      orientation: "horizontal",
      unit: "tokens",
      categories: Enum.map(models, &%{key: &1.key, label: &1.name}),
      series: kind_series(points, @token_kinds),
      points: points
    }
  end

  # Every model's prompt tokens per day, uncached at the foot of each bar and cached on top.
  defp caching_chart(days, daily) do
    kinds = [:uncached, :cached, :unreported]

    points =
      for {day, rows} <- Enum.group_by(daily, & &1.day),
          {kind, value} <- rows |> sum_tokens() |> token_split() |> Keyword.take(kinds),
          value > 0,
          do: %{category: Date.to_iso8601(day), series: Atom.to_string(kind), value: value}

    days_chart("tokens", days, kind_series(points, kinds), points)
  end

  # Tokens by kind: prompt tokens served from the backend's cache, prompt tokens it processed,
  # prompt tokens of runs that did not say (neither cached nor uncached), and completion tokens.
  defp token_split(row) do
    [
      cached: row.cached_tokens,
      uncached: max(row.cache_reported_tokens - row.cached_tokens, 0),
      unreported: row.prompt_tokens - row.cache_reported_tokens,
      completion: row.completion_tokens
    ]
  end

  defp sum_tokens(rows) do
    Map.new(
      [:prompt_tokens, :completion_tokens, :cached_tokens, :cache_reported_tokens],
      fn field -> {field, Enum.sum_by(rows, &Map.fetch!(&1, field))} end
    )
  end

  # The `kinds` that have any point, in that order (the order they stack).
  defp kind_series(points, kinds) do
    used = MapSet.new(points, & &1.series)

    for kind <- kinds, MapSet.member?(used, Atom.to_string(kind)) do
      {name, color} = token_kind(kind)
      %{key: Atom.to_string(kind), name: name, color: color}
    end
  end

  defp outcomes_chart(outcomes) do
    tags = outcomes |> Enum.map(& &1.tag) |> Enum.uniq()

    %{
      type: "stacked",
      orientation: "horizontal",
      unit: "count",
      categories: Enum.map(tags, &%{key: Atom.to_string(&1), label: tag_label(&1)}),
      series:
        for({status, {label, color}} <- statuses(), do: %{key: Atom.to_string(status), name: label, color: color}),
      points:
        for(
          row <- outcomes,
          do: %{category: Atom.to_string(row.tag), series: Atom.to_string(row.status), value: row.count}
        )
    }
  end

  # A tooltip note's token kinds, each shown after its number ("1,200 prompt · 300 completion").
  defp part_name(:prompt),
    do: dpgettext("ai", "unit: prompt tokens in a usage chart tooltip, after the number", "prompt")

  defp part_name(:cached),
    do: dpgettext("ai", "unit: cached prompt tokens in a usage chart tooltip, after the number", "cached")

  defp part_name(:completion),
    do: dpgettext("ai", "unit: completion tokens in a usage chart tooltip, after the number", "completion")

  defp tag_label(:reply), do: dpgettext("ai", "column header: job type in the outcomes chart", "Reply")
  defp tag_label(:regenerate), do: dpgettext("ai", "column header: job type in the outcomes chart", "Regenerate")
  defp tag_label(:continue), do: dpgettext("ai", "column header: job type in the outcomes chart", "Continue")
  defp tag_label(:refine), do: dpgettext("ai", "column header: job type in the outcomes chart", "Refine")
  defp tag_label(:memory), do: dpgettext("ai", "column header: job type in the outcomes chart", "Memory")
  defp tag_label(:side_prompt), do: dpgettext("ai", "column header: job type in the outcomes chart", "Side prompt")
  defp tag_label(:consolidation), do: dpgettext("ai", "column header: job type in the outcomes chart", "Consolidation")
  defp tag_label(:compaction), do: dpgettext("ai", "column header: job type in the outcomes chart", "Compaction")
  defp tag_label(:topical_clip), do: dpgettext("ai", "column header: job type in the outcomes chart", "Topical clip")

  defp tag_label(:memory_assistance),
    do: dpgettext("ai", "column header: job type in the outcomes chart", "Memory assistance")

  defp tag_label(:caption), do: dpgettext("ai", "column header: job type in the outcomes chart", "Caption")
  defp tag_label(:expression), do: dpgettext("ai", "column header: job type in the outcomes chart", "Expression")
  defp tag_label(:assistant), do: dpgettext("ai", "column header: job type in the outcomes chart", "Assistant")
  defp tag_label(:embedding), do: dpgettext("ai", "column header: job type in the outcomes chart", "Embedding")

  ## Totals

  defp seconds(nil), do: "—"
  defp seconds(ms), do: Format.seconds(ms, fractional_digits: 2)

  defp per_second(nil), do: "—"
  defp per_second(tps), do: Format.number(tps, fractional_digits: 1)

  # Cached share of the prompt tokens whose runs reported a cache count, so unreported runs neither
  # dilute nor inflate it.
  defp cache_share(%{cached_tokens: cached, cache_reported_tokens: reported}),
    do: Format.percent(min(1.0, cached / reported))

  defp costed_note(%{costed_runs: costed, runs: runs, estimated_runs: 0}),
    do:
      dngettext(
        "ai",
        "Cost known for %{costed_runs} of %{total_runs} run.",
        "Cost known for %{costed_runs} of %{total_runs} runs.",
        runs, costed_runs: Format.number(costed), total_runs: Format.number(runs))

  defp costed_note(%{costed_runs: costed, runs: runs, estimated_runs: estimated}),
    do:
      dngettext(
        "ai",
        "Cost known for %{costed_runs} of %{total_runs} run; %{estimated_runs} estimated from model prices.",
        "Cost known for %{costed_runs} of %{total_runs} runs; %{estimated_runs} estimated from model prices.",
        runs,
        costed_runs: Format.number(costed),
        total_runs: Format.number(runs),
        estimated_runs: Format.number(estimated)
      )

  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "the chart's accessible name"
  attr :spec, :map, required: true, doc: "the `Chart` hook's spec; no points renders `empty`"
  attr :empty, :string, required: true

  # Its own template, so its own styles: a function component's root bounds the page's scoped CSS.
  defp chart(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      /* `position: relative`: the hook places its tooltip inside. */
      div:scope {
        position: relative;
        inline-size: 100%;
        min-block-size: 4rem;
        font-size: var(--font-size-0);
      }

      p:scope {
        margin: 0;
        color: var(--muted-foreground);
        font-size: var(--font-size-0);
      }

      svg {
        display: block;
      }

      .chart-axis {
        & text {
          fill: var(--muted-foreground);
          font-size: 11px;
        }

        & path,
        & line {
          stroke: var(--border-grey);
        }
      }

      .chart-grid line {
        stroke: var(--border);
      }

      .chart-whisker {
        stroke: var(--foreground);
        stroke-width: 1.5;
      }

      .chart-rule {
        stroke: var(--foreground);
        stroke-opacity: 0.6;
        stroke-dasharray: 3 3;
        pointer-events: none;
      }

      .chart-rule-band {
        fill: var(--foreground);
        fill-opacity: 0.07;
        pointer-events: none;
      }

      .chart-tip {
        position: absolute;
        z-index: 2;
        display: flex;
        flex-direction: column;
        gap: 2px;
        min-inline-size: 11rem;
        max-inline-size: min(22rem, calc(100vw - 2 * var(--panel-gap)));
        padding: var(--size-2);
        background: var(--surface-8);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        box-shadow: var(--elevation-lg);
        pointer-events: none;

        &[hidden] {
          display: none;
        }
      }

      .chart-tip-title {
        font-weight: 600;
      }

      .chart-tip-row {
        display: flex;
        align-items: center;
        gap: var(--size-1);
      }

      .chart-tip-swatch {
        flex: none;
        inline-size: 0.65em;
        block-size: 0.65em;
        border-radius: 2px;
      }

      .chart-tip-name {
        flex: 1;
        color: var(--muted-foreground);
      }

      .chart-tip-value {
        font-variant-numeric: tabular-nums;
      }

      .chart-tip-note {
        padding-inline-start: 1.15em;
        color: var(--muted-foreground);
        font-size: 0.9em;
      }

      .chart-tip-total {
        margin-top: 2px;
        padding-top: 2px;
        border-top: 1px solid var(--border);
      }
    </style>
    <div
      :if={@spec.points != []}
      id={@id}
      class="analytics-chart"
      phx-hook="Chart"
      phx-update="ignore"
      data-chart={Jason.encode!(@spec)}
      data-label={@label}
    >
    </div>
    <p :if={@spec.points == []} id={"#{@id}-empty"} class="analytics-empty">{@empty}</p>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      /* The page is one panel; its root is a scope root, so it needs `:scope`. Tag and class both:
         the header's `:actions` content carries this block's scope marker too, so a bare
         `div:scope` would also turn `.analytics-controls` into a card. */
      div.analytics-page:scope {
        margin: var(--panel-gap);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        background: var(--card);
        box-shadow: var(--elevation-lg);
        overflow-y: auto;
      }

      div.analytics-controls:scope {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-3);
      }

      .analytics-group {
        display: flex;
        gap: var(--size-1);
      }

      .analytics-section {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-3) var(--size-4);
        border-top: 1px solid var(--border-grey);
      }

      .analytics-pair {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(22rem, 1fr));
        border-top: 1px solid var(--border-grey);

        & > .analytics-section {
          border-top: none;
        }
      }

      .analytics-totals {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr));
        gap: var(--size-3);
        margin: 0;
        padding: var(--size-3) var(--size-4);
      }

      .analytics-total {
        display: flex;
        flex-direction: column-reverse;
        gap: var(--size-1);
        padding: var(--size-2) var(--size-3);
        background: var(--surface-2);
        border-radius: var(--radius-2);

        & dt {
          color: var(--muted-foreground);
          font-size: var(--font-size-0);
        }

        & dd {
          margin: 0;
          font-size: var(--font-size-3);
          font-weight: 600;
          font-variant-numeric: tabular-nums;
        }
      }

      .analytics-note {
        margin: 0;
        color: var(--muted-foreground);
        font-size: var(--font-size-0);
      }

      .analytics-legend {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-1) var(--size-3);
        margin: 0;
        padding: 0;
        list-style: none;
        font-size: var(--font-size-0);

        & li {
          display: inline-flex;
          align-items: center;
          gap: var(--size-1);
        }
      }

      .analytics-swatch {
        inline-size: 0.75em;
        block-size: 0.75em;
        border-radius: 2px;
        background: var(--swatch);
      }

      @media (--phone) {
        .analytics-pair {
          grid-template-columns: minmax(0, 1fr);
        }
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="analytics-page">
        <.panel_header sticky>
          {dpgettext("ai", "heading: usage analytics page", "Analytics")}
          <:actions>
            <div class="analytics-controls">
              <div
                class="analytics-group"
                role="group"
                aria-label={
                  dpgettext(
                    "ai",
                    "aria label: buttons choosing how many days the analytics cover",
                    "Range"
                  )
                }
              >
                <.button
                  :for={days <- Analytics.ranges()}
                  size="sm"
                  id={"analytics-days-#{days}"}
                  patch={analytics_path(days, @all_users)}
                  aria-pressed={to_string(@days == days)}
                >
                  {dpngettext(
                    "ai",
                    "button: analytics range length",
                    "%{day_count} day",
                    "%{day_count} days",
                    days,
                    day_count: Format.number(days)
                  )}
                </.button>
              </div>
              <div
                :if={@see_all?}
                class="analytics-group"
                role="group"
                aria-label={
                  dpgettext(
                    "ai",
                    "aria label: buttons choosing whose job runs the analytics count",
                    "Whose runs"
                  )
                }
              >
                <.button
                  size="sm"
                  id="analytics-mine"
                  patch={analytics_path(@days, false)}
                  aria-pressed={to_string(!@all_users)}
                >
                  {dpgettext("ai", "button: analytics of my own job runs only", "Mine")}
                </.button>
                <.button
                  size="sm"
                  id="analytics-all-users"
                  patch={analytics_path(@days, true)}
                  aria-pressed={to_string(@all_users)}
                >
                  {dpgettext("ai", "button: analytics of every user's job runs", "All users")}
                </.button>
              </div>
            </div>
          </:actions>
        </.panel_header>

        <div :if={@overview} id="analytics-body">
          <dl class="analytics-totals" id="analytics-totals">
            <div class="analytics-total">
              <dt>{dpgettext("ai", "field label: analytics total of job runs", "Runs")}</dt>
              <dd id="analytics-total-runs">{Format.number(@overview.totals.runs)}</dd>
            </div>
            <div class="analytics-total">
              <dt>
                {dpgettext("ai", "field label: analytics total of prompt tokens", "Prompt tokens")}
              </dt>
              <dd id="analytics-total-prompt">{Format.number(@overview.totals.prompt_tokens)}</dd>
            </div>
            <div class="analytics-total">
              <dt>
                {dpgettext(
                  "ai",
                  "field label: analytics total of completion tokens",
                  "Completion tokens"
                )}
              </dt>
              <dd id="analytics-total-completion">
                {Format.number(@overview.totals.completion_tokens)}
              </dd>
            </div>
            <div class="analytics-total">
              <dt>
                {dpgettext(
                  "ai",
                  "field label: analytics total of cached prompt tokens",
                  "Cached prompt tokens"
                )}
              </dt>
              <dd id="analytics-total-cached">
                {Format.number(@overview.totals.cached_tokens)}<span
                  :if={@overview.totals.cache_reported_tokens > 0}
                  class="analytics-total-share"
                > · {cache_share(@overview.totals)}</span>
              </dd>
            </div>
            <div class="analytics-total">
              <dt>{dpgettext("ai", "field label: analytics total of money spent", "Spend")}</dt>
              <dd id="analytics-total-cost">{Format.money(@overview.totals.cost)}</dd>
            </div>
            <div class="analytics-total">
              <dt>
                {dpgettext(
                  "ai",
                  "field label: analytics median time to first token",
                  "Median time to first token"
                )}
              </dt>
              <dd id="analytics-total-ttft">{seconds(@overview.totals.ttft_p50)}</dd>
            </div>
            <div class="analytics-total">
              <dt>
                {dpgettext("ai", "field label: analytics median generation speed", "Median tokens/s")}
              </dt>
              <dd id="analytics-total-tps">{per_second(@overview.totals.tps_p50)}</dd>
            </div>
          </dl>

          <section class="analytics-section" id="analytics-models">
            <ul
              class="analytics-legend"
              aria-label={
                dpgettext("ai", "aria label: legend of the models in the analytics charts", "Models")
              }
            >
              <li :for={model <- @overview.models} id={"analytics-model-#{model.key}"}>
                <span class="analytics-swatch" style={"--swatch: var(--chart-#{model.color})"}></span>
                {model.name}
              </li>
            </ul>
            <p class="analytics-note">
              {dgettext(
                "ai",
                "Days are in %{timezone}. Every job run counts: replies, regenerations and memory work.",
                timezone: @overview.timezone
              )}
            </p>
          </section>

          <section class="analytics-section">
            <.section_header>
              {dpgettext("ai", "heading: analytics chart of tokens per day", "Tokens per day")}
            </.section_header>
            <.chart
              id="analytics-tokens-chart"
              label={dgettext("ai", "Tokens per day by model")}
              spec={@charts.tokens}
              empty={dgettext("ai", "No runs in this range.")}
            />
          </section>

          <section class="analytics-section">
            <.section_header>
              {dpgettext("ai", "heading: analytics chart of tokens by model", "Tokens by model")}
            </.section_header>
            <ul
              :if={@charts.by_model.points != []}
              class="analytics-legend"
              aria-label={
                dpgettext(
                  "ai",
                  "aria label: legend of the token kinds in an analytics chart",
                  "Token kinds"
                )
              }
            >
              <li :for={kind <- @charts.by_model.series} id={"analytics-token-kind-#{kind.key}"}>
                <span class="analytics-swatch" style={"--swatch: #{kind.color}"}></span>
                {kind.name}
              </li>
            </ul>
            <.chart
              id="analytics-by-model-chart"
              label={dgettext("ai", "Tokens by model: cached prompt, uncached prompt and completion")}
              spec={@charts.by_model}
              empty={dgettext("ai", "No runs in this range.")}
            />
          </section>

          <section class="analytics-section">
            <.section_header>
              {dpgettext(
                "ai",
                "heading: analytics chart of cached prompt tokens",
                "Prompt token caching"
              )}
            </.section_header>
            <ul
              :if={@charts.caching.points != []}
              class="analytics-legend"
              aria-label={
                dpgettext(
                  "ai",
                  "aria label: legend of the prompt token kinds in an analytics chart",
                  "Prompt token kinds"
                )
              }
            >
              <li :for={kind <- @charts.caching.series}>
                <span class="analytics-swatch" style={"--swatch: #{kind.color}"}></span>
                {kind.name}
              </li>
            </ul>
            <.chart
              id="analytics-caching-chart"
              label={dgettext("ai", "Cached and uncached prompt tokens per day")}
              spec={@charts.caching}
              empty={dgettext("ai", "No prompt tokens in this range.")}
            />
            <p :if={@charts.caching.points != []} class="analytics-note">
              {dgettext(
                "ai",
                "Cached prompt tokens are the ones the backend served from its prompt cache instead of processing them again."
              )}
            </p>
          </section>

          <section class="analytics-section">
            <.section_header>
              {dpgettext("ai", "heading: analytics chart of money spent per day", "Spend per day")}
            </.section_header>
            <.chart
              id="analytics-spend-chart"
              label={dgettext("ai", "Spend per day by model")}
              spec={@charts.spend}
              empty={
                dgettext(
                  "ai",
                  "No run in this range has a cost: its provider reported none (only OpenRouter does) and its model has no prices set."
                )
              }
            />
            <p
              :if={@overview.totals.costed_runs > 0}
              class="analytics-note"
              id="analytics-costed-note"
            >
              {costed_note(@overview.totals)}
            </p>
          </section>

          <div class="analytics-pair">
            <section class="analytics-section">
              <.section_header>
                {dpgettext(
                  "ai",
                  "heading: analytics chart of time to first token",
                  "Time to first token"
                )}
              </.section_header>
              <.chart
                id="analytics-ttft-chart"
                label={
                  dgettext("ai", "Median time to first token by model, with the 95th percentile")
                }
                spec={@charts.ttft}
                empty={dgettext("ai", "No completed runs in this range.")}
              />
              <p :if={@charts.ttft.points != []} class="analytics-note">
                {dgettext(
                  "ai",
                  "Median; the whisker reaches the 95th percentile. Timed from when the job started running, so queue time is left out."
                )}
              </p>
            </section>

            <section class="analytics-section">
              <.section_header>
                {dpgettext("ai", "heading: analytics chart of generation speed", "Generation speed")}
              </.section_header>
              <.chart
                id="analytics-speed-chart"
                label={dgettext("ai", "Median tokens per second by model")}
                spec={@charts.speed}
                empty={
                  dgettext("ai", "No completed run in this range generated for a second or more.")
                }
              />
              <p :if={@charts.speed.points != []} class="analytics-note">
                {dgettext("ai", "Median completion tokens per second after the first token.")}
              </p>
            </section>
          </div>

          <section class="analytics-section">
            <.section_header>
              {dpgettext("ai", "heading: analytics chart of job outcomes", "Outcomes by job type")}
            </.section_header>
            <ul
              :if={@charts.outcomes.points != []}
              class="analytics-legend"
              aria-label={
                dpgettext(
                  "ai",
                  "aria label: legend of job outcomes in an analytics chart",
                  "Outcomes"
                )
              }
            >
              <li :for={status <- @charts.outcomes.series}>
                <span class="analytics-swatch" style={"--swatch: #{status.color}"}></span>
                {status.name}
              </li>
            </ul>
            <.chart
              id="analytics-outcomes-chart"
              label={dgettext("ai", "Runs by job type and outcome")}
              spec={@charts.outcomes}
              empty={dgettext("ai", "No runs in this range.")}
            />
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
