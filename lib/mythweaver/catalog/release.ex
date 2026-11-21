defmodule Mythweaver.Catalog.Release do
  @moduledoc """
  One release of a catalog listing (`Mythweaver.Catalog`): its `version` (1, 2, …), notes and who
  published it. Only the latest has rows (the listing's mirror); older ones are history.
  """

  use Mythweaver.Schema

  alias Mythweaver.Accounts.User
  alias Mythweaver.Catalog.Listing

  @type t :: %__MODULE__{}

  schema "catalog_releases" do
    field :version, :integer
    field :notes, :string

    belongs_to :listing, Listing
    belongs_to :published_by, User

    timestamps(type: :utc_datetime)
  end
end
