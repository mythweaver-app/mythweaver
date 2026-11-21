defmodule Mythweaver.AI.Provider.SamplerDialect do
  @moduledoc """
  Behaviour naming `Mythweaver.AI.SamplerParams`' typed fields on one backend's wire.

  Not an `Mythweaver.AI.Provider.Adapter` callback, for the same reason as
  `Mythweaver.AI.Provider.ThinkingDialect`: one adapter fronts llama.cpp, vLLM, TabbyAPI, OpenRouter
  and OpenAI, and they disagree on sampler names (llama.cpp reads `repeat_penalty`, not
  `repetition_penalty`). The dialect is chosen per connection (`Provider.sampler_dialect`) and a link
  may override it (`ProviderModel.sampler_dialect`). It is separate from the thinking dialect: a vLLM
  connection thinks in OpenAI's `reasoning_effort` but still takes vLLM's extra samplers.

  ## Contract

  - `body/1` returns a string-keyed wire map of typed fields only, never `extra` or `thinking`. A
    dialect drops the fields its backend does not accept.
  - `adjust_body/2` sees the whole merged body (sampler, `extra`, `extra_body`) last, for rewrites
    that depend on the request mode.

  Register a dialect by writing the module, adding one `{atom, module}` pair to `@dialects` below, and
  adding the same atom to the `:sampler_dialect` enum on both `Mythweaver.AI.Provider` and
  `Mythweaver.AI.ProviderModel`. `nil` is `Mythweaver.AI.SamplerDialects.Generic`.
  """

  alias Mythweaver.AI.SamplerDialects
  alias Mythweaver.AI.SamplerParams

  @dialects %{
    openai: SamplerDialects.OpenAI,
    openrouter: SamplerDialects.OpenRouter,
    llama_cpp: SamplerDialects.LlamaCpp
  }

  @doc "Human-readable dialect name for pickers."
  @callback label() :: String.t()

  @doc "The typed sampler fields as this backend's string-keyed wire map."
  @callback body(sampler :: %SamplerParams{}) :: map()

  @doc "A last rewrite of the full request body for `mode`."
  @callback adjust_body(body :: map(), mode :: :chat | :text) :: map()

  @doc "The implementation module for a registered dialect atom; `nil` is the generic dialect."
  def module_for(nil), do: SamplerDialects.Generic
  def module_for(dialect) when is_map_key(@dialects, dialect), do: Map.fetch!(@dialects, dialect)

  @doc "The full `%{atom => module}` registry, for pickers and validation."
  def dialects, do: @dialects

  @doc """
  Keeps only the keys of `values` that appear in `mapping`, renamed to `mapping`'s string.
  """
  def pick(values, mapping) do
    for {field, value} <- values, wire = Map.get(mapping, field), into: %{}, do: {wire, value}
  end

  @doc """
  Puts the token-id entries of `values`' logit bias (keys of digits only) under `"logit_bias"`, with
  `false` (ban) as `-100`; `body` is unchanged when none remain. For backends that take only numeric
  token ids.
  """
  def put_numeric_bias(body, %{logit_bias: bias}) do
    numeric =
      for {key, value} <- bias, key =~ ~r/\A\d+\z/, into: %{} do
        {key, if(value == false, do: -100, else: value)}
      end

    if numeric == %{}, do: body, else: Map.put(body, "logit_bias", numeric)
  end

  def put_numeric_bias(body, _values), do: body

  @doc "Puts `values`' custom `sampler_order` under llama.cpp's `\"samplers\"` key, when one is set."
  def put_samplers(body, %{sampler_order: order}), do: Map.put(body, "samplers", Enum.map(order, &Atom.to_string/1))
  def put_samplers(body, _values), do: body
end
