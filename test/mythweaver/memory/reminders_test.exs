defmodule Mythweaver.Memory.RemindersTest do
  # Not `async: true`: messages run `Memory.Auto.check/2`, whose interval side prompts and
  # memories would run in scheduler-spawned tasks.
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Memory
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Messages

  setup do
    scope = scope!()
    player = character!(scope, "Player")
    responder = character!(scope, "Responder")
    chat = chat!(scope, [player, responder])
    :ok = Phoenix.PubSub.subscribe(Mythweaver.PubSub, Memory.topic(chat.id))
    %{scope: scope, chat: chat, player: player}
  end

  test "manual reminders arrive at the interval and every interval after", %{scope: scope} = ctx do
    put!(scope, "memory.manual_reminders", true)
    put!(scope, "memory.manual_reminder_interval", 3)

    send!(ctx, 2)
    refute_received {:memory_reminder, _}
    send!(ctx, 1)
    assert_received {:memory_reminder, %{mode: :manual, count: 3}}
    send!(ctx, 2)
    refute_received {:memory_reminder, _}
    send!(ctx, 1)
    assert_received {:memory_reminder, %{mode: :manual, count: 6}}
  end

  test "no reminders while they are off", ctx do
    send!(ctx, 4)
    refute_received {:memory_reminder, _}
    assert Repo.get_by(ChatSettings, chat_id: ctx.chat.id) == nil
  end

  test "moving the boundary resets the count", %{scope: scope, chat: chat} = ctx do
    put!(scope, "memory.manual_reminders", true)
    put!(scope, "memory.manual_reminder_interval", 3)

    send!(ctx, 3)
    assert_received {:memory_reminder, %{count: 3}}

    Repo.update_all(from(s in ChatSettings, where: s.chat_id == ^chat.id), set: [highest_processed: 2])

    send!(ctx, 2)
    refute_received {:memory_reminder, _}
    send!(ctx, 1)
    assert_received {:memory_reminder, %{mode: :manual, count: 3}}
  end

  # With no profile, each automatic memory logs that it could not start.
  @tag :capture_log
  test "auto reminders wait past the interval and buffer", %{scope: scope, chat: chat} = ctx do
    put!(scope, "memory.auto_reminders", true)
    put!(scope, "memory.auto_reminder_interval", 2)

    {:ok, _} =
      Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), %{
        auto_enabled: true,
        auto_interval: 5,
        auto_buffer: 0
      })

    send!(ctx, 6)
    refute_received {:memory_reminder, _}
    send!(ctx, 1)
    assert_received {:memory_reminder, %{mode: :auto, count: 7}}
    send!(ctx, 1)
    refute_received {:memory_reminder, _}
    send!(ctx, 1)
    assert_received {:memory_reminder, %{mode: :auto, count: 9}}
  end

  defp put!(scope, key, value), do: :ok = Mythweaver.Settings.put(scope, :site, key, value)

  defp send!(%{scope: scope, chat: chat, player: player}, count) do
    for i <- 1..count, do: {:ok, _} = Messages.send_message(scope, chat, player.id, "Line #{i}")
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp chat!(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Reminder chat",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end
end
