defmodule Mythweaver.MCPTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters.Character
  alias Mythweaver.MCP
  alias Mythweaver.MCP.Call
  alias Mythweaver.MCP.Token
  alias Mythweaver.Moderation.Fingerprints
  alias Mythweaver.Moderation.Sanctions
  alias Mythweaver.Permissions

  defp token!(scope, attrs \\ %{}) do
    attrs = Map.merge(%{"name" => "T-#{System.unique_integer([:positive])}", "access" => "full"}, attrs)
    {:ok, token, secret} = MCP.create_token(scope, attrs)
    {token, secret}
  end

  describe "tokens" do
    test "a created token authenticates as its owner and records its use" do
      scope = scope!(%{role: :user})
      user_id = scope.user.id

      assert {:ok, %Token{name: "Laptop", access: :full, last_used_at: nil} = token, "mwp_" <> _ = secret} =
               MCP.create_token(scope, %{"name" => " Laptop ", "access" => "full"})

      assert {:ok, %Scope{user: %{id: ^user_id}, sudo_until: nil}, %Token{}} = MCP.authenticate(secret, %{})
      assert Repo.get!(Token, token.id).last_used_at

      assert {:error, changeset} = MCP.create_token(scope, %{"name" => "Laptop", "access" => "read_only"})
      assert %{name: [_]} = errors_on(changeset)
    end

    test "creating a token needs sudo" do
      # Two users, so the install is not an auto-login one (which is always in sudo).
      _other = scope!(%{role: :user})
      scope = scope!(%{role: :user})

      assert {:error, :sudo_required} = MCP.create_token(%{scope | sudo_until: nil}, %{"name" => "X"})
      assert MCP.list_tokens(scope) == []
    end

    test "denying mcp.use refuses new tokens and stops existing ones" do
      scope = scope!(%{role: :user})
      {_token, secret} = token!(scope)

      Permissions.put_grant!(scope.user, "mcp.use", :deny)
      scope = sudo(Scope.for_user(scope.user))

      assert {:error, :unauthorized} = MCP.create_token(scope, %{"name" => "Another"})
      assert {:error, :unauthorized} = MCP.authenticate(secret, %{})
    end

    test "unknown, malformed and revoked secrets are refused" do
      scope = scope!(%{role: :user})
      other = scope!(%{role: :user})
      {token, secret} = token!(scope)

      assert {:error, :invalid_token} = MCP.authenticate("mwp_nope", %{})
      assert {:error, :invalid_token} = MCP.authenticate(nil, %{})

      assert {:error, :not_found} = MCP.revoke_token(other, token.id)
      assert {:error, :not_found} = MCP.revoke_token(scope, "not-a-uuid")
      assert {:ok, _scope, _token} = MCP.authenticate(secret, %{})

      assert {:ok, _} = MCP.revoke_token(scope, token.id)
      assert {:error, :invalid_token} = MCP.authenticate(secret, %{})
    end
  end

  describe "site access" do
    test "only a :site token keeps site permissions and the owner role" do
      owner = scope!(%{role: :owner})
      {_full, full_secret} = token!(owner, %{"access" => "full"})
      {_site, site_secret} = token!(owner, %{"access" => "site"})

      assert {:ok, scope, _} = MCP.authenticate(full_secret, %{})
      refute Scope.can?(scope, "site.ai.manage")
      refute Scope.owner?(scope)
      assert Scope.can?(scope, "mcp.use")

      assert {:ok, scope, _} = MCP.authenticate(site_secret, %{})
      assert Scope.can?(scope, "site.ai.manage")
      assert Scope.owner?(scope)
    end

    test "a user without site permissions cannot create a :site token" do
      scope = scope!(%{role: :user})

      assert {:error, changeset} = MCP.create_token(scope, %{"name" => "Site", "access" => "site"})
      assert %{access: [_]} = errors_on(changeset)
    end
  end

  describe "call log" do
    test "a known tool call is logged" do
      scope = scope!(%{role: :user})
      {token, _} = token!(scope, %{"access" => "read_only"})

      assert {:ok, _} = MCP.call_tool(scope, token, "list_characters", %{})

      assert [%Call{tool: "list_characters", outcome: :ok}] = Repo.all(Call)
      assert %{} = calls = MCP.list_calls(scope, [token.id])
      assert [%Call{}] = calls[token.id]
    end

    test "lists at most 20 calls per token, newest first" do
      scope = scope!(%{role: :user})
      {busy, _} = token!(scope)
      {quiet, _} = token!(scope)
      now = DateTime.utc_now(:second)

      calls =
        for {token, n} <- [{busy, 25}, {quiet, 2}], i <- 1..n do
          %{
            id: Mythweaver.Schema.generate_id(),
            token_id: token.id,
            user_id: scope.user.id,
            tool: "t#{i}",
            outcome: :ok,
            inserted_at: DateTime.add(now, -i, :minute)
          }
        end

      Repo.insert_all(Call, calls)
      listed = MCP.list_calls(scope, [busy.id, quiet.id])

      assert Enum.map(listed[busy.id], & &1.tool) == Enum.map(1..20, &"t#{&1}")
      assert Enum.map(listed[quiet.id], & &1.tool) == ["t1", "t2"]
    end
  end

  describe "bans" do
    test "a banned IP is refused, another IP is not" do
      scope = scope!(%{role: :user})
      {_token, secret} = token!(scope)
      :ok = Fingerprints.record(scope.user.id, %{ip: "203.0.113.9"})

      {:ok, _} =
        Sanctions.ban(scope!(), scope.user, %{
          "reason" => "x",
          "duration" => "7d",
          "values" => ["ip:203.0.113.9"]
        })

      assert MCP.authenticate(secret, %{ip: "203.0.113.9"}) == {:error, :banned}
      assert {:ok, _, _} = MCP.authenticate(secret, %{ip: "198.51.100.1"})
    end
  end

  describe "tools" do
    test "a read-only token sees and runs only reading tools" do
      scope = scope!(%{role: :user})
      {read_only, _} = token!(scope, %{"access" => "read_only"})
      {full, _} = token!(scope, %{"access" => "full"})

      read_tools = MCP.tools(read_only)
      assert Enum.all?(read_tools, &(&1.kind == :read))
      read_names = Enum.map(read_tools, & &1.name)
      full_names = Enum.map(MCP.tools(full), & &1.name)

      assert "list_characters" in read_names
      refute "create_characters" in read_names
      assert "create_characters" in full_names

      for name <- ~w(read_tool_result request_api_key transfer_lore_books transfer_connections transfer_models) do
        refute name in read_names
        refute name in full_names
      end

      assert :unknown_tool =
               MCP.call_tool(scope, read_only, "create_characters", %{"items" => [%{"name" => "X"}]})

      refute Repo.get_by(Character, name: "X")
    end

    test "arguments must be an object" do
      scope = scope!(%{role: :user})
      {full, _} = token!(scope)

      assert {:error, %{"error" => "arguments must be an object"}} =
               MCP.call_tool(scope, full, "list_characters", ["nope"])
    end
  end
end
