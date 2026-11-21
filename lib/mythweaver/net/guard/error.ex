defmodule Mythweaver.Net.Guard.Error do
  @moduledoc "Why `Mythweaver.Net.Guard` refused a request or its response."

  defexception [:reason, :host]

  @type t :: %__MODULE__{reason: :private_address | :unresolvable | :too_large, host: String.t()}

  @impl true
  def message(%__MODULE__{reason: :private_address, host: host}), do: "#{host} is a private or local network address"
  def message(%__MODULE__{reason: :unresolvable, host: host}), do: "#{host} could not be resolved"
  def message(%__MODULE__{reason: :too_large, host: host}), do: "the response from #{host} was too large"
end
