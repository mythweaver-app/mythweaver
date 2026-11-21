defmodule Mythweaver.Characters.Character do
  @moduledoc """
  A persona: the identity and description text a prompt speaks as or about.

  Only `name` is required. `creator`, `creator_notes` and `character_version` are card metadata kept
  so an imported character round-trips without losing attribution, not fields this app reasons about.

  A character is chat-independent. Everything per-conversation (which model they speak with, whether
  they are the player) lives on `Mythweaver.Chats.Participant` and `Mythweaver.Chats.Chat`.

  `talkativeness` (0..1) is the character's default chattiness in group chats, read by
  `Mythweaver.Generation.TurnPolicy`; a participant may override it per chat.

  `user_id` is the owner (`Mythweaver.Ownership`): nil for a site character. Never cast.

  `favorite` is virtual: whether the listing scope's user starred it (`Mythweaver.Characters.Favorite`),
  set only by `Mythweaver.Characters.list_characters/1` and `list_editable_characters/1`. Never cast.

  `appearance` is plain text describing how the character looks. Setting an avatar fills it with
  the avatar's description (`Mythweaver.Attachments.Captions.request_avatar/5`); it stays editable.
  `avatar_updates_appearance` overrides the `images.avatar_updates_appearance` setting for this
  character; `nil` follows it.

  Greetings mirror the card: `first_message` is its `first_mes`, `alternate_greetings` its
  `alternate_greetings`, `group_greetings` its `group_only_greetings`. A blank `first_message` is kept
  as nil, so a card whose greetings are all alternates exports the same way. All are Liquid, rendered
  once when a new chat posts its greeting (`Mythweaver.Greetings`); nothing else reads them.

  Expressions (`Mythweaver.Expressions`): `expression_labels` are the character's custom labels on
  top of the base emotions, `fallback_expression` the label shown when nothing matches, and
  `expression_profile_id` its rule profile (nil: the `expressions.default_profile` setting). Only
  `expression_changeset/2` casts them, so the main form never clobbers them.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Attachments.CharacterAttachment
  alias Mythweaver.Expressions
  alias Mythweaver.Expressions.Outfit
  alias Mythweaver.Expressions.Profile
  alias Mythweaver.Expressions.Sprite

  @type t :: %__MODULE__{}

  schema "characters" do
    field :name, :string
    field :description, :string
    field :creator, :string
    field :creator_notes, :string
    field :character_version, :string
    field :pronouns, :string
    field :appearance, :string
    field :first_message, :string
    field :alternate_greetings, {:array, :string}, default: []
    field :group_greetings, {:array, :string}, default: []
    field :avatar_updates_appearance, :boolean
    field :talkativeness, :float, default: 0.5
    field :favorite, :boolean, virtual: true, default: false
    field :expression_labels, {:array, :string}, default: []
    field :fallback_expression, :string, default: "neutral"
    # A card's system prompt and post-history instructions (Liquid). `card_prompt_mode` `:replace`
    # puts them in place of the prompt block tagged `:main`/`:post_history`
    # (`Mythweaver.Prompts.Block.role_tag`); `:add` renders them into the lore slots.
    field :system_prompt, :string
    field :post_history_instructions, :string
    field :card_prompt_mode, Ecto.Enum, values: [:replace, :add], default: :replace
    # The card file's name without extension, which SillyTavern character filters name it by.
    field :source_file, :string
    # Keys an import couldn't map, kept so an export can write them back. Never rendered.
    field :foreign, :map, default: %{}

    field :site_visibility, Ecto.Enum, values: [:readable, :runtime_only], default: :readable

    belongs_to :user, User
    # What `Mythweaver.Sharing.Clone` copied this from (no FK: the source may go). Never cast.
    field :cloned_from_type, Ecto.Enum,
      values: [
        :character,
        :lore_book,
        :prompt,
        :block,
        :outlet,
        :script,
        :memory_profile,
        :side_prompt,
        :side_prompt_set,
        :ai_model
      ]

    field :cloned_from_id, Ecto.UUID
    # The catalog release a clone from a listing was made of (`Mythweaver.Catalog`).
    field :cloned_from_release_id, Ecto.UUID
    # Set on a catalog mirror row (`Mythweaver.Catalog`): its listing and the live row it copies.
    # Never cast.
    field :frozen_listing_id, Ecto.UUID
    field :mirror_of_id, Ecto.UUID

    belongs_to :expression_profile, Profile

    has_one :avatar_link, CharacterAttachment, where: [role: :avatar]
    has_one :avatar, through: [:avatar_link, :attachment]
    has_many :outfits, Outfit, preload_order: [asc: :position, asc: :name]
    has_many :sprites, Sprite

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(character, attrs) do
    character
    |> cast(attrs, [
      :name,
      :description,
      :creator,
      :creator_notes,
      :character_version,
      :pronouns,
      :appearance,
      :first_message,
      :alternate_greetings,
      :group_greetings,
      :avatar_updates_appearance,
      :talkativeness,
      :site_visibility,
      :system_prompt,
      :post_history_instructions,
      :card_prompt_mode
    ])
    |> validate_required([:name])
    |> validate_number(:talkativeness, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> Mythweaver.Templates.validate(:description)
    |> Mythweaver.Templates.validate(:first_message)
    |> Mythweaver.Templates.validate(:system_prompt)
    |> Mythweaver.Templates.validate(:post_history_instructions)
    |> Mythweaver.Templates.validate_each(:alternate_greetings)
    |> Mythweaver.Templates.validate_each(:group_greetings)
    |> validate_site_visibility()
  end

  @doc """
  `changeset/2` plus the fields only an import writes: `source_file` and `foreign` (a map with
  string keys).
  """
  def import_changeset(character, attrs) do
    character
    |> changeset(attrs)
    |> cast(attrs, [:source_file, :foreign])
    |> validate_foreign()
  end

  defp validate_foreign(changeset) do
    validate_change(changeset, :foreign, fn _field, value ->
      if is_map(value) and Enum.all?(value, fn {key, _} -> is_binary(key) end),
        do: [],
        else: [foreign: dgettext_noop("errors", "is invalid")]
    end)
  end

  @doc """
  The greetings a new chat may open with, in card order: `first_message`, then `alternate_greetings`,
  then `group_greetings` when `group?`; blank ones dropped.
  """
  @spec greetings(t(), boolean()) :: [String.t()]
  def greetings(%__MODULE__{} = character, group?) do
    [character.first_message | character.alternate_greetings]
    |> Kernel.++(if group?, do: character.group_greetings, else: [])
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
  end

  @doc "The expression settings: custom labels, fallback label and rule profile."
  def expression_changeset(character, attrs) do
    character
    |> cast(attrs, [:expression_labels, :fallback_expression, :expression_profile_id])
    |> update_change(:expression_labels, &normalize_labels/1)
    |> validate_change(:expression_labels, fn :expression_labels, labels ->
      if Enum.all?(labels, &Expressions.valid_label?/1),
        do: [],
        else: [expression_labels: dgettext_noop("errors", "contains an invalid label")]
    end)
    |> update_change(:fallback_expression, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:fallback_expression])
    |> validate_change(:fallback_expression, fn :fallback_expression, label ->
      if Expressions.valid_label?(label),
        do: [],
        else: [fallback_expression: dgettext_noop("errors", "is not a valid label")]
    end)
    |> foreign_key_constraint(:expression_profile_id)
  end

  defp normalize_labels(labels) do
    labels
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == "" or &1 in Expressions.base_labels()))
    |> Enum.uniq()
  end

  # A site row may hide its protected content from users; a personal row is only ever its owner's.
  defp validate_site_visibility(changeset) do
    if get_field(changeset, :user_id) != nil and get_field(changeset, :site_visibility) != :readable,
      do: add_error(changeset, :site_visibility, dgettext_noop("errors", "only site items can be runtime-only")),
      else: changeset
  end
end
