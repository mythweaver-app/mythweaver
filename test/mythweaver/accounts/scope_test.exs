defmodule Mythweaver.Accounts.ScopeTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.Accounts.Scope

  test "authorize/2 refuses a user-less scope and admits a holder" do
    assert Scope.authorize(%Scope{}, "users.manage") == {:error, :unauthorized}
    assert Scope.authorize(scope!(), "users.manage") == :ok
    assert Scope.authorize(scope!(%{role: :user}), "users.manage") == {:error, :unauthorized}
  end

  test "owner?/1 follows the role" do
    assert Scope.owner?(scope!(%{role: :owner}))
    refute Scope.owner?(scope!(%{role: :admin})) or Scope.owner?(scope!(%{role: :user}))
  end
end
