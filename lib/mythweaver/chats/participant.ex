defmodule Mythweaver.Chats.Participant do
  @moduledoc """
  A character's seat in a chat, plus the per-chat settings that belong to that seat rather than to the
  character.

  `ai_model_id` is the most specific rung of `Mythweaver.Generation.model_for/3`'s ladder
  (participant → chat → `Mythweaver.AI.default_model/1`) and is nullable: unset is the normal case and
  falls through to the chat. Casting `""` clears it, which is what the UI's "Chat default" option submits.

  `muted` removes the character from automatic turn selection (`Mythweaver.Generation.TurnPolicy`),
  not from the scene. `talkativeness` overrides the character's value; `nil` falls through to it.

  `chat_id` is set by `Mythweaver.Chats` and is deliberately not castable, so a participant cannot be
  moved between chats by passing attrs. `position` (speaking order) is likewise set only by
  `Mythweaver.Chats`.

  `outfit_id` picks the character's expression set (`Mythweaver.Expressions.Outfit`) in this chat;
  nil is the Default set. `Mythweaver.Chats.update_participant/3` checks it belongs to the character.

  `added_by_id` is the chat member who brought their own character in (a guest, with the chat's
  `guests_bring_characters`); nil for the owner's cast. Set only by `Mythweaver.Chats`; when that
  member leaves, the character leaves with them.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.AI.Model
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Expressions.Outfit

  @type t :: %__MODULE__{}

  schema "chat_participants" do
    belongs_to :chat, Chat
    belongs_to :character, Character
    belongs_to :model, Model, foreign_key: :ai_model_id
    belongs_to :outfit, Outfit
    belongs_to :added_by, User
    field :position, :integer, default: 0
    field :muted, :boolean, default: false
    field :talkativeness, :float

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [:character_id, :ai_model_id, :muted, :talkativeness, :outfit_id])
    |> validate_required([:character_id])
    |> validate_number(:talkativeness, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> assoc_constraint(:character)
    |> unique_constraint([:chat_id, :character_id],
      name: :chat_participants_chat_id_character_id_index,
      message: dgettext_noop("errors", "is already a participant of this chat")
    )
  end
end
