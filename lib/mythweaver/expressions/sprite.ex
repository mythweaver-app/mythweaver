defmodule Mythweaver.Expressions.Sprite do
  @moduledoc """
  One expression image of a character: an attachment shown in place of the portrait beside a message
  whose expression is `label`. `outfit_id` nil is the Default set. Built only by
  `Mythweaver.Expressions`; there is no cast changeset.
  """

  use Mythweaver.Schema

  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters.Character
  alias Mythweaver.Expressions.Outfit

  @type t :: %__MODULE__{}

  schema "character_sprites" do
    # On a catalog mirror's row (`Mythweaver.Catalog`): the live row it copies. Never cast.
    field :mirror_of_id, Ecto.UUID
    field :label, :string

    belongs_to :character, Character
    belongs_to :outfit, Outfit
    belongs_to :attachment, Attachment

    timestamps(type: :utc_datetime_usec)
  end
end
