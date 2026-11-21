defmodule Mythweaver.Bundle.Codec do
  @moduledoc """
  Scalar payloads for bundle items.

  `dump/3` turns a row into the JSON-safe `data` map for its kind (scalar
  fields only; link fields are added by the exporter), and `attrs/2` turns a
  `data` map back into string-keyed attrs for the context create/update
  functions. Unknown keys are ignored so newer bundles still import.
  """

  alias Mythweaver.AI.Model
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePromptSet
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Outlet
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Scripts.Script

  @schemas %{
    character: Character,
    lore_book: LoreBook,
    lore_entry: LoreEntry,
    lore_pool: LorePool,
    prompt_outlet: Outlet,
    prompt: Prompt,
    prompt_block: Block,
    ai_model: Model,
    script: Script,
    memory_profile: Profile,
    side_prompt: SidePrompt,
    side_prompt_set: SidePromptSet,
    chat: Chat
  }

  @fields %{
    character: [
      :name,
      :description,
      :creator,
      :creator_notes,
      :character_version,
      :pronouns,
      :appearance,
      :avatar_updates_appearance,
      :talkativeness,
      :site_visibility,
      :first_message,
      :alternate_greetings,
      :group_greetings,
      :system_prompt,
      :post_history_instructions,
      :card_prompt_mode,
      :source_file,
      :foreign
    ],
    lore_book: [
      :name,
      :description,
      :global,
      :priority,
      :order_adjustment,
      :token_budget,
      :scan_depth,
      :recursive,
      :site_visibility,
      :forced,
      :tag_filter_mode,
      :kind,
      :foreign
    ],
    lore_entry: [
      :name,
      :content,
      :activation,
      :keywords,
      :secondary_keywords,
      :secondary_logic,
      :case_sensitive,
      :match_whole_words,
      :scan_depth,
      :outlet,
      :placement,
      :custom_outlet,
      :depth,
      :probability,
      :sticky,
      :cooldown,
      :delay,
      :exclude_recursion,
      :prevent_recursion,
      :character_filter_mode,
      :ignore_budget,
      :role,
      :trigger_only,
      :delay_until_recursion,
      :foreign
    ],
    lore_pool: [:name, :description, :max_activations],
    prompt_outlet: [:key, :name, :description],
    prompt: [:name, :description, :enabled, :purpose, :thinking, :site_visibility],
    prompt_block: [
      :name,
      :description,
      :role,
      :kind,
      :content,
      :enabled,
      :speaker_roles,
      :site_visibility,
      :role_tag,
      :forbid_overrides
    ],
    ai_model: [
      :name,
      :api_model_id,
      :completion_mode,
      :context_window,
      :supports_images,
      :supports_files,
      :supports_audio,
      :supports_video,
      :supports_tools,
      :supports_thinking,
      :continue_prefill,
      :reasoning_prefix,
      :reasoning_suffix,
      :prompt_cost_per_mtok,
      :completion_cost_per_mtok,
      :notes,
      :extra_body,
      :tokenizer,
      :caption_max_tokens,
      :inline_image_limit,
      :inline_audio_limit,
      :inline_video_limit,
      :inline_document_limit,
      :image_detail,
      :chat_first_token_seconds,
      :chat_stall_seconds,
      :chat_deadline_seconds,
      :background_first_token_seconds,
      :background_stall_seconds,
      :background_deadline_seconds
    ],
    script: [:name, :description, :priority, :trigger, :body, :enabled, :site_visibility],
    memory_profile: [
      :name,
      :temperature,
      :max_tokens,
      :structured_output,
      :title_format,
      :consolidation_title_format,
      :activation,
      :outlet,
      :placement,
      :custom_outlet,
      :depth,
      :order_mode,
      :order,
      :prevent_recursion,
      :exclude_recursion,
      :character_aware
    ],
    side_prompt: [
      :name,
      :enabled,
      :run_after_memory,
      :run_on_interval,
      :interval,
      :previous_memories,
      :use_context,
      :title,
      :keywords,
      :activation,
      :outlet,
      :placement,
      :custom_outlet,
      :depth,
      :order,
      :prevent_recursion,
      :exclude_recursion,
      :ignore_budget,
      :save_versions,
      :macros
    ],
    side_prompt_set: [:name],
    chat: [:name, :reply_strategy, :allow_self_responses, :max_turns, :auto_mode_delay, :group_cards]
  }

  @doc "Every kind with a payload."
  @spec kinds() :: [atom()]
  def kinds, do: Map.keys(@fields)

  @doc "The Ecto schema module for `kind`."
  @spec schema(atom()) :: module()
  def schema(kind), do: Map.fetch!(@schemas, kind)

  @doc "The scalar fields copied for `kind`."
  @spec fields(atom()) :: [atom()]
  def fields(kind), do: Map.fetch!(@fields, kind)

  @doc "The JSON-safe scalar payload of `row`. `ctx` is reserved for callers."
  @spec dump(atom(), struct(), map()) :: map()
  def dump(kind, row, _ctx \\ %{}) do
    Map.new(fields(kind), &{Atom.to_string(&1), value(Map.get(row, &1))})
  end

  @doc "String-keyed attrs from `data`, keeping only `fields(kind)` keys present."
  @spec attrs(atom(), map()) :: map()
  def attrs(kind, data) when is_map(data) do
    kind
    |> fields()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.filter(&Map.has_key?(data, &1))
    |> Map.new(&{&1, Map.fetch!(data, &1)})
  end

  @doc "The sampler as a map of its non-nil fields, or nil."
  @spec sampler(SamplerParams.t() | nil) :: map() | nil
  def sampler(nil), do: nil

  def sampler(%SamplerParams{} = params) do
    for field <- SamplerParams.__schema__(:fields),
        v = Map.get(params, field),
        not is_nil(v),
        into: %{},
        do: {Atom.to_string(field), value(v)}
  end

  @doc "Converts a value to its JSON-safe form."
  @spec value(term()) :: term()
  def value(v) when v in [nil, true, false], do: v
  def value(v) when is_atom(v), do: Atom.to_string(v)
  def value(%Decimal{} = v), do: Decimal.to_string(v)
  def value(%DateTime{} = v), do: DateTime.to_iso8601(v)
  def value(%NaiveDateTime{} = v), do: NaiveDateTime.to_iso8601(v)
  def value(%Date{} = v), do: Date.to_iso8601(v)
  def value(%SamplerParams{} = v), do: sampler(v)
  def value(v) when is_list(v), do: Enum.map(v, &value/1)
  def value(v) when is_struct(v), do: v
  def value(v) when is_map(v), do: Map.new(v, fn {k, x} -> {key(k), value(x)} end)
  def value(v), do: v

  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: k
end
