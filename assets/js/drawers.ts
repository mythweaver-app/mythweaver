// Closes an open drawer (`MythweaverWeb.CoreComponents.Drawer`) once a link inside it is
// followed (a patch keeps the drawer element, so it would stay open), or any button inside one
// marked `data-drawer-actions` (the chat's ⋯ sheet). Folder toggles, checkboxes and other
// buttons in a list drawer keep it open.
document.addEventListener("click", (event) => {
  const target = event.target as Element | null;
  const drawer = target?.closest<HTMLElement>("[popover].drawer");
  if (!drawer || !drawer.matches(":popover-open")) return;
  const closer = drawer.hasAttribute("data-drawer-actions") ? "a[href], button" : "a[href]";
  const hit = target!.closest(closer);
  if (hit && drawer.contains(hit)) drawer.hidePopover();
});

// Side drawers marked `data-drawer-swipe` (the chat picker and participants, every two-pane list)
// also follow a sideways flick: rightward opens the collapsed `drawer--start` one, leftward the
// `drawer--end` one, and a flick toward an open one's own edge closes it. Collapsed means closed and
// below its breakpoint (`--drawer-active: 1`), so the breakpoint stays in the stylesheet and a panel
// hidden for another reason (a collapsed rail) does not open.
//
// A flick is quick, long and mostly sideways, and never starts in a text field or editor, in
// something that scrolls sideways, or with text selected, so it cannot steal a drag, a caret move
// or a selection.
const FLICK_PX = 64;
const FLICK_MS = 500;
let flick: { x: number; y: number; at: number } | null = null;

document.addEventListener(
  "touchstart",
  (event) => {
    flick = null;
    if (event.touches.length !== 1) return;
    const target = event.target as Element;
    if (target.closest("input, textarea, select, [contenteditable]")) return;
    for (let el: Element | null = target; el && el !== document.body; el = el.parentElement) {
      const sideways = /(auto|scroll)/.test(getComputedStyle(el).overflowX) && el.scrollWidth > el.clientWidth;
      if (sideways) return;
    }
    const t = event.touches[0];
    flick = { x: t.clientX, y: t.clientY, at: event.timeStamp };
  },
  { passive: true },
);

document.addEventListener(
  "touchend",
  (event) => {
    if (!flick) return;
    const t = event.changedTouches[0];
    const dx = t.clientX - flick.x;
    const dy = t.clientY - flick.y;
    const quick = event.timeStamp - flick.at <= FLICK_MS;
    flick = null;
    if (!quick || Math.abs(dx) < FLICK_PX || Math.abs(dx) < 2 * Math.abs(dy)) return;
    if (document.getSelection()?.isCollapsed === false) return;

    const open = document.querySelector<HTMLElement>("[popover].drawer[data-drawer-swipe]:popover-open");
    if (open) {
      if (open.matches(dx < 0 ? ".drawer--start" : ".drawer--end")) open.hidePopover();
      return;
    }
    const side = dx > 0 ? ".drawer--start" : ".drawer--end";
    [...document.querySelectorAll<HTMLElement>(`[popover].drawer[data-drawer-swipe]${side}`)]
      .find((drawer) => getComputedStyle(drawer).getPropertyValue("--drawer-active").trim() === "1")
      ?.showPopover();
  },
  { passive: true },
);
