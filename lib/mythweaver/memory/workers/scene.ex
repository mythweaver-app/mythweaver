defmodule Mythweaver.Memory.Workers.Scene do
  @moduledoc """
  The `:memory` job: summarizes one scene into a memory entry.

  Params (string keys): `chat_id`, `start`, `end` (positions), `profile_id`, `previous_count`,
  `review`, `skip_side_prompts`, `scene_fingerprint`, `participant_ids` (character ids that replace
  detected speakers), and `record_id`/`entry_updated_at` when regenerating, `batch_id` for catch-up.
  A retry (`retry_params/2`) re-reads `scene_fingerprint` and `entry_updated_at` from the chat as it
  is then.

  A character's perspective copy (`Mythweaver.Memory.save_scene/3`) also has `message_ids` (the
  chat's memory's messages) and `copy` (`canonical_id`, `book_id`, `character_ids`, and `record_id`
  when it refreshes an existing copy after a regeneration): it summarizes exactly those messages
  with the profile's character memory prompt, for those characters, reading previous memories from
  the character book.
  """

  @behaviour Mythweaver.Jobs.Worker

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Anchors
  alias Mythweaver.Memory.JSON
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Request
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.Workers
  alias Mythweaver.Ownership
  alias Mythweaver.Repo
  alias Mythweaver.Sharing.Visibility

  @impl true
  def build(%Job{params: params} = job) do
    with {:ok, scope, chat, profile} <- Workers.context(job),
         {:ok, model} <- Workers.model(scope, job),
         [_ | _] = messages <- scene(scope, chat, params),
         {:ok, prompt} <- prompt(scope, chat, profile, messages, params) do
      opts = [previous_count: params["previous_count"] || 0, participant_ids: params["participant_ids"]]
      {:ok, input(scope, chat, profile, prompt, model, messages, opts ++ copy_opts(chat, params)), prompt.name}
    else
      [] -> {:error, :empty_scene}
      error -> error
    end
  end

  # A retry summarizes the scene as it is now, so the save checks against that, and a regeneration
  # rewrites the entry as it is now. Re-read as the retrying user, whom the retried job runs as. A
  # job whose chat is gone keeps its params; its build then fails on the missing chat.
  @impl true
  def retry_params(%Scope{} = scope, %Job{params: %{"chat_id" => chat_id} = params}) when is_binary(chat_id) do
    case Chats.get_chat(chat_id) do
      %Chat{} = chat ->
        %{"scene_fingerprint" => Scene.fingerprint(scene(scope, chat, params))}
        |> Map.merge(entry_version(params))

      nil ->
        %{}
    end
  end

  def retry_params(%Scope{}, %Job{}), do: %{}

  defp entry_version(%{"record_id" => id}) when is_binary(id) do
    case Repo.one(from(r in Record, where: r.id == ^id, preload: :entry)) do
      %Record{entry: %LoreEntry{updated_at: at}} -> %{"entry_updated_at" => DateTime.to_iso8601(at)}
      _gone -> %{}
    end
  end

  defp entry_version(_params), do: %{}

  defp scene(scope, chat, %{"copy" => %{}} = params),
    do: Scene.listed(scope, chat, params["start"], params["end"], params["message_ids"] || [])

  defp scene(scope, chat, params),
    do: Scene.messages(scope, chat, params["start"], params["end"], Memory.preferences(scope))

  defp prompt(scope, _chat, profile, _messages, %{"copy" => %{}}), do: Memory.character_memory_prompt(scope, profile)

  defp prompt(scope, chat, profile, messages, params),
    do: Memory.memory_prompt(scope, profile, length(Scene.speakers(chat, messages, params["participant_ids"])))

  defp copy_opts(chat, %{"copy" => %{} = copy}) do
    names = copy["character_ids"] |> Enum.map(&Chat.participant_name(chat, &1)) |> Enum.reject(&is_nil/1)
    [character: Enum.join(names, ", "), book_id: copy["book_id"]]
  end

  defp copy_opts(_chat, _params), do: []

  @doc """
  The rendered memory request for `messages`: the scene, the `:previous_count` (default 0) tier-0
  memories before it, and the chat's Additional Context entries. Other `opts`: `:participant_ids`,
  when a list, replaces the detected speakers (`Scene.speakers/3`); `:character`
  (`anchors.memory.character`, a character copy's names); and `:book_id` (the book previous memories
  come from, instead of the chat's).
  """
  def input(%Scope{} = scope, %Chat{} = chat, profile, prompt, model, [first | _] = messages, opts \\ []) do
    participant_ids = opts[:participant_ids]

    memory_map =
      Anchors.build(:memory,
        messages: messages,
        speakers: Scene.speaker_names(chat, messages, participant_ids),
        previous: previous_memories(scope, chat, first.position, opts[:previous_count] || 0, opts[:book_id]),
        context: context_entries(scope, chat),
        character: opts[:character]
      )

    Request.input(scope, chat, prompt, model, profile, memory_map)
  end

  @doc """
  The last `count` tier-0 memories of the chat's book (or of `book_id`) that end before position
  `start`, oldest first, as `%{"title", "content"}` maps. Shared copies
  (`Record.without_shared_copies/1`) are skipped.
  """
  def previous_memories(scope, chat, start, count, book_id \\ nil)

  def previous_memories(%Scope{}, _chat, _start, count, _book_id) when count <= 0, do: []

  def previous_memories(%Scope{} = scope, chat, start, count, book_id) do
    case book_id || Memory.chat_settings(scope, chat).memory_book_id do
      nil ->
        []

      book_id ->
        from(r in Record,
          join: e in assoc(r, :entry),
          where: r.lore_book_id == ^book_id and r.kind == :memory and r.range_end < ^start,
          order_by: [desc: r.range_end],
          limit: ^count,
          select: %{"title" => e.name, "content" => e.content}
        )
        |> Record.without_shared_copies()
        |> Repo.all()
        |> Enum.reverse()
    end
  end

  @doc """
  The chat's Additional Context entries in the settings' order; ids of deleted entries, and of entries
  `scope` may no longer use or read, are skipped.
  """
  def context_entries(%Scope{} = scope, chat) do
    ids = Memory.chat_settings(scope, chat).context_entry_ids
    query = from(e in LoreEntry, where: e.id in ^ids) |> Ownership.usable(scope) |> Visibility.readable_entries(scope)
    entries = Map.new(Repo.all(query), &{&1.id, &1})
    ids |> Enum.map(&entries[&1]) |> Enum.reject(&is_nil/1)
  end

  @impl true
  def finish(%Job{} = job, completion, retried?) do
    with %Scope{} = scope <- Workers.initiator(job),
         {:ok, map} <- JSON.decode(completion.text),
         {:ok, draft} <- JSON.memory(map) do
      if job.params["review"] do
        {:ok, :review, draft}
      else
        with {:ok, record} <- Memory.save_scene(scope, job, draft), do: {:ok, :completed, %{"record_id" => record.id}}
      end
    else
      {:error, :no_initiator} = error -> error
      _invalid -> Workers.repair(__MODULE__, job, retried?)
    end
  end

  # Catch-up stops at its first failure: the rest of the batch is canceled. A person canceling one
  # job is not a failure, and leaves the rest of the batch alone.
  @impl true
  def failed(%Job{status: :canceled}), do: :ok

  def failed(%Job{params: %{"batch_id" => batch_id}} = job) when is_binary(batch_id) do
    case Jobs.initiator_scope(job) do
      nil ->
        :ok

      scope ->
        from(j in Job,
          where: j.chat_id == ^job.chat_id and j.status == :queued and j.id != ^job.id,
          where: fragment("?->>'batch_id' = ?", j.params, ^batch_id),
          select: j.id
        )
        |> Repo.all()
        |> Enum.each(&Jobs.cancel(scope, &1))
    end
  end

  def failed(_job), do: :ok
end
