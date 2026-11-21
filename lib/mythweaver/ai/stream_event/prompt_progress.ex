defmodule Mythweaver.AI.StreamEvent.PromptProgress do
  @moduledoc """
  Prompt processing so far: `done` of the `total` prompt tokens this request must process, prompt
  cache hits excluded. Optional; see `Mythweaver.AI.Provider.Adapter`, "Progress contract".
  """

  @enforce_keys [:done, :total]
  defstruct [:done, :total]

  @type t :: %__MODULE__{done: non_neg_integer(), total: pos_integer()}
end
