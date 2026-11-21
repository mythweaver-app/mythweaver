defmodule Mythweaver.Assistant.Tools.AnalyticsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Analytics
  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Jobs.Job

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  # One finished run, through the writer `Jobs` uses.
  defp stat!(scope) do
    finished = DateTime.utc_now()

    :ok =
      Analytics.record_runs([
        %Job{
          id: Mythweaver.Schema.generate_id(),
          user_id: scope.user.id,
          tag: :reply,
          origin: :interactive,
          status: :completed,
          usage: %{"prompt_tokens" => 100, "completion_tokens" => 20},
          started_at: DateTime.add(finished, -10, :second),
          finished_at: finished
        }
      ])
  end

  test "totals for the caller only; all_users is ignored without the permission" do
    scope = scope!(%{role: :user})
    stat!(scope)
    stat!(scope!(%{role: :user}))

    assert {:ok, %{"totals" => %{"runs" => 1, "prompt_tokens" => 100}, "all_users" => false, "path" => "/analytics"}} =
             run!(scope, "get_analytics", %{})

    assert {:ok, %{"totals" => %{"runs" => 1}, "all_users" => false}} =
             run!(scope, "get_analytics", %{"all_users" => true})
  end

  test "an unsupported days value falls back to the default range" do
    assert {:ok, %{"start_date" => first, "end_date" => last}} =
             run!(scope!(%{role: :user}), "get_analytics", %{"days" => 14})

    assert Date.diff(last, first) + 1 == Analytics.default_range()
  end
end
