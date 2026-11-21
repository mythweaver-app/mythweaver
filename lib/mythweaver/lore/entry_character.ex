defmodule Mythweaver.Lore.EntryCharacter do
  @moduledoc """
  One character named in a lore entry's character filter.

  Direction lives on the entry, not here: `LoreEntry.character_filter_mode` decides whether this list
  is an allowlist (`:include`), a denylist (`:exclude`), or ignored (`:off`). Keeping the mode on the
  entry means flipping include to exclude does not rewrite every row.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Characters.Character
  alias Mythweaver.Lore.LoreEntry

  schema "lore_entry_characters" do
    belongs_to :entry, LoreEntry, foreign_key: :lore_entry_id
    belongs_to :character, Character

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(entry_character, attrs) do
    entry_character
    |> cast(attrs, [:lore_entry_id, :character_id])
    |> validate_required([:lore_entry_id, :character_id])
    |> assoc_constraint(:entry)
    |> assoc_constraint(:character)
    |> unique_constraint([:lore_entry_id, :character_id],
      name: :lore_entry_characters_lore_entry_id_character_id_index,
      message: dgettext_noop("errors", "is already filtered on this character")
    )
  end
end
