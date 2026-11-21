defmodule MythweaverWeb.MCPServer do
  @moduledoc """
  The Model Context Protocol over JSON-RPC 2.0, one message at a time (`handle/3`): `initialize`,
  `ping`, `tools/list` and `tools/call` over `Mythweaver.MCP`'s catalog. Notifications and client
  responses get no reply. Stateless: no sessions, no server-to-client stream, so `MythweaverWeb.MCPController`
  answers every request with plain JSON.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.MCP
  alias Mythweaver.MCP.Token

  require Logger

  @versions ["2025-06-18", "2025-03-26"]

  # These call outside AI services.
  @external ~w(test_connection discover_models add_models test_link)
  @destructive ~w(delete_ remove_ unbind_ dismiss_ cancel_)

  @instructions "Mythweaver is a web app for AI role-play: characters, lore books and entries, " <>
                  "prompts, group chats, memory, variables, scripts and tags. These tools act as " <>
                  "the token's owner with that account's permissions. Read before you change " <>
                  "something; ids come from tool results. A path in a result is a link into the " <>
                  "app. API keys and moving rows between the site and a user are done in the app, " <>
                  "not here."

  @doc "The reply to one JSON-RPC message, or nil for a notification or a client response."
  @spec handle(Scope.t(), Token.t(), term()) :: map() | nil
  def handle(scope, token, %{"jsonrpc" => "2.0", "method" => method} = message) when is_binary(method) do
    if Map.has_key?(message, "id") do
      id = message["id"]

      case dispatch(scope, token, method, Map.get(message, "params") || %{}) do
        {:result, result} -> %{"jsonrpc" => "2.0", "id" => id, "result" => result}
        {:error, code, text} -> error(id, code, text)
      end
    end
  end

  def handle(_scope, _token, %{} = message)
      when not is_map_key(message, "method") and (is_map_key(message, "result") or is_map_key(message, "error")),
      do: nil

  def handle(_scope, _token, %{} = message), do: error(message["id"], -32_600, "Invalid Request")
  def handle(_scope, _token, _message), do: error(nil, -32_600, "Invalid Request")

  defp dispatch(_scope, _token, "initialize", params) do
    {:result,
     %{
       "protocolVersion" => negotiate(params["protocolVersion"]),
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{
         "name" => "mythweaver",
         "title" => "Mythweaver",
         "version" => to_string(Application.spec(:mythweaver, :vsn))
       },
       "instructions" => @instructions
     }}
  end

  defp dispatch(_scope, _token, "ping", _params), do: {:result, %{}}

  defp dispatch(_scope, token, "tools/list", _params),
    do: {:result, %{"tools" => Enum.map(MCP.tools(token), &tool_def/1)}}

  defp dispatch(scope, token, "tools/call", %{"name" => name} = params) when is_binary(name) do
    case MCP.call_tool(scope, token, name, params["arguments"] || %{}) do
      :unknown_tool -> {:error, -32_602, "Unknown tool: #{name}"}
      {:ok, result} -> {:result, content(result, false)}
      {:error, result} -> {:result, content(result, true)}
    end
  rescue
    e ->
      Logger.error(Exception.format(:error, e, __STACKTRACE__))
      {:error, -32_603, "Internal error"}
  end

  defp dispatch(_scope, _token, "tools/call", _params), do: {:error, -32_602, "Invalid params"}
  defp dispatch(_scope, _token, _method, _params), do: {:error, -32_601, "Method not found"}

  defp negotiate(version) when version in @versions, do: version
  defp negotiate(_version), do: hd(@versions)

  defp content(result, error?) do
    %{"content" => [%{"type" => "text", "text" => Jason.encode!(absolute(result))}], "isError" => error?}
  end

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp tool_def(%Tool{} = tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => tool.parameters,
      "annotations" => annotations(tool)
    }
  end

  # `destructiveHint` is explicit because MCP defaults it to true.
  defp annotations(%Tool{kind: :read} = tool), do: %{"readOnlyHint" => true, "openWorldHint" => tool.name in @external}

  defp annotations(%Tool{} = tool) do
    %{
      "readOnlyHint" => false,
      "destructiveHint" => String.starts_with?(tool.name, @destructive),
      "openWorldHint" => tool.name in @external
    }
  end

  # Results carry app-relative paths (`Mythweaver.Assistant.Paths`); outside the app they need
  # the host.
  defp absolute(%{} = map) do
    Map.new(map, fn
      {"path", "/" <> _ = path} -> {"path", MythweaverWeb.Endpoint.url() <> path}
      {key, value} -> {key, absolute(value)}
    end)
  end

  defp absolute(list) when is_list(list), do: Enum.map(list, &absolute/1)
  defp absolute(value), do: value
end
