defmodule MythweaverWeb.MCPController do
  @moduledoc """
  The MCP Streamable HTTP endpoint, stateless with JSON replies: a POST carries one JSON-RPC
  message or a batch (`MythweaverWeb.MCPServer`); a request holding only notifications or
  responses gets 202. GET and DELETE are 405: no server-to-client stream, no sessions.
  `MythweaverWeb.MCPAuth` has already authenticated the request.
  """
  use MythweaverWeb, :controller

  alias MythweaverWeb.MCPServer

  def handle(conn, _params) do
    %{current_scope: scope, mcp_token: token} = conn.assigns

    case conn.body_params do
      %{"_json" => [_ | _] = messages} ->
        case Enum.flat_map(messages, &List.wrap(MCPServer.handle(scope, token, &1))) do
          [] -> send_resp(conn, 202, "")
          responses -> json(conn, responses)
        end

      %{"_json" => _} ->
        invalid(conn)

      %{} = message when map_size(message) > 0 ->
        case MCPServer.handle(scope, token, message) do
          nil -> send_resp(conn, 202, "")
          response -> json(conn, response)
        end

      _ ->
        invalid(conn)
    end
  end

  def not_allowed(conn, _params) do
    conn |> put_resp_header("allow", "POST") |> send_resp(405, "")
  end

  defp invalid(conn) do
    conn
    |> put_status(400)
    |> json(%{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32_600, "message" => "Invalid Request"}
    })
  end
end
