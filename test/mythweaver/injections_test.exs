defmodule Mythweaver.InjectionsTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Injections
  alias Mythweaver.Injections.Injection
  alias Mythweaver.Lore

  setup do
    scope = scope!()
    %{scope: scope, chat: chat!(scope)}
  end

  test "a limited injection starts with its full count, and changing uses resets it", %{scope: scope, chat: chat} do
    injection = injection!(scope, chat, %{key: "short", uses: 2})
    assert injection.remaining == 2

    :ok = Injections.spend(chat.id, [injection.id])
    assert %{remaining: 1} = reload(scope, injection)

    assert {:ok, %{remaining: 3}} = Injections.update_injection(scope, reload(scope, injection), %{uses: 3})
    # An edit that leaves `uses` alone keeps the countdown.
    :ok = Injections.spend(chat.id, [injection.id])
    assert {:ok, %{remaining: 2}} = Injections.update_injection(scope, reload(scope, injection), %{content: "new"})
  end

  test "spend/2 counts down limited injections only, never below zero", %{scope: scope, chat: chat} do
    once = injection!(scope, chat, %{key: "once", uses: 1})
    forever = injection!(scope, chat, %{key: "forever"})

    :ok = Injections.spend(chat.id, [once.id, forever.id])
    assert %{remaining: 0} = reload(scope, once)
    assert %{uses: nil, remaining: nil} = reload(scope, forever)

    :ok = Injections.spend(chat.id, [once.id])
    assert %{remaining: 0} = reload(scope, once)
  end

  test "spent? and active?" do
    assert Injection.active?(%Injection{enabled: true, uses: nil, remaining: nil})
    assert Injection.active?(%Injection{enabled: true, uses: 2, remaining: 1})
    refute Injection.active?(%Injection{enabled: false, uses: 2, remaining: 1})
    refute Injection.active?(%Injection{enabled: true, uses: 2, remaining: 0})

    refute Injection.spent?(%Injection{uses: nil, remaining: nil})
    refute Injection.spent?(%Injection{uses: 2, remaining: 1})
    assert Injection.spent?(%Injection{uses: 2, remaining: 0})
  end

  test "count_active/2 counts enabled, unspent injections", %{scope: scope, chat: chat} do
    injection!(scope, chat, %{key: "a"})
    injection!(scope, chat, %{key: "b", enabled: false})
    spent = injection!(scope, chat, %{key: "c", uses: 1})
    :ok = Injections.spend(chat.id, [spent.id])

    assert Injections.count_active(scope, chat.id) == 1
  end

  test "rearm/2 restores remaining to uses", %{scope: scope, chat: chat} do
    injection = injection!(scope, chat, %{key: "short", uses: 2})
    :ok = Injections.spend(chat.id, [injection.id])
    :ok = Injections.spend(chat.id, [injection.id])

    assert {:ok, %{remaining: 2}} = Injections.rearm(scope, reload(scope, injection))
  end

  test "clean_up/2 deletes spent injections and keeps a disabled one with replies left", %{scope: scope, chat: chat} do
    spent = injection!(scope, chat, %{key: "spent", uses: 1})
    off = injection!(scope, chat, %{key: "off", uses: 1, enabled: false})
    forever = injection!(scope, chat, %{key: "forever"})
    :ok = Injections.spend(chat.id, [spent.id])

    assert {:ok, 1} = Injections.clean_up(scope, chat.id)

    assert Injections.list_injections(scope, chat.id) |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([off.id, forever.id])

    assert {:ok, 0} = Injections.clean_up(scope, chat.id)
  end

  test "a key is unique per chat", %{scope: scope, chat: chat} do
    injection!(scope, chat, %{key: "short"})

    assert {:error, changeset} = Injections.create_injection(scope, chat.id, %{key: "short", content: "x"})
    assert "is already taken" in errors_on(changeset).key

    assert {:ok, _} = Injections.create_injection(scope, chat!(scope).id, %{key: "short", content: "x"})
  end

  test "an unparseable condition is a changeset error", %{scope: scope, chat: chat} do
    assert {:error, changeset} =
             Injections.create_injection(scope, chat.id, %{key: "k", content: "x", condition: "vars.x =="})

    assert [message] = errors_on(changeset).condition
    assert message =~ "is not a valid Liquid condition"

    assert {:ok, _} =
             Injections.create_injection(scope, chat.id, %{key: "k", content: "x", condition: ~s(vars.x == "a")})
  end

  test "writes are announced on the chat topic", %{scope: scope, chat: chat} do
    Phoenix.PubSub.subscribe(Mythweaver.PubSub, Mythweaver.Messages.topic(chat.id))
    chat_id = chat.id

    injection = injection!(scope, chat, %{key: "short", uses: 1})
    assert_receive {:injections_changed, ^chat_id}

    :ok = Injections.spend(chat.id, [injection.id])
    assert_receive {:injections_changed, ^chat_id}
  end

  test "position values stay in lockstep with Lore.Settings.slots/0" do
    assert Ecto.Enum.values(Injection, :position) |> Enum.map(&Atom.to_string/1) == Lore.Settings.slots()
  end

  defp reload(scope, %Injection{id: id, chat_id: chat_id}),
    do: Enum.find(Injections.list_injections(scope, chat_id), &(&1.id == id))

  defp injection!(scope, chat, attrs) do
    {:ok, injection} = Injections.create_injection(scope, chat.id, Map.merge(%{content: "Be brief."}, attrs))
    injection
  end

  defp chat!(scope) do
    [player, other] =
      for name <- ["Hero", "Foil"] do
        {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{System.unique_integer([:positive])}"})
        character
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
