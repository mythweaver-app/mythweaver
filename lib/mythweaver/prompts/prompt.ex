defmodule Mythweaver.Prompts.Prompt do
  @moduledoc """
  An ordered composition of reusable blocks.

  The order lives on the join (`Mythweaver.Prompts.PromptBlock.position`), not here, because the same
  block sits at different positions in different prompts.

  `purpose` says what renders it. Only `:roleplay` prompts are bound and resolved for chat replies
  (`Mythweaver.Prompts.resolve_prompt/1`). A `:caption` prompt is assigned to a vision model
  (`AI.Model.caption_prompt_id`) and renders the request that model gets to describe an image; every
  other purpose is a memory-book prompt, chosen by a memory profile or side prompt. None but
  `:roleplay` is bound.

  `thinking` is the reasoning effort the prompt asks for (`Mythweaver.AI.SamplerParams` levels),
  capped by the model's own level (`SamplerParams.cap_thinking/2`, applied in `Mythweaver.AI`); nil
  takes the model's level.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.Prompts.Binding
  alias Mythweaver.Prompts.PromptBlock

  schema "prompts" do
    field :name, :string
    field :description, :string
    field :enabled, :boolean, default: true

    field :purpose, Ecto.Enum,
      values: [
        :roleplay,
        :memory,
        :consolidation,
        :compaction,
        :topical_clip,
        :side_prompt,
        :clip_review,
        :clip_suggestions,
        :combine_clips,
        :caption
      ],
      default: :roleplay

    field :thinking, Ecto.Enum, values: SamplerParams.thinking_levels()

    has_many :prompt_blocks, PromptBlock, foreign_key: :prompt_id, preload_order: [asc: :position]
    has_many :blocks, through: [:prompt_blocks, :block]
    has_many :bindings, Binding, foreign_key: :prompt_id

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

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(prompt, attrs) do
    prompt
    |> cast(attrs, [:name, :description, :enabled, :purpose, :thinking, :site_visibility])
    |> validate_required([:name])
    |> validate_site_visibility()
    |> unique_constraint(:name, name: :prompts_user_id_name_index)
  end

  # A site row may hide its protected content from users; a personal row is only ever its owner's.
  defp validate_site_visibility(changeset) do
    if get_field(changeset, :user_id) != nil and get_field(changeset, :site_visibility) != :readable,
      do: add_error(changeset, :site_visibility, dgettext_noop("errors", "only site items can be runtime-only")),
      else: changeset
  end
end
