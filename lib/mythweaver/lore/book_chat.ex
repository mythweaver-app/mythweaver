defmodule Mythweaver.Lore.BookChat do
  @moduledoc """
  Binds a lore book to one chat, so that book's entries are in scope for that chat only.

  `enabled` suspends the binding without deleting it, which keeps the choice recoverable. A `global`
  book needs no row here; this is the explicit-scope path.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.LoreBook

  schema "lore_book_chats" do
    field :enabled, :boolean, default: true

    belongs_to :book, LoreBook, foreign_key: :lore_book_id
    belongs_to :chat, Chat

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(book_chat, attrs) do
    book_chat
    |> cast(attrs, [:lore_book_id, :chat_id, :enabled])
    |> validate_required([:lore_book_id, :chat_id])
    |> assoc_constraint(:book)
    |> assoc_constraint(:chat)
    |> unique_constraint([:lore_book_id, :chat_id],
      name: :lore_book_chats_lore_book_id_chat_id_index,
      message: dgettext_noop("errors", "is already bound to this chat")
    )
  end
end
