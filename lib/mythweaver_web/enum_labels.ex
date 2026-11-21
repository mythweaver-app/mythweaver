defmodule MythweaverWeb.EnumLabels do
  @moduledoc """
  Display labels for schema fields and their `Ecto.Enum` values, and for the atom reasons a bulk
  action skips a row with (`MythweaverWeb.Bulk`).

  Display text never comes from Phoenix's `humanize/1`: it can't be translated. Each
  (schema, field, value) has its own clause with a literal msgid, so `mix gettext.extract` sees
  every label. There is no catch-all: a value without a clause raises, and
  `test/mythweaver_web/enum_labels_test.exs` checks every value of every `covered/0` field.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Provider
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Outlet
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Scripts.Script

  # A memory profile's and a side prompt's activation, outlet and placement are those of the lore
  # entries they write, with the lore entry's values.
  @lore_entry_copies [Profile, SidePrompt]

  @doc "The `{schema, field}` enum fields `label/3` covers."
  @spec covered() :: [{module(), atom()}]
  def covered,
    do: [
      {LoreEntry, :activation},
      {LoreEntry, :secondary_logic},
      {LoreEntry, :outlet},
      {LoreEntry, :placement},
      {LoreEntry, :character_filter_mode},
      {Profile, :activation},
      {Profile, :outlet},
      {Profile, :placement},
      {SidePrompt, :activation},
      {SidePrompt, :outlet},
      {SidePrompt, :placement},
      {Model, :completion_mode},
      {Model, :image_detail},
      {Chat, :reply_strategy},
      {Chat, :group_cards},
      {Block, :role},
      {Script, :trigger}
    ]

  @doc "Select options for an `Ecto.Enum` field: `{label, value}` in the schema's order."
  @spec values(module(), atom()) :: [{String.t(), atom()}]
  def values(schema, field), do: for(v <- Ecto.Enum.values(schema, field), do: {label(schema, field, v), v})

  @doc "The label of `value` of the `Ecto.Enum` field `field` of `schema`."
  @spec label(module(), atom(), atom()) :: String.t()
  def label(schema, field, value) when schema in @lore_entry_copies and field in [:activation, :outlet, :placement],
    do: label(LoreEntry, field, value)

  def label(LoreEntry, :activation, :keyword), do: pgettext("option: lore entry activation", "Keyword")
  def label(LoreEntry, :activation, :constant), do: pgettext("option: lore entry activation", "Constant")
  def label(LoreEntry, :activation, :vector), do: pgettext("option: lore entry activation", "Vector")

  def label(LoreEntry, :secondary_logic, :and_any), do: pgettext("option: lore entry secondary logic", "And any")
  def label(LoreEntry, :secondary_logic, :and_all), do: pgettext("option: lore entry secondary logic", "And all")
  def label(LoreEntry, :secondary_logic, :not_any), do: pgettext("option: lore entry secondary logic", "Not any")
  def label(LoreEntry, :secondary_logic, :not_all), do: pgettext("option: lore entry secondary logic", "Not all")

  def label(LoreEntry, :outlet, :character), do: pgettext("option: lore entry outlet", "Character")
  def label(LoreEntry, :outlet, :examples), do: pgettext("option: lore entry outlet", "Examples")
  def label(LoreEntry, :outlet, :author_note), do: pgettext("option: lore entry outlet", "Author note")
  def label(LoreEntry, :outlet, :at_depth), do: pgettext("option: lore entry outlet", "At depth")
  def label(LoreEntry, :outlet, :custom), do: pgettext("option: lore entry outlet", "Custom")

  def label(LoreEntry, :placement, :before), do: pgettext("option: lore entry placement", "Before")
  def label(LoreEntry, :placement, :after), do: pgettext("option: lore entry placement", "After")

  def label(LoreEntry, :character_filter_mode, :off), do: pgettext("option: lore entry character filter mode", "Off")

  def label(LoreEntry, :character_filter_mode, :include),
    do: pgettext("option: lore entry character filter mode", "Include")

  def label(LoreEntry, :character_filter_mode, :exclude),
    do: pgettext("option: lore entry character filter mode", "Exclude")

  def label(Model, :completion_mode, :chat), do: pgettext("option: ai model completion mode", "Chat")
  def label(Model, :completion_mode, :text), do: pgettext("option: ai model completion mode", "Text")
  def label(Model, :completion_mode, :embedding), do: pgettext("option: ai model completion mode", "Embedding")
  def label(Model, :completion_mode, :classifier), do: pgettext("option: ai model completion mode", "Classifier")

  def label(Model, :image_detail, :low), do: pgettext("option: ai model image detail", "Low")
  def label(Model, :image_detail, :auto), do: pgettext("option: ai model image detail", "Auto")
  def label(Model, :image_detail, :high), do: pgettext("option: ai model image detail", "High")

  def label(Chat, :reply_strategy, :manual), do: pgettext("option: chat reply strategy", "Manual")
  def label(Chat, :reply_strategy, :natural), do: pgettext("option: chat reply strategy", "Natural")
  def label(Chat, :reply_strategy, :list), do: pgettext("option: chat reply strategy", "List")
  def label(Chat, :reply_strategy, :pooled), do: pgettext("option: chat reply strategy", "Pooled")

  def label(Chat, :group_cards, :swap), do: pgettext("option: chat group cards", "Swap")
  def label(Chat, :group_cards, :join), do: pgettext("option: chat group cards", "Join")
  def label(Chat, :group_cards, :join_all), do: pgettext("option: chat group cards", "Join all")

  def label(Block, :role, :system), do: pgettext("option: prompt block role", "System")
  def label(Block, :role, :user), do: pgettext("option: prompt block role", "User")
  def label(Block, :role, :assistant), do: pgettext("option: prompt block role", "Assistant")

  def label(Script, :trigger, :ai_generation), do: pgettext("option: script trigger", "Ai generation")
  def label(Script, :trigger, :user_message), do: pgettext("option: script trigger", "User message")
  def label(Script, :trigger, :lore_activated), do: pgettext("option: script trigger", "Lore activated")
  def label(Script, :trigger, :image_described), do: pgettext("option: script trigger", "Image described")
  def label(Script, :trigger, :command), do: pgettext("option: script trigger", "Command")
  def label(Script, :trigger, :quick_reply), do: pgettext("option: script trigger", "Quick reply")

  @doc "The label of the field `field` of `schema`: `(Character, :creator_notes)` → \"Creator notes\"."
  @spec field_label(module(), atom()) :: String.t()
  def field_label(LoreEntry, :activation), do: pgettext("field label: lore entry", "Activation")
  def field_label(LoreEntry, :placement), do: pgettext("field label: lore entry", "Placement")
  def field_label(LoreEntry, :secondary_logic), do: pgettext("field label: lore entry", "Secondary logic")
  def field_label(LoreEntry, :character_filter_mode), do: pgettext("field label: lore entry", "Character filter mode")
  def field_label(LoreEntry, :case_sensitive), do: pgettext("field label: lore entry", "Case sensitive")
  def field_label(LoreEntry, :match_whole_words), do: pgettext("field label: lore entry", "Match whole words")
  def field_label(LoreEntry, :exclude_recursion), do: pgettext("field label: lore entry", "Exclude recursion")
  def field_label(LoreEntry, :prevent_recursion), do: pgettext("field label: lore entry", "Prevent recursion")
  def field_label(LoreEntry, :ignore_budget), do: pgettext("field label: lore entry", "Ignore budget")
  def field_label(LoreEntry, :content), do: pgettext("field label: lore entry", "Content")
  def field_label(LoreEntry, :keywords), do: pgettext("field label: lore entry", "Keywords")
  def field_label(LoreEntry, :secondary_keywords), do: pgettext("field label: lore entry", "Secondary keywords")

  def field_label(Character, :creator), do: pgettext("field label: character", "Creator")
  def field_label(Character, :creator_notes), do: pgettext("field label: character", "Creator notes")
  def field_label(Character, :character_version), do: pgettext("field label: character", "Character version")
  def field_label(Character, :pronouns), do: pgettext("field label: character", "Pronouns")
  def field_label(Character, :talkativeness), do: pgettext("field label: character", "Talkativeness")
  def field_label(Character, :description), do: pgettext("field label: character", "Description")
  def field_label(Character, :appearance), do: pgettext("field label: character", "Appearance")

  def field_label(LoreBook, :description), do: pgettext("field label: lore book", "Description")

  def field_label(LorePool, :description), do: pgettext("field label: lore pool", "Description")
  def field_label(LorePool, :max_activations), do: pgettext("field label: lore pool", "Max activations")

  def field_label(Prompt, :description), do: pgettext("field label: prompt", "Description")

  def field_label(Block, :description), do: pgettext("field label: prompt block", "Description")
  def field_label(Block, :role), do: pgettext("field label: prompt block", "Role")
  def field_label(Block, :enabled), do: pgettext("field label: prompt block", "Enabled")
  def field_label(Block, :content), do: pgettext("field label: prompt block", "Content")

  def field_label(Outlet, :key), do: pgettext("field label: prompt outlet", "Key")
  def field_label(Outlet, :description), do: pgettext("field label: prompt outlet", "Description")

  def field_label(Script, :description), do: pgettext("field label: script", "Description")
  def field_label(Script, :trigger), do: pgettext("field label: script", "Trigger")
  def field_label(Script, :body), do: pgettext("field label: script", "Body")

  def field_label(Model, :completion_mode), do: pgettext("field label: ai model", "Completion mode")
  def field_label(Model, :context_window), do: pgettext("field label: ai model", "Context window")
  def field_label(Model, :supports_images), do: pgettext("field label: ai model", "Supports images")
  def field_label(Model, :supports_files), do: pgettext("field label: ai model", "Supports files")
  def field_label(Model, :supports_audio), do: pgettext("field label: ai model", "Supports audio")
  def field_label(Model, :supports_video), do: pgettext("field label: ai model", "Supports video")
  def field_label(Model, :supports_tools), do: pgettext("field label: ai model", "Supports tools")
  def field_label(Model, :supports_thinking), do: pgettext("field label: ai model", "Supports thinking")
  def field_label(Model, :prompt_cost_per_mtok), do: pgettext("field label: ai model", "Prompt cost per mtok")
  def field_label(Model, :completion_cost_per_mtok), do: pgettext("field label: ai model", "Completion cost per mtok")
  def field_label(Model, :api_model_id), do: pgettext("field label: ai model", "Api model")
  def field_label(Model, :sampler), do: pgettext("field label: ai model", "Sampler")
  def field_label(Model, :extra_body), do: pgettext("field label: ai model", "Extra body")
  def field_label(Model, :reasoning_prefix), do: pgettext("field label: ai model", "Reasoning prefix")
  def field_label(Model, :reasoning_suffix), do: pgettext("field label: ai model", "Reasoning suffix")
  def field_label(Model, :tokenizer), do: pgettext("field label: ai model", "Tokenizer")
  def field_label(Model, :notes), do: pgettext("field label: ai model", "Notes")
  def field_label(Model, :chat_first_token_seconds), do: pgettext("field label: ai model", "Chat first token seconds")
  def field_label(Model, :chat_stall_seconds), do: pgettext("field label: ai model", "Chat stall seconds")
  def field_label(Model, :chat_deadline_seconds), do: pgettext("field label: ai model", "Chat deadline seconds")

  def field_label(Model, :background_first_token_seconds),
    do: pgettext("field label: ai model", "Background first token seconds")

  def field_label(Model, :background_stall_seconds), do: pgettext("field label: ai model", "Background stall seconds")

  def field_label(Model, :background_deadline_seconds),
    do: pgettext("field label: ai model", "Background deadline seconds")

  def field_label(Model, :caption_prompt_id), do: pgettext("field label: ai model", "Caption prompt")

  def field_label(Provider, :base_url), do: pgettext("field label: ai provider", "Base url")
  def field_label(Provider, :enabled), do: pgettext("field label: ai provider", "Enabled")
  def field_label(Provider, :priority), do: pgettext("field label: ai provider", "Priority")
  def field_label(Provider, :max_concurrency), do: pgettext("field label: ai provider", "Max concurrency")

  @doc "Why a bulk action skipped a row, for an atom reason its callbacks return."
  @spec skip_reason(atom()) :: String.t()
  def skip_reason(:unauthorized), do: pgettext("status: why a bulk action skipped an item", "Unauthorized")
  def skip_reason(:in_use), do: pgettext("status: why a bulk action skipped an item", "In use")
  def skip_reason(:sudo_required), do: pgettext("status: why a bulk action skipped an item", "Sudo required")
end
