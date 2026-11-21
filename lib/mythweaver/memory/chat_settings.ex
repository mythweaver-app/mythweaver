defmodule Mythweaver.Memory.ChatSettings do
  @moduledoc """
  One chat's memory settings: its memory book and profile, automatic-memory triggers, auto-hide, and
  the ordered Additional Context entries fed into every memory prompt.

  `memory_book_id` nil means no book yet (one is created on the first save); `profile_id` nil means
  the default profile. `highest_processed` is the `Messages.Message.position` of the last message a
  memory covers, nil when nothing is processed; it is not castable (only `Mythweaver.Memory` sets it).

  `auto_trigger`, `auto_interval`, `auto_buffer` and `auto_token_threshold` nil follow the
  `memory.auto_*` settings; `Mythweaver.Memory.auto_settings/2` resolves the values in effect.

  `context_entry_ids` holds lore entry ids in order. An array cannot carry a foreign key, so a deleted
  entry's id lingers until the settings are next saved, and readers skip ids that no longer exist.

  `side_prompt_book_ids` maps a side prompt id to the book its new entries go to in this chat. Like
  `context_entry_ids` it has no foreign key, so readers skip a book that is gone.

  `character_book_ids` maps a non-player character id to this chat's character memory book for it:
  the book that receives that character's copies of new memories, unless the character is locked to
  a book (`Mythweaver.Memory.CharacterBook`). `cast_ids` lists characters present in every scene
  (silent witnesses) besides those who speak. Neither has a foreign key.

  `side_prompt_set_mode` picks what runs automatically: `:default` follows the
  `memory.side_prompt_set_solo`/`_group` setting, `:individual` the enabled side prompts, `:set`
  the rows of `side_prompt_set_id` (required then).
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.SidePromptSet

  @type t :: %__MODULE__{}

  schema "chat_memory_settings" do
    field :highest_processed, :integer
    field :auto_enabled, :boolean, default: false
    field :auto_trigger, Ecto.Enum, values: [:messages, :tokens]
    field :auto_interval, :integer
    field :auto_buffer, :integer
    field :auto_token_threshold, :integer
    field :auto_hide, Ecto.Enum, values: [:none, :all, :last], default: :none
    field :leave_unhidden, :integer, default: 2
    field :context_entry_ids, {:array, Ecto.UUID}, default: []
    field :side_prompt_book_ids, :map, default: %{}
    field :character_book_ids, :map, default: %{}
    field :cast_ids, {:array, Ecto.UUID}, default: []
    # Memory reminder state (`Mythweaver.Memory.Reminders`): `signature`, `notified_at`. Not cast.
    field :reminder, :map, default: %{}
    field :side_prompt_set_mode, Ecto.Enum, values: [:default, :individual, :set], default: :default

    belongs_to :chat, Chat
    belongs_to :memory_book, LoreBook
    belongs_to :profile, Profile
    belongs_to :side_prompt_set, SidePromptSet

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :memory_book_id,
      :profile_id,
      :auto_enabled,
      :auto_trigger,
      :auto_interval,
      :auto_buffer,
      :auto_token_threshold,
      :auto_hide,
      :leave_unhidden,
      :context_entry_ids,
      :side_prompt_book_ids,
      :character_book_ids,
      :cast_ids,
      :side_prompt_set_mode,
      :side_prompt_set_id
    ])
    |> validate_required([:auto_hide, :leave_unhidden, :side_prompt_set_mode])
    |> validate_set()
    |> validate_number(:auto_interval, greater_than_or_equal_to: 5, less_than_or_equal_to: 250)
    |> validate_number(:auto_buffer, greater_than_or_equal_to: 0, less_than_or_equal_to: 50)
    |> validate_number(:auto_token_threshold, greater_than: 0)
    |> validate_number(:leave_unhidden, greater_than_or_equal_to: 0, less_than_or_equal_to: 50)
    |> assoc_constraint(:memory_book)
    |> assoc_constraint(:profile)
    |> assoc_constraint(:side_prompt_set)
    |> validate_id_map(:side_prompt_book_ids, dgettext_noop("errors", "must map side prompts to books"))
    |> validate_id_map(:character_book_ids, dgettext_noop("errors", "must map characters to books"))
  end

  # A map of id to book id: every key and value a UUID.
  defp validate_id_map(changeset, field, message) do
    validate_change(changeset, field, fn ^field, ids ->
      if Enum.all?(ids, fn {id, book_id} -> uuid?(id) and uuid?(book_id) end), do: [], else: [{field, message}]
    end)
  end

  defp validate_set(changeset) do
    if get_field(changeset, :side_prompt_set_mode) == :set,
      do: validate_required(changeset, [:side_prompt_set_id], message: dgettext_noop("errors", "pick a set")),
      else: changeset
  end

  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
end
