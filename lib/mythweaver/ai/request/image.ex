defmodule Mythweaver.AI.Request.Image do
  @moduledoc """
  An image part of a `Mythweaver.AI.Request.Message`'s content. `data` is the raw bytes; the adapter
  chooses the wire encoding. `detail` is the model's `image_detail`, sent where the wire format has a
  place for it.
  """

  @enforce_keys [:media_type, :data]
  defstruct [:media_type, :data, detail: nil]

  @type t :: %__MODULE__{media_type: String.t(), data: binary(), detail: :low | :auto | :high | nil}
end
