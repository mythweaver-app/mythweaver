defmodule Mythweaver.AI.ThinkingDialects.OpenRouter do
  @moduledoc """
  OpenRouter's unified `reasoning: {effort: …}` object.

  OpenRouter maps a level the routed model does not support onto the nearest supported one itself,
  and `"none"` disables reasoning, so every level is sent verbatim.
  """

  @behaviour Mythweaver.AI.Provider.ThinkingDialect

  use Gettext, backend: Mythweaver.Gettext

  @impl true
  def label, do: dpgettext("ai", "option: thinking dialect of an AI connection", "OpenRouter reasoning")

  @impl true
  def body(effort, _sampler), do: %{"reasoning" => %{"effort" => Atom.to_string(effort)}}
end
