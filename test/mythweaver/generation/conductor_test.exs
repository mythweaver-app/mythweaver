defmodule Mythweaver.Generation.ConductorTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Generation.Conductor
  alias Mythweaver.Permissions.Member

  describe "fresh_scope/1" do
    test "a stored scope takes the user's current permissions, and is gone with the user" do
      stored = scope!()
      assert Scope.can?(stored, "users.manage")

      Repo.delete_all(from(m in Member, where: m.user_id == ^stored.user.id))

      fresh = Conductor.fresh_scope(stored)
      assert fresh.user.id == stored.user.id
      refute Scope.can?(fresh, "users.manage")

      Repo.delete!(Repo.get!(User, stored.user.id))
      assert Conductor.fresh_scope(stored) == nil
      assert Conductor.fresh_scope(nil) == nil
    end
  end
end
