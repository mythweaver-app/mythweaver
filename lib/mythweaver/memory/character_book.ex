defmodule Mythweaver.Memory.CharacterBook do
  @moduledoc """
  A character memory book lock: pins one character to one lore book for every chat of one user.

  The locked book is live in each of that user's chats the character joins
  (`Mythweaver.Lore.books_for_chat/2`), and receives the character's copies of new memories. It is
  per user rather than a `Lore.BookCharacter` binding, because a personal book cannot be bound to a
  site character. Only `Mythweaver.Memory` writes these rows: `changeset/2` casts nothing.
  """

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Characters.Character
  alias Mythweaver.Lore.LoreBook

  @type t :: %__MODULE__{}

  schema "memory_character_books" do
    belongs_to :user, User
    belongs_to :character, Character
    belongs_to :book, LoreBook, foreign_key: :lore_book_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(character_book, attrs), do: cast(character_book, attrs, [])
end
