defmodule Mythweaver.AI.Completion do
  @moduledoc """
  One provider response, normalized across adapters.

  `cost` is the provider's own charge for this request when it reports one (OpenRouter returns
  `usage.cost`); it is `nil` for backends that do not, and is never computed from token pricing, so
  a theoretical figure is never mistaken for a real charge.

  `reasoning` exists because a thinking model truncated by `max_tokens` returns `content: ""` with
  the whole answer in `reasoning_content`; discarding it would look like an empty response.

  `model` is whatever the API echoed. llama.cpp echoes a `.gguf` filesystem path, not the requested
  id, so it is kept verbatim for diagnostics and never treated as a model id.

  `tool_calls` are the function calls a streamed chat reply made, in index order, typed like
  `Mythweaver.AI.Request.Message.tool_calls`; `[]` when it made none.
  """

  defstruct [
    :text,
    :reasoning,
    :finish_reason,
    :model,
    :prompt_tokens,
    :completion_tokens,
    :total_tokens,
    :cost,
    :raw,
    tool_calls: []
  ]

  @type t :: %__MODULE__{}
end
