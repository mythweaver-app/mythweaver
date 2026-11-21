defmodule MythweaverWeb.WarningLive do
  @moduledoc """
  The warning page (`/warnings`): a moderator's pending warnings to the viewer
  (`Mythweaver.Moderation.Sanctions.pending_warnings/1`). `MythweaverWeb.ModerationGate` sends every
  other page here until the viewer acknowledges them (`Sanctions.acknowledge_warnings/1`).
  """

  use MythweaverWeb, :live_view

  alias Mythweaver.Moderation.Sanctions

  @impl true
  def mount(_params, _session, socket) do
    warnings = Sanctions.pending_warnings(socket.assigns.current_scope.user.id)

    {:ok,
     socket
     |> assign(
       page_title: dpgettext("moderation", "page title: moderator warnings to the viewer", "Warnings"),
       warnings_empty?: warnings == []
     )
     |> stream(:warnings, warnings)}
  end

  @impl true
  def handle_event("acknowledge", _params, socket) do
    :ok = Sanctions.acknowledge_warnings(socket.assigns.current_scope)
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div.warning-page:scope {
        display: flex;
        flex: 1 1 auto;
        align-items: flex-start;
        justify-content: center;
        padding: var(--size-6) var(--panel-gap);
        overflow-y: auto;
      }

      .warning-card {
        display: flex;
        flex-direction: column;
        gap: var(--size-4);
        inline-size: min(40rem, 100%);
        padding: var(--size-5);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        background: var(--card);
        box-shadow: var(--elevation-sm);
      }

      .warning-card h1 {
        margin: 0;
        font-size: var(--font-size-4);
      }

      .warning-card p {
        margin: 0;
      }

      .warning-list {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
        margin: 0;
        padding: 0;
        list-style: none;

        & li {
          display: flex;
          flex-direction: column;
          gap: var(--size-1);
          padding: var(--size-3);
          border-inline-start: 3px solid var(--destructive);
          background: var(--surface-2);
          border-radius: var(--radius-2);
        }
      }

      .warning-reason {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      .warning-when {
        color: var(--muted-foreground);
        font-size: 0.875rem;
      }

      .warning-actions {
        display: flex;
        justify-content: flex-end;
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="warning-page">
        <section class="warning-card" aria-labelledby="warnings-title">
          <h1 id="warnings-title">
            {dpgettext(
              "moderation",
              "heading: page showing a moderator's warnings to the viewer",
              "A moderator warned you"
            )}
          </h1>
          <%= if @warnings_empty? do %>
            <p id="warnings-none">{dgettext("moderation", "You have no warnings to read.")}</p>
            <div class="warning-actions">
              <.button navigate={~p"/"} id="warnings-home">
                {dpgettext(
                  "moderation",
                  "button: leave the warnings page for the app",
                  "Back to the app"
                )}
              </.button>
            </div>
          <% else %>
            <p>{dgettext("moderation", "Read these before you go on using the app.")}</p>
            <ul id="warnings" class="warning-list" phx-update="stream">
              <li :for={{id, warning} <- @streams.warnings} id={id}>
                <span class="warning-reason">{warning.reason}</span>
                <.local_time
                  id={"#{id}-at"}
                  at={warning.inserted_at}
                  format={:full}
                  class="warning-when"
                />
              </li>
            </ul>
            <div class="warning-actions">
              <.button id="acknowledge-warnings" variant="primary" phx-click="acknowledge">
                {dpgettext(
                  "moderation",
                  "button: acknowledge the moderator's warnings",
                  "I understand"
                )}
              </.button>
            </div>
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
