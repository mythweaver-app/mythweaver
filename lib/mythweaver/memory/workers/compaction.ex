defmodule Mythweaver.Memory.Workers.Compaction do
  @moduledoc """
  The `:compaction` job: rewrites one entry more token-efficiently.

  A memory record's compaction is always reviewed; `Mythweaver.Memory.approve/3` replaces the
  entry's content. Params (string keys): `chat_id`, `profile_id`, `prompt_id`, `record_id`, and
  `entry_updated_at` and `entry_fingerprint` (the entry as it was when queued; a retry,
  `retry_params/2`, re-reads them).

  The lore entry editor's (`Mythweaver.Memory.compact_text/2`) has no chat or record and completes
  unreviewed with `%{"content" => text}`, saving nothing. Params: `profile_id`, `prompt_id`, `title`,
  `content`, `kind`.

  The response limit is sized from the entry, not the profile (`response_limit/3`): a compaction
  comes back no longer than what it compacts, so a model that loops, in its reply or its reasoning,
  is cut off near the entry's own length instead of running to the profile's cap. The backend counts
  reasoning tokens against `max_tokens`, so the limit adds room for reasoning at the request's
  effective thinking level.
  """

  @behaviour Mythweaver.Jobs.Worker

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Anchors
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Request
  alias Mythweaver.Memory.Workers
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Repo
  alias Mythweaver.Tokenizer

  # Room for the rewrite over the entry's own length: formatting, a heading kept, a tokenizer that
  # splits the new wording differently.
  @reply_slack 1.1
  @reply_floor 64

  # Reasoning room per effective level: `{floor tokens, multiple of the entry's tokens}`, the larger
  # of the two. A longer entry takes longer to reason about; a short one still needs some room.
  @reasoning %{
    minimal: {256, 0.25},
    low: {512, 0.5},
    medium: {1024, 1.0},
    high: {2048, 2.0},
    xhigh: {4096, 3.0},
    max: {4096, 4.0}
  }

  # A record's compaction is approved against its entry as the retry finds it; the editor's has no
  # record.
  @impl true
  def retry_params(%Scope{}, %Job{params: %{"record_id" => id}}) when is_binary(id),
    do: Workers.record_entry_version(id)

  def retry_params(%Scope{}, %Job{}), do: %{}

  @impl true
  def build(%Job{params: params} = job) when not is_map_key(params, "record_id") do
    with %Scope{} = scope <- Workers.initiator(job),
         %Profile{} = profile <- Memory.get_profile(scope, params["profile_id"]) || {:error, :no_profile},
         {:ok, prompt} <- Memory.compaction_prompt(scope, params["prompt_id"]),
         {:ok, model} <- Workers.model(scope, job) do
      entry = %{"title" => params["title"], "content" => params["content"], "kind" => params["kind"]}
      memory_map = Anchors.build(:compaction, entry: entry, speakers: [])

      {:ok,
       Request.input(scope, %Chat{participants: [], player_character: nil}, prompt, model, profile, memory_map,
         context: [messages: [], variables: %{chat: %{}, global: %{}}, character: nil],
         max_tokens: response_limit(model, prompt, entry["content"])
       ), prompt.name}
    end
  end

  def build(%Job{params: params} = job) do
    with {:ok, scope, chat, profile} <- Workers.context(job),
         {:ok, prompt} <- Memory.compaction_prompt(scope, params["prompt_id"]),
         {:ok, model} <- Workers.model(scope, job),
         %Record{} = record <-
           (params["record_id"] && Repo.get(Record, params["record_id"])) || {:error, :source_missing} do
      %Record{entry: entry} = record = Repo.preload(record, :entry)

      memory_map =
        Anchors.build(:compaction,
          entry: Workers.entry_map(entry, Atom.to_string(record.kind)),
          speakers: Workers.character_names(chat)
        )

      {:ok,
       Request.input(scope, chat, prompt, model, profile, memory_map,
         max_tokens: response_limit(model, prompt, entry.content)
       ), prompt.name}
    end
  end

  @doc """
  The most tokens a compaction of `content` may generate on `model` with `prompt`: the entry's own
  length with a little slack, plus reasoning room for the effective thinking level
  (`Mythweaver.AI.effective_thinking/2`). Off adds none. Backend default adds medium's room on a
  model that thinks (separate reasoning, or inline reasoning tags), and none on one that does not.
  """
  @spec response_limit(Model.t(), Prompt.t(), String.t() | nil) :: pos_integer()
  def response_limit(%Model{} = model, %Prompt{} = prompt, content) do
    {tokens, _kind} = Tokenizer.count(model, content)
    reply = max(ceil(tokens * @reply_slack), tokens + @reply_floor)
    reply + reasoning_room(reasoning_level(model, AI.effective_thinking(model, prompt.thinking)), tokens)
  end

  defp reasoning_level(model, nil), do: if(thinks?(model), do: :medium, else: :none)
  defp reasoning_level(_model, level), do: level

  defp thinks?(model), do: model.supports_thinking or Model.reasoning_tags(model) != nil

  defp reasoning_room(:none, _tokens), do: 0

  defp reasoning_room(level, tokens) do
    {floor, multiple} = Map.fetch!(@reasoning, level)
    max(floor, ceil(tokens * multiple))
  end

  @impl true
  def finish(%Job{params: params}, completion, _retried?) do
    with {:ok, text} <- Workers.text(completion) do
      if Map.has_key?(params, "record_id"),
        do: {:ok, :review, %{"content" => text}},
        else: {:ok, :completed, %{"content" => text}}
    end
  end
end
