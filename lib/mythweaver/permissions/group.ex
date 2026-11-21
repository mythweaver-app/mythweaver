defmodule Mythweaver.Permissions.Group do
  @moduledoc """
  A flat set of users sharing permission grants. `system_key` marks the two seeded groups:
  `:everyone` (implicitly every account; it has no member rows) and `:administrators`. It is set only
  by the migration that seeds them.
  """
  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Permissions.Grant
  alias Mythweaver.Permissions.Member

  @type t :: %__MODULE__{}

  schema "permission_groups" do
    field :name, :string
    field :description, :string
    field :system_key, Ecto.Enum, values: [:everyone, :administrators]

    has_many :grants, Grant
    many_to_many :users, User, join_through: Member, join_keys: [group_id: :id, user_id: :id]

    timestamps(type: :utc_datetime)
  end

  @doc "Name and description; the name is unique case-insensitively."
  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :description])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> unique_constraint(:name,
      name: :permission_groups_lower_name_index,
      message: dgettext_noop("errors", "has already been taken")
    )
  end
end
