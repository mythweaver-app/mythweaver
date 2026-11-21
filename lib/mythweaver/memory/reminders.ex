defmodule Mythweaver.Memory.Reminders do
  @moduledoc """
  Memory reminders, a port of STMB's `createMemoryReminderController.check` (`memoryReminders.js`).

  With automatic memories off, `memory.manual_reminders` reminds the user once
  `memory.manual_reminder_interval` messages sit past the processed boundary, and again every
  interval after. With them on, `memory.auto_reminders` reminds once the unprocessed count passes
  the automatic interval plus buffer plus `memory.auto_reminder_interval` (always message-based,
  even with the token trigger), and every reminder interval after.

  A reminder is `{:memory_reminder, %{mode: :manual | :auto, count: n}}` on
  `Mythweaver.Memory.topic/1`. The chat's `ChatSettings.reminder` keeps a `signature` of the mode,
  boundary and intervals (a change resets the count) and `notified_at`, the count at the last one.
  """

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats
  alias Mythweaver.Memory
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Messages.Message
  alias Mythweaver.Repo

  @doc """
  Checks the chat's reminder and broadcasts one when due and not `busy?` (a memory job pending or
  just fired). `settings` is the chat's row, or nil when it has none yet.
  """
  @spec check(Scope.t(), Ecto.UUID.t(), ChatSettings.t() | nil, boolean()) :: :ok
  def check(%Scope{} = scope, chat_id, nil, busy?) do
    if Memory.preferences(scope).manual_reminders do
      settings = Memory.chat_settings(scope, Chats.get_chat!(scope, chat_id))
      check(scope, chat_id, settings, busy?)
    else
      :ok
    end
  end

  def check(%Scope{} = scope, chat_id, %ChatSettings{} = settings, busy?) do
    prefs = Memory.preferences(scope)
    mode = if settings.auto_enabled, do: :auto, else: :manual

    {enabled?, interval} =
      case mode do
        :auto -> {prefs.auto_reminders, prefs.auto_reminder_interval}
        :manual -> {prefs.manual_reminders, prefs.manual_reminder_interval}
      end

    state = settings.reminder || %{}

    if not enabled? and state == %{} do
      :ok
    else
      baseline = settings.highest_processed || -1

      count =
        Repo.aggregate(
          from(m in Message, where: m.chat_id == ^chat_id and m.draft == false and m.position > ^baseline),
          :count
        )

      first =
        case mode do
          :manual ->
            interval

          :auto ->
            auto = Memory.auto_settings(scope, settings)
            auto.auto_interval + auto.auto_buffer + interval
        end

      signature = "#{mode}:#{baseline}:#{interval}:#{first}"
      new_state = rebase(state, signature, count)
      notified_at = new_state["notified_at"]

      due? = enabled? and count >= first and (is_nil(notified_at) or count >= notified_at + interval)

      new_state =
        if due? and not busy? do
          Phoenix.PubSub.broadcast(
            Mythweaver.PubSub,
            Memory.topic(chat_id),
            {:memory_reminder, %{mode: mode, count: count}}
          )

          Map.put(new_state, "notified_at", count)
        else
          new_state
        end

      if new_state != state do
        Repo.update_all(from(s in ChatSettings, where: s.id == ^settings.id), set: [reminder: new_state])
      end

      :ok
    end
  end

  defp rebase(state, signature, count) do
    state =
      if state["signature"] == signature,
        do: state,
        else: %{"signature" => signature, "notified_at" => nil}

    case state["notified_at"] do
      n when is_integer(n) and n > count -> Map.put(state, "notified_at", count)
      _ -> state
    end
  end
end
