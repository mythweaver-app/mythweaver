defmodule Mythweaver.AI.Request.File do
  @moduledoc """
  A document part of a `Mythweaver.AI.Request.Message`'s content (a PDF, for a model that
  `Mythweaver.AI.Model.reads_files?/1`). `data` is the raw bytes; the adapter chooses the wire
  encoding.
  """

  @enforce_keys [:media_type, :data]
  defstruct [:media_type, :filename, :data]

  @type t :: %__MODULE__{media_type: String.t(), filename: String.t() | nil, data: binary()}
end
