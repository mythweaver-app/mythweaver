defmodule Mythweaver.AI.StreamEvent.Reasoning do
  @moduledoc "A reasoning/thinking token. `text` is never `nil` or `\"\"`."

  @enforce_keys [:text]
  defstruct [:text]

  @type t :: %__MODULE__{text: String.t()}
end
