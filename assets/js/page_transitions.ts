// View transitions for LiveView navigation. LiveView hands every DOM patch to `onDocumentPatch`
// (the LiveSocket `dom` option): mounts, patches, streamed tokens, PubSub updates, form changes.
// Only the patch a navigation brings is wrapped in `document.startViewTransition`; everything else
// applies at once.
//
// A navigation is a `phx:page-loading-start` of kind "patch" (patch link) or "redirect" (navigate
// link, push_navigate), or a back/forward `phx:navigate` (`pop: true`, which has no loading
// events). It stays armed until its first patch, its loading stop, or NAVIGATION_WINDOW_MS,
// whichever comes first. The window keeps a back/forward that patches nothing from fading some
// later, unrelated update, and a navigation slower than that just lands instantly. A diff that
// races ahead of a patch reply (a streamed token mid-click) takes the transition instead, so that
// navigation lands without a fade.
//
// LiveView requires start callbacks to run in the order received. While a transition's update has
// not run yet (it waits for the old-page snapshot), later patches queue behind it and run in the
// same update.
const NAVIGATION_WINDOW_MS = 2000;
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
let armedUntil = 0;
let queued: Array<() => void> | null = null;

// Page-loading kinds that are a navigation: a patch link, or a navigate link / push_navigate.
const NAVIGATION_KINDS: Record<string, true> = { patch: true, redirect: true };

window.addEventListener("phx:page-loading-start", (event) => {
  if (NAVIGATION_KINDS[(event as CustomEvent<{ kind: string }>).detail.kind]) {
    armedUntil = performance.now() + NAVIGATION_WINDOW_MS;
  }
});

window.addEventListener("phx:page-loading-stop", (event) => {
  if (NAVIGATION_KINDS[(event as CustomEvent<{ kind: string }>).detail.kind]) armedUntil = 0;
});

window.addEventListener("phx:navigate", (event) => {
  if ((event as CustomEvent<{ pop: boolean }>).detail.pop) {
    armedUntil = performance.now() + NAVIGATION_WINDOW_MS;
  }
});

export function onDocumentPatch(start: () => void) {
  if (queued) {
    queued.push(start);
    return;
  }
  const armed = performance.now() < armedUntil;
  if (
    !armed ||
    !("startViewTransition" in document) ||
    reducedMotion.matches ||
    document.visibilityState === "hidden"
  ) {
    start();
    return;
  }
  armedUntil = 0;
  queued = [start];
  document.startViewTransition(() => {
    const starts = queued!;
    queued = null;
    // One failing patch must not strand the ones queued behind it.
    for (const run of starts) {
      try {
        run();
      } catch (error) {
        reportError(error);
      }
    }
  });
}
