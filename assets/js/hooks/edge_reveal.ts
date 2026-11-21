import type { Hook, HookInterface } from "phoenix_live_view";

/**
 * Phone chrome that waits at a screen edge, a few pixels showing, until the user pulls it in: the
 * top bar (`Layouts.app`, pulled down) and the chat composer (`Chat.Messages`, swiped up).
 *
 * DOM contract:
 *   * The element carries `phx-hook="EdgeReveal"`, an `id` and `data-edge` (`top` or `bottom`).
 *   * Its CSS opts in with `--edge-reveal: on` inside the breakpoint where it collapses
 *     (`(--phone)`), so the breakpoint lives only in the stylesheet; elsewhere the hook does nothing.
 *   * Shown is `data-reveal-<edge>="shown"` on `<html>`, which LiveView never patches, and the
 *     element's CSS reveals it from that (and from `:focus-within`, so keyboard focus shows it too).
 *   * `data-reveal-hide-on-click`: following a link or button inside hides it again (the top bar's
 *     navigation); invoker toggles (`popovertarget`, `commandfor`: drawers, menus, the inbox bell)
 *     and clicks inside a `[data-reveal-keep]` element (the inbox panel) keep it.
 *
 * A pull counts when it starts in the part of the screen nearest the edge and every scroller under
 * the finger is already at that end, so scrolling a list never triggers it; it reveals once it has
 * travelled `PULL_PX` mostly toward the screen's middle. A touch outside the element hides it, and
 * so does a navigation that remounts the hook.
 */
type Edge = "top" | "bottom";

type State = {
  edge: Edge;
  // The `<html>` dataset key holding this edge's shown state.
  key: "revealTop" | "revealBottom";
  start: { x: number; y: number } | null;
  onStart: (e: TouchEvent) => void;
  onMove: (e: TouchEvent) => void;
  onClick: (e: MouseEvent) => void;
};

type Self = State & HookInterface;

const PULL_PX = 56;
// A pull must start in this fraction of the viewport nearest its edge.
const START_ZONE = 0.35;

// Whether nothing between `node` and the page can scroll any further toward `edge`.
function atEnd(node: Element | null, edge: Edge): boolean {
  for (let el = node; el && el !== document.body; el = el.parentElement) {
    if (!/(auto|scroll)/.test(getComputedStyle(el).overflowY) || el.scrollHeight <= el.clientHeight) continue;
    const more = edge === "top" ? el.scrollTop > 0 : el.scrollTop + el.clientHeight < el.scrollHeight - 1;
    if (more) return false;
  }
  return true;
}

// Every way a pull ends (revealed, touched outside, followed a link, remounted) sets the same key.
function setShown(key: State["key"], on: boolean) {
  if (on) document.documentElement.dataset[key] = "shown";
  else delete document.documentElement.dataset[key];
}

export const EdgeReveal: Hook<State> = {
  mounted(this: Self) {
    this.edge = this.el.dataset.edge === "bottom" ? "bottom" : "top";
    this.key = this.edge === "top" ? "revealTop" : "revealBottom";
    this.start = null;
    setShown(this.key, false);

    this.onStart = (e) => {
      this.start = null;
      if (e.touches.length !== 1) return;
      if (getComputedStyle(this.el).getPropertyValue("--edge-reveal").trim() !== "on") return;
      const target = e.target as Element;
      if (document.documentElement.dataset[this.key] === "shown") {
        if (!this.el.contains(target)) setShown(this.key, false);
        return;
      }
      const t = e.touches[0];
      const fromEdge = this.edge === "top" ? t.clientY : innerHeight - t.clientY;
      if (fromEdge > innerHeight * START_ZONE || !atEnd(target, this.edge)) return;
      this.start = { x: t.clientX, y: t.clientY };
    };

    this.onMove = (e) => {
      if (!this.start) return;
      const t = e.touches[0];
      const travel = this.edge === "top" ? t.clientY - this.start.y : this.start.y - t.clientY;
      if (travel < 0 || Math.abs(t.clientX - this.start.x) > travel) {
        this.start = null;
      } else if (travel >= PULL_PX) {
        this.start = null;
        setShown(this.key, true);
      }
    };

    this.onClick = (e) => {
      const hit = (e.target as Element).closest("a[href], button");
      if (hit && !hit.matches("[popovertarget], [commandfor]") && !hit.closest("[data-reveal-keep]"))
        setShown(this.key, false);
    };

    document.addEventListener("touchstart", this.onStart, { passive: true });
    document.addEventListener("touchmove", this.onMove, { passive: true });
    if (this.el.hasAttribute("data-reveal-hide-on-click")) this.el.addEventListener("click", this.onClick);
  },

  destroyed(this: Self) {
    document.removeEventListener("touchstart", this.onStart);
    document.removeEventListener("touchmove", this.onMove);
    setShown(this.key, false);
  },
};
