defmodule Mythweaver.AI.ThinkingDialects.OpenAI do
  @moduledoc """
  Top-level `reasoning_effort` string, as OpenAI, xAI, DeepSeek, Fireworks and vLLM (gpt-oss
  templates) read it.

  Every level is sent verbatim, without remapping: a backend that rejects one returns its own HTTP
  400, which surfaces through the adapter's `{:http_error, …}` path.
  """

  @behaviour Mythweaver.AI.Provider.ThinkingDialect

  use Gettext, backend: Mythweaver.Gettext

  @impl true
  def label do
    gettext_comment("reasoning_effort is an API field name; keep it as is.")
    dpgettext("ai", "option: thinking dialect of an AI connection", "OpenAI reasoning_effort")
  end

  @impl true
  def body(effort, _sampler), do: %{"reasoning_effort" => Atom.to_string(effort)}
end
