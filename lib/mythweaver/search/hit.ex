defmodule Mythweaver.Search.Hit do
  @moduledoc """
  One search result. `title` and `snippet` are `[{text, highlighted?}]` segments (nil when the row
  has none); `chat_id`, `chat_title` and `position` are set only for `:message` hits, whose `id` is
  the message's.
  """

  @type segments :: [{String.t(), boolean()}] | nil

  @type t :: %__MODULE__{
          kind: atom(),
          id: Ecto.UUID.t(),
          title: segments(),
          snippet: segments(),
          rank: float() | nil,
          chat_id: Ecto.UUID.t() | nil,
          chat_title: String.t() | nil,
          position: non_neg_integer() | nil
        }

  @enforce_keys [:kind, :id]
  defstruct [:kind, :id, :title, :snippet, :rank, :chat_id, :chat_title, :position]
end
