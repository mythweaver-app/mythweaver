defmodule Mythweaver.Attachments.BodyAttachment do
  @moduledoc "Links an image to the swipe whose guide it was sent with. Written only by `Mythweaver.Attachments`."

  use Mythweaver.Schema

  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Messages.MessageBody

  schema "message_body_attachments" do
    belongs_to :message_body, MessageBody
    belongs_to :attachment, Attachment

    timestamps(type: :utc_datetime_usec)
  end
end
