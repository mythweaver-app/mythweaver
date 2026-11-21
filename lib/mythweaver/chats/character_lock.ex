defmodule Mythweaver.Chats.CharacterLock do
  @moduledoc """
  One account playing one character in one chat. A user may hold several characters in a chat and
  a character may have several holders; a row is unique per `(chat, character, user)`. With the
  chat's `free_switching` members take and release characters themselves, one at a time
  (`Mythweaver.Chats.lock/3`, `unlock/3`), else a chat manager sets each user's held set
  (`Mythweaver.Chats.assign_characters/4`). A member posts as one of the characters they hold
  (`Mythweaver.Messages.send_message/5`). Leaving or being removed from a chat drops the member's
  locks (`Mythweaver.Chats.leave/2`, `Mythweaver.Chats.remove_member/2`), and a character leaving
  the chat drops all of its locks.

  Rows are built only inside `Mythweaver.Chats` from trusted values, so there is no changeset.
  """

  use Mythweaver.Schema

  alias Mythweaver.Accounts.User
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat

  @type t :: %__MODULE__{}

  schema "character_locks" do
    belongs_to :chat, Chat
    belongs_to :character, Character
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end
end
