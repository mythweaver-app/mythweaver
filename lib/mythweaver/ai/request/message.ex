defmodule Mythweaver.AI.Request.Message do
  @moduledoc """
  One chat message of a `Mythweaver.AI.Request`. `content` is a string, or a list of parts for a
  model that sees images, reads PDFs, hears audio or watches video
  (`Mythweaver.AI.Model.sees_images?/1`, `reads_files?/1`, `hears_audio?/1`, `watches_video?/1`).

  `tool_calls` are the calls an `:assistant` message made (OpenAI `tool_calls`; `arguments` is the
  raw JSON string), and a `:tool` message answers the call named by `tool_call_id`.
  """

  alias Mythweaver.AI.Request.Audio
  alias Mythweaver.AI.Request.File
  alias Mythweaver.AI.Request.Image
  alias Mythweaver.AI.Request.Text
  alias Mythweaver.AI.Request.Video

  @enforce_keys [:role, :content]
  defstruct [:role, :content, tool_calls: [], tool_call_id: nil]

  @type tool_call :: %{id: String.t(), name: String.t(), arguments: String.t()}

  @type t :: %__MODULE__{
          role: :system | :user | :assistant | :tool,
          content: String.t() | [Text.t() | Image.t() | File.t() | Audio.t() | Video.t()] | nil,
          tool_calls: [tool_call()],
          tool_call_id: String.t() | nil
        }
end
