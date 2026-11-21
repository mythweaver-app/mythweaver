defmodule Mythweaver.Scripts.CommandTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Scripts.Command

  setup do
    %{scope: scope!()}
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{System.unique_integer([:positive])}"})
    character
  end

  defp chat!(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{System.unique_integer([:positive])}",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end

  describe "parse/1" do
    test "reads the leading --- run: description, params, ignored tags" do
      body =
        "--- Greets.\n---@param who character Who\n---@param mood? \"happy\"|'sad' Mood\n---@return nil\nreturn 1\n---@param late string"

      assert {:ok, %{description: "Greets.", params: [who, mood]}} = Command.parse(body)
      assert %{name: "who", type: :character, label: "Who", optional?: false} = who
      assert %{name: "mood", type: :choice, choices: ["happy", "sad"], optional?: true} = mood
    end

    test "a label defaults to the name; no header means no params" do
      assert {:ok, %{params: [%{label: "n"}]}} = Command.parse("---@param n integer\nreturn n")
      assert {:ok, %{description: nil, params: []}} = Command.parse("return 1")
    end

    test "reports every bad line" do
      assert {:error, [~s(line 1: unknown type "foo") <> _]} = Command.parse("---@param a foo")

      assert {:error, [~s(line 2: "a" is declared twice)]} =
               Command.parse("---@param a string\n---@param a integer")

      nine = Enum.map_join(1..9, "\n", &"---@param p#{&1} string")
      assert {:error, ["a command takes at most 8 parameters"]} = Command.parse(nine)

      assert {:error, [~s(line 1: write @param as "---@param name type Label"), "line 2: choices cannot be blank"]} =
               Command.parse(~s(---@param\n---@param c ""|"x"))
    end
  end

  describe "cast_args/3" do
    test "casts primitives and leaves blank optionals out", %{scope: scope} do
      params = [
        %{name: "n", label: "n", type: :integer, optional?: false, choices: nil},
        %{name: "x", label: "x", type: :number, optional?: true, choices: nil},
        %{name: "b", label: "b", type: :boolean, optional?: true, choices: nil}
      ]

      assert {:error, %{"n" => "Must be a whole number."}} = Command.cast_args(scope, params, %{"n" => "abc"}, nil)
      assert {:ok, args} = Command.cast_args(scope, params, %{"n" => " 3 ", "x" => "", "b" => "TRUE"}, nil)
      assert args == %{"n" => 3, "b" => true}
      assert {:ok, %{"x" => 1.5}} = Command.cast_args(scope, params, %{"n" => "1", "x" => "1.5"}, nil)
    end

    test "resolves entities to their tables", %{scope: scope} do
      character = character!(scope, "Ana")
      params = [%{name: "who", label: "Who", type: :character, optional?: false, choices: nil}]

      assert {:ok, %{"who" => %{name: name}}} = Command.cast_args(scope, params, %{"who" => character.id}, nil)
      assert name == character.name

      assert {:error, %{"who" => "That character no longer exists."}} =
               Command.cast_args(scope, params, %{"who" => "not-a-uuid"}, nil)
    end

    test "a participant must be in the chat", %{scope: scope} do
      [player, bot, outsider] = Enum.map(~w(P B O), &character!(scope, &1))
      chat = chat!(scope, [player, bot])
      params = [%{name: "who", label: "Who", type: :participant, optional?: false, choices: nil}]

      assert {:error, %{"who" => "Not a participant of this chat."}} =
               Command.cast_args(scope, params, %{"who" => outsider.id}, chat)

      assert {:error, %{"who" => "Not a participant of this chat."}} =
               Command.cast_args(scope, params, %{"who" => bot.id}, nil)

      assert {:ok, %{"who" => %{id: id}}} = Command.cast_args(scope, params, %{"who" => bot.id}, chat)
      assert id == bot.id
    end
  end
end
