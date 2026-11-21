defmodule Mythweaver.Assistant.Tools.Jobs do
  @moduledoc "Assistant tools over `Mythweaver.Jobs`: the generation job queue."

  alias Mythweaver.AI
  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job

  defp statuses, do: Enum.map(Ecto.Enum.values(Job, :status), &Atom.to_string/1)
  defp tags, do: Enum.map(Ecto.Enum.values(Job, :tag), &Atom.to_string/1)

  def tools do
    jobs = {"job", "jobs"}
    label = fn scope, id -> with %Job{label: label} <- Jobs.get_job(scope, id), do: label end

    [
      %Tool{
        name: "list_jobs",
        description:
          "List the newest 200 generation jobs the user may see, optionally narrowed by chat, status and kind.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "chat_id" => %{"type" => "string", "description" => "Only this chat's jobs."},
            "statuses" => %{
              "type" => "array",
              "items" => %{"type" => "string", "enum" => statuses()},
              "description" => "Only these statuses."
            },
            "tags" => %{
              "type" => "array",
              "items" => %{"type" => "string", "enum" => tags()},
              "description" => "Only these job kinds."
            }
          },
          "required" => []
        },
        kind: :read,
        summary: fn _ -> "List jobs" end,
        run: &list/2
      },
      %Tool{
        name: "get_job",
        description: "Read a job: its status, error, parameters, result and token usage.",
        parameters: %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string", "description" => "Job id."}},
          "required" => ["id"]
        },
        kind: :read,
        summary: fn _ -> "Read a job" end,
        run: fn scope, args ->
          with {:ok, id} <- Args.uuid(args, "id") do
            case Jobs.get_job(scope, id) do
              nil -> {:error, Args.error(:not_found)}
              job -> {:ok, job_full(scope, job)}
            end
          end
        end
      },
      Batch.ids("cancel_jobs",
        description: "Cancel queued, running or review-pending jobs.",
        verb: "Cancel",
        noun: jobs,
        label: label,
        run: fn scope, args ->
          with {:ok, id} <- Args.uuid(args, "id") do
            case Jobs.cancel(scope, id) do
              :ok -> {:ok, %{"id" => id, "canceled" => true}}
              {:error, reason} -> {:error, Args.error(reason)}
            end
          end
        end
      ),
      Batch.ids("retry_jobs",
        description:
          "Run finished memory jobs again with their sources re-read. A chat reply is retried by regenerating it, " <>
            "not with this tool.",
        verb: "Retry",
        noun: jobs,
        label: label,
        run: fn scope, args ->
          with {:ok, id} <- Args.uuid(args, "id"), do: scope |> Jobs.retry(id) |> Args.wrap(&job_row/1)
        end
      ),
      Batch.ids("dismiss_jobs",
        description: "Delete finished jobs' rows (completed, failed, canceled or interrupted).",
        verb: "Dismiss",
        noun: jobs,
        label: label,
        run: fn scope, args ->
          with {:ok, id} <- Args.uuid(args, "id") do
            scope |> Jobs.dismiss(id) |> Args.wrap(&%{"id" => &1.id, "dismissed" => true})
          end
        end
      )
    ]
  end

  defp list(scope, args) do
    with {:ok, chat_id} <- chat_id(args),
         {:ok, statuses} <- atoms(args["statuses"], statuses(), "statuses"),
         {:ok, tags} <- atoms(args["tags"], tags(), "tags") do
      opts = Enum.reject([chat_id: chat_id, statuses: statuses, tags: tags], &match?({_, nil}, &1))
      rows = scope |> Jobs.list_jobs(opts) |> Enum.map(&job_row/1)
      {:ok, Map.put(Args.list("jobs", rows), "path", Paths.index(:jobs))}
    end
  end

  defp chat_id(%{"chat_id" => id} = args) when not is_nil(id), do: Args.uuid(args, "chat_id")
  defp chat_id(_args), do: {:ok, nil}

  defp atoms(nil, _allowed, _key), do: {:ok, nil}

  defp atoms(list, allowed, key) when is_list(list) do
    if Enum.all?(list, &(&1 in allowed)),
      do: {:ok, Enum.map(list, &String.to_existing_atom/1)},
      else: {:error, Args.error("#{key} must each be one of #{Enum.join(allowed, ", ")}")}
  end

  defp atoms(_list, _allowed, key), do: {:error, Args.error("#{key} must be a list")}

  defp job_row(%Job{} = j) do
    %{
      "id" => j.id,
      "tag" => to_string(j.tag),
      "status" => to_string(j.status),
      "origin" => to_string(j.origin),
      "label" => j.label,
      "chat_id" => j.chat_id,
      "error" => j.error,
      "attempts" => j.attempts,
      "inserted_at" => j.inserted_at,
      "started_at" => j.started_at,
      "finished_at" => j.finished_at,
      "path" => j.chat_id && Paths.chat(j.chat_id)
    }
  end

  defp job_full(scope, %Job{} = j) do
    model = j.ai_model_id && AI.get_model(scope, j.ai_model_id)

    j
    |> job_row()
    |> Map.merge(%{
      "chat_title" => j.chat && Chat.title(j.chat),
      "provider_name" => j.provider && j.provider.name,
      "model_name" => model && model.name,
      "params" => j.params,
      "result" => j.result,
      "usage" => j.usage
    })
  end
end
