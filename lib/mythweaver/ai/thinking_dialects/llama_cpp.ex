defmodule Mythweaver.AI.ThinkingDialects.LlamaCpp do
  @moduledoc """
  llama.cpp server: `reasoning_effort` plus a `reasoning_budget_tokens` cap derived from `max_tokens`.

  `"none"` disables reasoning outright. Any other level sends both halves:

  - `reasoning_effort` is forwarded to the chat template, which is what drives gpt-oss templates.
  - `reasoning_budget_tokens` caps templates that ignore the effort string (Gemma 4, Qwen), using
    OpenRouter's effort-to-budget ratios of `max_tokens`. Without a `max_tokens` there is nothing to
    take a ratio of, so the budget stays unrestricted.
  """

  @behaviour Mythweaver.AI.Provider.ThinkingDialect

  @budget_ratios %{minimal: 0.1, low: 0.2, medium: 0.5, high: 0.8, xhigh: 0.95, max: 0.95}

  @impl true
  def label, do: "llama.cpp"

  @impl true
  def body(:none, _sampler), do: %{"reasoning_effort" => "none"}

  def body(effort, sampler) do
    # The effort string drives templates that read it (gpt-oss) ...
    base = %{"reasoning_effort" => Atom.to_string(effort)}

    # ... and the budget caps the ones that ignore it (Gemma 4, Qwen). Floored at 1: llama.cpp treats
    # a budget of 0 as "end immediately", which would turn :minimal with a small max_tokens into off.
    case sampler.max_tokens do
      max_tokens when is_integer(max_tokens) ->
        budget = max(floor(max_tokens * Map.fetch!(@budget_ratios, effort)), 1)
        Map.put(base, "reasoning_budget_tokens", budget)

      nil ->
        base
    end
  end
end
