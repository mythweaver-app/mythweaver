defmodule Mythweaver.Assistant.ToolCall do
  @moduledoc """
  One tool call an assistant reply (`message`) made, in reply order (`position`).

  `call_id` is the id the model gave the call (or `text_<n>` under the text protocol), echoed back
  with its result. `arguments` is the decoded JSON object; `result` the JSON object the tool
  returned (an `"error"` key on failure).

  `status`:

    * `:pending`: a write tool waiting for the user's approval
    * `:awaiting_input`: the `request_api_key` card is open
    * `:running`: claimed by a decision
    * `:succeeded`, `:failed`, `:rejected`: terminal

  Every field is set by `Mythweaver.Assistant`; nothing is cast.
  """

  use Mythweaver.Schema

  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages.Message

  @type t :: %__MODULE__{}

  @statuses [:pending, :awaiting_input, :running, :succeeded, :failed, :rejected]
  @terminal [:succeeded, :failed, :rejected]

  schema "assistant_tool_calls" do
    field :position, :integer
    field :call_id, :string
    field :name, :string
    field :arguments, :map, default: %{}
    field :status, Ecto.Enum, values: @statuses
    field :result, :map
    field :error, :string

    belongs_to :chat, Chat
    belongs_to :message, Message

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The statuses no decision changes any more."
  def terminal_statuses, do: @terminal

  @doc "Whether the call is finished."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  @doc "The JSON text the model reads as the call's result, before any cut."
  @spec result_json(t()) :: String.t()
  def result_json(%__MODULE__{} = call), do: Jason.encode!(call.result || %{"error" => call.error})
end
