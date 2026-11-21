defmodule Mythweaver.Tags.Tagging do
  @moduledoc """
  One hard tag on one item. Exactly one target column is set (`taggings_one_target`).

  The tag row's domain decides who sees the tagging: a site tag on a site item is everyone's; a
  user's own tag is only theirs, on any item they can see. Parents are never stored here.
  """

  use Mythweaver.Schema

  alias Mythweaver.AI
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Tags.Tag

  @kinds [
    character: {Character, :character_id},
    chat: {Chat, :chat_id},
    lore_entry: {LoreEntry, :lore_entry_id},
    lore_book: {LoreBook, :lore_book_id},
    prompt: {Prompt, :prompt_id},
    prompt_block: {Block, :prompt_block_id},
    script: {Script, :script_id},
    ai_model: {AI.Model, :ai_model_id}
  ]

  @type kind :: :character | :chat | :lore_entry | :lore_book | :prompt | :prompt_block | :script | :ai_model

  schema "taggings" do
    belongs_to :tag, Tag
    belongs_to :character, Character
    belongs_to :chat, Chat
    belongs_to :lore_entry, LoreEntry
    belongs_to :lore_book, LoreBook
    belongs_to :prompt, Prompt
    belongs_to :prompt_block, Block
    belongs_to :script, Script
    belongs_to :ai_model, AI.Model

    timestamps(type: :utc_datetime)
  end

  @doc "Every taggable kind."
  @spec kinds() :: [kind()]
  def kinds, do: Keyword.keys(@kinds)

  @doc "The kind of a taggable struct."
  @spec kind_of(struct()) :: kind()
  for {kind, {schema, _column}} <- @kinds do
    def kind_of(%unquote(schema){}), do: unquote(kind)
  end

  @doc "The target column of `kind`."
  @spec column(kind()) :: atom()
  for {kind, {_schema, column}} <- @kinds do
    def column(unquote(kind)), do: unquote(column)
  end

  @doc "The schema of `kind`."
  @spec schema(kind()) :: module()
  for {kind, {schema, _column}} <- @kinds do
    def schema(unquote(kind)), do: unquote(schema)
  end
end
