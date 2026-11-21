defmodule Mythweaver.Assistant.Tools.Analytics do
  @moduledoc "The assistant's usage overview tool over `Mythweaver.Analytics`."

  alias Mythweaver.Analytics
  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool

  def tools do
    [
      %Tool{
        name: "get_analytics",
        description:
          "Usage stats: tokens, cost, run counts, outcomes and latency over the last 7, 30 or 90 days (UTC). " <>
            "all_users needs the analytics permission; it is otherwise ignored.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "days" => %{"type" => "integer", "enum" => Analytics.ranges(), "description" => "7, 30 or 90 (default 30)."},
            "all_users" => %{"type" => "boolean", "description" => "Every user's runs, not just the caller's."}
          },
          "required" => []
        },
        kind: :read,
        summary: fn args -> "Read analytics (#{args["days"] || Analytics.default_range()} days)" end,
        run: fn scope, args ->
          o = Analytics.overview(scope, days: args["days"], all_users: args["all_users"] == true)

          {:ok,
           %{
             "start_date" => List.first(o.days),
             "end_date" => List.last(o.days),
             "timezone" => o.timezone,
             "all_users" => o.all_users,
             "totals" => Map.new(o.totals, fn {k, v} -> {Atom.to_string(k), v} end),
             "models" =>
               Enum.map(
                 o.models,
                 &%{
                   "key" => &1.key,
                   "name" => &1.name,
                   "prompt_tokens" => &1.prompt_tokens,
                   "completion_tokens" => &1.completion_tokens,
                   "cached_tokens" => &1.cached_tokens,
                   "cache_reported_tokens" => &1.cache_reported_tokens
                 }
               ),
             "latency" =>
               Enum.map(
                 o.latency,
                 &%{"model" => &1.model, "ttft_p50" => &1.ttft_p50, "ttft_p95" => &1.ttft_p95, "tps_p50" => &1.tps_p50}
               ),
             "outcomes" =>
               Enum.map(
                 o.outcomes,
                 &%{"tag" => to_string(&1.tag), "status" => to_string(&1.status), "count" => &1.count}
               ),
             "path" => Paths.index(:analytics)
           }}
        end
      }
    ]
  end
end
