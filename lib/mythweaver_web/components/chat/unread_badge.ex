defmodule MythweaverWeb.Chat.UnreadBadge do
  @moduledoc """
  The open chat's unread count while the tab is away: a hidden element whose colocated
  `.UnreadBadge` hook counts each `message_arrived` push and shows it as a "(N) " title prefix and
  a favicon badge until the user is back.
  """

  use MythweaverWeb, :html

  attr(:chat_id, :string, required: true)

  def unread_badge(assigns) do
    ~H"""
    <div id="chat-unread" phx-hook=".UnreadBadge" data-chat-id={@chat_id} hidden></div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".UnreadBadge">
      // Counts "message_arrived" pushes while this tab is hidden or unfocused, and shows the count as
      // a "(N) " title prefix and a favicon badge until the user is back. Per tab, never persisted.
      const away = () =>
        !(document.visibilityState === "visible" && document.hasFocus());

      export default {
        mounted() {
          this.count = 0;
          this.chatId = this.el.dataset.chatId;
          this.titleEl = document.querySelector("title");
          this.link = document.querySelector('link[rel~="icon"]');
          this.baseHref = this.link?.href;
          this.icon = new Image();
          this.icon.src = this.baseHref;
          this.iconReady = this.icon.decode().then(
            () => true,
            () => false,
          );

          this.handleEvent("message_arrived", () => {
            if (away()) this.set(this.count + 1);
          });
          this.onBack = () => {
            if (!away()) this.set(0);
          };
          window.addEventListener("focus", this.onBack);
          document.addEventListener("visibilitychange", this.onBack);
        },

        // The element survives a patch to another chat; that chat starts unread-free.
        updated() {
          if (this.el.dataset.chatId !== this.chatId) {
            this.chatId = this.el.dataset.chatId;
            this.set(0);
          }
        },

        destroyed() {
          window.removeEventListener("focus", this.onBack);
          document.removeEventListener("visibilitychange", this.onBack);
          this.set(0);
        },

        set(count) {
          this.count = count;

          // LiveView rebuilds `document.title` from `<title>`'s data-prefix on every page_title
          // change, so the prefix lives there and survives server title updates.
          const prefix = count > 0 ? `(${count}) ` : "";
          const old = this.titleEl.dataset.prefix || "";
          this.titleEl.dataset.prefix = prefix;
          if (document.title.startsWith(old)) {
            document.title = prefix + document.title.slice(old.length);
          }

          if (!this.link) return;
          if (count === 0) {
            this.link.href = this.baseHref;
            return;
          }
          this.iconReady.then((ok) => this.paint(ok));
        },

        // Reads the count at call time, so out-of-order paints settle on the latest one.
        paint(ok) {
          if (this.count === 0) return;

          const canvas = document.createElement("canvas");
          canvas.width = 32;
          canvas.height = 32;
          const ctx = canvas.getContext("2d");
          if (ok) ctx.drawImage(this.icon, 0, 0, 32, 32);

          // The title carries the exact number; the favicon is too small for more.
          const text = this.count > 9 ? "9+" : String(this.count);
          ctx.font = "bold 18px sans-serif";
          const w = Math.max(20, Math.ceil(ctx.measureText(text).width) + 8);
          const x = 32 - w;
          const y = 12;

          // Fixed colours: the favicon sits in browser chrome, outside the app's theme.
          ctx.fillStyle = "#e5484d";
          ctx.beginPath();
          ctx.roundRect(x, y, w, 20, 10);
          ctx.fill();

          ctx.fillStyle = "#ffffff";
          ctx.textAlign = "center";
          ctx.textBaseline = "middle";
          ctx.fillText(text, x + w / 2, y + 11);

          this.link.href = canvas.toDataURL("image/png");
        },
      };
    </script>
    """
  end
end
