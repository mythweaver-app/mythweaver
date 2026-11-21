defmodule Mythweaver.Memory.SidePrompt do
  @moduledoc """
  A side prompt: a `:side_prompt`-purpose prompt plus when it runs and the lore entry it maintains (a
  tracker, a cast list…), separate from the scene memories.

  It runs on demand, after each saved memory (`run_after_memory`), or every `interval` messages
  (`run_on_interval`). `target_book_id` nil writes into the chat's memory book; `title` nil names the
  entry after the side prompt. The entry settings mirror `Mythweaver.Memory.Profile`'s, plus
  `ignore_budget`. `profile_id` overrides the chat's profile for the model. `save_versions` keeps
  numbered copies instead of updating one entry, when versioning is on in the preferences.

  `macros` names the runtime macros the prompt uses as Liquid variables (`{{ npc_name }}`). Their
  values come from a `Mythweaver.Memory.SidePromptSetRow` or a manual run; a side prompt with an
  unfilled macro never runs automatically.

  `prompt_id` must point at a `:side_prompt` prompt; `Mythweaver.Memory` validates that. Deleting the
  prompt deletes the side prompt.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Prompts.Prompt

  @type t :: %__MODULE__{}

  schema "side_prompts" do
    field :name, :string
    field :enabled, :boolean, default: true
    field :run_after_memory, :boolean, default: false
    field :run_on_interval, :boolean, default: false
    field :interval, :integer, default: 20
    field :previous_memories, :integer, default: 0
    field :use_context, :boolean, default: false
    field :title, :string
    field :keywords, {:array, :string}, default: []
    field :macros, {:array, :string}, default: []
    field :activation, Ecto.Enum, values: Ecto.Enum.values(LoreEntry, :activation), default: :constant
    field :outlet, Ecto.Enum, values: Ecto.Enum.values(LoreEntry, :outlet), default: :character
    field :placement, Ecto.Enum, values: Ecto.Enum.values(LoreEntry, :placement), default: :after
    field :custom_outlet, :string
    field :depth, :integer
    field :order, :integer, default: 100
    field :prevent_recursion, :boolean, default: false
    field :exclude_recursion, :boolean, default: false
    field :ignore_budget, :boolean, default: false
    field :save_versions, :boolean, default: false

    belongs_to :prompt, Prompt
    belongs_to :target_book, LoreBook
    belongs_to :profile, Profile
    # nil: a site side prompt. Set by `Mythweaver.Memory` from `Mythweaver.Ownership`; never cast.
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
  def changeset(side_prompt, attrs) do
    side_prompt
    |> cast(attrs, [
      :name,
      :prompt_id,
      :enabled,
      :run_after_memory,
      :run_on_interval,
      :interval,
      :previous_memories,
      :use_context,
      :target_book_id,
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
      :profile_id,
      :save_versions,
      :macros
    ])
    |> validate_required([:name, :prompt_id, :interval, :previous_memories, :activation, :outlet, :placement, :order])
    |> validate_number(:interval, greater_than_or_equal_to: 1)
    |> validate_number(:previous_memories, greater_than_or_equal_to: 0, less_than_or_equal_to: 7)
    |> validate_number(:order, greater_than_or_equal_to: 0)
    |> update_change(:keywords, &LoreEntry.normalize_keywords/1)
    |> update_change(:macros, &LoreEntry.normalize_keywords/1)
    |> validate_change(:macros, fn :macros, macros ->
      if Enum.all?(macros, &Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, &1)),
        do: [],
        else: [macros: dgettext_noop("errors", "must be lowercase letters, digits and underscores")]
    end)
    |> validate_custom_outlet()
    |> assoc_constraint(:prompt)
    |> assoc_constraint(:target_book)
    |> assoc_constraint(:profile)
    |> unique_constraint(:name, name: :side_prompts_user_id_name_index)
  end

  # Mirrors `LoreEntry`: a custom outlet with no name would write an entry that renders nowhere.
  defp validate_custom_outlet(changeset) do
    if get_field(changeset, :outlet) == :custom,
      do:
        validate_required(changeset, [:custom_outlet],
          message: dgettext_noop("errors", "a custom outlet needs an outlet")
        ),
      else: changeset
  end
end
