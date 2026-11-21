defmodule Mythweaver.PermissionsTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Permissions
  alias Mythweaver.Permissions.Catalog
  alias Mythweaver.Permissions.Group
  alias Mythweaver.Repo

  defp group!(name) do
    Repo.insert!(Group.changeset(%Group{}, %{name: "#{name} #{System.unique_integer([:positive])}"}))
  end

  defp member!(group, scope) do
    :ok = Permissions.add_member!(group, scope.user)
    Scope.for_user(scope.user)
  end

  describe "effective/1 flags" do
    test "a user deny beats a group allow" do
      scope = scope!(%{role: :user})
      group = group!("Allow")
      :ok = Permissions.put_grant!(group, "users.manage", :allow)
      :ok = Permissions.put_grant!(scope.user, "users.manage", :deny)

      refute Scope.can?(member!(group, scope), "users.manage")
    end

    test "a user allow beats a group deny" do
      scope = scope!(%{role: :user})
      :ok = Permissions.put_grant!(:everyone, "users.manage", :deny)
      :ok = Permissions.put_grant!(scope.user, "users.manage", :allow)

      assert Scope.can?(Scope.for_user(scope.user), "users.manage")
    end

    test "any group deny beats any group allow" do
      scope = scope!(%{role: :user})
      allow = group!("Allow")
      deny = group!("Deny")
      :ok = Permissions.put_grant!(allow, "users.manage", :allow)
      :ok = Permissions.put_grant!(deny, "users.manage", :deny)
      member!(allow, scope)

      refute Scope.can?(member!(deny, scope), "users.manage")
    end

    test "unset everywhere is off" do
      refute Scope.can?(scope!(%{role: :user}), "users.manage")
    end

    test "an unknown key raises" do
      assert_raise ArgumentError, fn -> Scope.can?(scope!(%{role: :user}), "users.manag") end
    end
  end

  describe "effective/1 limits" do
    test "the most generous group wins; unlimited beats numbers" do
      scope = scope!(%{role: :user})
      five = group!("Five")
      ten = group!("Ten")
      :ok = Permissions.put_grant!(five, "quota.chats", 5)
      :ok = Permissions.put_grant!(ten, "quota.chats", 10)
      member!(five, scope)
      assert Scope.limit(member!(ten, scope), "quota.chats") == 10

      :ok = Permissions.put_grant!(:everyone, "quota.chats", :unlimited)
      assert Scope.limit(Scope.for_user(scope.user), "quota.chats") == :unlimited
    end

    test "a user value replaces the groups'" do
      scope = scope!(%{role: :user})
      ten = group!("Ten")
      :ok = Permissions.put_grant!(ten, "quota.chats", 10)
      :ok = Permissions.put_grant!(scope.user, "quota.chats", 3)

      assert Scope.limit(member!(ten, scope), "quota.chats") == 3
    end

    test "unset is unlimited" do
      assert Scope.limit(scope!(%{role: :user}), "quota.chats") == :unlimited
    end
  end

  test "an owner holds every flag and no limit, whatever the rows say" do
    owner = scope!(%{role: :owner})
    :ok = Permissions.put_grant!(owner.user, "users.manage", :deny)
    :ok = Permissions.put_grant!(owner.user, "quota.chats", 0)
    owner = Scope.for_user(owner.user)

    assert Enum.all?(Catalog.all(), fn
             %{kind: :flag, key: key} -> Scope.can?(owner, key)
             %{kind: :limit, key: key} -> Scope.limit(owner, key) == :unlimited
           end)
  end

  describe "creating content" do
    test "a user denied content.characters.create cannot create a character" do
      :ok = Permissions.put_grant!(:everyone, "content.characters.create", :deny)
      scope = scope!(%{role: :user})

      assert Characters.create_character(scope, %{"name" => "Ann"}) == {:error, :unauthorized}
    end

    test "an Administrators member creates their own rows, and site rows on request" do
      scope = scope!(%{role: :user})
      scope = member!(Permissions.system_group!(:administrators), scope)
      user_id = scope.user.id

      assert {:ok, %{user_id: ^user_id}} = Characters.create_character(scope, %{"name" => "Ann"})
      assert {:ok, %{user_id: nil}} = Characters.create_character(scope, %{"name" => "Bea"}, site: true)
    end
  end

  describe "management" do
    defp manager! do
      scope = scope!(%{role: :user})
      group = group!("Managers")
      :ok = Permissions.put_grant!(group, "groups.manage", :allow)
      {:ok, scope} = Mythweaver.Accounts.enter_sudo(member!(group, scope), "a long test password")
      scope
    end

    test "a manager cannot set a key it does not hold" do
      manager = manager!()
      target = group!("Target")

      assert Permissions.set_group_grants(manager, target, %{"site.ai.manage" => "allow"}) ==
               {:error, {:not_held, "site.ai.manage"}}

      assert {:ok, _} = Permissions.set_group_grants(manager, target, %{"groups.manage" => "deny"})
      assert %{"groups.manage" => %{effect: :deny}} = Permissions.grants_for(target)
    end

    test "a manager cannot change a group holding a key it lacks, nor its members" do
      manager = manager!()
      target = group!("Target")
      :ok = Permissions.put_grant!(target, "site.ai.manage", :allow)
      user = scope!(%{role: :user}).user

      assert Permissions.update_group(manager, target, %{"name" => "Renamed"}) ==
               {:error, {:not_held, "site.ai.manage"}}

      assert Permissions.set_group_members(manager, target, [user.id]) == {:error, {:not_held, "site.ai.manage"}}
      assert Permissions.set_user_groups(manager, user, [target.id]) == {:error, {:not_held, "site.ai.manage"}}
    end

    test "limits may be set only up to the manager's own" do
      manager = manager!()
      :ok = Permissions.put_grant!(manager.user, "quota.chats", 5)
      {:ok, manager} = Mythweaver.Accounts.enter_sudo(Scope.for_user(manager.user), "a long test password")
      target = group!("Target")

      assert {:ok, _} = Permissions.set_group_grants(manager, target, %{"quota.chats" => "5"})

      assert Permissions.set_group_grants(manager, target, %{"quota.chats" => "6"}) ==
               {:error, {:not_held, "quota.chats"}}

      assert Permissions.set_group_grants(manager, target, %{"quota.chats" => "unlimited"}) ==
               {:error, {:not_held, "quota.chats"}}
    end

    test "system groups are not deleted, and Everyone has no member list" do
      owner = scope!(%{role: :owner})
      {:ok, owner} = Mythweaver.Accounts.enter_sudo(owner, "a long test password")
      everyone = Permissions.system_group!(:everyone)

      assert Permissions.delete_group(owner, everyone) == {:error, :system_group}
      assert Permissions.delete_group(owner, Permissions.system_group!(:administrators)) == {:error, :system_group}
      assert Permissions.set_group_members(owner, everyone, []) == {:error, :system_group}
    end

    test "a non-owner cannot change an owner's grants or groups" do
      manager = manager!()
      owner = scope!(%{role: :owner}).user

      assert Permissions.set_user_grants(manager, owner, %{"groups.manage" => "deny"}) == {:error, :unauthorized}
      assert Permissions.set_user_groups(manager, owner, []) == {:error, :unauthorized}
    end

    test "groups and user grants resolve into the user's next scope" do
      manager = manager!()
      target = group!("Target")
      user = scope!(%{role: :user}).user

      assert {:ok, _} = Permissions.set_user_groups(manager, user, [target.id])
      assert {:ok, _} = Permissions.set_group_grants(manager, target, %{"groups.manage" => "allow"})
      assert Scope.can?(Scope.for_user(user), "groups.manage")

      assert {:ok, _} = Permissions.set_user_grants(manager, user, %{"groups.manage" => "deny"})
      refute Scope.can?(Scope.for_user(user), "groups.manage")
    end
  end
end
