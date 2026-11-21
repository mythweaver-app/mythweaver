defmodule Mythweaver.Generation.TurnPolicyTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Generation.TurnPolicy
  alias Mythweaver.Messages

  defp character!(scope, name, talkativeness) do
    {:ok, c} = Characters.create_character(scope, %{name: name, talkativeness: talkativeness})
    c
  end

  # `[player | bots]`, participants in that order.
  defp chat!(scope, characters, attrs \\ %{}) do
    [player | _] = characters

    {:ok, chat} =
      Chats.create_chat(scope, %{
        player_character_id: player.id,
        participants: Enum.map(characters, &%{character_id: &1.id})
      })

    {:ok, chat} = Chats.update_chat(scope, chat, attrs)
    Chats.get_chat!(chat.id)
  end

  defp say!(scope, chat, character, text) do
    {:ok, _} = Messages.send_message(scope, chat, character.id, text)
  end

  defp round(chat, trigger), do: TurnPolicy.round(chat, Messages.list_messages(chat), trigger)

  setup do
    scope = scope!()

    %{
      scope: scope,
      player: character!(scope, "Player", 0.5),
      alice: character!(scope, "Alice", 0.0),
      bob: character!(scope, "Bob", 0.0),
      carol: character!(scope, "Carol", 0.0)
    }
  end

  test ":list returns unmuted non-player participants in order, capped by max_turns", ctx do
    chat = chat!(ctx.scope, [ctx.player, ctx.alice, ctx.bob, ctx.carol], %{reply_strategy: :list})
    carol = Enum.find(chat.participants, &(&1.character_id == ctx.carol.id))
    {:ok, _} = Chats.update_participant(ctx.scope, carol, %{muted: true})
    chat = Chats.get_chat!(chat.id)

    assert round(chat, :player) == [ctx.alice.id, ctx.bob.id]

    {:ok, chat} = Chats.update_chat(ctx.scope, chat, %{max_turns: 1})
    assert round(Chats.get_chat!(chat.id), :player) == [ctx.alice.id]
  end

  test ":manual never replies to the player", ctx do
    chat = chat!(ctx.scope, [ctx.player, ctx.alice, ctx.bob])
    assert round(chat, :player) == []
  end

  describe ":natural" do
    test "a mention activates the named character", ctx do
      chat = chat!(ctx.scope, [ctx.player, ctx.alice, ctx.bob], %{reply_strategy: :natural})
      say!(ctx.scope, chat, ctx.player, "hello Bob")
      assert round(chat, :player) == [ctx.bob.id]
    end

    test "with no mention and no talkativeness, exactly one falls back", ctx do
      chat = chat!(ctx.scope, [ctx.player, ctx.alice, ctx.bob], %{reply_strategy: :natural})
      say!(ctx.scope, chat, ctx.player, "hello there")
      assert [id] = round(chat, :player)
      assert id in [ctx.alice.id, ctx.bob.id]
    end

    test "an auto tick excludes the last speaker unless self responses are allowed", ctx do
      alice = character!(ctx.scope, "Alicia", 1.0)
      bob = character!(ctx.scope, "Bobby", 1.0)
      chat = chat!(ctx.scope, [ctx.player, alice, bob], %{reply_strategy: :natural})
      say!(ctx.scope, chat, bob, "I speak")

      refute bob.id in round(chat, :auto)

      {:ok, chat} = Chats.update_chat(ctx.scope, chat, %{allow_self_responses: true})
      assert bob.id in round(Chats.get_chat!(chat.id), :auto)
    end
  end

  test ":pooled on an auto tick picks whoever has not spoken since the player", ctx do
    chat = chat!(ctx.scope, [ctx.player, ctx.alice, ctx.bob], %{reply_strategy: :pooled})
    say!(ctx.scope, chat, ctx.player, "hi")
    say!(ctx.scope, chat, ctx.bob, "hey")
    assert round(chat, :auto) == [ctx.alice.id]
  end
end
