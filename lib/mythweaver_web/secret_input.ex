defmodule MythweaverWeb.SecretInput do
  @moduledoc """
  The text of a write-only secret input (an API key) held in a LiveView assign. `inspect/1` prints
  it as `#SecretInput<redacted>`, so a crash report's assigns never show it.
  """

  @type t :: %__MODULE__{value: String.t()}
  defstruct value: ""

  defimpl Inspect do
    def inspect(_input, _opts), do: "#SecretInput<redacted>"
  end
end
