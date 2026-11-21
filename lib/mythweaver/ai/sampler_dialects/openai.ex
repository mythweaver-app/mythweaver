defmodule Mythweaver.AI.SamplerDialects.OpenAI do
  @moduledoc """
  OpenAI itself, strictly: only the sampler parameters OpenAI's API accepts, since it rejects unknown
  body keys. Logit bias keeps token-id keys only, with `false` (ban) sent as -100.
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
    stop_sequences: "stop"
  }

  @impl true
  def label, do: dpgettext("ai", "option: sampler dialect of an AI connection", "OpenAI (strict)")

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
