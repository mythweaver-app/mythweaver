defmodule Mythweaver.AI.StreamEvent.Request do
  @moduledoc "Emitted once, before the HTTP request: the URL and the exact JSON body sent (headers omitted because they carry secrets)."

  @enforce_keys [:url, :body]
  defstruct [:url, :body]

  @type t :: %__MODULE__{url: String.t(), body: %{optional(String.t()) => term()}}
end
