defmodule MythweaverWeb.NotificationInbox do
  @moduledoc """
  The notifications inbox: a `popover="auto"` panel the top bar's `MythweaverWeb.NotificationBell`s
  toggle, listing `Mythweaver.Notifications.inbox/1` newest first. Each item links where it was
  about (`Notifications.path/1`; an error toast links nowhere) and can be dismissed; "Clear all"
  empties the inbox but for the items still waiting on the user (`Notifications.needs_action?/1`),
  so it shows only while something else is listed. A share invite carries Accept and Decline
  (`Mythweaver.Sharing.accept/2`, `decline/2`); accepting opens the shared item's editor (an editor
  invite) or its `/shared` card (a subscriber invite). A chat invite does too
  (`Mythweaver.Chats.accept_invite/2`, `decline_invite/2`); accepting opens the chat.

  The panel sits under the bell that opened it, by CSS anchor positioning on the invoker's implicit
  anchor; the `.NotificationInbox` hook covers browsers without invoker commands or anchor
  positioning. `MythweaverWeb.NotificationsHook` reloads it (`reload: true`) on every inbox change.
  """

  use MythweaverWeb, :live_component

  alias Mythweaver.Chats
  alias Mythweaver.Notifications
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Items

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> stream_configure(:notifications, dom_id: &"notification-inbox-items-#{&1.id}")
     |> assign(loaded?: false)}
  end

  @impl true
  def update(%{reload: true}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    socket = assign(socket, current_scope: assigns.current_scope)
    {:ok, if(socket.assigns.loaded?, do: socket, else: load(socket))}
  end

  defp load(socket) do
    items = Notifications.inbox(socket.assigns.current_scope)

    socket
    |> assign(
      loaded?: true,
      notifications_empty?: items == [],
      clearable?: not Enum.all?(items, &Notifications.needs_action?/1)
    )
    |> stream(:notifications, items, reset: true)
  end

  @impl true
  def handle_event("dismiss", %{"id" => id}, socket) do
    # `{:error, :not_found}`: already gone elsewhere; the reload shows that too.
    _ = Notifications.dismiss(socket.assigns.current_scope, id)
    {:noreply, load(socket)}
  end

  def handle_event("clear", _params, socket) do
    :ok = Notifications.dismiss_all(socket.assigns.current_scope)
    {:noreply, load(socket)}
  end

  def handle_event("accept_share", %{"id" => id}, socket) do
    case Sharing.accept(socket.assigns.current_scope, id) do
      {:ok, share} -> {:noreply, push_navigate(socket, to: accepted_path(share))}
      {:error, _} -> {:noreply, load(socket)}
    end
  end

  def handle_event("decline_share", %{"id" => id}, socket) do
    _ = Sharing.decline(socket.assigns.current_scope, id)
    {:noreply, load(socket)}
  end

  def handle_event("accept_chat_invite", %{"id" => id}, socket) do
    case Chats.accept_invite(socket.assigns.current_scope, id) do
      {:ok, member} -> {:noreply, push_navigate(socket, to: ~p"/chats/#{member.chat_id}")}
      {:error, _} -> {:noreply, load(socket)}
    end
  end

  def handle_event("decline_chat_invite", %{"id" => id}, socket) do
    _ = Chats.decline_invite(socket.assigns.current_scope, id)
    {:noreply, load(socket)}
  end

  defp accepted_path(%{role: :subscriber, id: id}), do: ~p"/shared/#{id}"
  defp accepted_path(share), do: Items.edit_path(share.item_type, share.item_id)

  @impl true
  def render(assigns) do
    Iconex.hint(
      :lucide,
      ~w[message-square refresh-cw forward brain layers circle-alert user-plus user-minus gift eye-off shield-alert circle-check circle-x]
    )

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* A popover in the top layer, under the bell that opened it. `--inbox-arrow` is the height
         of the arrow pointing at the bell (half its width). */
      section:scope {
        --inbox-arrow: 0.75rem;
        inset: auto;
        margin: var(--size-1) 0 0;
        padding: 0;
        inline-size: min(24rem, calc(100vw - 2 * var(--panel-gap)));
        max-block-size: min(32rem, calc(100dvh - 6rem));
        overflow-y: auto;
        color: var(--foreground);
        background: linear-gradient(var(--card), var(--card)), var(--background);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }

      section:scope:popover-open {
        display: flex;
        flex-direction: column;
      }

      /* The invoker (the bell) is the implicit anchor. Without anchor positioning
         `.NotificationInbox` places it from script, and there is no arrow.

         The panel drops by the arrow's height and reaches past the bell's end, so the arrow
         clears the rounded corner. The arrow is two triangles anchored to the bell itself
         (`--notification-bell`, on `MythweaverWeb.NotificationBell`'s root), not to the panel, so
         it stays on the bell's centre when a phone's edges push the panel aside or it flips:
         the border colour, and the header's fill 1px lower, covering the panel's top border.
         `position: fixed` keeps them outside the panel's `overflow` clip; it relies on nothing
         on the panel (`translate`, `transform`, `filter`) making it their containing block. */
      @supports (anchor-name: --a) {
        section:scope {
          margin-block-start: calc(var(--size-1) + var(--inbox-arrow));
          margin-inline-end: calc(-1 * var(--size-3));
          position-area: block-end span-inline-start;
          position-try-fallbacks: flip-inline;
        }

        section:scope::before,
        section:scope::after {
          content: "";
          position: fixed;
          position-anchor: --notification-bell;
          inset-block-start: calc(anchor(end) + var(--size-1));
          inset-inline-start: calc(anchor(center) - var(--inbox-arrow));
          inline-size: calc(2 * var(--inbox-arrow));
          block-size: var(--inbox-arrow);
          clip-path: polygon(50% 0, 100% 100%, 0 100%);
          background: var(--border);
        }

        section:scope::after {
          inset-block-start: calc(anchor(end) + var(--size-1) + 1px);
          background: var(--surface-3);
        }
      }

      /* On a phone the panel is wider than the room beside the bell and gets pushed back on
         screen; the margin keeps it off the screen's edges there. */
      @media (--phone) {
        section:scope {
          margin-inline: var(--panel-gap);
        }
      }

      /* A fade only: a `translate` slide would make the panel the arrow's containing block. */
      @media (prefers-reduced-motion: no-preference) {
        section:scope {
          opacity: 0;
          transition:
            opacity 0.15s,
            display 0.15s allow-discrete,
            overlay 0.15s allow-discrete;
        }

        section:scope:popover-open {
          opacity: 1;
          transition-duration: 0.1s;

          @starting-style {
            opacity: 0;
          }
        }
      }

      .notification-inbox-empty {
        margin: 0;
        padding: var(--size-4) var(--size-3);
        color: var(--muted-foreground);
        text-align: center;
      }

      .notification-inbox-items {
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .notification-inbox-items > li {
        display: grid;
        grid-template-columns: 2rem 1fr auto;
        align-items: start;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);

        & + li {
          border-block-start: 1px solid var(--border);
        }
      }

      /* The link spans the media and text columns, a real box (a `display: contents` link loses
         its focusability in some browsers); the dismiss button stays its own cell. */
      .notification-inbox-link {
        display: grid;
        grid-template-columns: subgrid;
        grid-column: 1 / 3;
        align-items: start;
        color: inherit;
        text-decoration: none;
      }

      .notification-inbox-media {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        inline-size: 2rem;
        block-size: 2rem;
        font-size: 1.1rem;
        color: var(--muted-foreground);
      }

      li[data-kind="error"] .notification-inbox-media {
        color: var(--destructive);
      }

      .notification-inbox-avatar {
        inline-size: 2rem;
        block-size: 2rem;
        border-radius: 50%;
        object-fit: cover;
      }

      .notification-inbox-text {
        display: flex;
        flex-direction: column;
        gap: 0.125rem;
        min-inline-size: 0;
      }

      .notification-inbox-text p {
        margin: 0;
        overflow-wrap: anywhere;
      }

      .notification-inbox-title {
        font-weight: 600;
      }

      .notification-inbox-body {
        display: -webkit-box;
        -webkit-box-orient: vertical;
        -webkit-line-clamp: 2;
        line-clamp: 2;
        overflow: hidden;
        color: var(--muted-foreground);
        font-size: 0.875rem;
      }

      .notification-inbox-time {
        color: var(--muted-foreground);
        font-size: 0.75rem;
      }

      .notification-inbox-actions {
        display: flex;
        gap: var(--size-2);
        margin-block-start: var(--size-1);
      }

      .notification-inbox-link:hover .notification-inbox-title {
        text-decoration: underline;
      }

      .notification-inbox-dismiss {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: var(--size-1);
        font: inherit;
        color: var(--muted-foreground);
        background: none;
        border: 0;
        border-radius: var(--radius-2);
        cursor: pointer;

        &:hover {
          color: var(--foreground);
          background: var(--surface-4);
        }
      }

      @media (--coarse) {
        .notification-inbox-dismiss {
          min-block-size: var(--touch-target);
          min-inline-size: var(--touch-target);
        }
      }
    </style>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".NotificationInbox">
      // The bells open the inbox through the browser's invokers alone (`commandfor`). This covers
      // what they don't: browsers without invoker commands (toggling it, and `aria-expanded` on the
      // bells), without anchor positioning (placing it under the bell that opened it), and closing
      // it once a link in it is followed (a live navigation keeps the element, and its open state).
      export default {
        mounted() {
          const native = "commandForElement" in HTMLButtonElement.prototype;
          const selector = '[commandfor="notification-inbox"]';
          const bells = () => document.querySelectorAll(selector);

          // Light dismiss closes an open panel on pointerdown, before the bell's click: remember
          // whether it was open then, so that click closes it rather than reopening it.
          this.onPress = (event) => {
            if (event.target.closest(selector))
              this.openAtPress = this.el.matches(":popover-open");
          };

          this.onClick = (event) => {
            const trigger = event.target.closest(selector);
            if (!trigger) return;
            // The bell that opened it: the anchor for the no-anchor-positioning fallback.
            this.source = trigger;
            if (native) return;

            const open = this.openAtPress ?? this.el.matches(":popover-open");
            this.openAtPress = undefined;

            if (open) {
              if (this.el.matches(":popover-open")) this.el.hidePopover();
            } else {
              this.el.showPopover({ source: trigger });
            }
          };

          document.addEventListener("pointerdown", this.onPress, true);
          document.addEventListener("click", this.onClick);

          this.el.addEventListener("toggle", (event) => {
            if (!native) {
              bells().forEach((bell) =>
                bell.setAttribute("aria-expanded", String(event.newState === "open")),
              );
            }

            if (
              event.newState !== "open" ||
              !this.source ||
              CSS.supports("anchor-name: --a")
            )
              return;
            const rect = this.source.getBoundingClientRect();
            this.el.style.position = "fixed";
            this.el.style.top = `${rect.bottom}px`;
            this.el.style.right = `${document.documentElement.clientWidth - rect.right}px`;
          });

          this.el.addEventListener("click", (event) => {
            if (event.target.closest("a[href]")) this.el.hidePopover();
          });
        },

        destroyed() {
          document.removeEventListener("pointerdown", this.onPress, true);
          document.removeEventListener("click", this.onClick);
        },
      };
    </script>
    <section
      id="notification-inbox"
      class="notification-inbox"
      popover="auto"
      aria-labelledby="notification-inbox-title"
      phx-hook=".NotificationInbox"
      phx-mounted={JS.ignore_attributes(["style"])}
      data-reveal-keep
    >
      <.panel_header sticky>
        <span id="notification-inbox-title">
          {dpgettext("notifications", "heading: notification inbox panel", "Notifications")}
        </span>
        <:actions>
          <.button
            :if={@clearable?}
            size="sm"
            id="notification-inbox-clear"
            phx-click="clear"
            phx-target={@myself}
          >
            {dpgettext(
              "notifications",
              "button: dismiss every notification in the inbox",
              "Clear all"
            )}
          </.button>
        </:actions>
      </.panel_header>
      <p :if={@notifications_empty?} id="notification-inbox-empty" class="notification-inbox-empty">
        {dpgettext("notifications", "empty state: notification inbox", "Nothing new.")}
      </p>
      <ul id="notification-inbox-items" class="notification-inbox-items" phx-update="stream">
        <li :for={{dom_id, n} <- @streams.notifications} id={dom_id} data-kind={n.kind}>
          <%= if path = Notifications.path(n) do %>
            <.link navigate={path} class="notification-inbox-link">
              <.item notification={n} />
            </.link>
          <% else %>
            <div class="notification-inbox-link">
              <.item notification={n}>
                <:actions :if={n.kind == :share_invite}>
                  <.button
                    size="sm"
                    variant="primary"
                    id={"notification-inbox-accept-#{n.id}"}
                    phx-click="accept_share"
                    phx-value-id={n.share_id}
                    phx-target={@myself}
                  >
                    {dpgettext("notifications", "button: accept an invite to share an item", "Accept")}
                  </.button>
                  <.button
                    size="sm"
                    id={"notification-inbox-decline-#{n.id}"}
                    phx-click="decline_share"
                    phx-value-id={n.share_id}
                    phx-target={@myself}
                  >
                    {dpgettext(
                      "notifications",
                      "button: decline an invite to share an item",
                      "Decline"
                    )}
                  </.button>
                </:actions>
                <:actions :if={n.kind == :chat_invite}>
                  <.button
                    size="sm"
                    variant="primary"
                    id={"notification-inbox-accept-#{n.id}"}
                    phx-click="accept_chat_invite"
                    phx-value-id={n.chat_member_id}
                    phx-target={@myself}
                  >
                    {dpgettext("notifications", "button: accept an invite to a chat", "Accept")}
                  </.button>
                  <.button
                    size="sm"
                    id={"notification-inbox-decline-#{n.id}"}
                    phx-click="decline_chat_invite"
                    phx-value-id={n.chat_member_id}
                    phx-target={@myself}
                  >
                    {dpgettext("notifications", "button: decline an invite to a chat", "Decline")}
                  </.button>
                </:actions>
              </.item>
            </div>
          <% end %>
          <button
            type="button"
            class="notification-inbox-dismiss"
            phx-click="dismiss"
            phx-value-id={n.id}
            phx-target={@myself}
            aria-label={
              dpgettext(
                "notifications",
                "aria label: icon button that dismisses one notification",
                "Dismiss"
              )
            }
            title={
              dpgettext(
                "notifications",
                "tooltip: icon button that dismisses one notification",
                "Dismiss"
              )
            }
          >
            <.lucide name="x" />
          </button>
        </li>
      </ul>
    </section>
    """
  end

  attr :notification, :map, required: true
  slot :actions

  defp item(assigns) do
    ~H"""
    <span class="notification-inbox-media">
      <img
        :if={@notification.icon}
        src={@notification.icon}
        alt=""
        class="notification-inbox-avatar"
      />
      <.lucide :if={!@notification.icon} name={kind_icon(@notification.kind)} />
    </span>
    <div class="notification-inbox-text">
      <p class="notification-inbox-title">{@notification.title}</p>
      <p :if={@notification.body} class="notification-inbox-body">{@notification.body}</p>
      <.local_time
        id={"notification-inbox-time-#{@notification.id}"}
        at={@notification.inserted_at}
        class="notification-inbox-time"
      />
      <div :if={@actions != []} class="notification-inbox-actions">{render_slot(@actions)}</div>
    </div>
    """
  end

  defp kind_icon(:new_message), do: "message-square"
  defp kind_icon(:regenerate), do: "refresh-cw"
  defp kind_icon(:continue), do: "forward"
  defp kind_icon(:memory_review), do: "brain"
  defp kind_icon(:consolidation_ready), do: "layers"
  defp kind_icon(:error), do: "circle-alert"
  defp kind_icon(:share_invite), do: "user-plus"
  defp kind_icon(:chat_invite), do: "user-plus"
  defp kind_icon(:share_ended), do: "user-minus"
  defp kind_icon(:handed_off), do: "gift"
  defp kind_icon(:listing_taken_down), do: "eye-off"
  defp kind_icon(:moderation_warning), do: "shield-alert"
  defp kind_icon(:submission_approved), do: "circle-check"
  defp kind_icon(:submission_rejected), do: "circle-x"
end
