defmodule Mythweaver.Assistant.Tools.CharactersTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Characters

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp character!(scope, name, attrs \\ %{}) do
    {:ok, character} = Characters.create_character(scope, Map.merge(%{name: name, description: "d"}, attrs))
    character
  end

  setup do
    %{scope: scope!(%{role: :user})}
  end

  test "create then partial update keeps other fields", %{scope: scope} do
    {:ok, %{"done" => [created]}} =
      run!(scope, "create_characters", %{"items" => [%{"name" => "Bob", "description" => "old"}]})

    assert %{"id" => id, "name" => "Bob", "path" => path} = created
    assert path == "/characters/#{id}/edit"
    assert Characters.get_character(scope, id).name == "Bob"

    {:ok, %{"done" => [updated]}} =
      run!(scope, "update_characters", %{"items" => [%{"id" => id, "description" => "new"}]})

    assert %{"name" => "Bob", "description" => "new"} = updated
    assert %{name: "Bob", description: "new"} = Characters.get_character(scope, id)
  end

  test "update_characters ignores user_id", %{scope: scope} do
    character = character!(scope, "Ann")
    other = scope!(%{role: :user})

    {:ok, _} =
      run!(scope, "update_characters", %{
        "items" => [%{"id" => character.id, "user_id" => other.user.id, "name" => "Ann 2"}]
      })

    assert Characters.get_character(scope, character.id).user_id == scope.user.id
  end

  test "a non-UUID id gives an error map", %{scope: scope} do
    assert {:error, %{"error" => "id is not a valid id"}} = run!(scope, "get_character", %{"id" => "nope"})

    assert {:error, %{"failed" => [%{"error" => "id is not a valid id"}]}} =
             run!(scope, "update_characters", %{"items" => [%{"id" => "nope", "name" => "x"}]})

    assert {:error, %{"failed" => [%{"error" => "id is not a valid id"}]}} =
             run!(scope, "delete_characters", %{"ids" => ["nope"]})
  end

  test "list filters by name case-insensitively", %{scope: scope} do
    character!(scope, "Lute Bard")
    character!(scope, "Knight")

    {:ok, %{"characters" => rows, "total" => 1}} = run!(scope, "list_characters", %{"query" => "bARD"})
    assert [%{"name" => "Lute Bard", "editable" => true, "owner" => "personal"}] = rows
  end

  test "delete removes the character", %{scope: scope} do
    character = character!(scope, "Gone")
    assert {:ok, %{"done" => [%{"deleted" => true}]}} = run!(scope, "delete_characters", %{"ids" => [character.id]})
    assert Characters.get_character(scope, character.id) == nil
  end

  test "avatar_updates_appearance is writable and nullable", %{scope: scope} do
    character = character!(scope, "Bob")

    {:ok, %{"done" => [_]}} =
      run!(scope, "update_characters", %{"items" => [%{"id" => character.id, "avatar_updates_appearance" => false}]})

    assert Characters.get_character(scope, character.id).avatar_updates_appearance == false

    {:ok, %{"done" => [_]}} =
      run!(scope, "update_characters", %{"items" => [%{"id" => character.id, "avatar_updates_appearance" => nil}]})

    assert Characters.get_character(scope, character.id).avatar_updates_appearance == nil
  end

  test "the card prompt fields are readable and writable", %{scope: scope} do
    character = character!(scope, "Bob")

    attrs = %{"system_prompt" => "Be Bob.", "post_history_instructions" => "Stay Bob.", "card_prompt_mode" => "add"}

    assert {:ok, %{"done" => [%{"system_prompt" => "Be Bob.", "card_prompt_mode" => :add}]}} =
             run!(scope, "update_characters", %{"items" => [Map.put(attrs, "id", character.id)]})

    assert %{system_prompt: "Be Bob.", post_history_instructions: "Stay Bob.", card_prompt_mode: :add} =
             Characters.get_character(scope, character.id)
  end

  test "a runtime-only site character's description and appearance reach only site.hidden.view holders",
       %{scope: scope} do
    admin = scope!(%{role: :admin})

    {:ok, secret} =
      Characters.create_character(
        admin,
        %{
          name: "Sphinx",
          description: "riddle answer",
          appearance: "lion body",
          system_prompt: "secret prompt",
          site_visibility: :runtime_only
        },
        site: true
      )

    assert {:ok, %{"description" => nil, "appearance" => nil, "system_prompt" => nil, "content_hidden" => true}} =
             run!(scope, "get_character", %{"id" => secret.id})

    {:ok, %{"characters" => rows}} = run!(scope, "list_characters", %{"query" => "Sphinx"})
    assert [%{"name" => "Sphinx", "description" => nil, "content_hidden" => true}] = rows

    assert {:ok, %{"description" => "riddle answer", "appearance" => "lion body"} = full} =
             run!(admin, "get_character", %{"id" => secret.id})

    refute Map.has_key?(full, "content_hidden")
  end
end
