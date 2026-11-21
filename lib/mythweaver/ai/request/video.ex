defmodule Mythweaver.AI.Request.Video do
  @moduledoc """
  A video part of a `Mythweaver.AI.Request.Message`'s content, for a model that
  `Mythweaver.AI.Model.watches_video?/1`. `data` is the raw bytes and `media_type` the stored type
  (`video/mp4`, `video/webm`, `video/quicktime`); the adapter chooses the wire encoding.
  """

  @enforce_keys [:media_type, :data]
  defstruct [:media_type, :data]

  @type t :: %__MODULE__{media_type: String.t(), data: binary()}
end
