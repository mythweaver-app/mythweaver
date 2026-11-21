defmodule Mythweaver.Memory.Workers do
  @moduledoc """
  Helpers shared by the memory job workers (`Mythweaver.Memory.Workers.*`): what every build loads,
  reading plain-text and JSON replies, and the maps the anchors take.
  """

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Request
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Repo

  # Shared by every JSON memory job; the reply may be valid JSON in the wrong shape (a field written
  # as prose after the object), so the nudge names the shape, not only the syntax.
  @repair "Your previous reply was not valid JSON in the required format. Reply with only the JSON object described above, with every required field inside it."

  @doc """
  The scope the job acts as (`Jobs.run_scope/1`: a chat job's chat owner, whoever started it), or
  `{:error, :no_initiator}`.
  """
  @spec initiator(Job.t()) :: Scope.t() | {:error, :no_initiator}
  def initiator(%Job{} = job), do: Jobs.run_scope(job) || {:error, :no_initiator}

  @doc "The job's initiator scope, chat and profile (`chat_id`, `profile_id`), or the first one missing."
  @spec context(Job.t()) :: {:ok, Scope.t(), Chat.t(), Profile.t()} | {:error, :no_initiator | :no_chat | :no_profile}
  def context(%Job{params: params} = job) do
    with %Scope{} = scope <- initiator(job),
         %Chat{} = chat <- Chats.get_chat(params["chat_id"]) || {:error, :no_chat},
         %Profile{} = profile <- Memory.get_profile(scope, params["profile_id"]) || {:error, :no_profile},
         do: {:ok, scope, chat, profile}
  end

  @doc "The job's model, when `scope` may run it; else `{:error, :no_model}`."
  @spec model(Scope.t(), Job.t()) :: {:ok, Model.t()} | {:error, :no_model}
  def model(%Scope{} = scope, %Job{ai_model_id: id}) do
    case id && AI.get_model(scope, id) do
      %Model{} = model -> {:ok, model}
      _none -> {:error, :no_model}
    end
  end

  @doc "A plain-text reply, trimmed; `{:error, :empty}` when blank."
  @spec text(%{text: String.t() | nil}) :: {:ok, String.t()} | {:error, :empty}
  def text(%{text: text}) do
    case String.trim(text || "") do
      "" -> {:error, :empty}
      text -> {:ok, text}
    end
  end

  @doc """
  The answer to a JSON reply that does not parse or fit its contract: `{:error, :unparseable}` after
  the one repair retry, else `{:retry, input}` with `worker`'s request rebuilt and the
  not-valid-JSON nudge appended.
  """
  @spec repair(module(), Job.t(), boolean()) :: {:retry, term()} | {:error, term()}
  def repair(_worker, %Job{}, true), do: {:error, :unparseable}

  def repair(worker, %Job{} = job, false) do
    with {:ok, input, _prompt_name} <- worker.build(job), do: {:retry, Request.append_user(input, @repair)}
  end

  @doc "The records `ids` with entries, in that order; nil in place of each one gone."
  @spec records([Ecto.UUID.t()]) :: [Record.t() | nil]
  def records(ids) do
    by_id = Map.new(Repo.all(from(r in Record, where: r.id in ^ids, preload: :entry)), &{&1.id, &1})
    Enum.map(ids, &by_id[&1])
  end

  @doc ~S|The item of `list` that a model's `label` names, counting from 1: "001", "1" and "[001]" all name the first.|
  @spec nth(list(), term()) :: term() | nil
  def nth(list, label) do
    case Integer.parse(Regex.replace(~r/[^0-9]/, to_string(label), "")) do
      {n, ""} when n >= 1 -> Enum.at(list, n - 1)
      _other -> nil
    end
  end

  @doc ~s|Records (entries preloaded) as `%{"title", "content"}` source maps.|
  @spec source_maps([Record.t()]) :: [map()]
  def source_maps(records), do: Enum.map(records, &%{"title" => &1.entry.name, "content" => &1.entry.content})

  @doc "An entry as the `entry` anchor map, with its record `kind`."
  @spec entry_map(LoreEntry.t(), String.t()) :: map()
  def entry_map(entry, kind), do: %{"title" => entry.name, "content" => entry.content, "kind" => kind}

  @doc """
  `entry`'s `entry_updated_at` and `entry_fingerprint` as it is now: the pair a save checks a target
  entry against, re-read when a job is retried (`Mythweaver.Jobs.Worker.retry_params/3`).
  """
  @spec entry_version(LoreEntry.t()) :: %{String.t() => String.t()}
  def entry_version(%LoreEntry{} = entry),
    do: %{
      "entry_updated_at" => DateTime.to_iso8601(entry.updated_at),
      "entry_fingerprint" => Scene.sha256(entry.content)
    }

  @doc "Record `id`'s `entry_version/1`; `%{}` when the record or its entry is gone."
  @spec record_entry_version(Ecto.UUID.t()) :: map()
  def record_entry_version(id) do
    case records([id]) do
      [%Record{entry: %LoreEntry{} = entry}] -> entry_version(entry)
      _gone -> %{}
    end
  end

  @doc "Each record's entry digest (`Scene.sha256/1` of its content) as it is now, by id; gone ones left out."
  @spec fingerprints([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => String.t()}
  def fingerprints(ids),
    do:
      for(%Record{entry: %LoreEntry{} = entry} = r <- records(ids), into: %{}, do: {r.id, Scene.sha256(entry.content)})

  @doc "Each record's entry `updated_at` (ISO 8601) as it is now, by id; gone ones left out."
  @spec versions([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => String.t()}
  def versions(ids),
    do:
      for(
        %Record{entry: %LoreEntry{} = entry} = r <- records(ids),
        into: %{},
        do: {r.id, DateTime.to_iso8601(entry.updated_at)}
      )

  @doc "The names of the chat's non-player characters."
  @spec character_names(Chat.t()) :: [String.t()]
  def character_names(%Chat{} = chat),
    do: chat |> Chat.bots() |> Enum.map(&(&1.character && &1.character.name)) |> Enum.reject(&is_nil/1)
end
