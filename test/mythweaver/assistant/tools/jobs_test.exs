defmodule Mythweaver.Assistant.Tools.JobsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Repo

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp job!(scope, status, tag \\ :memory) do
    Repo.insert!(%Job{user_id: scope.user.id, tag: tag, origin: :background, status: status, label: "Test"})
  end

  setup do
    %{scope: scope!(%{role: :user})}
  end

  test "list_jobs filters by status and rejects an unknown one", %{scope: scope} do
    done = job!(scope, :completed)
    job!(scope, :queued)

    assert {:ok, %{"jobs" => [%{"id" => id, "status" => "completed"}], "total" => 1, "path" => "/jobs"}} =
             run!(scope, "list_jobs", %{"statuses" => ["completed"]})

    assert id == done.id

    assert {:error, %{"error" => "statuses must each be one of " <> _}} =
             run!(scope, "list_jobs", %{"statuses" => ["bogus"]})
  end

  test "get_job reads one and refuses another user's", %{scope: scope} do
    job = job!(scope, :failed)

    assert {:ok, %{"id" => id, "label" => "Test", "tag" => "memory"}} = run!(scope, "get_job", %{"id" => job.id})
    assert id == job.id
    assert {:error, %{"error" => "Not found."}} = run!(scope!(%{role: :user}), "get_job", %{"id" => job.id})
  end

  test "dismiss_jobs deletes a terminal job and refuses a running one", %{scope: scope} do
    failed = job!(scope, :failed)
    running = job!(scope, :running)

    assert {:ok, %{"done" => [%{"dismissed" => true}]}} = run!(scope, "dismiss_jobs", %{"ids" => [failed.id]})
    assert Jobs.get_job(scope, failed.id) == nil

    assert {:error, %{"failed" => [%{"error" => "Not found."}]}} = run!(scope, "dismiss_jobs", %{"ids" => [running.id]})
  end

  test "cancel_jobs with nothing to cancel and retry_jobs on a chat tag are refused", %{scope: scope} do
    queued = job!(scope, :queued)
    reply = job!(scope, :failed, :reply)

    assert {:error, %{"failed" => [%{"error" => "Not found."}]}} = run!(scope, "cancel_jobs", %{"ids" => [queued.id]})

    assert {:error, %{"failed" => [%{"error" => "That job cannot be retried."}]}} =
             run!(scope, "retry_jobs", %{"ids" => [reply.id]})
  end
end
