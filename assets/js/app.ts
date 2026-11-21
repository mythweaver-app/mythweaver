// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/mythweaver";
import topbar from "topbar";
import { Blurhash } from "./hooks/blurhash";
import { Chart } from "./hooks/chart";
import { EdgeReveal } from "./hooks/edge_reveal";
import { SortableList } from "./hooks/sortable_list";
import { LoreTree } from "./hooks/lore_tree";
import { RadialMenu } from "./hooks/radial_menu";
import { RangeSelect } from "./hooks/range_select";
import { RichInput } from "./hooks/rich_input";
import { TagInput } from "./hooks/tag_input";
import { UnsavedChanges } from "./hooks/unsaved_changes";
import { Uploaders } from "./uploaders";
import "./drawers";
import "./katex";
import { onDocumentPatch } from "./page_transitions";
import { computeFingerprint } from "./fingerprint";

// Interest invokers (`interestfor`, the account menu's hover) are Chromium-only so far; elsewhere the
// polyfill provides them. Loaded only when native support is missing.
if (!Object.prototype.hasOwnProperty.call(HTMLButtonElement.prototype, "interestForElement")) {
  import("interestfor");
}

declare global {
  interface Window {
    liveSocket: LiveSocket;
    liveReloader: unknown;
  }
}

const csrfToken = document
  .querySelector("meta[name='csrf-token']")!
  .getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // `timezone` lets a LiveView group by the reader's local day (`Mythweaver.Analytics.timezone/1`);
  // `fingerprint` feeds moderation's account fingerprints (`MythweaverWeb.Signals`).
  params: {
    _csrf_token: csrfToken,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    fingerprint: computeFingerprint(),
  },
  hooks: {
    ...colocatedHooks,
    Blurhash,
    Chart,
    EdgeReveal,
    SortableList,
    LoreTree,
    RadialMenu,
    RangeSelect,
    RichInput,
    TagInput,
    UnsavedChanges,
  },
  uploaders: Uploaders,
  dom: { onDocumentPatch },
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// Progress bar for anything LiveView reports as page loading (`phx:page-loading-*`: live
// navigation, joins, reconnects), shown only once a load has taken 300ms. topbar draws on a
// canvas, which needs a concrete color rather than a `var()`, so the scheme's `--primary-accent`
// is read at each load and follows the tint setting and dark mode.
topbar.config({ shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", () => {
  const accent = getComputedStyle(document.documentElement).getPropertyValue("--primary-accent").trim();
  if (accent) topbar.config({ barColors: { 0: accent } });
  topbar.show(300);
});
window.addEventListener("phx:page-loading-stop", () => topbar.hide());

// The push service worker (`assets/sw/sw.ts`, served as `/sw.js`) needs a secure context: https, or
// localhost. Elsewhere the `.Notifications` hook keeps showing popups itself. A notification click
// handled by the worker asks this tab to show the notification's page.
if ("serviceWorker" in navigator && window.isSecureContext) {
  navigator.serviceWorker
    .register("/sw.js")
    .catch((error) => console.warn("service worker registration failed", error));

  navigator.serviceWorker.addEventListener("message", (event) => {
    const { type, path } = event.data ?? {};
    if (type === "navigate" && typeof path === "string" && location.pathname + location.search !== path) {
      liveSocket.js().navigate(path);
    }
  });
}

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", (event) => {
    const reloader = (event as CustomEvent).detail;
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs();

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown: string | null;
    window.addEventListener("keydown", (e) => (keyDown = e.key));
    window.addEventListener("keyup", (_e) => (keyDown = null));
    window.addEventListener(
      "click",
      (e) => {
        if (keyDown === "c") {
          e.preventDefault();
          e.stopImmediatePropagation();
          reloader.openEditorAtCaller(e.target);
        } else if (keyDown === "d") {
          e.preventDefault();
          e.stopImmediatePropagation();
          reloader.openEditorAtDef(e.target);
        }
      },
      true,
    );

    window.liveReloader = reloader;
  });
}
