defmodule Mythweaver.Memory.Workers.Assistance do
  @moduledoc """
  The `:memory_assistance` job: after a new scene memory, reviews the book's clips against the scene
  (`"pass" => "review"`) or suggests new topical clips (`"pass" => "suggest"`).

  Params (string keys): `chat_id`, `profile_id`, `prompt_id`, `book_id`, `record_id` (the saved
  memory), `start`, `end`, `message_ids`, `mode` (the `memory.assistance_mode` it was queued under),
  `pass`, `clip_ids` (the clips sent, in uid order) and, for a review, `fingerprints` (each clip's
  content hash when queued; a retry, `retry_params/2`, re-reads them).

  Results go to review as `%{"candidates" => …, "topics" => …}`; in Automatic mode ordinary clip
  additions are written without review.
  """

  @behaviour Mythweaver.Jobs.Worker

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Memory.Anchors
  alias Mythweaver.Memory.Clips
  alias Mythweaver.Memory.JSON
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Request
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.Workers

  @impl true
  def build(%Job{params: params} = job) do
    with {:ok, scope, chat, profile} <- Workers.context(job),
         {:ok, prompt} <- prompt(scope, params),
         {:ok, model} <- Workers.model(scope, job),
         [_ | _] = messages <- Scene.listed(scope, chat, params["start"], params["end"], params["message_ids"] || []),
         {:ok, clips} <- clips(params) do
      memory_map = Anchors.build(:memory_assistance, messages: messages, clips: clip_maps(params["pass"], clips))
      {:ok, Request.input(scope, chat, prompt, model, profile, memory_map), prompt.name}
    else
      [] -> {:error, :empty_scene}
      error -> error
    end
  end

  @impl true
  def retry_params(%Scope{}, %Job{params: %{"fingerprints" => %{}, "clip_ids" => ids}}) when is_list(ids),
    do: %{"fingerprints" => Workers.fingerprints(ids)}

  def retry_params(%Scope{}, %Job{}), do: %{}

  defp prompt(scope, %{"pass" => "suggest", "prompt_id" => id}), do: Clips.clip_suggestions_prompt(scope, id)
  defp prompt(scope, %{"prompt_id" => id}), do: Clips.clip_review_prompt(scope, id)

  defp clips(params) do
    clips = Workers.records(params["clip_ids"] || [])
    if Enum.any?(clips, &(is_nil(&1) or is_nil(&1.entry))), do: {:error, :source_missing}, else: {:ok, clips}
  end

  defp clip_maps("suggest", clips), do: Enum.map(clips, &Map.take(clip_map(&1), ["title", "topic", "keywords"]))

  defp clip_maps(_review, clips) do
    for {record, n} <- Enum.with_index(clips, 1) do
      Map.merge(clip_map(record), %{
        "uid" => String.pad_leading(Integer.to_string(n), 3, "0"),
        "type" => type(record),
        "content" => record.entry.content
      })
    end
  end

  defp clip_map(record) do
    %{
      "title" => record.entry.name,
      "topic" => (record.snapshot || %{})["topic"] || "",
      "keywords" => Enum.join(record.entry.keywords || [], ", ")
    }
  end

  defp type(%Record{kind: :topical_clip}), do: "topical"
  defp type(%Record{}), do: "ordinary"

  @impl true
  def finish(%Job{} = job, completion, retried?) do
    with %Scope{} = scope <- Workers.initiator(job) do
      case JSON.decode(completion.text) do
        {:ok, map} -> with {:ok, result} <- result(scope, job, map), do: outcome(scope, job, result)
        {:error, _} -> Workers.repair(__MODULE__, job, retried?)
      end
    end
  end

  defp result(_scope, %Job{params: %{"pass" => "suggest"} = params}, map) do
    existing =
      (params["clip_ids"] || [])
      |> Workers.records()
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&[(&1.snapshot || %{})["topic"], &1.entry && &1.entry.name])
      |> Enum.filter(&is_binary/1)

    with {:ok, topics} <- JSON.clip_suggestions(map, existing),
         do: {:ok, %{"candidates" => [], "topics" => topics}}
  end

  defp result(scope, %Job{params: params}, map) do
    with {:ok, review} <- JSON.clip_review(map),
         %Chat{} = chat <- Chats.get_chat(params["chat_id"]) || {:error, :no_chat} do
      ids = params["clip_ids"] || []
      clips = Workers.records(ids)
      messages = Scene.listed(scope, chat, params["start"], params["end"], params["message_ids"] || [])
      scene = Enum.map(messages, &{collapse(Scene.content(&1)), &1.position + 1})

      candidates =
        review
        |> Enum.flat_map(fn {uid, text} ->
          text = String.trim(text)

          case Workers.nth(clips, uid) do
            nil -> []
            _record when text == "" -> []
            record -> candidate(record, text, scene)
          end
        end)
        |> Enum.sort_by(&Enum.find_index(ids, fn id -> id == &1["record_id"] end))

      if map_size(review) > 0 and candidates == [],
        do: {:error, :invalid},
        else: {:ok, %{"candidates" => candidates, "topics" => []}}
    end
  end

  defp candidate(%Record{kind: :topical_clip} = record, text, _scene),
    do: [
      %{
        "record_id" => record.id,
        "type" => "topical",
        "title" => record.entry.name,
        "text" => text,
        "message_number" => nil
      }
    ]

  defp candidate(record, text, scene) do
    needle = collapse(text)

    case Enum.find(scene, fn {content, _n} -> String.contains?(content, needle) end) do
      nil ->
        []

      {_content, n} ->
        [
          %{
            "record_id" => record.id,
            "type" => "ordinary",
            "title" => record.entry.name,
            "text" => text,
            "message_number" => n
          }
        ]
    end
  end

  defp collapse(text), do: text |> String.split() |> Enum.join(" ")

  defp outcome(_scope, _job, %{"candidates" => [], "topics" => []} = result), do: {:ok, :completed, result}

  defp outcome(scope, %Job{params: %{"mode" => "automatic", "pass" => "review"}} = job, result) do
    {ordinary, topical} = Enum.split_with(result["candidates"], &(&1["type"] == "ordinary"))

    if topical == [] do
      with {:ok, n} <- Clips.save_assistance(scope, job, ordinary), do: {:ok, :completed, %{"applied" => n}}
    else
      with {:ok, n} <- Clips.apply_clip_additions(scope, job, ordinary),
           do: {:ok, :review, result |> Map.put("candidates", topical) |> Map.put("applied", n)}
    end
  end

  defp outcome(_scope, _job, result), do: {:ok, :review, result}
end
