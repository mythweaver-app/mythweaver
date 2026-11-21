defmodule Mythweaver.AI.Embedding do
  @moduledoc """
  One embedding response: `vectors` in input order, each a list of floats, and `usage`, the raw
  `"usage"` map the backend reported (`%{}` when absent).
  """

  @type t :: %__MODULE__{vectors: [[float()]], usage: map()}

  defstruct vectors: [], usage: %{}
end
