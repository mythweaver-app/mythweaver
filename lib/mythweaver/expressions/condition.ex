defmodule Mythweaver.Expressions.Condition do
  @moduledoc """
  One emotion of a `Mythweaver.Expressions.Rule`. `min`/`max` (percent) bound it in a range rule; a
  combination rule ignores them.
  """

  use Ecto.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Expressions

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    field :label, :string
    field :min, :integer
    field :max, :integer
  end

  @doc false
  def changeset(condition, attrs) do
    condition
    |> cast(attrs, [:label, :min, :max])
    |> update_change(:label, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:label])
    |> validate_change(:label, fn :label, label ->
      if Expressions.valid_label?(label),
        do: [],
        else: [label: dgettext_noop("errors", "may use only a-z, 0-9 and _ (at most 40)")]
    end)
    |> validate_number(:min, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:max, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_bounds()
  end

  defp validate_bounds(changeset) do
    min = get_field(changeset, :min)
    max = get_field(changeset, :max)

    if is_integer(min) and is_integer(max) and min > max,
      do: add_error(changeset, :max, dgettext_noop("errors", "must be at least the minimum")),
      else: changeset
  end
end
