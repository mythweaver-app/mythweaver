defmodule Mythweaver.Lore.EntryState do
  @moduledoc "Per-chat sticky/cooldown bookkeeping for a lore entry; counts are non-draft message counts."

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.LoreEntry

  schema "lore_entry_states" do
    field :sticky_until, :integer
    field :cooldown_until, :integer
    field :last_activated_at_count, :integer

    belongs_to :chat, Chat
    belongs_to :entry, LoreEntry, foreign_key: :lore_entry_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(entry_state, attrs) do
    entry_state
    |> cast(attrs, [
      :chat_id,
      :lore_entry_id,
      :sticky_until,
      :cooldown_until,
      :last_activated_at_count
    ])
    |> validate_required([:chat_id, :lore_entry_id])
    |> assoc_constraint(:chat)
    |> assoc_constraint(:entry)
    |> unique_constraint([:chat_id, :lore_entry_id],
      name: :lore_entry_states_chat_id_lore_entry_id_index
    )
  end
end
