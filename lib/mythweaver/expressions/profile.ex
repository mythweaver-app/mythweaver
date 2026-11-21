defmodule Mythweaver.Expressions.Profile do
  @moduledoc """
  An expression rule profile: named range and combination rules (`Mythweaver.Expressions.Rule`)
  layered over the classifier's base emotions, after expressions-plus. A character picks one
  (`Character.expression_profile_id`), else the `expressions.default_profile` setting applies.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Expressions.Rule

  @type t :: %__MODULE__{}

  schema "expression_profiles" do
    # Set on a catalog mirror row (`Mythweaver.Catalog`): its listing and the live row it copies.
    # Never cast.
    field :frozen_listing_id, Ecto.UUID
    field :mirror_of_id, Ecto.UUID

    field :name, :string

    embeds_many :rules, Rule, on_replace: :delete
    # nil: a site profile. Set by `Mythweaver.Expressions` from `Mythweaver.Ownership`; never cast.
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> unique_constraint([:user_id, :name], name: :expression_profiles_user_id_name_index)
    |> cast_embed(:rules, sort_param: :rules_sort, drop_param: :rules_drop)
    |> validate_unique_rule_names()
  end

  defp validate_unique_rule_names(changeset) do
    changeset
    |> get_field(:rules, [])
    |> Enum.map(& &1.name)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.find(fn {_name, n} -> n > 1 end)
    |> case do
      {name, _} ->
        add_error(changeset, :rules, dgettext_noop("errors", "has two rules named %{rule_name}"), rule_name: name)

      nil ->
        changeset
    end
  end
end
