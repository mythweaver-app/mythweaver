defmodule Mythweaver.Messages.Scratchpad do
  @moduledoc """
  A holding area for text cut off the end of a message, never a message itself.

  `Mythweaver.Messages.split_to_scratchpad/4` moves a message's tail here so the user can continue or
  regenerate the head, then `append_scratchpad/1` puts the text back onto the message's current
  swipe. Being its own table keeps it out of every prompt: the transcript reads only `messages`.

  `chat_id` and `message_id` are set only by `Mythweaver.Messages`. Deleting the message leaves the
  scratchpad behind with `message_id` nil (orphaned): it can still be edited or discarded.
  """

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages.Message

  @type t :: %__MODULE__{}

  schema "message_scratchpads" do
    field :content, :string

    belongs_to :chat, Chat
    belongs_to :message, Message

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(scratchpad, attrs) do
    scratchpad
    |> cast(attrs, [:content])
    |> validate_required([:content])
    |> update_change(:content, &String.trim/1)
  end
end
