defmodule Mythweaver.Chats.Member do
  @moduledoc """
  Another account invited into one chat. `role` `:editor` (a chat editor: everything but deleting the
  chat) or `:guest` (reads and posts, with the chat's guest toggles, `Chat.guest_permissions/1`);
  `status` moves `:pending` → `:accepted` or `:declined`, and a declined member may be invited
  again. `invited_by_id` is who sent the invite. The chat's owner is never a member row.
  `last_read_at` is this member's own read cursor (nil: read up to `accepted_at`).
  `model_source`, set by the chat's owner, is whose models, connections, keys and quota the member's
  own replies and captions spend: `:owner` (the owner's) or `:own` (the member's).
  `ai_model_id` is an `:own` member's per-chat model pick (nil: their default model).

  Rows are built only inside `Mythweaver.Chats` from trusted values, so there is no changeset.
  """

  use Mythweaver.Schema

  alias Mythweaver.Accounts.User
  alias Mythweaver.AI.Model
  alias Mythweaver.Chats.Chat

  @type t :: %__MODULE__{}

  schema "chat_members" do
    field :role, Ecto.Enum, values: [:editor, :guest]
    field :status, Ecto.Enum, values: [:pending, :accepted, :declined], default: :pending
    field :accepted_at, :utc_datetime
    field :last_read_at, :utc_datetime_usec
    field :model_source, Ecto.Enum, values: [:owner, :own], default: :owner

    belongs_to :chat, Chat
    belongs_to :user, User
    belongs_to :invited_by, User
    belongs_to :ai_model, Model

    timestamps(type: :utc_datetime)
  end
end
