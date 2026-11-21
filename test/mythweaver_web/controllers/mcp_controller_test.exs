defmodule MythweaverWeb.MCPControllerTest do
  use MythweaverWeb.ConnCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters.Character
  alias Mythweaver.MCP
  alias Mythweaver.Moderation.Fingerprints
  alias Mythweaver.Moderation.Sanctions
  alias Mythweaver.Permissions
  alias Mythweaver.Repo

  setup do
    user = register_user!(%{role: :user})
    scope = Mythweaver.DataCase.sudo(Scope.for_user(user))
    %{user: user, scope: scope}
  end

  defp secret!(scope, access) do
    {:ok, _token, secret} =
      MCP.create_token(scope, %{"name" => "T-#{System.unique_integer([:positive])}", "access" => access})

    secret
  end

  defp rpc(conn, secret, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> secret)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post(~p"/mcp", Jason.encode!(body))
  end

  defp call(id, method, params \\ %{}), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp tool_text(response), do: response |> get_in(["result", "content"]) |> hd() |> Map.fetch!("text")

  test "initialize negotiates the protocol version", %{conn: conn, scope: scope} do
    secret = secret!(scope, "read_only")

    response =
      conn |> rpc(secret, call(1, "initialize", %{"protocolVersion" => "2025-03-26"})) |> json_response(200)

    assert %{"id" => 1, "result" => result} = response
    assert result["protocolVersion"] == "2025-03-26"
    assert result["capabilities"]["tools"]
    assert result["serverInfo"]["name"] == "mythweaver"

    response =
      build_conn()
      |> rpc(secret, call(2, "initialize", %{"protocolVersion" => "1999-01-01"}))
      |> json_response(200)

    assert response["result"]["protocolVersion"] == "2025-06-18"
  end

  test "a notification gets 202 and no body", %{conn: conn, scope: scope} do
    conn = rpc(conn, secret!(scope, "full"), %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    assert conn.status == 202
    assert conn.resp_body == ""
  end

  test "tools/list annotates by kind and access", %{conn: conn, scope: scope} do
    read_tools =
      conn
      |> rpc(secret!(scope, "read_only"), call(1, "tools/list"))
      |> json_response(200)
      |> get_in(["result", "tools"])

    assert read_tools != []
    assert Enum.all?(read_tools, &(&1["annotations"]["readOnlyHint"] == true))

    full_tools =
      build_conn()
      |> rpc(secret!(scope, "full"), call(1, "tools/list"))
      |> json_response(200)
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    assert full_tools["delete_characters"]["annotations"]["destructiveHint"] == true
    assert full_tools["create_characters"]["annotations"]["destructiveHint"] == false
    assert Enum.all?(Map.values(full_tools), &(&1["inputSchema"]["type"] == "object"))
  end

  test "tools/call runs a write tool and returns absolute paths", %{conn: conn, scope: scope, user: user} do
    args = %{"items" => [%{"name" => "Remote Bob"}]}

    response =
      conn
      |> rpc(secret!(scope, "full"), call(7, "tools/call", %{"name" => "create_characters", "arguments" => args}))
      |> json_response(200)

    assert response["result"]["isError"] == false
    character = Repo.get_by!(Character, name: "Remote Bob")
    assert character.user_id == user.id

    assert [%{"path" => path} | _] = response |> tool_text() |> Jason.decode!() |> Map.fetch!("done")
    assert path == MythweaverWeb.Endpoint.url() <> "/characters/#{character.id}/edit"
  end

  test "tool errors, unknown tools and unknown methods", %{conn: conn, scope: scope} do
    secret = secret!(scope, "full")

    response =
      conn
      |> rpc(secret, call(1, "tools/call", %{"name" => "get_character", "arguments" => %{"id" => "nope"}}))
      |> json_response(200)

    assert response["result"]["isError"] == true
    assert tool_text(response) =~ "id is not a valid id"

    response =
      build_conn() |> rpc(secret, call(2, "tools/call", %{"name" => "no_such_tool"})) |> json_response(200)

    assert response["error"]["code"] == -32_602

    response = build_conn() |> rpc(secret, call(3, "frobnicate")) |> json_response(200)
    assert response["error"]["code"] == -32_601
  end

  test "a batch answers only its requests", %{conn: conn, scope: scope} do
    body = [call(9, "ping"), %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}]

    assert [%{"id" => 9, "result" => %{}}] =
             conn |> rpc(secret!(scope, "read_only"), body) |> json_response(200)
  end

  test "authentication and methods", %{conn: conn, scope: scope, user: user} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/mcp", Jason.encode!(call(1, "ping")))

    assert json_response(conn, 401)["error"]["code"] == -32_001
    assert [_] = get_resp_header(conn, "www-authenticate")

    secret = secret!(scope, "full")

    conn = build_conn() |> put_req_header("authorization", "Bearer " <> secret) |> get(~p"/mcp")
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["POST"]

    Permissions.put_grant!(user, "mcp.use", :deny)
    assert build_conn() |> rpc(secret, call(1, "ping")) |> json_response(403)
  end

  describe "bans" do
    setup do
      %{moderator: Mythweaver.DataCase.sudo(Scope.for_user(register_user!()))}
    end

    test "an account ban refuses the token", %{conn: conn, scope: scope, user: user, moderator: moderator} do
      secret = secret!(scope, "full")

      {:ok, _} =
        Sanctions.ban(moderator, user, %{"reason" => "x", "duration" => "7d", "account" => "true"})

      assert json_response(rpc(conn, secret, call(1, "tools/list")), 403)["error"]["message"] ==
               "This account or network is blocked."
    end

    test "a banned forwarded IP is refused", %{conn: conn, scope: scope, user: user, moderator: moderator} do
      secret = secret!(scope, "full")
      :ok = Fingerprints.record(user.id, %{ip: "203.0.113.9"})

      {:ok, _} =
        Sanctions.ban(moderator, user, %{
          "reason" => "x",
          "duration" => "7d",
          "values" => ["ip:203.0.113.9"]
        })

      conn = conn |> put_req_header("x-forwarded-for", "203.0.113.9") |> rpc(secret, call(1, "tools/list"))
      assert json_response(conn, 403)["error"]["message"] == "This account or network is blocked."
    end
  end
end
