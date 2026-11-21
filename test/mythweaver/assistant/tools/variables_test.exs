defmodule Mythweaver.Assistant.Tools.VariablesTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Variables

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp chat!(scope) do
    {:ok, a} = Characters.create_character(scope, %{name: "A", description: "d"})
    {:ok, b} = Characters.create_character(scope, %{name: "B", description: "d"})

    {:ok, chat} =
      Chats.create_chat(scope, %{"participants" => [%{"character_id" => a.id}, %{"character_id" => b.id}]})

    chat
  end

  setup do
    %{scope: scope!(%{role: :user})}
  end

  test "create a global and a chat variable; list keeps them apart", %{scope: scope} do
    chat = chat!(scope)

    assert {:ok, %{"done" => [%{"id" => global_id, "scope" => "global", "value" => "calm"}, %{"scope" => "chat"}]}} =
             run!(scope, "create_variables", %{
               "items" => [
                 %{"key" => "mood", "value" => "calm"},
                 %{"key" => "turn", "value" => 1, "chat_id" => chat.id}
               ]
             })

    assert Variables.get_editable_variable(scope, global_id).key == "mood"

    assert {:ok, %{"variables" => [%{"key" => "mood"}]}} = run!(scope, "list_variables", %{})

    assert {:ok, %{"variables" => [%{"key" => "turn", "value" => 1}]}} =
             run!(scope, "list_variables", %{"chat_id" => chat.id})
  end

  test "update changes only the given fields, and delete removes it", %{scope: scope} do
    {:ok, variable} = Variables.create_variable(scope, nil, %{"key" => "mood", "value" => "calm"})

    assert {:ok, %{"done" => [%{"key" => "mood", "value" => %{"level" => 3}}]}} =
             run!(scope, "update_variables", %{"items" => [%{"id" => variable.id, "value" => %{"level" => 3}}]})

    assert {:ok, %{"key" => "mood"}} = run!(scope, "get_variable", %{"id" => variable.id})

    assert {:ok, %{"done" => [%{"deleted" => true}]}} = run!(scope, "delete_variables", %{"ids" => [variable.id]})
    assert Variables.get_editable_variable(scope, variable.id) == nil
  end

  test "another user's chat is not found and a non-UUID id is an error map", %{scope: scope} do
    chat = chat!(scope)
    other = scope!(%{role: :user})

    assert {:error, %{"failed" => [%{"error" => "Not found."}]}} =
             run!(other, "create_variables", %{"items" => [%{"chat_id" => chat.id, "key" => "x", "value" => 1}]})

    assert {:error, %{"error" => "id is not a valid id"}} = run!(scope, "get_variable", %{"id" => "nope"})

    assert {:error, %{"failed" => [%{"error" => "id is not a valid id"}]}} =
             run!(scope, "delete_variables", %{"ids" => ["nope"]})
  end
end
