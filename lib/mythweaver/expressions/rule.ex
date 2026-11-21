defmodule Mythweaver.Expressions.Rule do
  @moduledoc """
  One expressions-plus rule: a derived expression label (`name`) that wins when its conditions match.

    * `:range`: every condition's score lies within its `min`..`max` (percent, either bound optional).
    * `:combination`: every listed emotion scores above zero and within `max_difference` percent of
      the strongest of them.

  Scored and compared by `Mythweaver.Expressions.Resolver`.
  """

  use Ecto.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Expressions
  alias Mythweaver.Expressions.Condition

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    field :name, :string
    field :kind, Ecto.Enum, values: [:range, :combination], default: :combination
    field :max_difference, :integer, default: 25
    field :enabled, :boolean, default: true

    embeds_many :conditions, Condition, on_replace: :delete
  end

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:name, :kind, :max_difference, :enabled])
    |> update_change(:name, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:name, :kind])
    |> validate_label(:name)
    |> validate_number(:max_difference, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> cast_embed(:conditions, sort_param: :conditions_sort, drop_param: :conditions_drop)
    |> validate_conditions()
  end

  defp validate_label(changeset, field) do
    validate_change(changeset, field, fn ^field, name ->
      cond do
        not Expressions.valid_label?(name) ->
          [{field, dgettext_noop("errors", "may use only a-z, 0-9 and _ (at most 40)")}]

        name in Expressions.base_labels() ->
          [{field, dgettext_noop("errors", "is a built-in label")}]

        true ->
          []
      end
    end)
  end

  defp validate_conditions(changeset) do
    conditions = get_field(changeset, :conditions, [])

    case get_field(changeset, :kind) do
      :range ->
        cond do
          conditions == [] ->
            add_error(changeset, :conditions, dgettext_noop("errors", "a range rule needs at least one emotion"))

          Enum.any?(conditions, &(is_nil(&1.min) and is_nil(&1.max))) ->
            add_error(
              changeset,
              :conditions,
              dgettext_noop("errors", "each range condition needs a minimum or maximum")
            )

          true ->
            changeset
        end

      :combination ->
        labels = Enum.map(conditions, & &1.label)

        if length(labels) >= 2 and Enum.uniq(labels) == labels,
          do: changeset,
          else:
            add_error(
              changeset,
              :conditions,
              dgettext_noop("errors", "a combination needs at least two different emotions")
            )

      _ ->
        changeset
    end
  end
end
