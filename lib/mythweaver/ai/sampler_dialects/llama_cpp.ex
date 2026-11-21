defmodule Mythweaver.AI.SamplerDialects.LlamaCpp do
  @moduledoc """
  llama.cpp server (`tools/server/server-schema.cpp`).

  - Repetition penalties are `repeat_penalty`/`repeat_last_n`; llama.cpp silently ignores the
    canonical `repetition_penalty` names.
  - Dynamic temperature is a centre and a half-width: `temperature` = (low + high) / 2 and
    `dynatemp_range` = (high - low) / 2, replacing any plain temperature.
  - `logit_bias` goes out as-is: llama.cpp tokenizes text keys and takes `false` as a ban.
  - `top_a` and `skip_special_tokens` are not llama.cpp parameters and are dropped.
  - `/v1/completions` ignores `response_format`, so text mode rewrites it to llama.cpp's own
    `json_schema` (`adjust_body/2`). The chat path converts `response_format` itself.
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
    typical_p: "typical_p",
    repetition_penalty: "repeat_penalty",
    repetition_penalty_range: "repeat_last_n",
    top_n_sigma: "top_n_sigma",
    dry_multiplier: "dry_multiplier",
    dry_base: "dry_base",
    dry_allowed_length: "dry_allowed_length",
    dry_penalty_last_n: "dry_penalty_last_n",
    dry_sequence_breakers: "dry_sequence_breakers",
    xtc_threshold: "xtc_threshold",
    xtc_probability: "xtc_probability",
    ignore_eos: "ignore_eos",
    dynatemp_exponent: "dynatemp_exponent",
    logit_bias: "logit_bias"
  }

  @impl true
  def label, do: "llama.cpp"

  @impl true
  def body(%SamplerParams{} = sampler) do
    values = SamplerParams.set_values(sampler)

    values
    |> SamplerDialect.pick(@names)
    |> put_dynatemp(values)
    |> SamplerDialect.put_samplers(values)
  end

  defp put_dynatemp(body, %{dynatemp_low: low, dynatemp_high: high}),
    do: Map.merge(body, %{"temperature" => (low + high) / 2, "dynatemp_range" => (high - low) / 2})

  defp put_dynatemp(body, _values), do: body

  @impl true
  def adjust_body(%{"response_format" => format} = body, :text) when not is_map_key(body, "json_schema") do
    case json_schema(format) do
      nil -> body
      schema -> body |> Map.delete("response_format") |> Map.put("json_schema", schema)
    end
  end

  def adjust_body(body, _mode), do: body

  defp json_schema(%{"type" => "json_schema", "json_schema" => %{"schema" => schema}}), do: schema
  defp json_schema(%{"type" => "json_object", "schema" => schema}), do: schema
  defp json_schema(%{"type" => "json_object"}), do: %{}
  defp json_schema(_format), do: nil
end
