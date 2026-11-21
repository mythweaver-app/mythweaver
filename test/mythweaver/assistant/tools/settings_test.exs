defmodule Mythweaver.Assistant.Tools.SettingsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Settings

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  test "update_setting at the user level round-trips" do
    scope = scope!(%{role: :user})

    assert {:ok, %{"key" => "lore.case_sensitive", "value" => true}} =
             run!(scope, "update_setting", %{"key" => "lore.case_sensitive", "value" => true})

    assert Settings.get(scope, "lore.case_sensitive") == true

    assert {:ok, %{"settings" => rows}} = run!(scope, "list_settings", %{"category" => "lore"})
    assert %{"value" => true, "editable" => true} = Enum.find(rows, &(&1["key"] == "lore.case_sensitive"))
  end

  test "a non-admin may not change a site setting" do
    scope = scope!(%{role: :user})

    assert {:error, %{"error" => "You are not allowed to do that."}} =
             run!(scope, "update_setting", %{"key" => "lore.case_sensitive", "value" => true, "level" => "site"})

    assert {:ok, %{"settings" => [], "total" => 0}} = run!(scope, "list_settings", %{"level" => "site"})
  end

  test "an unknown key is refused" do
    assert {:error, %{"error" => "unknown setting"}} =
             run!(scope!(), "update_setting", %{"key" => "no.such.key", "value" => 1})
  end

  test "a bad value passes the setting's message through" do
    assert {:error, %{"error" => "must be true or false"}} =
             run!(scope!(), "update_setting", %{"key" => "lore.case_sensitive", "value" => "maybe"})
  end

  test "lock_settings locks a key for an admin, unlocks it, and refuses a non-admin" do
    admin = scope!()
    user = scope!(%{role: :user})

    assert {:ok, %{"done" => [%{"key" => "lore.case_sensitive", "locked" => true}]}} =
             run!(admin, "lock_settings", %{"items" => [%{"key" => "lore.case_sensitive", "locked" => true}]})

    assert {:ok, %{"settings" => rows}} = run!(user, "list_settings", %{"category" => "lore"})
    assert %{"locked" => true, "editable" => false} = Enum.find(rows, &(&1["key"] == "lore.case_sensitive"))

    assert {:error, %{"failed" => [%{"error" => "You are not allowed to do that."}]}} =
             run!(user, "lock_settings", %{"items" => [%{"key" => "lore.case_sensitive", "locked" => false}]})

    assert {:ok, %{"done" => [%{"locked" => false}]}} =
             run!(admin, "lock_settings", %{"items" => [%{"key" => "lore.case_sensitive", "locked" => false}]})
  end

  test "lock_settings refuses an unknown key" do
    assert {:error, %{"failed" => [%{"error" => "unknown setting"}]}} =
             run!(scope!(), "lock_settings", %{"items" => [%{"key" => "no.such.key", "locked" => true}]})
  end
end
