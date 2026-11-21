defmodule Mythweaver.Lore.PoolEntry do
  @moduledoc """
  Membership of a lore entry in a pool, carrying that entry's draw `weight` within it.

  The weight is per membership rather than per entry because the same entry can be a long shot in one
  pool and the favorite in another. `Mythweaver.Lore.Activation.weighted_draw/4` reads it; a weight of
  0 makes the entry eligible but never drawn.

  `override` (SillyTavern's group override) makes the member win over non-override members, by
  highest order; `scored` (group scoring) drops members whose keys match fewer than the best.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.LorePool

  schema "lore_pool_entries" do
    field :weight, :integer, default: 100
    field :override, :boolean, default: false
    field :scored, :boolean, default: false

    belongs_to :pool, LorePool, foreign_key: :lore_pool_id
    belongs_to :entry, LoreEntry, foreign_key: :lore_entry_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(pool_entry, attrs) do
    pool_entry
    |> cast(attrs, [:lore_pool_id, :lore_entry_id, :weight, :override, :scored])
    |> validate_required([:lore_pool_id, :lore_entry_id])
    |> validate_number(:weight, greater_than_or_equal_to: 0)
    |> assoc_constraint(:pool)
    |> assoc_constraint(:entry)
    |> unique_constraint([:lore_pool_id, :lore_entry_id],
      name: :lore_pool_entries_lore_pool_id_lore_entry_id_index,
      message: dgettext_noop("errors", "is already in this pool")
    )
  end
end
