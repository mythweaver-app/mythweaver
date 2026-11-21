defmodule Mythweaver.Notifications.Notification do
  @moduledoc """
  One item in a user's notifications inbox, as `Mythweaver.Notifications.notify/2` stores it and hands
  it to every channel, or an error toast `Mythweaver.Notifications.record_error/2` keeps.

  `id` doubles as the dedupe tag: tabs and push devices that all receive one notification deliver it
  once. Callers set it with `Mythweaver.Schema.generate_id/0`, and an explicit id is stored as is.
  `icon` is an image URL (a reply's character avatar), or nil for the kind's icon. `expires_at` is
  when it stops being listed; nil keeps it until its context deletes it (a memory review, a ready
  consolidation tier). `lore_book_id` and `tier` name the tier a `:consolidation_ready` item
  announces; `share_id` the invite a `:share_invite` item asks about (it goes with the share), and
  `chat_member_id` the invite a `:chat_invite` item asks about (it goes with the member row). A
  `:share_ended` item tells a user they lost an item shared with them, a `:handed_off` one that they
  own one now, a `:listing_taken_down` one that a moderator took down their catalog listing, a
  `:moderation_warning` one that a moderator warned them (`/warnings`), a `:submission_approved` or
  `:submission_rejected` one that content held for review (`Mythweaver.Moderation.Holds`) was saved
  or discarded. Rows are
  built only inside `Mythweaver.Notifications` from trusted values, so there is
  no changeset.
  """

  use Mythweaver.Schema

  alias Mythweaver.Accounts.User
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Member
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Messages.Message
  alias Mythweaver.Sharing.Share

  @type kind ::
          :new_message
          | :regenerate
          | :continue
          | :memory_review
          | :consolidation_ready
          | :share_invite
          | :chat_invite
          | :share_ended
          | :handed_off
          | :listing_taken_down
          | :moderation_warning
          | :submission_approved
          | :submission_rejected
          | :error

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          kind: kind(),
          title: String.t(),
          body: String.t() | nil,
          icon: String.t() | nil,
          expires_at: DateTime.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          chat_id: Ecto.UUID.t() | nil,
          message_id: Ecto.UUID.t() | nil,
          job_id: Ecto.UUID.t() | nil,
          lore_book_id: Ecto.UUID.t() | nil,
          share_id: Ecto.UUID.t() | nil,
          chat_member_id: Ecto.UUID.t() | nil,
          tier: 1..6 | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "notifications" do
    field :kind, Ecto.Enum,
      values: [
        :new_message,
        :regenerate,
        :continue,
        :memory_review,
        :consolidation_ready,
        :share_invite,
        :chat_invite,
        :share_ended,
        :handed_off,
        :listing_taken_down,
        :moderation_warning,
        :submission_approved,
        :submission_rejected,
        :error
      ]

    field :title, :string
    field :body, :string
    field :icon, :string
    field :expires_at, :utc_datetime
    field :tier, :integer

    belongs_to :user, User
    belongs_to :chat, Chat
    belongs_to :message, Message
    belongs_to :job, Job
    belongs_to :lore_book, LoreBook
    belongs_to :share, Share
    belongs_to :chat_member, Member

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
