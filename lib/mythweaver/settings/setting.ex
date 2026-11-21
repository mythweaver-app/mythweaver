defmodule Mythweaver.Settings.Setting do
  @moduledoc """
  One level's setting overrides: the site row (`user_id` nil) or one user's row. `values` maps a
  setting key to its stored (JSON-encoded) value; `locked_keys`, meaningful only on the site row,
  lists the keys users may not override.

  Every field is set programmatically by `Mythweaver.Settings`, so there is no changeset.
  """

  use Mythweaver.Schema

  alias Mythweaver.Accounts.User

  @type t :: %__MODULE__{}

  schema "settings" do
    belongs_to :user, User
    field :values, :map, default: %{}
    field :locked_keys, {:array, :string}, default: []

    timestamps(type: :utc_datetime)
  end
end
