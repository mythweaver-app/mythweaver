defmodule Mythweaver.AI.SamplerDialects.OpenRouter do
  @moduledoc """
  OpenRouter: OpenAI's parameters plus the extra samplers OpenRouter documents (`top_k`, `min_p`,
  `top_a`, `repetition_penalty`). Everything else is dropped. Logit bias keeps token-id keys only,
  with `false` (ban) sent as -100.
  """

  @behaviour Mythweaver.AI.Provider.SamplerDialect

  alias Mythweaver.AI.Provider.SamplerDialect
  alias Mythweaver.AI.SamplerParams

  @names %{
    temperature: "temperature",
    top_p: "top_p",
    frequency_penalty: "frequency_penalty",
    presence_penalty: "presence_penalty",
    max_tokens: "max_tokens",
    seed: "seed",
    stop_sequences: "stop",
    top_k: "top_k",
    min_p: "min_p",
    top_a: "top_a",
    repetition_penalty: "repetition_penalty"
  }

  @impl true
  def label, do: "OpenRouter"

  @impl true
  def body(%SamplerParams{} = sampler) do
    values = SamplerParams.set_values(sampler)

    values
    |> SamplerDialect.pick(@names)
    |> SamplerDialect.put_numeric_bias(values)
  end

  @impl true
  def adjust_body(body, _mode), do: body
end
