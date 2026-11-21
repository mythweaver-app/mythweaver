defmodule Mythweaver.Assistant.Tool do
  @moduledoc """
  One function the Mythweaver assistant may call.

  `parameters` is a JSON Schema object with string keys (its `"required"` list is checked by
  `Mythweaver.Assistant.Tools.run/3`). `kind` decides what happens when the model calls it:

    * `:read` runs at once
    * `:write` waits for the user's Approve/Reject
    * `:input` opens a form card the user fills in (what they enter never passes through the model)

  `summary` is the one-line human text on the call's card; `run` does the work as the chat owner's
  scope and returns a JSON-encodable map either way. An `:input` tool's `run` only checks its
  arguments: an error fails the call instead of opening the card. `preview` (optional) lists what
  a pending call would touch, one line per row, read as the user's scope while the card waits for
  approval: the batch tools (`Mythweaver.Assistant.Tools.Batch`) name every row there, since
  their summary only counts them.
  """

  alias Mythweaver.Accounts.Scope

  @enforce_keys [:name, :description, :parameters, :kind, :summary, :run]
  defstruct [:name, :description, :parameters, :kind, :summary, :run, :preview]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          kind: :read | :write | :input,
          summary: (map() -> String.t()),
          run: (Scope.t(), map() -> {:ok, map()} | {:error, map()}),
          preview: (Scope.t(), map() -> [String.t()]) | nil
        }

  @doc "The OpenAI `tools` entry for the tool."
  @spec wire(t()) :: map()
  def wire(%__MODULE__{} = tool) do
    %{
      "type" => "function",
      "function" => %{"name" => tool.name, "description" => tool.description, "parameters" => tool.parameters}
    }
  end
end
