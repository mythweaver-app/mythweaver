defmodule Mythweaver.MCP.Call do
  @moduledoc """
  One MCP tool call made with a token: the tool's name and whether it succeeded. Built in
  `Mythweaver.MCP.call_tool/4`; pruned after 90 days (`Mythweaver.MCP.prune_calls/0`).
  """
  use Mythweaver.Schema

  alias Mythweaver.Accounts.User
  alias Mythweaver.MCP.Token

  schema "mcp_calls" do
    field :tool, :string
    field :outcome, Ecto.Enum, values: [:ok, :error]

    belongs_to :token, Token
    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
