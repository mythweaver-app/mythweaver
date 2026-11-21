defmodule Mythweaver.Memory.SidePromptSetRow do
  @moduledoc """
  One row of a `Mythweaver.Memory.SidePromptSet`: a side prompt, the `label` that names its entry
  (blank: the side prompt's title), and `macro_values`, the values of the side prompt's runtime
  macros (`SidePrompt.macros`) for this row. `position` orders the rows.
  """

  use Gettext, backend: Mythweaver.Gettext
  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePromptSet

  @type t :: %__MODULE__{}

  schema "side_prompt_set_rows" do
    # On a catalog mirror's row (`Mythweaver.Catalog`): the live row it copies. Never cast.
    field :mirror_of_id, Ecto.UUID
    field :position, :integer
    field :label, :string
    field :macro_values, :map, default: %{}

    belongs_to :side_prompt, SidePrompt
    belongs_to :side_prompt_set, SidePromptSet

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(row, attrs, index) do
    row
    |> cast(attrs, [:side_prompt_id, :label, :macro_values])
    |> put_change(:position, index)
    |> validate_required([:side_prompt_id])
    |> validate_change(:macro_values, fn :macro_values, values ->
      if Enum.all?(values, fn {key, value} -> is_binary(key) and is_binary(value) end),
        do: [],
        else: [macro_values: dgettext_noop("errors", "must map macro names to text")]
    end)
    |> update_change(:macro_values, &normalize_values/1)
    |> assoc_constraint(:side_prompt)
  end

  defp normalize_values(values) do
    for {key, value} when is_binary(value) <- values,
        value = String.trim(value),
        value != "",
        into: %{},
        do: {key, value}
  end
end
