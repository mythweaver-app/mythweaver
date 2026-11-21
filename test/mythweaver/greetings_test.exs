defmodule Mythweaver.GreetingsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Greetings
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message

  setup do
    %{scope: scope!()}
  end

  defp character!(scope, name, attrs \\ %{}) do
    {:ok, character} = Characters.create_character(scope, Map.put(attrs, :name, name))
    character
  end

  defp chat!(scope, participants, attrs) do
    attrs = Map.put(attrs, :participants, Enum.map(participants, &%{character_id: &1.id}))
    {:ok, chat} = Chats.create_chat(scope, attrs)
    chat
  end

  defp bodies(message), do: Enum.map(message.bodies, & &1.content)

  test "one-on-one, a character's greetings become swipes of message #1, the first one shown", %{scope: scope} do
    ann = character!(scope, "Ann")
    bob = character!(scope, "Bob", %{first_message: "Hi {{ anchors.player.name }}.", alternate_greetings: ["Yo."]})
    chat = chat!(scope, [ann, bob], %{player_character_id: ann.id, greeting: bob.id})

    assert {:ok, [_message]} = Greetings.post(scope, chat)
    assert [message] = Messages.list_messages(chat)
    assert message.position == 0
    assert message.author_character_id == bob.id
    assert bodies(message) == ["Hi Ann.", "Yo."]
    assert Message.active_content(message) == "Hi Ann."
  end

  test "one-on-one with a blank first message, the first alternate is shown", %{scope: scope} do
    ann = character!(scope, "Ann")
    bob = character!(scope, "Bob", %{first_message: " ", alternate_greetings: ["Yo.", "Hey."]})
    chat = chat!(scope, [ann, bob], %{player_character_id: ann.id, greeting: bob.id})

    assert {:ok, [message]} = Greetings.post(scope, chat)
    assert bodies(message) == ["Yo.", "Hey."]
    assert Message.active_content(message) == "Yo."
  end

  test "group-only greetings join the pool only with two or more non-player characters", %{scope: scope} do
    ann = character!(scope, "Ann")
    cy = character!(scope, "Cy")

    bob =
      character!(scope, "Bob", %{first_message: "Hi.", alternate_greetings: ["Yo."], group_greetings: ["Hello all."]})

    duo = chat!(scope, [ann, bob], %{player_character_id: ann.id, greeting: bob.id})
    assert {:ok, [message]} = Greetings.post(scope, duo)
    assert bodies(message) == ["Hi.", "Yo."]

    trio = chat!(scope, [ann, bob, cy], %{player_character_id: ann.id, greeting: bob.id})
    assert {:ok, [message]} = Greetings.post(scope, trio)
    assert bodies(message) == ["Hi.", "Yo.", "Hello all."]

    # No player: both participants are characters, so it is a group.
    bots = chat!(scope, [bob, cy], %{greeting: bob.id})
    assert {:ok, [message]} = Greetings.post(scope, bots)
    assert bodies(message) == ["Hi.", "Yo.", "Hello all."]
  end

  test "all posts one message per non-player character with greetings, in speaking order", %{scope: scope} do
    ann = character!(scope, "Ann", %{first_message: "I am the player."})
    bob = character!(scope, "Bob", %{first_message: "Hi."})
    cy = character!(scope, "Cy")
    dee = character!(scope, "Dee", %{alternate_greetings: ["Dee here."]})
    chat = chat!(scope, [ann, bob, cy, dee], %{player_character_id: ann.id, greeting: "all"})

    assert {:ok, [_, _]} = Greetings.post(scope, chat)

    assert [%{position: 0} = first, %{position: 1} = second] = Messages.list_messages(chat)
    assert {first.author_character_id, bodies(first)} == {bob.id, ["Hi."]}
    assert {second.author_character_id, bodies(second)} == {dee.id, ["Dee here."]}
  end

  test "a template error in any greeting posts none of them", %{scope: scope} do
    bob = character!(scope, "Bob", %{first_message: "Hi."})
    # The changeset refuses it; a row stored before that check (or by hand) still can hold one.
    cy = Mythweaver.Repo.update!(Ecto.Changeset.change(character!(scope, "Cy"), first_message: "{% if %}"))
    chat = chat!(scope, [bob, cy], %{greeting: "all"})

    assert {:error, "Template syntax error: " <> _} = Greetings.post(scope, chat)
    assert Messages.list_messages(chat) == []
  end

  test "random picks among the non-player characters with greetings", %{scope: scope} do
    ann = character!(scope, "Ann", %{first_message: "I am the player."})
    cy = character!(scope, "Cy")
    bob = character!(scope, "Bob", %{first_message: "Hi."})
    chat = chat!(scope, [ann, cy, bob], %{player_character_id: ann.id, greeting: "random"})

    assert {:ok, [message]} = Greetings.post(scope, chat)
    assert message.author_character_id == bob.id
  end

  test "custom posts the narrator's message", %{scope: scope} do
    ann = character!(scope, "Ann")
    bob = character!(scope, "Bob")

    chat =
      chat!(scope, [ann, bob], %{
        player_character_id: ann.id,
        greeting: "custom",
        greeting_text: "The tavern door creaks."
      })

    assert {:ok, [message]} = Greetings.post(scope, chat)
    assert message.author_is_character == false
    assert message.author_name == "Narrator"
    assert bodies(message) == ["The tavern door creaks."]
  end

  test "a greeter with no greetings posts nothing", %{scope: scope} do
    ann = character!(scope, "Ann")
    bob = character!(scope, "Bob", %{first_message: "  "})
    chat = chat!(scope, [ann, bob], %{player_character_id: ann.id, greeting: bob.id})

    assert {:error, :no_greeting} = Greetings.post(scope, chat)
    assert Messages.list_messages(chat) == []
  end

  test "no greeting chosen is :none", %{scope: scope} do
    chat = chat!(scope, [character!(scope, "Ann"), character!(scope, "Bob", %{first_message: "Hi."})], %{})
    assert Greetings.post(scope, chat) == :none
  end

  test "choices skips the player and those without greetings for the chat's size, in display order" do
    index = %{"a" => {true, true}, "b" => {false, true}, "c" => {true, false}, "d" => {true, true}}

    assert Greetings.choices(index, ["a", "b", "b"], "a") == ["custom"]
    assert Greetings.choices(index, ["a", "c"], "a") == ["random", "c", "custom"]
    assert Greetings.choices(index, ["a", "b", "c"], "a") == ["random", "b", "custom"]
    assert Greetings.choices(index, ["a", "c"], nil) == ["random", "a", "custom"]
    assert Greetings.choices(index, ["b", "d"], nil) == ["all", "random", "b", "d", "custom"]
  end
end
