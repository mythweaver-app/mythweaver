defmodule Mythweaver.AI.Provider.ThinkingDialect do
  @moduledoc """
  Behaviour translating `Mythweaver.AI.SamplerParams.thinking` (a backend-neutral effort level)
  into one backend's wire fields.

  Not an `Mythweaver.AI.Provider.Adapter` callback: one adapter (`OpenAICompatible`) fronts llama.cpp,
  vLLM, OpenRouter and OpenAI, and the thinking wire shape depends on the server behind the protocol.
  The dialect is chosen per connection (`Provider.thinking_dialect`) and a link may override it
  (`ProviderModel.thinking_dialect`).

  ## Contract

  - `body/2` is only called with a non-nil effort.
  - It returns a string-keyed, `Jason`-encodable JSON fragment; nested objects are allowed.
  - The fragment is the *base* layer of the request-body extras: the model, connection and link
    `extra_body` all deep-merge over it, so any of them can override a translated key.

  Register a dialect by writing the module, adding one `{atom, module}` pair to `@dialects` below, and
  adding the same atom to the `:thinking_dialect` enum on both `Mythweaver.AI.Provider` and
  `Mythweaver.AI.ProviderModel`.
  """

  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.AI.ThinkingDialects

  @dialects %{
    openai: ThinkingDialects.OpenAI,
    openrouter: ThinkingDialects.OpenRouter,
    llama_cpp: ThinkingDialects.LlamaCpp
  }

  @doc "Human-readable dialect name for pickers."
  @callback label() :: String.t()

  @doc "The JSON fragment carrying `effort` in this dialect; `sampler` supplies context such as `max_tokens`."
  @callback body(effort :: SamplerParams.thinking(), sampler :: %SamplerParams{}) :: map()

  @doc "The implementation module for a registered dialect atom."
  def module_for(dialect) when is_map_key(@dialects, dialect), do: Map.fetch!(@dialects, dialect)

  @doc "The full `%{atom => module}` registry, for pickers and validation."
  def dialects, do: @dialects
end
