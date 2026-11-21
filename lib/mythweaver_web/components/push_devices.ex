defmodule MythweaverWeb.PushDevices do
  @moduledoc """
  The Notifications settings page's "Push devices" panel (shown by `MythweaverWeb.SettingsLive` only
  while `Mythweaver.Notifications.WebPush.configured?/0`): whether this browser can receive Web Push
  and why not, the button that enables or disables it here, and the user's devices
  (`Mythweaver.Notifications.list_devices/1`) with Send test and Remove.

  The `.PushDevices` hook owns what needs the browser: it reports this browser's state as
  `"push_state"` (`%{"status" => "ready" | "insecure" | "ios_install" | "unsupported" | "denied",
  "endpoint" => endpoint | nil}`), and on a click (a user gesture, which iOS and Firefox require)
  asks for permission, subscribes with `data-key` (the VAPID public key) and sends
  `"push_subscribe"` (`%{"subscription" => toJSON(), "label" => "Chrome on Android"}`), or
  unsubscribes and sends `"push_unsubscribe"` (`%{"endpoint" => endpoint}`). The LiveView answers
  `"push_subscribe"` with `%{ok: boolean}` and the hook reports its state again either way.
  """

  use MythweaverWeb, :html

  attr :public_key, :string, required: true
  attr :devices, :list, required: true, doc: "`Mythweaver.Notifications.PushSubscription`s"
  attr :state, :map, default: nil, doc: "this browser's last `push_state` report, nil until it arrives"
  attr :testing, :any, default: MapSet.new(), doc: "ids of devices with a test push in flight"

  def panel(assigns) do
    this_endpoint = assigns.state && assigns.state["endpoint"]
    assigns = assign(assigns, :this_id, Enum.find_value(assigns.devices, &(&1.endpoint == this_endpoint && &1.id)))

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      section.push-devices:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        scroll-margin-block-start: var(--size-9);
      }

      .push-devices-note {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.9rem;
      }

      .push-this-device {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2) var(--size-3);
      }

      .push-this-device p {
        margin: 0;
      }

      .push-device-list {
        list-style: none;
        margin: 0;
        padding: 0;
      }

      .push-device {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-1) var(--size-3);
        padding: var(--size-2) 0;
        border-block-end: 1px solid var(--border-grey);
      }

      .push-device-info {
        flex: 1;
        min-inline-size: 12rem;
        display: flex;
        flex-direction: column;
      }

      .push-device-label {
        font-weight: 600;
      }

      .push-device-badge {
        margin-inline-start: var(--size-2);
        color: var(--primary-accent);
        font-size: 0.8rem;
        font-weight: 600;
      }

      .push-device-meta {
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .push-device-failure {
        color: var(--destructive);
        font-size: 0.85rem;
      }

      .push-device-actions {
        display: flex;
        gap: var(--size-1);
      }
    </style>
    <section
      id="settings-push-devices"
      class="push-devices"
      phx-hook=".PushDevices"
      data-key={@public_key}
    >
      <.section_header>
        {dpgettext(
          "notifications",
          "heading: settings panel listing the user's push devices",
          "Push devices"
        )}
      </.section_header>
      <p class="push-devices-note">
        {dgettext(
          "notifications",
          "Push notifications reach a device even with %{app_name} closed, for the kinds ticked in the Push column. Enable push on each phone or computer you want them on. Nothing is pushed while you are looking at the app.",
          app_name: Mythweaver.Branding.name()
        )}
      </p>

      <div id="push-this-device" class="push-this-device">
        <%= case @state && @state["status"] do %>
          <% nil -> %>
            <p>
              {dpgettext(
                "notifications",
                "status: push support of this browser is being checked",
                "Checking this browser…"
              )}
            </p>
          <% "insecure" -> %>
            <p id="push-unavailable">
              {dgettext(
                "notifications",
                "Push needs the app served over HTTPS, or opened on localhost on this computer. The README's Deploying section lists ways to serve it."
              )}
            </p>
          <% "ios_install" -> %>
            <p id="push-unavailable">
              {dgettext(
                "notifications",
                "On iPhone and iPad, push works only in the installed app: tap Share, then Add to Home Screen, open %{app_name} from the Home Screen and enable push there.",
                app_name: Mythweaver.Branding.name()
              )}
            </p>
          <% "denied" -> %>
            <p id="push-unavailable">
              {dgettext(
                "notifications",
                "Notifications are blocked for this site. Allow them in the browser's site settings, then reload the page."
              )}
            </p>
          <% "ready" -> %>
            <%= if @this_id do %>
              <p>{dgettext("notifications", "Push is on for this browser.")}</p>
              <.button size="sm" id="push-disable" data-push-action="disable">
                <.lucide name="bell-off" />
                {dpgettext(
                  "notifications",
                  "button: turn push notifications off for this browser",
                  "Disable on this browser"
                )}
              </.button>
            <% else %>
              <p>{dgettext("notifications", "Push is off for this browser.")}</p>
              <.button size="sm" variant="primary" id="push-enable" data-push-action="enable">
                <.lucide name="bell-ring" />
                {dpgettext(
                  "notifications",
                  "button: turn push notifications on for this browser",
                  "Enable push on this browser"
                )}
              </.button>
            <% end %>
          <% _unsupported -> %>
            <p id="push-unavailable">
              {dgettext("notifications", "This browser does not support push notifications.")}
            </p>
        <% end %>
      </div>

      <ul :if={@devices != []} id="push-device-list" class="push-device-list">
        <li :for={device <- @devices} id={"push-devices-#{device.id}"} class="push-device">
          <div class="push-device-info">
            <span>
              <span class="push-device-label">{device.label}</span>
              <span :if={device.id == @this_id} class="push-device-badge">
                {dpgettext(
                  "notifications",
                  "badge: the push device is the browser in use",
                  "This browser"
                )}
              </span>
            </span>
            <span class="push-device-meta">
              <%= if device.last_success_at do %>
                {dpgettext(
                  "notifications",
                  "field label: time of the last successful push to a device",
                  "Last push"
                )}
                <.local_time id={"push-device-time-#{device.id}"} at={device.last_success_at} />
              <% else %>
                {dpgettext(
                  "notifications",
                  "status: a push device has never received a push",
                  "No push yet"
                )}
              <% end %>
            </span>
            <span :if={device.last_failure} class="push-device-failure">{device.last_failure}</span>
          </div>
          <div class="push-device-actions">
            <.button
              size="sm"
              id={"push-device-test-#{device.id}"}
              phx-click="push_test"
              phx-value-id={device.id}
              disabled={MapSet.member?(@testing, device.id)}
            >
              <.lucide name="send" />
              {dpgettext("notifications", "button: send a test push to a device", "Send test")}
            </.button>
            <.button
              size="sm"
              danger
              id={"push-device-remove-#{device.id}"}
              phx-click="push_remove"
              phx-value-id={device.id}
              data-confirm={remove_confirm(device.label)}
            >
              <.lucide name="trash" />
              {dpgettext("notifications", "button: remove a push device", "Remove")}
            </.button>
          </div>
        </li>
      </ul>
    </section>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PushDevices">
      // This browser's Web Push state and its enable/disable buttons; see `MythweaverWeb.PushDevices`.
      const deviceLabel = () => {
        const ua = navigator.userAgent;
        const browser = /Edg\//.test(ua)
          ? "Edge"
          : /Firefox\//.test(ua)
            ? "Firefox"
            : /Chrome\//.test(ua)
              ? "Chrome"
              : /Safari\//.test(ua)
                ? "Safari"
                : "Browser";
        const os = /Android/.test(ua)
          ? "Android"
          : /iPhone|iPad|iPod/.test(ua)
            ? "iOS"
            : /Mac OS X/.test(ua)
              ? "macOS"
              : /Windows/.test(ua)
                ? "Windows"
                : /Linux/.test(ua)
                  ? "Linux"
                  : null;
        const app = matchMedia("(display-mode: standalone)").matches ? " (app)" : "";
        return (os ? `${browser} on ${os}` : browser) + app;
      };

      // `applicationServerKey` wants the raw key bytes, not the url-safe base64 the server holds.
      const keyBytes = (base64url) => {
        const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/");
        return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
      };

      // `ready` never settles when the worker failed to register (`app.ts` logs why).
      const workerReady = () =>
        Promise.race([
          navigator.serviceWorker.ready,
          new Promise((resolve) => setTimeout(() => resolve(null), 5000)),
        ]);

      export default {
        mounted() {
          this.report();
          this.el.addEventListener("click", (e) => {
            const action = e.target.closest("[data-push-action]")?.dataset.pushAction;
            if (action === "enable") this.enable();
            if (action === "disable") this.disable();
          });
        },

        reconnected() {
          this.report();
        },

        status() {
          if (!window.isSecureContext) return "insecure";
          const ios = /iPhone|iPad|iPod/.test(navigator.userAgent);
          if (!("serviceWorker" in navigator) || !("PushManager" in window))
            return ios ? "ios_install" : "unsupported";
          if (Notification.permission === "denied") return "denied";
          return "ready";
        },

        async report() {
          let status = this.status();
          let endpoint = null;
          if (status === "ready") {
            const registration = await workerReady();
            if (registration) {
              endpoint =
                (await registration.pushManager.getSubscription())?.endpoint ?? null;
            } else {
              status = "unsupported";
            }
          }
          this.pushEvent("push_state", { status, endpoint });
        },

        async enable() {
          // Asked first and directly in the click: iOS and Firefox only ask from a user gesture.
          const permission = await Notification.requestPermission();
          const registration = permission === "granted" && (await workerReady());
          if (!registration) return this.report();

          const manager = registration.pushManager;
          const options = {
            userVisibleOnly: true,
            applicationServerKey: keyBytes(this.el.dataset.key),
          };
          let sub;
          try {
            sub = await manager.subscribe(options);
          } catch (_error) {
            // A subscription made with an older key blocks a new one: replace it.
            await (await manager.getSubscription())?.unsubscribe();
            sub = await manager.subscribe(options).catch(() => null);
          }

          if (sub) {
            this.pushEvent(
              "push_subscribe",
              { subscription: sub.toJSON(), label: deviceLabel() },
              () => this.report(),
            );
          } else {
            this.report();
          }
        },

        async disable() {
          const registration = await workerReady();
          const sub = await registration?.pushManager.getSubscription();
          if (sub) {
            this.pushEvent("push_unsubscribe", { endpoint: sub.endpoint });
            await sub.unsubscribe();
          }
          this.report();
        },
      };
    </script>
    """
  end

  defp remove_confirm(device_name) do
    gettext_comment("Confirm dialog before removing a push device from the user's account.")
    dgettext("notifications", "Stop push notifications on %{device_name}?", device_name: device_name)
  end
end
