defmodule Mythweaver.AI.Request.Text do
  @moduledoc "A text part of a `Mythweaver.AI.Request.Message`'s content."

  @enforce_keys [:text]
  defstruct [:text]

  @type t :: %__MODULE__{text: String.t()}
end
