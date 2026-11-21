defmodule Mythweaver.Lore.EntryFilterTag do
  @moduledoc """
  One tag named in a lore entry's tag filter.

  Direction lives on the entry, not here: `LoreEntry.character_filter_mode` covers this list together with the entry's filter characters. The tag row is always of the entry's own domain (`Mythweaver.Tags.ensure_tags/3`).
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Tags.Tag

  schema "lore_entry_filter_tags" do
    belongs_to :entry, LoreEntry, foreign_key: :lore_entry_id
    belongs_to :tag, Tag

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(filter_tag, attrs) do
    filter_tag
    |> cast(attrs, [:lore_entry_id, :tag_id])
    |> validate_required([:lore_entry_id, :tag_id])
    |> assoc_constraint(:entry)
    |> assoc_constraint(:tag)
    |> unique_constraint([:lore_entry_id, :tag_id],
      name: :lore_entry_filter_tags_lore_entry_id_tag_id_index,
      message: dgettext_noop("errors", "is already filtered on this tag")
    )
  end
end
