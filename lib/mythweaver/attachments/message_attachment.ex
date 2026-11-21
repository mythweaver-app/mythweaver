defmodule Mythweaver.Attachments.MessageAttachment do
  @moduledoc "Links an attachment to the message it was sent with. Written only by `Mythweaver.Attachments`."

  use Mythweaver.Schema

  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Messages.Message

  schema "message_attachments" do
    belongs_to :message, Message
    belongs_to :attachment, Attachment

    timestamps(type: :utc_datetime_usec)
  end
end
