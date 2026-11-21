defmodule Mythweaver.Expressions.Outfit do
  @moduledoc """
  A named expression set of a character (expressions-plus "outfits"). Sprites with `outfit_id` nil
  form the character's Default set; a chat participant picks an outfit (`Participant.outfit_id`).
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Characters.Character

  @type t :: %__MODULE__{}

  schema "character_outfits" do
    # On a catalog mirror's row (`Mythweaver.Catalog`): the live row it copies. Never cast.
    field :mirror_of_id, Ecto.UUID
    field :name, :string
    # Set by `Mythweaver.Expressions`; never cast.
    field :position, :integer, default: 0

    belongs_to :character, Character

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(outfit, attrs) do
    outfit
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 40)
    |> unique_constraint([:character_id, :name],
      message: dgettext_noop("errors", "is already an outfit of this character")
    )
  end
end
