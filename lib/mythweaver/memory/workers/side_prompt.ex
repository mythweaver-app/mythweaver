defmodule Mythweaver.Memory.Workers.SidePrompt do
  @moduledoc """
  The `:side_prompt` job: runs one side prompt over a range of messages and writes (or, in review,
  drafts) its tracker entry through `Mythweaver.Memory.SidePrompts.save_side_prompt/3`.

  Params (string keys): `chat_id`, `side_prompt_id`, `profile_id`, `prompt_id`, `start`, `end`
  (positions), `trigger`, `message_ids` (read exactly these, hidden or not), `review`, and for a
  regeneration `record_id` with `written_fingerprint` (the record as it was when queued; a retry,
  `retry_params/2`, re-reads it). A set row's
  run adds `set_row_id`, `row_label` and `macros` (runtime macro values, Liquid variables in the
  prompt); a manual run may carry `macros` alone.

  The model sees the side prompt's current entry (`entry`), up to `previous_memories` earlier
  memories, the Additional Context when `use_context`, and the scene.
  """

  @behaviour Mythweaver.Jobs.Worker

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Anchors
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Request
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePrompts
  alias Mythweaver.Memory.Workers
  alias Mythweaver.Repo

  @impl true
  def build(%Job{params: params} = job) do
    with %Scope{} = scope <- Workers.initiator(job),
         %Chat{} = chat <- Chats.get_chat(params["chat_id"]) || {:error, :no_chat},
         %SidePrompt{} = side_prompt <-
           Memory.get_side_prompt(scope, params["side_prompt_id"]) || {:error, :source_missing},
         %Profile{} = profile <- Memory.get_profile(scope, params["profile_id"]) || {:error, :no_profile},
         {:ok, prompt} <- SidePrompts.side_prompt_prompt(scope, side_prompt),
         {:ok, model} <- Workers.model(scope, job),
         [first | _] = messages <- scene(scope, chat, params) do
      memory_map =
        Anchors.build(:side_prompt,
          messages: messages,
          speakers: Scene.speaker_names(chat, messages),
          entry: entry(scope, chat, side_prompt, params),
          previous: Workers.Scene.previous_memories(scope, chat, first.position, side_prompt.previous_memories),
          context: if(side_prompt.use_context, do: Workers.Scene.context_entries(scope, chat), else: [])
        )

      {:ok, Request.input(scope, chat, prompt, model, profile, memory_map, macros: params["macros"] || %{}),
       prompt.name}
    else
      [] -> {:error, :empty_scene}
      error -> error
    end
  end

  # The record as the side prompt last wrote it. An entry edited by hand since is still refused at
  # save: its content no longer matches what was written.
  @impl true
  def retry_params(%Scope{}, %Job{params: %{"record_id" => id}}) when is_binary(id) do
    case Repo.get(Record, id) do
      %Record{written_fingerprint: written} -> %{"written_fingerprint" => written}
      nil -> %{}
    end
  end

  def retry_params(%Scope{}, %Job{}), do: %{}

  defp scene(scope, chat, %{"message_ids" => ids} = params) when is_list(ids),
    do: Scene.listed(scope, chat, params["start"], params["end"], ids)

  defp scene(scope, chat, params),
    do: Scene.messages(scope, chat, params["start"], params["end"], Memory.preferences(scope))

  # The entry this run rewrites: the regenerated record's, else the side prompt's latest in the chat.
  defp entry(scope, chat, side_prompt, params) do
    record =
      case params["record_id"] do
        id when is_binary(id) -> Memory.get_record(scope, id)
        _new -> SidePrompts.target_record(chat.id, side_prompt.id, params["set_row_id"])
      end

    case record do
      %Record{entry: entry} -> Workers.entry_map(entry, "side_prompt")
      nil -> nil
    end
  end

  @impl true
  def finish(%Job{} = job, completion, _retried?) do
    with %Scope{} = scope <- Workers.initiator(job),
         {:ok, text} <- Workers.text(completion) do
      if job.params["review"] do
        {:ok, :review, %{"content" => text}}
      else
        with {:ok, record} <- SidePrompts.save_side_prompt(scope, job, text),
             do: {:ok, :completed, %{"record_id" => record.id}}
      end
    end
  end
end
