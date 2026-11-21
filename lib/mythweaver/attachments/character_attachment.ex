defmodule Mythweaver.Attachments.CharacterAttachment do
  @moduledoc """
  Links an attachment to a character in a `role`. A character has at most one `:avatar`
  (`character_attachments_one_avatar_index`). Written only by `Mythweaver.Attachments`.
  """

  use Mythweaver.Schema

  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters.Character

  schema "character_attachments" do
    field :role, Ecto.Enum, values: [:avatar]

    belongs_to :character, Character
    belongs_to :attachment, Attachment

    timestamps(type: :utc_datetime_usec)
  end
end
