defmodule MythweaverWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use MythweaverWeb, :html

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Branding

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :chat, :any, default: nil, doc: "the open chat; enables chat commands in the command palette"
  attr :current_scope, :map, default: nil, doc: "the signed-in scope; shows the account links"

  attr :search, :any,
    default: nil,
    doc:
      "the page's Mod-F search scope (`MythweaverWeb.Search`'s `local`); a chat page gets `{:chat, chat}` from `chat`"

  slot :inner_block, required: true

  def app(assigns) do
    # Nothing derived from the scope is computed here: this body runs on every parent render
    # (each streamed token), while template expressions re-run only when the assigns they read change.
    ~H"""
    <%!--
      `lower-bound="none"`: `.top-bar-brand`/`.top-bar-link` are `<.link>` roots, and that wrapper
      carries `phx-r`, which the default exclusive bound would cut off, so the brand would silently
      render at the inherited font-size. With no lower bound every element carrying this block's
      scope marker is a scope root, which already includes `<header>` and `<main>`, so both root
      rules must be tag-qualified `:scope` selectors.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      header:scope {
        flex: 0 0 auto;
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--size-3);
        padding: var(--size-2) var(--size-3);
        margin: var(--panel-gap) var(--panel-gap) 0;
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
        /* The account menu hangs off the bar's corner (see `.top-bar-account-menu`). */
        anchor-name: --top-bar;
      }

      main:scope {
        flex: 1 1 auto;
        min-height: 0;
        display: flex;
        flex-direction: column;
      }

      .top-bar-brand {
        font-size: 1.25rem;
        font-weight: 600;
        color: inherit;
        text-decoration: none;
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
      }

      .top-bar-nav {
        display: flex;
        align-items: center;
        gap: var(--size-2);
      }

      /* Brand and command palette on the left; configuration links and the account menu at the
         right end. */
      .top-bar-menu {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        margin-inline-start: auto;
        --drawer-padding: var(--size-3);
      }

      /* Holds only the compact bell and the drawer toggle, so it is gone above the tablet
         breakpoint: an empty flex item would still take a header gap and push the account menu in
         from the edge. */
      .top-bar-end {
        display: none;
        align-items: center;
        gap: var(--size-1);
      }

      /* The username. Interest in it (hover, keyboard focus, a long press) shows the account menu,
         and a click or tap opens it until dismissed: `interestfor` plus `commandfor`. */
      .top-bar-account {
        display: flex;
        align-items: center;
        gap: var(--size-1);
        padding-inline-start: var(--size-2);
        border-inline-start: 1px solid var(--border);
      }

      .top-bar-account-toggle {
        --interest-delay-start: 0.1s;
        --interest-delay-end: 0.25s;
        /* Native interest invokers read these; the `interestfor` polyfill reads the variables. */
        interest-delay-start: var(--interest-delay-start);
        interest-delay-end: var(--interest-delay-end);
      }

      .top-bar-account-chevron {
        display: inline-flex;
        font-size: 0.75em;
        opacity: 0.7;
      }

      /* The drawer's static label for the name, in place of the toggle (see `--laptop` below). */
      .top-bar-account-name {
        display: none;
      }

      /* A popover in the top layer. Its inline end sits on the bar's outer edge, so it lines up
         with the panes below; without anchor positioning `.AccountMenu` places it from script. */
      .top-bar-account-menu {
        inset: auto;
        flex-direction: column;
        gap: var(--size-1);
        min-inline-size: 11rem;
        margin: var(--size-1) 0 0;
        padding: var(--size-1);
        color: var(--foreground);
        background: linear-gradient(var(--card), var(--card)), var(--background);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);

        transition: all 50ms ease-in allow-discrete;

        @starting-style {
          translate: 0 -10px;
          opacity: 0;
        }

        &:popover-open {
          display: flex;
          opacity: 1 translate: 0 0;
        }
      }

      @supports (anchor-name: --a) {
        .top-bar-account-menu {
          position-anchor: --top-bar;
          inset-block-start: anchor(end);
          inset-inline-end: anchor(end);
        }
      }

      .top-bar-account-separator {
        margin: 0;
        border: 0;
        border-block-start: 1px solid var(--border);
      }

      .top-bar-link {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
        padding: var(--size-1) var(--size-2);
        border-radius: var(--radius-2);
        color: inherit;
        text-decoration: none;

        &:hover {
          background: var(--surface-4);
        }
      }

      /* Zero specificity so `.top-bar-link:hover`'s background still wins. */
      :where(.top-bar-account-toggle) {
        font: inherit;
        color: inherit;
        background: none;
        border: 0;
        cursor: pointer;
      }

      @media (--coarse) {
        .top-bar-link {
          min-block-size: var(--touch-target);
        }
      }

      /* Below `--laptop` the full link row no longer fits beside the brand and account menu, so
         the links move into the menu drawer, one per line. */
      @media (--laptop) {
        .top-bar-end {
          display: flex;
          margin-inline-start: auto;
        }

        .top-bar-menu:popover-open {
          align-items: stretch;
          gap: var(--size-3);
        }

        .top-bar-menu:popover-open :is(.top-bar-nav, .top-bar-account) {
          display: flex;
          flex-direction: column;
          align-items: stretch;
          gap: var(--size-2);
        }

        .top-bar-menu:popover-open .top-bar-account {
          padding-inline-start: 0;
          border-inline-start: 0;
          padding-block-start: var(--size-3);
          border-block-start: 1px solid var(--border);
        }

        /* In the drawer the account links are listed under the name, always shown: the toggle
           gives way to a plain label, so nothing there can open the popover. */
        .top-bar-menu:popover-open .top-bar-account-toggle {
          display: none;
        }

        .top-bar-menu:popover-open .top-bar-account-name {
          display: inline-flex;
          align-items: center;
          gap: var(--size-1);
          padding: var(--size-1) var(--size-2);
        }

        .top-bar-menu:popover-open .top-bar-account-menu {
          position: static;
          display: flex;
          gap: var(--size-2);
          min-inline-size: 0;
          margin: 0;
          padding: 0;
          background: none;
          border: 0;
          box-shadow: none;
        }

        .top-bar-menu:popover-open .top-bar-account-separator {
          display: none;
        }
      }

      /* Phones: the bar waits above the screen and overlays the page once pulled down (the
         `EdgeReveal` hook sets `data-reveal-top` on `<html>`), so the page gets the full height.
         Tucked away, its bottom edge stays `--top-bar-peek` into view, just under the safe area, as
         a hint that it can be pulled down; its shadow waits until it is shown. Keyboard focus
         inside it shows it too. */
      @media (--phone) {
        header:scope {
          --edge-reveal: on;
          --top-bar-peek: 3px;
          position: fixed;
          inset-block-start: calc(env(safe-area-inset-top) + var(--panel-gap));
          inset-inline: calc(env(safe-area-inset-left) + var(--panel-gap))
            calc(env(safe-area-inset-right) + var(--panel-gap));
          z-index: 10;
          margin: 0;
          /* It overlays the page, so the translucent card colour sits on the opaque page colour. */
          background: linear-gradient(var(--card), var(--card)), var(--background);
          box-shadow: none;
          translate: 0 calc(var(--top-bar-peek) - 100% - var(--panel-gap));
          transition:
            translate 200ms ease,
            box-shadow 200ms ease;
        }

        :root[data-reveal-top="shown"] header:scope,
        header:scope:focus-within {
          translate: none;
          box-shadow: var(--elevation-lg);
        }
      }

      @media (prefers-reduced-motion: reduce) {
        header:scope {
          transition: none;
        }
      }
    </style>

    <header
      id="top-bar"
      class="top-bar"
      phx-hook="EdgeReveal"
      data-edge="top"
      data-reveal-hide-on-click
    >
      <.link navigate={~p"/"} class="top-bar-brand"><.logo />{Branding.name()}<sup :if={
        Branding.default_name?()
      }>&alpha;</sup></.link>
      <.button
        size="sm"
        icon
        id="command-palette-button"
        phx-click={JS.dispatch("shortcuts:palette")}
        aria-label={
          pgettext("aria label: top bar button that opens the command palette", "Command palette")
        }
        title={
          pgettext(
            "tooltip: top bar button that opens the command palette, with its shortcut",
            "Command palette (Ctrl/⌘ P)"
          )
        }
      >
        <.lucide name="ship-wheel" />
      </.button>
      <div id="top-bar-menu" class="top-bar-menu drawer drawer--end drawer--laptop" popover>
        <nav
          class="top-bar-nav"
          aria-label={pgettext("aria label: top bar navigation to the app's areas", "Configuration")}
        >
          <.link navigate={~p"/"} class="top-bar-link" id="nav-chat">
            <.lucide name="message-square" /> {pgettext(
              "link: top bar navigation to the chats",
              "Chat"
            )}
          </.link>
          <.link
            :if={MythweaverWeb.ContentAccess.allowed?(@current_scope, :characters)}
            navigate={~p"/characters"}
            class="top-bar-link"
          >
            <.lucide name="users" /> {pgettext(
              "link: top bar navigation to the characters",
              "Characters"
            )}
          </.link>
          <.link
            :if={MythweaverWeb.ContentAccess.allowed?(@current_scope, :lore)}
            navigate={~p"/lore"}
            class="top-bar-link"
          >
            <.lucide name="book-open" /> {pgettext(
              "link: top bar navigation to the lore books",
              "Lore"
            )}
          </.link>
          <.link
            :if={MythweaverWeb.ContentAccess.allowed?(@current_scope, :prompts)}
            navigate={~p"/prompts"}
            class="top-bar-link"
          >
            <.lucide name="messages-square" /> {pgettext(
              "link: top bar navigation to the prompts",
              "Prompts"
            )}
          </.link>
          <.link
            :if={MythweaverWeb.AIAccess.allowed?(@current_scope)}
            navigate={~p"/ai/providers"}
            class="top-bar-link"
          >
            <.lucide name="plug" /> {pgettext(
              "link: top bar navigation to the AI providers and models",
              "AI"
            )}
          </.link>
          <.link
            :if={MythweaverWeb.ContentAccess.allowed?(@current_scope, :variables)}
            navigate={~p"/variables"}
            class="top-bar-link"
          >
            <.lucide name="variable" /> {pgettext(
              "link: top bar navigation to the global variables",
              "Variables"
            )}
          </.link>
          <.link
            :if={MythweaverWeb.ContentAccess.allowed?(@current_scope, :scripts)}
            navigate={~p"/scripts"}
            class="top-bar-link"
          >
            <.lucide name="scroll-text" /> {pgettext(
              "link: top bar navigation to the Lua scripts",
              "Scripts"
            )}
          </.link>
          <.link
            :if={MythweaverWeb.ContentAccess.allowed?(@current_scope, :tags)}
            navigate={~p"/tags"}
            class="top-bar-link"
          >
            <.lucide name="tags" /> {pgettext("link: top bar navigation to the tags", "Tags")}
          </.link>
          <.link navigate={~p"/jobs"} class="top-bar-link">
            <.lucide name="list-checks" /> {pgettext(
              "link: top bar navigation to the generation jobs",
              "Jobs"
            )}
          </.link>
          <.link navigate={~p"/analytics"} class="top-bar-link" id="nav-analytics">
            <.lucide name="chart-column" /> {pgettext(
              "link: top bar navigation to the usage analytics",
              "Analytics"
            )}
          </.link>
          <.link
            :if={MythweaverWeb.ContentAccess.allowed?(@current_scope, :memory)}
            navigate={~p"/memory/profiles"}
            class="top-bar-link"
          >
            <.lucide name="brain" /> {pgettext(
              "link: top bar navigation to the memory profiles",
              "Memory"
            )}
          </.link>
          <.link
            :if={Mythweaver.Sharing.received_any?(@current_scope)}
            navigate={~p"/shared"}
            class="top-bar-link"
            id="nav-shared"
          >
            <.lucide name="share-2" /> {pgettext(
              "link: top bar navigation to items others shared with me",
              "Shared with me"
            )}
          </.link>
          <.link navigate={~p"/catalog"} class="top-bar-link" id="nav-catalog">
            <.lucide name="store" /> {pgettext(
              "link: top bar navigation to the public catalog",
              "Catalog"
            )}
          </.link>
        </nav>
        <div
          :if={@current_scope}
          class="top-bar-account"
          id="nav-account-menu"
          phx-hook=".AccountMenu"
        >
          <.live_component
            module={MythweaverWeb.NotificationBell}
            id="notification-bell"
            current_scope={@current_scope}
          />
          <button
            type="button"
            class="top-bar-link top-bar-account-toggle"
            id="nav-account-toggle"
            interestfor="nav-account-popover"
            commandfor="nav-account-popover"
            command="show-popover"
          >
            <.lucide name="circle-user" /> {User.display_name(@current_scope.user)}
            <span class="top-bar-account-chevron"><.lucide name="chevron-down" /></span>
          </button>
          <span class="top-bar-account-name">
            <.lucide name="circle-user" /> {User.display_name(@current_scope.user)}
          </span>
          <nav
            id="nav-account-popover"
            class="top-bar-account-menu"
            popover="auto"
            aria-label={pgettext("aria label: the account menu", "Account")}
            phx-mounted={JS.ignore_attributes(["style"])}
          >
            <.link navigate={~p"/users/settings"} class="top-bar-link" id="nav-account">
              <.lucide name="circle-user" /> {pgettext(
                "link: account menu, the user's account settings",
                "Account"
              )}
            </.link>
            <%!-- The moderation panel opens on the first section the viewer may use. --%>
            <.link
              :if={MythweaverWeb.ModerationNav.home(@current_scope)}
              navigate={MythweaverWeb.ModerationNav.home(@current_scope)}
              class="top-bar-link"
              id="nav-moderation"
            >
              <.lucide name="shield" /> {pgettext(
                "link: account menu, the moderation panel",
                "Moderation"
              )}
            </.link>
            <.link
              :if={Mythweaver.Moderation.Modes.any_restrictive?(@current_scope)}
              navigate={~p"/submissions"}
              class="top-bar-link"
              id="nav-submissions"
            >
              <.lucide name="hourglass" /> {pgettext(
                "link: account menu, items waiting for moderator review",
                "Submissions"
              )}
            </.link>
            <.link
              :if={MythweaverWeb.ContentAccess.any?(@current_scope)}
              navigate={~p"/import"}
              class="top-bar-link"
              id="nav-import"
            >
              <.lucide name="arrow-up-down" /> {pgettext(
                "link: account menu, the import and export pages",
                "Import/Export"
              )}
            </.link>
            <.link navigate={~p"/settings"} class="top-bar-link" id="nav-settings">
              <.lucide name="settings" /> {pgettext(
                "link: account menu, the app settings",
                "Settings"
              )}
            </.link>
            <hr class="top-bar-account-separator" />
            <.link href={~p"/users/log-out"} method="delete" class="top-bar-link" id="nav-log-out">
              <.lucide name="log-out" /> {pgettext("link: account menu, sign out", "Log out")}
            </.link>
          </nav>
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".AccountMenu">
          // The account menu opens through the browser's invokers alone (`interestfor` for hover,
          // focus and long press, `commandfor` for a click or tap; the `interestfor` polyfill is
          // loaded in app.ts). This covers what they don't: browsers without invoker commands, without
          // anchor positioning, and closing the menu once a link in it is followed (a live
          // navigation can keep the element, and with it the open state).
          export default {
            mounted() {
              const menu = this.el.querySelector("#nav-account-popover");
              const trigger = this.el.querySelector("#nav-account-toggle");

              if (!("commandForElement" in HTMLButtonElement.prototype)) {
                trigger.addEventListener("click", () =>
                  menu.showPopover({ source: trigger }),
                );
              }

              if (!CSS.supports("anchor-name: --a")) {
                menu.addEventListener("toggle", (event) => {
                  if (event.newState !== "open") return;
                  const bar = document.getElementById("top-bar").getBoundingClientRect();
                  menu.style.position = "fixed";
                  menu.style.top = `${bar.bottom}px`;
                  menu.style.right = `${document.documentElement.clientWidth - bar.right}px`;
                });
              }

              menu.addEventListener("click", (event) => {
                if (event.target.closest("a[href]")) menu.hidePopover();
              });
            },
          };
        </script>
      </div>
      <div class="top-bar-end">
        <.live_component
          :if={@current_scope}
          module={MythweaverWeb.NotificationBell}
          id="notification-bell-compact"
          compact
          current_scope={@current_scope}
        />
        <.drawer_toggle
          for="top-bar-menu"
          breakpoint="laptop"
          label={pgettext("aria label: button that opens the top bar menu on small screens", "Menu")}
          id="top-bar-menu-toggle"
        >
          <.lucide name="menu" />
        </.drawer_toggle>
      </div>
      <%!-- Outside `#top-bar-menu`, which is hidden below `--laptop`; inside the header, so the
        phone's EdgeReveal keeps the bar shown while the panel is in use. --%>
      <.live_component
        :if={@current_scope}
        module={MythweaverWeb.NotificationInbox}
        id="notification-inbox"
        current_scope={@current_scope}
      />
    </header>

    <main>
      {render_slot(@inner_block)}
    </main>
    <.flash_group flash={@flash} />
    <.live_component
      module={MythweaverWeb.CommandPalette}
      id="command-palette"
      chat={@chat}
      current_scope={@current_scope}
    />
    <.live_component
      module={MythweaverWeb.Search}
      id="search"
      current_scope={@current_scope}
      local={@search || (@chat && {:chat, @chat})}
    />
    <MythweaverWeb.Shortcuts.help />
    <.radial_menu />
    <div id="notifications" phx-hook=".Notifications" hidden></div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Notifications">
      // Delivers `MythweaverWeb.NotificationsHook`'s "notify" events: once across tabs (the focused one
      // first), a sound, and a browser popup unless the user is looking at the app. The popup goes
      // through the push service worker (`assets/sw/sw.ts`) when one is active (Android Chrome allows
      // no other kind, and a push for the same notification then replaces it via the same `tag`), and
      // is a page `Notification` otherwise (no secure context, or no worker yet).
      // Also plays the settings page's previews (`notifications:play`, `detail.src`), and reports
      // whether this tab is visible and focused (`app_focus`), so Web Push skips someone looking at it.
      const CLAIM_PREFIX = "mw-notified:";
      const CLAIM_TTL_MS = 10 * 60 * 1000;

      const prune = () => {
        const cutoff = Date.now() - CLAIM_TTL_MS;
        for (let i = localStorage.length - 1; i >= 0; i--) {
          const key = localStorage.key(i);
          if (
            key?.startsWith(CLAIM_PREFIX) &&
            Number(localStorage.getItem(key)) < cutoff
          ) {
            localStorage.removeItem(key);
          }
        }
      };

      export default {
        mounted() {
          this.handleEvent("notify", (n) => this.deliver(n));

          // One preview at a time: a second click restarts it.
          this.playPreview = (e) => {
            this.preview?.pause();
            this.preview = new Audio(e.detail.src);
            this.preview.play().catch(() => {});
          };
          window.addEventListener("notifications:play", this.playPreview);

          // Firefox and Safari only ask from a user gesture.
          if ("Notification" in window && Notification.permission === "default") {
            this.askPermission = () => Notification.requestPermission();
            document.addEventListener("pointerdown", this.askPermission, {
              once: true,
            });
          }

          // A focus change (debounced) reaches the server only when it differs from the last report.
          this.reportFocus = () => {
            clearTimeout(this.focusTimer);
            this.focusTimer = setTimeout(() => {
              const focused =
                document.visibilityState === "visible" && document.hasFocus();
              if (focused === this.focused) return;
              this.focused = focused;
              this.pushEvent("app_focus", { focused });
            }, 200);
          };
          window.addEventListener("focus", this.reportFocus);
          window.addEventListener("blur", this.reportFocus);
          document.addEventListener("visibilitychange", this.reportFocus);
          this.reportFocus();
        },

        // A reconnect is a new LiveView process, registered unfocused until told otherwise.
        reconnected() {
          this.focused = undefined;
          this.reportFocus();
        },

        destroyed() {
          window.removeEventListener("notifications:play", this.playPreview);
          this.preview?.pause();
          if (this.askPermission)
            document.removeEventListener("pointerdown", this.askPermission);
          clearTimeout(this.focusTimer);
          window.removeEventListener("focus", this.reportFocus);
          window.removeEventListener("blur", this.reportFocus);
          document.removeEventListener("visibilitychange", this.reportFocus);
        },

        async deliver(n) {
          // Whatever page this tab shows, the user is already looking at the app.
          const focused =
            document.visibilityState === "visible" && document.hasFocus();

          // The focused tab claims first; the others give it a head start.
          if (!focused) await new Promise((resolve) => setTimeout(resolve, 150));

          const claim = () => {
            const key = CLAIM_PREFIX + n.id;
            if (localStorage.getItem(key)) return false;
            localStorage.setItem(key, String(Date.now()));
            prune();
            return true;
          };

          const claimed = navigator.locks
            ? await navigator.locks.request("mw-notifications", claim)
            : claim();
          if (!claimed) return;

          // Autoplay may be blocked before the first interaction.
          if (n.sound) new Audio(n.sound).play().catch(() => {});

          if (
            n.popup &&
            !focused &&
            "Notification" in window &&
            Notification.permission === "granted"
          ) {
            const options = { body: n.body, tag: n.id, icon: n.icon };
            const worker = await navigator.serviceWorker?.getRegistration();

            if (worker?.active) {
              // The worker handles the click (focus + `navigate` message to `app.ts`).
              await worker.showNotification(n.title, {
                ...options,
                data: { path: n.path },
              });
              return;
            }

            const popup = new Notification(n.title, options);

            popup.onclick = () => {
              window.focus();
              if (location.pathname + location.search !== n.path)
                this.js().navigate(n.path);
              popup.close();
            };
          }
        },
      };
    </script>
    """
  end

  @tint_keys ["appearance.primary_hue", "appearance.tint_strength"]

  @doc "The settings `tint_style/1` reads."
  def tint_keys, do: @tint_keys

  @doc """
  The `<html>` `style` the root layout tints every color token with: `--tint-h` from
  `appearance.primary_hue` and `--tint-strength` from `appearance.tint_strength`
  (`assets/css/tokens.css` scales `--tint-c` by it). Signed out, the site's.
  """
  def tint_style(scope) do
    %{"appearance.primary_hue" => hue, "appearance.tint_strength" => strength} =
      Mythweaver.Settings.get_many(scope || %Scope{}, @tint_keys)

    "--tint-h: #{hue}; --tint-strength: #{strength}"
  end

  @doc """
  The `<style id="custom-styles">` text the root layout loads the custom stylesheets with: `@import`s
  into `userstyles.site` then `userstyles.user` (`Mythweaver.Stylesheets`), leaving out an empty sheet
  and, in safe mode, the user's.
  """
  def custom_style_imports(scope, safe_mode?) do
    versions = Mythweaver.Stylesheets.versions(scope || %Scope{})

    [
      versions.site && "@import url(#{~p"/styles/site.css?#{[v: versions.site]}"}) layer(userstyles.site);",
      !safe_mode? && versions.user &&
        "@import url(#{~p"/styles/user.css?#{[v: versions.user]}"}) layer(userstyles.user);"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  @doc """
  The signed-out layout for login and setup: one centered card, with no navigation and no command
  palette (whose commands act on app data a signed-out visitor must not reach).
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      main:scope {
        flex: 1 1 auto;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: var(--size-5) var(--panel-gap);
      }

      .auth-card {
        inline-size: 100%;
        max-inline-size: 24rem;
        padding: var(--size-5);
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }
    </style>

    <main class="auth-shell">
      <div class="auth-card">
        {render_slot(@inner_block)}
      </div>
    </main>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  Besides `:info` and `:error`, the memory prompts have entries of their own, so one never
  replaces another or a passing notice: `:memory_review` (`MythweaverWeb.NotificationsHook`) and
  `:consolidation` (a ready tier, `MythweaverWeb.MainChatLive`). Both are styled as `:info`.
  The plain `:info` entry clears itself after five seconds, the prompts after ten (the inbox keeps
  them until reviewed or dismissed, and `NotificationsHook` carries them across live patches);
  errors stay until closed.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div:scope {
        position: fixed;
        bottom: calc(var(--panel-gap) * 2);
        translate: -50% 0;
        left: 50%;
        z-index: 100;
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        max-inline-size: min(28rem, calc(100vw - 2 * var(--panel-gap)));
        pointer-events: none;
      }
    </style>

    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} dismiss_after={5000} />
      <.flash kind={:info} key={:memory_review} flash={@flash} dismiss_after={10_000} />
      <.flash kind={:info} key={:consolidation} flash={@flash} dismiss_after={10_000} />
      <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={offline_title()}
        phx-disconnected={JS.remove_attribute("hidden", to: ".phx-client-error #client-error")}
        phx-connected={JS.set_attribute({"hidden", ""}, to: "#client-error")}
        hidden
      >
        {reconnecting_text()}
      </.flash>
      <.flash
        id="server-error"
        kind={:error}
        title={server_error_title()}
        phx-disconnected={JS.remove_attribute("hidden", to: ".phx-server-error #server-error")}
        phx-connected={JS.set_attribute({"hidden", ""}, to: "#server-error")}
        hidden
      >
        {reconnecting_text()}
      </.flash>
    </div>
    """
  end

  defp offline_title do
    gettext_comment("Error notice title shown while the browser has lost its connection to the server.")
    pgettext("notification title: the browser lost its connection", "We can't find the internet")
  end

  defp server_error_title do
    gettext_comment("Error notice title shown when the server dropped the page's live connection.")
    pgettext("notification title: the server dropped the live connection", "Something went wrong!")
  end

  defp reconnecting_text do
    gettext_comment("Error notice body under a lost-connection title, while the page tries to connect again.")
    pgettext("status: the page is reconnecting after a lost connection", "Attempting to reconnect")
  end
end
