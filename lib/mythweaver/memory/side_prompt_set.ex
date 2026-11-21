defmodule Mythweaver.Memory.SidePromptSet do
  @moduledoc """
  A side prompt set: an ordered list of rows (`Mythweaver.Memory.SidePromptSetRow`), each one side
  prompt with its own label and runtime macro values. A chat on a set runs its rows after memories
  and on intervals instead of the individually enabled side prompts; the same side prompt may
  appear in several rows (one tracker per NPC, say), each keeping its own entry and checkpoint.
  """

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Memory.SidePromptSetRow

  @type t :: %__MODULE__{}

  schema "side_prompt_sets" do
    field :name, :string

    has_many :rows, SidePromptSetRow, preload_order: [asc: :position], on_replace: :delete
    # nil: a site set. Set by `Mythweaver.Memory` from `Mythweaver.Ownership`; never cast.
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
  def changeset(set, attrs) do
    set
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name, name: :side_prompt_sets_user_id_name_index)
    |> cast_assoc(:rows, with: &SidePromptSetRow.changeset/3, sort_param: :rows_sort, drop_param: :rows_drop)
  end
end
