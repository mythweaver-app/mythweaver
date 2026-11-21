defmodule MythweaverWeb.MCPAuth do
  @moduledoc """
  Authenticates an MCP request by its `Authorization: Bearer <token>` header
  (`Mythweaver.MCP.authenticate/2`), assigning `current_scope` and `mcp_token`. A missing or
  unknown token gets 401; an account without `"mcp.use"`, suspended, or calling from a banned device
  or network gets 403. Each
  request records its IP and user agent among the account's fingerprints.
  """
  @behaviour Plug

  import Plug.Conn

  alias Mythweaver.MCP
  alias Mythweaver.Moderation.Fingerprints
  alias MythweaverWeb.Signals

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    signals = Signals.from_conn(conn, nil)

    conn
    |> bearer()
    |> MCP.authenticate(signals)
    |> case do
      {:ok, scope, token} ->
        :ok = Fingerprints.record(scope.user.id, signals)
        conn |> assign(:current_scope, scope) |> assign(:mcp_token, token)

      {:error, :banned} ->
        refuse(conn, 403, "This account or network is blocked.")

      {:error, :unauthorized} ->
        refuse(conn, 403, "MCP access is turned off for this account.")

      {:error, :invalid_token} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="Mythweaver"))
        |> refuse(401, "Missing or invalid MCP access token.")
    end
  end

  defp bearer(conn) do
    with [header | _] <- get_req_header(conn, "authorization"),
         [scheme, secret] <- String.split(String.trim(header), " ", parts: 2),
         "bearer" <- String.downcase(scheme) do
      String.trim(secret)
    else
      _ -> nil
    end
  end

  defp refuse(conn, status, message) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32_001, "message" => message}
    })
    |> halt()
  end
end
