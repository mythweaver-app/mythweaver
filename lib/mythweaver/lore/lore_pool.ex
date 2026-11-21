defmodule Mythweaver.Lore.LorePool do
  @moduledoc """
  A set of lore entries of which at most `max_activations` may activate in one prompt.

  This generalizes SillyTavern's inclusion group, which always picks exactly one winner. Losers are
  chosen by a weighted draw over `PoolEntry.weight`, and sticky entries consume slots before the draw
  runs, so a pool cannot exceed its cap by carrying a previous turn's winner forward
  (`Mythweaver.Lore.Activation.draw_pool/5`).

  A pool is orthogonal to a book: books decide what is *available*, a pool decides how many of several
  mutually exclusive variants may speak at once.
  """

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Lore.PoolEntry

  schema "lore_pools" do
    # Set on a catalog mirror row (`Mythweaver.Catalog`): its listing and the live row it copies.
    # Never cast.
    field :frozen_listing_id, Ecto.UUID
    field :mirror_of_id, Ecto.UUID

    field :name, :string
    field :description, :string
    field :max_activations, :integer, default: 1

    # nil: a site pool. Set by `Mythweaver.Lore` from `Mythweaver.Ownership`; never cast.
    belongs_to :user, User

    has_many :pool_entries, PoolEntry, foreign_key: :lore_pool_id
    has_many :entries, through: [:pool_entries, :entry]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(pool, attrs) do
    pool
    |> cast(attrs, [:name, :description, :max_activations])
    |> validate_required([:name])
    |> validate_number(:max_activations, greater_than_or_equal_to: 1)
    |> unique_constraint(:name, name: :lore_pools_user_id_name_index)
  end
end
