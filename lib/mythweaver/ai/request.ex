defmodule Mythweaver.AI.Request do
  @moduledoc """
  The request an adapter's `complete/2` and `stream/3` receive: the behaviour's request contract
  (`Mythweaver.AI.Provider.Adapter`). `Mythweaver.AI` builds it from a model, a link and an input; an
  adapter only reads it.

  `messages` is set for `mode: :chat` and `prompt` for `mode: :text`; the other is `nil`. A request
  built for an embedding model carries `mode: :embedding`, which the adapter refuses as a completion.

  `stop` is every string that ends the reply, enforced by the adapter on the text it returns
  (`Mythweaver.AI.StopScanner`) whether or not the backend honored its wire `stop`: the model's own
  stop sequences plus the caller's (`Mythweaver.AI.stream/3`'s `:stop` input key).

  `session_id` groups a chat's requests (`"<user id>:<chat id>"`), or is `nil`; the adapter decides
  how it goes on the wire.

  `tools` are the functions a chat request offers the model, wire-ready OpenAI maps
  (`%{"type" => "function", "function" => %{"name", "description", "parameters"}}`); `[]` offers none.
  """

  alias Mythweaver.AI.Request.Message
  alias Mythweaver.AI.SamplerParams

  @enforce_keys [:model_id, :mode]
  defstruct [
    :model_id,
    :mode,
    :messages,
    :prompt,
    :sampler,
    :sampler_dialect,
    :reasoning_tags,
    :session_id,
    extra_body: %{},
    stop: [],
    tools: []
  ]

  @type t :: %__MODULE__{
          model_id: String.t(),
          mode: :chat | :text | :embedding,
          messages: [Message.t()] | nil,
          prompt: String.t() | nil,
          sampler: %SamplerParams{} | nil,
          sampler_dialect: atom() | nil,
          extra_body: map(),
          reasoning_tags: {String.t(), String.t()} | nil,
          stop: [String.t()],
          session_id: String.t() | nil,
          tools: [map()]
        }
end
