defmodule MythweaverWeb.NotificationBell do
  @moduledoc """
  The top bar's notifications bell: toggles `MythweaverWeb.NotificationInbox` (`commandfor`) and
  badges how many notifications the inbox holds (`Mythweaver.Notifications.inbox_count/1`; error
  toasts are listed but not counted).

  `Layouts.app/1` renders two: `"notification-bell"` beside the username, which in the menu drawer
  (below `--laptop`) reads "Notifications" like the drawer's other entries, and the `compact`
  `"notification-bell-compact"` beside the menu toggle below the `--laptop` breakpoint. A
  LiveComponent because the layout has no data of its own to feed them: the count comes from
  `MythweaverWeb.NotificationsHook`, which `send_update`s `count` on every inbox change.
  """

  use MythweaverWeb, :live_component

  alias Mythweaver.Notifications

  @impl true
  def update(%{count: count}, socket), do: {:ok, assign(socket, count: count)}

  def update(assigns, socket) do
    socket =
      assign(socket,
        id: assigns.id,
        current_scope: assigns.current_scope,
        compact: Map.get(assigns, :compact, false)
      )

    socket =
      if is_nil(socket.assigns[:count]),
        do: assign(socket, count: Notifications.inbox_count(assigns.current_scope)),
        else: socket

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `lower-bound="none"` reaches the icon inside the compact bell's `<.button>`. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* `MythweaverWeb.NotificationInbox`'s arrow points here. Both bells carry the name; only
         the one shown at this width has a box, so it is the only one that can be the anchor. */
      span.notification-bell:scope {
        position: relative;
        display: inline-flex;
        anchor-name: --notification-bell;
      }

      /* Unread: the bell itself turns the accent, on the icon so neither button's own colour
         (or hover colour) has to be outranked. `--primary-accent`: primary as a colour on a
         surface, not a fill. */
      [data-unread] .iconex {
        color: var(--primary-accent);
      }

      /* Zero specificity, so the layout's `.top-bar-link:hover` still wins. */
      :where(.notification-bell-button) {
        font: inherit;
        color: inherit;
        background: none;
        border: 0;
        cursor: pointer;
      }

      /* `--primary` is a fill: paired with its foreground. */
      .notification-bell-badge {
        position: absolute;
        inset-block-start: -0.3rem;
        inset-inline-end: -0.3rem;
        min-inline-size: 1.1rem;
        padding: 0 0.3rem;
        border-radius: 999px;
        background: var(--primary);
        color: var(--primary-foreground);
        font-size: 0.7rem;
        line-height: 1.1rem;
        text-align: center;
        font-variant-numeric: tabular-nums;
        pointer-events: none;
      }

      /* Only the drawer lists the bell among labelled links; the desktop bar shows the icon alone. */
      .notification-bell-label {
        display: none;
      }

      @media (--laptop) {
        .notification-bell-label {
          display: inline;
        }

        /* The drawer's column stretches its rows; the drawer's bell stays its own width, so the
           badge sits at the label's end rather than the drawer's edge. */
        .top-bar-account > span.notification-bell:scope {
          align-self: flex-start;
        }
      }
    </style>
    <span class="notification-bell">
      <.button
        :if={@compact}
        size="sm"
        icon
        id={@id}
        commandfor="notification-inbox"
        command="toggle-popover"
        aria-label={label(@count)}
        data-unread={@count > 0}
        title={
          dpgettext(
            "notifications",
            "tooltip: bell button that opens the notification inbox",
            "Notifications"
          )
        }
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.lucide name="bell" />
      </.button>
      <button
        :if={!@compact}
        type="button"
        id={@id}
        class="top-bar-link notification-bell-button"
        commandfor="notification-inbox"
        command="toggle-popover"
        aria-label={label(@count)}
        data-unread={@count > 0}
        title={
          dpgettext(
            "notifications",
            "tooltip: bell button that opens the notification inbox",
            "Notifications"
          )
        }
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.lucide name="bell" />
        <span class="notification-bell-label">
          {dpgettext(
            "notifications",
            "button: bell button that opens the notification inbox",
            "Notifications"
          )}
        </span>
      </button>
      <span :if={@count > 0} id={"#{@id}-badge"} class="notification-bell-badge" aria-hidden="true">
        {if @count > 9, do: "9+", else: @count}
      </span>
    </span>
    """
  end

  defp label(0),
    do: dpgettext("notifications", "aria label: bell button that opens the notification inbox", "Notifications")

  defp label(count) do
    dpngettext(
      "notifications",
      "aria label: bell button that opens the notification inbox, with the unread count",
      "Notifications, %{unread_count} new",
      "Notifications, %{unread_count} new",
      count,
      unread_count: Mythweaver.Format.number(count)
    )
  end
end
