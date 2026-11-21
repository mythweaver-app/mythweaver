defmodule Mythweaver.Permissions.Grant do
  @moduledoc """
  One permission key set on one holder: a group or a user (exactly one, enforced by the
  `exactly_one_holder` check). A flag key carries `effect` (`:allow`/`:deny`); a limit key carries
  `limit_value`, nil meaning unlimited. An absent row is "unset". Holders are set by
  `Mythweaver.Permissions`, never cast.
  """
  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Permissions.Catalog
  alias Mythweaver.Permissions.Group

  @type t :: %__MODULE__{}

  schema "permission_grants" do
    field :key, :string
    field :effect, Ecto.Enum, values: [:allow, :deny]
    field :limit_value, :integer

    belongs_to :group, Group
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc "Key, effect and limit, validated against `Catalog`."
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:key, :effect, :limit_value])
    |> validate_required([:key])
    |> validate_shape()
    |> check_constraint(:key, name: :exactly_one_holder, message: dgettext_noop("errors", "needs exactly one holder"))
    |> unique_constraint(:key, name: :permission_grants_group_id_key_index)
    |> unique_constraint(:key, name: :permission_grants_user_id_key_index)
  end

  defp validate_shape(changeset) do
    key = get_field(changeset, :key)

    case key && Catalog.get(key) do
      nil when is_binary(key) ->
        add_error(changeset, :key, dgettext_noop("errors", "is not a permission"))

      nil ->
        changeset

      %{kind: :flag} ->
        changeset
        |> validate_required([:effect])
        |> validate_absent(:limit_value)

      %{kind: :limit} ->
        changeset
        |> validate_absent(:effect)
        |> validate_number(:limit_value, greater_than_or_equal_to: 0)
    end
  end

  defp validate_absent(changeset, field) do
    if is_nil(get_field(changeset, field)),
      do: changeset,
      else: add_error(changeset, field, dgettext_noop("errors", "must be blank"))
  end
end
