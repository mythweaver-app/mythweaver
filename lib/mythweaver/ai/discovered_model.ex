defmodule Mythweaver.AI.DiscoveredModel do
  @moduledoc """
  One model a provider advertises, as an adapter's `discover_models/1` returns it
  (`Mythweaver.AI.Provider.Adapter`).

  `name` is the friendly name when the API supplies one (llama-swap does), `nil` otherwise. `attrs`
  holds `Mythweaver.AI.Model` field names (string keys) for whatever the payload advertised, and omits
  every field it did not, so the schema's defaults survive; it is ready for `Model.changeset/2`.
  """

  @enforce_keys [:id]
  defstruct [:id, :name, attrs: %{}]

  @type t :: %__MODULE__{id: String.t(), name: String.t() | nil, attrs: %{optional(String.t()) => term()}}
end
