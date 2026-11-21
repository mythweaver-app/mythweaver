defmodule Mythweaver.Sharing.Toggle do
  @moduledoc """
  One user's own on/off switch over a lore entry, block or script they don't own, without cloning
  it (`Mythweaver.Sharing.set_toggle/3`). A lore entry or block is on unless toggled off; a shared
  script is off until toggled on, a site script on until toggled off. Rows are built only inside
  `Mythweaver.Sharing`, so there is no changeset.

  For an enabled script, `consent_hash` is `Mythweaver.Scripts.Script.consent_hash/1` of what was
  enabled; the toggle counts only while it still matches.
  """

  use Mythweaver.Schema

  alias Mythweaver.Accounts.User

  @type item_type :: :lore_entry | :block | :script
  @type t :: %__MODULE__{}

  schema "subscriber_toggles" do
    field :item_type, Ecto.Enum, values: [:lore_entry, :block, :script]
    field :item_id, Ecto.UUID
    field :enabled, :boolean
    field :consent_hash, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end
end
