defmodule Mythweaver.Assistant.Tools.ScriptsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Scripts

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp script!(scope, name, trigger, attrs \\ %{}) do
    {:ok, script} =
      Scripts.create_script(scope, Map.merge(%{"name" => name, "trigger" => trigger, "body" => "return nil"}, attrs))

    script
  end

  setup do
    %{scope: scope!(%{role: :user})}
  end

  test "create then a partial update keeps the other fields", %{scope: scope} do
    assert {:ok, %{"done" => [%{"id" => id, "trigger" => :user_message, "owner" => "personal", "path" => path}]}} =
             run!(scope, "create_scripts", %{
               "items" => [%{"name" => "Greet", "trigger" => "user_message", "body" => "return event.text"}]
             })

    assert path == "/scripts/#{id}/edit"

    assert {:ok, %{"done" => [%{"priority" => 5}]}} =
             run!(scope, "update_scripts", %{"items" => [%{"id" => id, "priority" => 5}]})

    assert %{name: "Greet", body: "return event.text", priority: 5} = Scripts.get_script(scope, id)
  end

  test "a dependency of another trigger is refused", %{scope: scope} do
    first = script!(scope, "First", "user_message")
    other = script!(scope, "Other", "ai_generation")

    assert {:error, %{"failed" => [%{"error" => "invalid", "fields" => %{dependency_ids: [_]}}]}} =
             run!(scope, "update_scripts", %{"items" => [%{"id" => other.id, "dependency_ids" => [first.id]}]})
  end

  test "list and get show dependencies; delete removes it", %{scope: scope} do
    first = script!(scope, "First", "user_message")
    second = script!(scope, "Second", "user_message", %{"dependency_ids" => [first.id]})

    assert {:ok, %{"scripts" => rows}} = run!(scope, "list_scripts", %{})
    assert %{"dependency_ids" => [first_id]} = Enum.find(rows, &(&1["id"] == second.id))
    assert first_id == first.id

    assert {:ok, %{"body" => "return nil", "dependencies" => [%{"name" => "First"}]}} =
             run!(scope, "get_script", %{"id" => second.id})

    assert {:ok, %{"done" => [%{"deleted" => true}]}} = run!(scope, "delete_scripts", %{"ids" => [second.id]})
    assert Scripts.get_script(scope, second.id) == nil
  end

  test "a non-UUID id gives an error map", %{scope: scope} do
    assert {:error, %{"error" => "id is not a valid id"}} = run!(scope, "get_script", %{"id" => "nope"})

    assert {:error, %{"failed" => [%{"error" => "id is not a valid id"}]}} =
             run!(scope, "update_scripts", %{"items" => [%{"id" => "nope"}]})

    assert {:error, %{"failed" => [%{"error" => "id is not a valid id"}]}} =
             run!(scope, "delete_scripts", %{"ids" => ["nope"]})
  end
end
