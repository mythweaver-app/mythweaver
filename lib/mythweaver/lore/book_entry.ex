defmodule Mythweaver.Lore.BookEntry do
  @moduledoc """
  Membership of a lore entry in a book, with the per-membership overrides that go with it.

  A join rather than a `belongs_to` on the entry because the same entry is shared across books, and
  each book may want it enabled and ordered differently: `enabled` switches the entry off in this book
  only, and `order` is the entry's position in this book only. `Mythweaver.Lore.Activation` computes
  the effective order as `order + book.order_adjustment`.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry

  schema "lore_book_entries" do
    field :enabled, :boolean, default: true
    field :order, :integer

    belongs_to :book, LoreBook, foreign_key: :lore_book_id
    belongs_to :entry, LoreEntry, foreign_key: :lore_entry_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(book_entry, attrs) do
    book_entry
    |> cast(attrs, [:lore_book_id, :lore_entry_id, :enabled, :order])
    |> validate_required([:lore_book_id, :lore_entry_id, :order])
    |> validate_number(:order, greater_than_or_equal_to: 0)
    |> assoc_constraint(:book)
    |> assoc_constraint(:entry)
    |> unique_constraint([:lore_book_id, :lore_entry_id],
      name: :lore_book_entries_lore_book_id_lore_entry_id_index,
      message: dgettext_noop("errors", "is already in this book")
    )
  end
end
