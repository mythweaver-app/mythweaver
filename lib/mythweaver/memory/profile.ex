defmodule Mythweaver.Memory.Profile do
  @moduledoc """
  A reusable memory profile: which model and prompts a memory job uses, and the lore-entry settings
  every memory it writes gets.

  `ai_model_id` nil means the chat's model (`Mythweaver.Memory.model_for/2`). The prompt ids
  point at prompts of the matching `Prompts.Prompt.purpose`; `Mythweaver.Memory` validates that,
  since it needs the database. At most one profile is `default` (a partial unique index), and only
  `Mythweaver.Memory.set_default_profile/1` moves it.

  `group_memory_prompt_id` is used instead of `memory_prompt_id` when a scene has two or more
  non-player speakers; nil means always use the memory prompt.

  `character_memory_prompt_id` (a `:memory` prompt) writes each character memory book's copy from
  that character's perspective; nil means character books get verbatim copies of the memory.
  `clip_review_prompt_id` (`:clip_review`) and `clip_suggestions_prompt_id` (`:clip_suggestions`)
  drive Memory Assistance's clip updates and topic suggestions; `combine_clips_prompt_id`
  (`:combine_clips`) merges topical clips into one.

  `max_tokens` caps the response; 0 sends no cap, so the model's own response limit applies
  (`Mythweaver.Memory.Request.input/6`).

  `activation`, `outlet`, `placement`, `custom_outlet`, `depth`, `prevent_recursion` and
  `exclude_recursion` are copied onto each memory's lore entry; `order_mode: :auto` orders entries by
  their sequence, `:manual` uses `order`.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.AI.Model
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Prompts.Prompt

  @type t :: %__MODULE__{}

  schema "memory_profiles" do
    field :name, :string
    field :default, :boolean, default: false
    field :temperature, :float
    field :max_tokens, :integer, default: 4096
    field :structured_output, :boolean, default: false
    field :title_format, :string, default: "[000] - {{title}}"
    # Arcs and up; `{{tier}}` is the tier's name in capitals, as SillyTavern-MemoryBooks titles them.
    field :consolidation_title_format, :string, default: "[{{tier}} 000] - {{title}}"
    field :activation, Ecto.Enum, values: Ecto.Enum.values(LoreEntry, :activation), default: :keyword
    field :outlet, Ecto.Enum, values: Ecto.Enum.values(LoreEntry, :outlet), default: :character
    field :placement, Ecto.Enum, values: Ecto.Enum.values(LoreEntry, :placement), default: :after
    field :custom_outlet, :string
    field :depth, :integer
    field :order_mode, Ecto.Enum, values: [:auto, :manual], default: :auto
    field :order, :integer, default: 100
    field :prevent_recursion, :boolean, default: false
    field :exclude_recursion, :boolean, default: false
    field :character_aware, :boolean, default: true

    belongs_to :model, Model, foreign_key: :ai_model_id
    belongs_to :memory_prompt, Prompt
    belongs_to :group_memory_prompt, Prompt
    belongs_to :consolidation_prompt, Prompt
    belongs_to :compaction_prompt, Prompt
    belongs_to :topical_clip_prompt, Prompt
    belongs_to :character_memory_prompt, Prompt
    belongs_to :clip_review_prompt, Prompt
    belongs_to :clip_suggestions_prompt, Prompt
    belongs_to :combine_clips_prompt, Prompt
    # nil: a site profile. Set by `Mythweaver.Memory` from `Mythweaver.Ownership`; never cast.
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

    timestamps(type: :utc_datetime)
  end

  @doc "Each prompt field and the `Prompts.Prompt.purpose` it must point at."
  def prompt_purposes do
    [
      memory_prompt_id: :memory,
      group_memory_prompt_id: :memory,
      consolidation_prompt_id: :consolidation,
      compaction_prompt_id: :compaction,
      topical_clip_prompt_id: :topical_clip,
      character_memory_prompt_id: :memory,
      clip_review_prompt_id: :clip_review,
      clip_suggestions_prompt_id: :clip_suggestions,
      combine_clips_prompt_id: :combine_clips
    ]
  end

  @doc false
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :name,
      :ai_model_id,
      :memory_prompt_id,
      :group_memory_prompt_id,
      :consolidation_prompt_id,
      :compaction_prompt_id,
      :topical_clip_prompt_id,
      :character_memory_prompt_id,
      :clip_review_prompt_id,
      :clip_suggestions_prompt_id,
      :combine_clips_prompt_id,
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
    ])
    |> validate_required([
      :name,
      :max_tokens,
      :title_format,
      :consolidation_title_format,
      :activation,
      :outlet,
      :placement,
      :order_mode,
      :order
    ])
    |> validate_number(:max_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:order, greater_than_or_equal_to: 0)
    |> validate_custom_outlet()
    |> assoc_constraint(:model)
    |> unique_constraint(:name, name: :memory_profiles_user_id_name_index)
  end

  # Mirrors `LoreEntry`: a custom outlet with no name would write entries that render nowhere.
  defp validate_custom_outlet(changeset) do
    if get_field(changeset, :outlet) == :custom,
      do:
        validate_required(changeset, [:custom_outlet],
          message: dgettext_noop("errors", "a custom outlet needs an outlet")
        ),
      else: changeset
  end
end
