defmodule Mythweaver.AI.StreamEvent.Delta do
  @moduledoc "A content token. `text` is never `nil` or `\"\"`."

  @enforce_keys [:text]
  defstruct [:text]

  @type t :: %__MODULE__{text: String.t()}
end
