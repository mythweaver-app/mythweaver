defmodule Mythweaver.Lore.BookCharacter do
  @moduledoc """
  Binds a lore book to one character, putting that book in scope for every chat the character is in.

  This is how a character carries their own world knowledge between chats, in contrast to `BookChat`,
  which scopes a book to one conversation. `enabled` suspends the binding without deleting it.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Characters.Character
  alias Mythweaver.Lore.LoreBook

  schema "lore_book_characters" do
    field :enabled, :boolean, default: true

    belongs_to :book, LoreBook, foreign_key: :lore_book_id
    belongs_to :character, Character

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(book_character, attrs) do
    book_character
    |> cast(attrs, [:lore_book_id, :character_id, :enabled])
    |> validate_required([:lore_book_id, :character_id])
    |> assoc_constraint(:book)
    |> assoc_constraint(:character)
    |> unique_constraint([:lore_book_id, :character_id],
      name: :lore_book_characters_lore_book_id_character_id_index,
      message: dgettext_noop("errors", "is already bound to this character")
    )
  end
end
