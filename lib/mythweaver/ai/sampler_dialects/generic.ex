defmodule Mythweaver.AI.SamplerDialects.Generic do
  @moduledoc """
  The dialect of a connection with none set: canonical names for every typed field (vLLM, TabbyAPI,
  and other servers that take the llama.cpp-era names, ignoring the ones they do not know).

  `stop_sequences` goes out as `stop` and `sampler_order` as `samplers`; only token-id logit bias
  keys are sent, since text keys are a llama.cpp extension.
  """

  @behaviour Mythweaver.AI.Provider.SamplerDialect

  use Gettext, backend: Mythweaver.Gettext

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
    typical_p: "typical_p",
    repetition_penalty: "repetition_penalty",
    repetition_penalty_range: "repetition_penalty_range",
    top_n_sigma: "top_n_sigma",
    dry_multiplier: "dry_multiplier",
    dry_base: "dry_base",
    dry_allowed_length: "dry_allowed_length",
    dry_penalty_last_n: "dry_penalty_last_n",
    dry_sequence_breakers: "dry_sequence_breakers",
    xtc_threshold: "xtc_threshold",
    xtc_probability: "xtc_probability",
    ignore_eos: "ignore_eos",
    skip_special_tokens: "skip_special_tokens",
    dynatemp_low: "dynatemp_low",
    dynatemp_high: "dynatemp_high",
    dynatemp_exponent: "dynatemp_exponent"
  }

  @impl true
  def label, do: dpgettext("ai", "option: sampler dialect of an AI connection", "Generic")

  @impl true
  def body(%SamplerParams{} = sampler) do
    values = SamplerParams.set_values(sampler)

    values
    |> SamplerDialect.pick(@names)
    |> SamplerDialect.put_samplers(values)
    |> SamplerDialect.put_numeric_bias(values)
  end

  @impl true
  def adjust_body(body, _mode), do: body
end
