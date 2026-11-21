defmodule Mythweaver.AI.StreamEvent.Done do
  @moduledoc "The generation ended. `finish_reason` is whatever the backend reported, `nil` when it reported none."

  @enforce_keys [:finish_reason]
  defstruct [:finish_reason]

  @type t :: %__MODULE__{finish_reason: String.t() | nil}
end
