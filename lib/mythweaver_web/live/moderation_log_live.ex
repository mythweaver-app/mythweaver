defmodule MythweaverWeb.ModerationLogLive do
  @moduledoc """
  The moderation log (`/moderation/log`): the newest moderation actions and looks at private content
  (`Mythweaver.Moderation.Log.list/2`), all of them or, with `?user=<id>`, those one account did or
  that were about it.
  """
  use MythweaverWeb, :live_view

  alias Mythweaver.Accounts
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Log
  alias Mythweaver.Moderation.LogEntry
  alias Mythweaver.Moderation.Lookup
  alias MythweaverWeb.ModerationNav

  on_mount {MythweaverWeb.UserAuth, {:require_permission, "moderation.log.view"}}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Moderation.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: dpgettext("moderation", "page title: the moderation log", "Moderation log"),
       user_id: nil,
       filter_user: nil,
       entries_empty?: true
     )
     |> stream_configure(:entries, dom_id: &"log-#{&1.id}")
     |> stream(:entries, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user_id =
      case Ecto.UUID.cast(params["user"]) do
        {:ok, id} -> id
        :error -> nil
      end

    {:noreply,
     socket
     |> assign(user_id: user_id, filter_user: user_id && Accounts.get_user(user_id))
     |> stream_entries()}
  end

  defp stream_entries(%{assigns: %{current_scope: scope, user_id: user_id}} = socket) do
    entries = Log.list(scope, user_id: user_id)

    socket
    |> assign(entries_empty?: entries == [])
    |> stream(:entries, entries, reset: true)
  end

  @impl true
  def handle_info({Moderation, :changed}, socket), do: {:noreply, stream_entries(socket)}

  defp subject_path(%LogEntry{subject_type: type, subject_id: id}) when is_binary(id) do
    if type in Lookup.types(), do: Lookup.path({type, id})
  end

  defp subject_path(_entry), do: nil

  defp subject_text(%LogEntry{subject_type: type, details: details}) do
    name = details["name"] || details["title"]
    label = ModerationNav.subject_label(type)

    if name do
      gettext_comment("Moderation log row: the type of item an action was about (e.g. \"Character\"), then its name.")

      dpgettext(
        "moderation",
        "status: type and name of the item a moderation log entry is about",
        "%{item_type} %{item_name}",
        item_type: label,
        item_name: name
      )
    else
      label
    end
  end

  # The subject and, when the entry concerns an account, that account (`:target`), in the
  # translation's order, with the words between them.
  defp subject_parts(%LogEntry{target_user: nil}), do: [:subject]

  defp subject_parts(_entry) do
    gettext_comment(
      "Moderation log row: what an action was about (e.g. \"Character Aqua\"), then the account it concerned (an @handle). Both are links."
    )

    dpgettext(
      "moderation",
      "status: what a moderation log entry is about, and the account it concerned",
      "%{log_subject} of %{account_handle}",
      log_subject: "\u{F0010}",
      account_handle: "\u{F0011}"
    )
    |> String.split(~r/[\x{F0010}\x{F0011}]/u, include_captures: true, trim: true)
    |> Enum.map(fn
      "\u{F0010}" -> :subject
      "\u{F0011}" -> :target
      text -> String.trim(text)
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp action_label(:viewed), do: dpgettext("moderation", "status: moderation log action", "Viewed")

  defp action_label(:report_dismissed),
    do: dpgettext("moderation", "status: moderation log action", "Dismissed a report")

  defp action_label(:warned), do: dpgettext("moderation", "status: moderation log action", "Warned")
  defp action_label(:banned), do: dpgettext("moderation", "status: moderation log action", "Banned")
  defp action_label(:ban_lifted), do: dpgettext("moderation", "status: moderation log action", "Lifted a ban")
  defp action_label(:deleted), do: dpgettext("moderation", "status: moderation log action", "Deleted")
  defp action_label(:taken_down), do: dpgettext("moderation", "status: moderation log action", "Took down")

  defp action_label(:hold_approved),
    do: dpgettext("moderation", "status: moderation log action", "Approved held content")

  defp action_label(:hold_rejected),
    do: dpgettext("moderation", "status: moderation log action", "Rejected held content")

  defp action_label(:rule_created),
    do: dpgettext("moderation", "status: moderation log action", "Created a moderation rule")

  defp action_label(:rule_updated),
    do: dpgettext("moderation", "status: moderation log action", "Changed a moderation rule")

  defp action_label(:rule_deleted),
    do: dpgettext("moderation", "status: moderation log action", "Deleted a moderation rule")

  defp detail(%LogEntry{details: details}), do: details["reason"] || details["page"]

  defp log_of(user) do
    gettext_comment("Heading of the moderation log filtered to one account; the handle may read \"a deleted account\".")

    dpgettext("moderation", "heading: moderation log filtered to one account", "Log of %{account_handle}",
      account_handle: ModerationNav.handle(user)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div.moderation-log:scope {
        flex: 1 1 auto;
        min-block-size: 0;
        overflow-y: auto;
        margin: var(--panel-gap);
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }

      .log-body {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
        padding: var(--size-3);
      }

      .log-list {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .log-row {
        display: flex;
        flex-wrap: wrap;
        align-items: baseline;
        gap: var(--size-1) var(--size-2);
        padding: var(--size-2) 0;
        border-bottom: 1px solid var(--border);
      }

      .log-when {
        color: var(--muted-foreground);
        font-size: 0.875rem;
        font-variant-numeric: tabular-nums;
      }

      .log-action {
        font-weight: 600;
      }

      .log-detail {
        flex: 1 1 100%;
        color: var(--muted-foreground);
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      .log-empty {
        margin: 0;
        color: var(--muted-foreground);
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <ModerationNav.nav current_scope={@current_scope} active="log" />
      <div class="moderation-log">
        <.panel_header sticky>
          <%= if @user_id do %>
            {log_of(@filter_user)}
          <% else %>
            {dpgettext("moderation", "heading: the moderation log", "Moderation log")}
          <% end %>
          <:actions>
            <.button :if={@user_id} size="sm" patch={~p"/moderation/log"} id="log-filter-clear">
              {dpgettext(
                "moderation",
                "button: stop filtering the moderation log to one account",
                "Show everyone"
              )}
            </.button>
          </:actions>
        </.panel_header>

        <div class="log-body">
          <p :if={@entries_empty?} id="log-empty" class="log-empty">
            {dpgettext("moderation", "empty state: moderation log", "Nothing logged yet")}
          </p>
          <ul id="log" class="log-list" phx-update="stream">
            <li :for={{id, entry} <- @streams.entries} id={id} class="log-row">
              <.local_time id={"#{id}-at"} at={entry.inserted_at} format={:seconds} class="log-when" />
              <.link
                :if={entry.actor}
                navigate={~p"/moderation/users/#{entry.actor.id}/record"}
                id={"#{id}-actor"}
              >
                {ModerationNav.handle(entry.actor)}
              </.link>
              <span :if={!entry.actor}>
                {if entry.details["automatic"],
                  do:
                    dpgettext(
                      "moderation",
                      "status: actor of a moderation log entry made by the rules",
                      "Automatic rules"
                    ),
                  else: ModerationNav.handle(nil)}
              </span>
              <span class="log-action">{action_label(entry.action)}</span>
              <%= for part <- subject_parts(entry) do %>
                <%= case part do %>
                  <% :subject -> %>
                    <%= if path = subject_path(entry) do %>
                      <.link navigate={path} id={"#{id}-subject"}>{subject_text(entry)}</.link>
                    <% else %>
                      <span id={"#{id}-subject"}>{subject_text(entry)}</span>
                    <% end %>
                  <% :target -> %>
                    <.link
                      navigate={~p"/moderation/users/#{entry.target_user.id}/record"}
                      id={"#{id}-target"}
                    >
                      {ModerationNav.handle(entry.target_user)}
                    </.link>
                  <% text -> %>
                    <span>{text}</span>
                <% end %>
              <% end %>
              <span :if={detail(entry)} class="log-detail">{detail(entry)}</span>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
