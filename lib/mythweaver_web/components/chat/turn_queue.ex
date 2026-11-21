defmodule MythweaverWeb.Chat.TurnQueue do
  @moduledoc """
  The reply-queue popup opened from the chat header: who is speaking (with Stop), the waiting
  entries in order (each removable), and Clear queue. Driven entirely by the `turn_state` the
  conductor broadcasts (`Mythweaver.Generation.status/1`); names resolve from the chat's
  participants, so an entry whose character has left the chat reads "Removed character".
  """

  use MythweaverWeb, :html

  alias Mythweaver.Chats.Chat

  attr(:chat, :any, required: true)
  attr(:turn_state, :map, required: true)

  def turn_queue(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: the content lives inside `<.modal>`'s slot, a nested component root. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      .turn-queue-speaking,
      .turn-queue-entry {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-1) 0;
      }

      .turn-queue-name {
        flex: 1 1 auto;
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .turn-queue-status {
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .turn-queue-list {
        margin: 0;
        padding-inline-start: var(--size-4);
      }

      .turn-queue-empty {
        color: var(--muted-foreground);
      }

      .turn-queue-actions {
        display: flex;
        justify-content: flex-end;
        margin-top: var(--size-2);
      }
    </style>

    <.modal
      id="turn-queue-modal"
      title={dpgettext("chat", "heading: dialog listing characters waiting to reply", "Reply queue")}
      on_cancel="close_queue"
    >
      <div :if={@turn_state.speaking} class="turn-queue-speaking" id="turn-queue-speaking">
        <span class="turn-queue-name">{name(@chat, @turn_state.speaking)}</span>
        <span class="turn-queue-status">
          {dpgettext("chat", "status: character currently generating a reply", "Speaking")}
        </span>
        <.button id="queue-stop" phx-click="stop_generation">
          <.lucide name="square" /> {dpgettext(
            "chat",
            "button: stop the reply being generated",
            "Stop"
          )}
        </.button>
      </div>

      <div :if={@turn_state.paused?} class="turn-queue-speaking" id="turn-queue-paused">
        <span class="turn-queue-name">
          {dpgettext("chat", "status: reply queue", "Queue paused")}
        </span>
        <.button id="queue-resume" phx-click="resume_queue">
          <.lucide name="step-forward" /> {dpgettext(
            "chat",
            "button: resume the paused reply queue",
            "Resume"
          )}
        </.button>
      </div>

      <ol id="turn-queue-list" class="turn-queue-list">
        <li :for={entry <- @turn_state.queue} id={"queue-entry-#{entry.id}"} class="turn-queue-entry">
          <span class="turn-queue-name">{name(@chat, entry.character_id)}</span>
          <.button
            icon
            danger
            phx-click="dequeue"
            phx-value-id={entry.id}
            aria-label={
              dpgettext(
                "chat",
                "aria label: icon button that removes a character from the reply queue",
                "Remove from queue"
              )
            }
          >
            <.lucide name="x" />
          </.button>
        </li>
      </ol>

      <p :if={@turn_state.queue == []} id="turn-queue-empty" class="turn-queue-empty">
        {dpgettext("chat", "empty state: reply queue", "Queue is empty")}
      </p>

      <div class="turn-queue-actions">
        <.button
          id="queue-clear"
          danger
          phx-click="clear_queue"
          disabled={@turn_state.queue == []}
        >
          {dpgettext("chat", "button: remove every entry from the reply queue", "Clear queue")}
        </.button>
      </div>
    </.modal>
    """
  end

  defp name(chat, character_id),
    do:
      Chat.participant_name(chat, character_id) ||
        dpgettext("chat", "status: queued character who has left the chat", "Removed character")
end
