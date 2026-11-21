defmodule Mythweaver.Memory.Workers.Consolidation do
  @moduledoc """
  The `:consolidation` job: summarizes one batch of tier `n - 1` records into tier `n` summaries.

  Params (string keys): `chat_id`, `profile_id`, `book_id`, `prompt_id`, `target_tier`, `source_ids`
  (in batch order), `disable_sources`, `review`, `source_versions` and `source_fingerprints` (each
  source entry's `updated_at` and content digest when queued), and `record_id` when regenerating one
  consolidation over its own sources. A retry (`retry_params/2`) re-reads `source_versions` and
  `source_fingerprints` from the sources as they are then.

  Sources are numbered `001`… within the batch; the reply's `member_ids` map back to record ids and
  unknown ids are dropped.
  """

  @behaviour Mythweaver.Jobs.Worker

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Memory.Anchors
  alias Mythweaver.Memory.Consolidation
  alias Mythweaver.Memory.JSON
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Request
  alias Mythweaver.Memory.Tiers
  alias Mythweaver.Memory.Workers
  alias Mythweaver.Repo

  @single "Write exactly one summary that covers every source entry."

  @impl true
  def build(%Job{params: params} = job) do
    with {:ok, scope, chat, profile} <- Workers.context(job),
         {:ok, prompt} <- Consolidation.consolidation_prompt(scope, params["prompt_id"]),
         {:ok, model} <- Workers.model(scope, job),
         {:ok, sources} <- Consolidation.consolidation_sources(params) do
      {:ok, input(scope, chat, profile, prompt, model, params, sources), prompt.name}
    end
  end

  @impl true
  def retry_params(%Scope{}, %Job{params: %{"source_ids" => ids}}) when is_list(ids),
    do: %{"source_versions" => Workers.versions(ids), "source_fingerprints" => Workers.fingerprints(ids)}

  def retry_params(%Scope{}, %Job{}), do: %{}

  @doc "The rendered consolidation request over `sources` (records with entries, in batch order)."
  def input(%Scope{} = scope, %Chat{} = chat, profile, prompt, model, params, sources) do
    tier = params["target_tier"]

    memory_map =
      Anchors.build(:consolidation,
        sources: Workers.source_maps(sources),
        previous_summary: previous_summary(params["book_id"], tier, params["record_id"]),
        target_tier: %{"number" => tier, "name" => Tiers.name(tier)},
        speakers: Workers.character_names(chat)
      )

    input = Request.input(scope, chat, prompt, model, profile, memory_map)
    if params["record_id"] || params["replace"], do: Request.append_user(input, @single), else: input
  end

  # The newest summary already at the target tier, as canon; a regeneration sees the one before it.
  defp previous_summary(book_id, tier, record_id) do
    query =
      from(r in Record,
        join: e in assoc(r, :entry),
        where: r.lore_book_id == ^book_id and r.kind == :consolidation and r.tier == ^tier,
        order_by: [desc: r.sequence, desc: r.inserted_at],
        limit: 1,
        select: %{"title" => e.name, "content" => e.content}
      )

    query =
      case record_id && Repo.get(Record, record_id) do
        %Record{id: id, sequence: sequence} -> where(query, [r], r.id != ^id and r.sequence < ^sequence)
        nil -> query
      end

    Repo.one(query)
  end

  @impl true
  def finish(%Job{params: params} = job, completion, retried?) do
    with %Scope{} = scope <- Workers.initiator(job),
         {:ok, map} <- JSON.decode(completion.text),
         {:ok, reply} <- JSON.consolidation(map),
         {:ok, result} <- result(params, reply) do
      cond do
        params["replace"] ->
          with {:ok, replaced} <- Consolidation.replace_candidate(scope, job, hd(result["candidates"])),
               do: {:ok, :completed, replaced}

        params["review"] ->
          {:ok, :review, result}

        true ->
          with {:ok, records} <-
                 Consolidation.save_consolidation(scope, job, result["candidates"], result["unassigned"]),
               do:
                 {:ok, :completed, %{"record_ids" => Enum.map(records, & &1.id), "unassigned" => result["unassigned"]}}
      end
    else
      {:error, :no_initiator} = error -> error
      _invalid -> Workers.repair(__MODULE__, job, retried?)
    end
  end

  @doc """
  The review result for a parsed consolidation reply: candidates mapped to the job's source ids.
  A regeneration keeps one summary over every source; otherwise each summary keeps the sources its
  member ids name, and a summary naming none is dropped. Sources neither summarized nor listed as
  unassigned by the model are added to `"unassigned"`. A single-candidate replacement
  (`params["replace"]`) works like a regeneration.
  """
  def result(%{"record_id" => id, "source_ids" => source_ids}, %{"summaries" => [summary | _]}) when is_binary(id),
    do: {:ok, %{"candidates" => [candidate(summary, source_ids)], "unassigned" => []}}

  def result(%{"replace" => %{}, "source_ids" => source_ids}, %{"summaries" => [summary | _]}),
    do: {:ok, %{"candidates" => [candidate(summary, source_ids)], "unassigned" => []}}

  def result(%{"source_ids" => source_ids}, %{"summaries" => summaries, "unassigned" => unassigned}) do
    candidates =
      summaries
      |> Enum.map(&candidate(&1, &1["member_ids"] |> Enum.map(fn id -> Workers.nth(source_ids, id) end) |> clean()))
      |> Enum.reject(&(&1["source_ids"] == []))

    unassigned =
      Enum.flat_map(unassigned, fn item ->
        case Workers.nth(source_ids, item["id"]) do
          nil -> []
          id -> [%{"record_id" => id, "reason" => to_string(item["reason"] || "")}]
        end
      end)

    claimed = Enum.flat_map(candidates, & &1["source_ids"]) ++ Enum.map(unassigned, & &1["record_id"])

    omitted =
      Enum.map(source_ids -- claimed, &%{"record_id" => &1, "reason" => "Not summarized or listed by the model."})

    if candidates == [],
      do: {:error, :invalid},
      else: {:ok, %{"candidates" => candidates, "unassigned" => unassigned ++ omitted}}
  end

  defp candidate(summary, source_ids),
    do: %{
      "title" => summary["title"],
      "summary" => summary["summary"],
      "keywords" => summary["keywords"],
      "source_ids" => source_ids
    }

  defp clean(ids), do: ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
end
