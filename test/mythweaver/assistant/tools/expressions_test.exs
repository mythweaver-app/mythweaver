defmodule Mythweaver.Assistant.Tools.ExpressionsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Characters
  alias Mythweaver.Expressions

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name, description: "d"})
    character
  end

  setup do
    %{scope: scope!(%{role: :user})}
  end

  describe "profiles" do
    test "create, partial update and delete", %{scope: scope} do
      rule = %{"name" => "smug", "kind" => "combination", "conditions" => [%{"label" => "joy"}, %{"label" => "pride"}]}

      assert {:ok,
              %{"done" => [%{"id" => id, "name" => "P1", "rules" => [%{"name" => "smug", "kind" => "combination"}]}]}} =
               run!(scope, "create_expression_profiles", %{"items" => [%{"name" => "P1", "rules" => [rule]}]})

      assert {:ok, %{"done" => [%{"name" => "Renamed", "rules" => [%{"name" => "smug"}]}]}} =
               run!(scope, "update_expression_profiles", %{"items" => [%{"id" => id, "name" => "Renamed"}]})

      assert {:ok, %{"expression_profiles" => [%{"id" => ^id, "rule_count" => 1, "editable" => true}]}} =
               run!(scope, "list_expression_profiles", %{"query" => "renamed"})

      assert {:ok, %{"done" => [%{"deleted" => true}]}} = run!(scope, "delete_expression_profiles", %{"ids" => [id]})
      assert Expressions.get_profile(scope, id) == nil
    end

    test "a combination rule needs two different emotions", %{scope: scope} do
      rule = %{"name" => "smug", "kind" => "combination", "conditions" => [%{"label" => "joy"}]}

      assert {:error, %{"failed" => [%{"error" => "invalid", "fields" => %{rules: _}}]}} =
               run!(scope, "create_expression_profiles", %{"items" => [%{"name" => "Bad", "rules" => [rule]}]})
    end
  end

  test "outfits: create, list, refuse another user's, delete", %{scope: scope} do
    character = character!(scope, "Bob")

    assert {:ok, %{"done" => [%{"id" => id, "position" => 0}]}} =
             run!(scope, "create_character_outfits", %{
               "items" => [%{"character_id" => character.id, "name" => "Armor"}]
             })

    assert {:ok, %{"outfits" => [%{"id" => ^id, "name" => "Armor"}]}} =
             run!(scope, "list_character_outfits", %{"character_id" => character.id})

    assert {:error, %{"failed" => [%{"error" => "Not found."}]}} =
             run!(scope!(%{role: :user}), "delete_character_outfits", %{"ids" => [id]})

    assert {:ok, %{"done" => [%{"deleted" => true}]}} = run!(scope, "delete_character_outfits", %{"ids" => [id]})
    assert {:ok, %{"outfits" => []}} = run!(scope, "list_character_outfits", %{"character_id" => character.id})

    assert {:ok, %{"sprites" => [], "total" => 0}} =
             run!(scope, "list_character_sprites", %{"character_id" => character.id})
  end

  test "update_character_expression_settings sets labels and refuses another owner's profile", %{scope: scope} do
    character = character!(scope, "Bob")

    assert {:ok, %{"done" => [%{"expression_labels" => ["smug"], "fallback_expression" => "smug"}]}} =
             run!(scope, "update_character_expression_settings", %{
               "items" => [%{"id" => character.id, "expression_labels" => ["smug"], "fallback_expression" => "smug"}]
             })

    assert Characters.get_character(scope, character.id).expression_labels == ["smug"]

    {:ok, theirs} = Expressions.create_profile(scope!(%{role: :user}), %{name: "Theirs"})

    assert {:error,
            %{
              "failed" => [
                %{"error" => "invalid", "fields" => %{expression_profile_id: ["is not available to this character"]}}
              ]
            }} =
             run!(scope, "update_character_expression_settings", %{
               "items" => [%{"id" => character.id, "expression_profile_id" => theirs.id}]
             })
  end
end
