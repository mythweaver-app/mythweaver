defmodule Mythweaver.Lore.BookFilterTag do
  @moduledoc """
  One tag named in a lore book's tag filter.

  Direction lives on the book, not here: `LoreBook.tag_filter_mode` decides whether this list is an allowlist (`:include`), a denylist (`:exclude`), or ignored (`:off`). The tag row is always of the book's own domain (`Mythweaver.Tags.ensure_tags/3`).
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Tags.Tag

  schema "lore_book_filter_tags" do
    belongs_to :book, LoreBook, foreign_key: :lore_book_id
    belongs_to :tag, Tag

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(filter_tag, attrs) do
    filter_tag
    |> cast(attrs, [:lore_book_id, :tag_id])
    |> validate_required([:lore_book_id, :tag_id])
    |> assoc_constraint(:book)
    |> assoc_constraint(:tag)
    |> unique_constraint([:lore_book_id, :tag_id],
      name: :lore_book_filter_tags_lore_book_id_tag_id_index,
      message: dgettext_noop("errors", "is already filtered on this tag")
    )
  end
end
