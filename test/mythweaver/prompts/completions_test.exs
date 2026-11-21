defmodule Mythweaver.Prompts.CompletionsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Completions
  alias Mythweaver.Variables

  setup do
    %{scope: scope!()}
  end

  test "builds the anchor tree without nil detail or info keys", %{scope: scope} do
    data = Completions.template(scope)

    assert %{type: "namespace"} = find(data.properties["anchors"], "character")
    assert %{detail: "string | nil"} = find(data.properties["anchors.character"], "name")
    assert %{detail: "bool"} = find(data.properties["anchors.chat.members.[]"], "muted")

    options =
      data.variables ++ data.tags ++ data.filters ++ Enum.flat_map(data.properties, &elem(&1, 1))

    for option <- options, key <- [:info, :detail], Map.has_key?(option, key) do
      assert is_binary(option[key]), "#{option.label} has non-string #{key}"
    end
  end

  test "scopes vars to the chat with global fallback", %{scope: scope} do
    chat = chat!(scope)
    {:ok, _} = Variables.create_variable(scope, nil, %{key: "mood", value: "calm"})
    {:ok, _} = Variables.create_variable(scope, nil, %{key: "hp", value: 1})
    {:ok, _} = Variables.create_variable(scope, chat.id, %{key: "hp", value: 2})

    data = Completions.template(scope, chat.id)
    assert labels(data.properties["vars"]) == ["hp", "mood"]
    assert %{detail: "chat"} = find(data.properties["vars"], "hp")
    assert labels(data.properties["globals"]) == ["hp", "mood"]

    assert Enum.all?(Completions.template(scope).properties["vars"], &(&1.detail == "global"))
  end

  test "lists outlets", %{scope: scope} do
    {:ok, _} = Prompts.create_outlet(scope, %{key: "weather", name: "Weather"})
    assert "weather" in labels(Completions.template(scope).properties["outlets"])
  end

  defp find(options, label), do: Enum.find(options, &(&1.label == label))
  defp labels(options), do: Enum.map(options, & &1.label)

  defp chat!(scope) do
    [player, other] =
      for _ <- 1..2 do
        {:ok, c} = Characters.create_character(scope, %{name: "c-#{System.unique_integer([:positive])}"})
        c
      end

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{System.unique_integer([:positive])}",
        participants: [%{character_id: player.id}, %{character_id: other.id}],
        player_character_id: player.id
      })

    chat
  end
end
