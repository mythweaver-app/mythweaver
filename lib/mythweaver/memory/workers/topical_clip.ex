defmodule Mythweaver.Memory.Workers.TopicalClip do
  @moduledoc """
  The `:topical_clip` job: gathers everything about one topic from memory entries and, optionally,
  chat messages into a single entry. Always reviewed; `Mythweaver.Memory.approve/3` writes it.

  Params (string keys): `chat_id`, `profile_id`, `prompt_id`, `book_id`, `topic`, `keywords`,
  `source_ids` (the records to send, in story order), `messages` (`"start"`, `"end"`,
  `"fingerprint"` and, for picked messages, `"message_ids"`; or absent), `rebuild`, and for an
  update `target_record_id` with
  `entry_updated_at` and `entry_fingerprint` (the target as it was when queued). `snapshot` is what
  the saved record will cover. A combination (`combine`) sends the topical clips `source_ids` as
  its sources, with `source_fingerprints` and `disable_originals` for the save. A retry
  (`retry_params/2`) re-reads the target's version and the combined clips' fingerprints.
  """

  @behaviour Mythweaver.Jobs.Worker

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Anchors
  alias Mythweaver.Memory.Clips
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Request
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.Workers

  @impl true
  def build(%Job{params: %{"combine" => true} = params} = job) do
    with {:ok, scope, chat, profile} <- Workers.context(job),
         {:ok, prompt} <- Clips.combine_clips_prompt(scope, params["prompt_id"]),
         {:ok, model} <- Workers.model(scope, job),
         {:ok, sources} <- sources(params["source_ids"] || []) do
      memory_map =
        Anchors.build(:topical_clip,
          sources: Workers.source_maps(sources),
          topic: params["topic"],
          keywords: params["keywords"]
        )

      {:ok, Request.input(scope, chat, prompt, model, profile, memory_map), prompt.name}
    end
  end

  def build(%Job{params: params} = job) do
    with {:ok, scope, chat, profile} <- Workers.context(job),
         {:ok, prompt} <- Clips.topical_clip_prompt(scope, params["prompt_id"]),
         {:ok, model} <- Workers.model(scope, job),
         {:ok, sources} <- sources(params["source_ids"] || []),
         {:ok, messages} <- messages(scope, chat, params["messages"]) do
      memory_map =
        Anchors.build(:topical_clip,
          sources: Workers.source_maps(sources),
          messages: messages,
          entry: entry(scope, params),
          topic: params["topic"],
          keywords: params["keywords"],
          speakers: Scene.speaker_names(chat, messages)
        )

      {:ok, Request.input(scope, chat, prompt, model, profile, memory_map), prompt.name}
    end
  end

  @impl true
  def retry_params(%Scope{}, %Job{params: params}), do: Map.merge(target_version(params), combined(params))

  defp target_version(%{"target_record_id" => id}) when is_binary(id), do: Workers.record_entry_version(id)
  defp target_version(_params), do: %{}

  defp combined(%{"combine" => true, "source_ids" => ids}) when is_list(ids),
    do: %{"source_fingerprints" => Workers.fingerprints(ids)}

  defp combined(_params), do: %{}

  defp sources(ids) do
    sources = Workers.records(ids)
    if nil in sources, do: {:error, :source_missing}, else: {:ok, sources}
  end

  defp messages(scope, chat, %{"message_ids" => ids, "start" => first, "end" => last}) when is_list(ids),
    do: {:ok, Scene.listed(scope, chat, first, last, ids)}

  defp messages(_scope, _chat, nil), do: {:ok, []}

  defp messages(scope, chat, %{"start" => first, "end" => last}) do
    case Scene.messages(scope, chat, first, last, Memory.preferences(scope)) do
      [] -> {:error, :source_missing}
      messages -> {:ok, messages}
    end
  end

  # An update shows the model the clip it extends; a rebuild starts over from the sources.
  defp entry(_scope, %{"rebuild" => true}), do: nil

  defp entry(scope, %{"target_record_id" => id}) when is_binary(id) do
    case Memory.get_record(scope, id) do
      %Record{entry: entry} -> Workers.entry_map(entry, "topical_clip")
      nil -> nil
    end
  end

  defp entry(_scope, _params), do: nil

  @impl true
  def finish(%Job{}, completion, _retried?) do
    with {:ok, text} <- Workers.text(completion), do: {:ok, :review, %{"content" => text}}
  end
end
