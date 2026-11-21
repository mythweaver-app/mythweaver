defmodule Mythweaver.AI.EmbeddingRequest do
  @moduledoc """
  One embedding request handed to an adapter: `model_id` is the wire model id, `input` the texts to
  embed, and `extra_body` merged under the request's own keys.
  """

  @type t :: %__MODULE__{model_id: String.t(), input: [String.t()], extra_body: map()}

  @enforce_keys [:model_id, :input]
  defstruct [:model_id, :input, extra_body: %{}]
end
