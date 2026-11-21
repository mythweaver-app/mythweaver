defmodule MythweaverWeb.Bulk.Field do
  @moduledoc """
  One field a bulk edit can write to every selected row.

  - `type`: `:checkbox | :select | :number | :text | :tags`. A `:tags` field is a chip input
    (`<.tag_input>`) whose submitted value is its list of chips, or the single chip (nil: none)
    when `max` is 1.
  - `options`: a select's `{label, value}` list or a `:tags` field's vocabulary
    (`Mythweaver.Tags.vocabulary/2`), or a `(Scope.t() -> list)` resolved when the edit modal opens.
  - `prompt`: a select's blank option label; a submitted `""` then becomes `nil`.
  - `cast`: `(String.t() -> term)` applied to the submitted value.
  """

  alias MythweaverWeb.EnumLabels

  @enforce_keys [:key, :label]
  defstruct [:key, :label, type: :checkbox, options: [], prompt: nil, min: nil, max: nil, step: nil, cast: nil]

  @type t :: %__MODULE__{}

  @doc "Select options for an `Ecto.Enum` field, minus `except`."
  @spec enum_options(module(), atom(), [atom()]) :: [{String.t(), atom()}]
  def enum_options(schema, field, except \\ []) do
    for v <- Ecto.Enum.values(schema, field), v not in except, do: {EnumLabels.label(schema, field, v), v}
  end
end
