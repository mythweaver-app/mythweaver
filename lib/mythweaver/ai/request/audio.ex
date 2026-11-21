defmodule Mythweaver.AI.Request.Audio do
  @moduledoc """
  An audio part of a `Mythweaver.AI.Request.Message`'s content, for a model that
  `Mythweaver.AI.Model.hears_audio?/1`. `data` is the raw bytes, `format` the short name the wire
  format wants (`"mp3"`, `"wav"`, `"ogg"`, `"flac"`, `"m4a"`).
  """

  @enforce_keys [:format, :data]
  defstruct [:format, :data]

  @type t :: %__MODULE__{format: String.t(), data: binary()}
end
