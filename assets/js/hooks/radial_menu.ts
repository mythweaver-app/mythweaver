import type { Hook } from "phoenix_live_view";

/**
 * The radial (pie) menu. Markup contract and styles: `MythweaverWeb.CoreComponents.RadialMenu`.
 *
 * Right-click (mouse, opened on the press) or long-press (touch) on a `[data-radial-menu]` row
 * opens a ring of that row's `[data-radial-item]` controls around the pointer, each on its
 * `data-radial-slot` (0 = N, clockwise; the target's `data-radial-slots` divides the ring, 8 by
 * default, and a ring of many slots grows to keep its slices apart). A control that is disabled
 * or hidden, and a slot only the target's `data-radial-layout` template names, shows dimmed and
 * can't be picked. Press-drag-release onto a slice activates it, and releasing back at the center
 * cancels; releasing without a drag leaves the ring open for a tap. A slice activates its control
 * with `.click()`, so the control's own `phx-click`, `data-confirm` and permissions apply.
 *
 * The ring is a modal `<dialog>`: `MythweaverWeb.Shortcuts` skips its bindings while any
 * `dialog[open]` exists, and Escape closes it natively. It's an external hook rather than a
 * colocated one because every opted-in surface shares the one instance `Layouts.app` renders.
 */

const LONG_PRESS_MS = 450;
const MOVE_TOLERANCE_PX = 10;
const DEAD_ZONE_PX = 24;
// A drag that comes back this close to the ring's center highlights nothing, so releasing there
// cancels.
const CENTER_CANCEL_PX = 40;
const CLICK_SUPPRESS_MS = 700;
const RADIUS_FINE = 84;
const RADIUS_COARSE = 104;
// Center-to-center distance between neighbouring slices along the ring: the slice (2.5rem, or
// the 44px touch target) plus a gap. A ring of many slots takes the radius that keeps it.
const PITCH_FINE = 52;
const PITCH_COARSE = 58;
const EDGE_PAD = 32;
const DEFAULT_SLOTS = 8;

const MOUSE_SKIP = "input, textarea, select, [contenteditable], .cm-editor, a[href]";
const TOUCH_SKIP =
  "input, textarea, select, button, a[href], label, summary, [contenteditable], .cm-editor, [data-drag-handle], [data-radial-native]";

type Point = { x: number; y: number };
// `el` is the row's control; null for a slot only the target's layout names. A disabled entry is
// drawn dimmed and can't be picked, so the ring keeps its shape on every row.
type Entry = { el: HTMLElement | null; label: string; icon: Element; enabled: boolean };

type OpenState = {
  target: HTMLElement;
  entries: Map<number, Entry>;
  slots: number;
  center: Point;
  origin: Point;
  pressing: boolean;
  pointerId: number | null;
  dragged: boolean;
  active: number | null;
};

type Pending = { pointerId: number; x: number; y: number; target: HTMLElement; timer: number };

type OpenOptions = { pressing?: boolean; pointerId?: number | null; keyboard?: boolean; touch?: boolean };

function visible(el: HTMLElement): boolean {
  if (typeof el.checkVisibility === "function") return el.checkVisibility();
  return el.offsetParent !== null || getComputedStyle(el).position === "fixed";
}

function labelOf(el: Element): string {
  return el.getAttribute("aria-label") ?? el.getAttribute("title") ?? el.textContent?.trim() ?? "";
}

function slotOf(el: HTMLElement, slots: number): number | null {
  const slot = Number(el.dataset.radialSlot);
  return Number.isInteger(slot) && slot >= 0 && slot < slots ? slot : null;
}

/**
 * The target's ring: its own `[data-radial-item]` controls (on a slot, the first usable one wins,
 * else the first), then every remaining slot its `data-radial-layout` template names, disabled.
 */
function collect(target: HTMLElement, slots: number): Map<number, Entry> {
  const entries = new Map<number, Entry>();

  for (const el of target.querySelectorAll<HTMLElement>("[data-radial-item]")) {
    if (el.closest("[data-radial-menu]") !== target) continue;
    const svg = el.querySelector("svg.iconex");
    const slot = slotOf(el, slots);
    if (!svg || slot === null) continue;

    const enabled = !el.matches(":disabled, [aria-disabled='true']") && visible(el);
    const prev = entries.get(slot);
    if (prev && (prev.enabled || !enabled)) continue;
    entries.set(slot, { el, label: labelOf(el), icon: svg.cloneNode(true) as Element, enabled });
  }

  const layoutId = target.dataset.radialLayout;
  const layout = layoutId ? document.getElementById(layoutId) : null;
  if (layout instanceof HTMLTemplateElement) {
    for (const el of layout.content.querySelectorAll<HTMLElement>("[data-radial-slot]")) {
      const svg = el.querySelector("svg.iconex");
      const slot = slotOf(el, slots);
      if (!svg || slot === null || entries.has(slot)) continue;
      const icon = svg.cloneNode(true) as Element;
      entries.set(slot, { el: null, label: labelOf(el), icon, enabled: false });
    }
  }

  return entries;
}

function setup(host: HTMLElement): () => void {
  const ring = document.createElement("dialog");
  ring.className = "radial-menu";
  ring.tabIndex = -1;
  host.appendChild(ring);

  let state: OpenState | null = null;
  let pending: Pending | null = null;
  let lastPointerType = "mouse";
  let suppressClickUntil = 0;
  // True while a slice's own `.click()` runs: a tap soon after a long-press must reach its control.
  let activating = false;
  // A right-press opened the ring itself; the contextmenu event it still brings (on press on macOS
  // and Linux, on release on Windows) must not open the native menu or a second ring.
  let swallowContextMenu = false;

  /** The target a right-click at `origin` opens, or null where the native menu stays. */
  function menuTarget(origin: Element | null, e: MouseEvent): HTMLElement | null {
    const target = origin?.closest<HTMLElement>("[data-radial-menu]");
    if (!origin || !target || e.shiftKey || origin.closest(MOUSE_SKIP)) return null;
    if (document.getSelection()?.isCollapsed === false) return null;
    return target;
  }

  function cancelPending() {
    if (!pending) return;
    clearTimeout(pending.timer);
    pending = null;
  }

  // A non-passive touchmove listener blocks passive scrolling, so it is on the document only
  // while a touch press on a target is pending or the ring is open.
  function holdTouch() {
    document.addEventListener("touchmove", onTouchMove, { passive: false });
  }

  function releaseTouch() {
    document.removeEventListener("touchmove", onTouchMove);
  }

  function open(target: HTMLElement, x: number, y: number, opts: OpenOptions = {}): boolean {
    // On touch a message's controls exist only while its row holds focus (`messages.ex`).
    if (opts.touch && target.hasAttribute("tabindex")) target.focus({ preventScroll: true });

    const count = Number(target.dataset.radialSlots);
    const slots = Number.isInteger(count) && count > 0 ? count : DEFAULT_SLOTS;
    const entries = collect(target, slots);
    if (![...entries.values()].some((entry) => entry.enabled)) return false;

    const label = target.dataset.radialMenu ?? "";
    const children: Element[] = [];

    // Slot order, so the arrow keys walk the ring clockwise.
    for (const [slot, entry] of [...entries].sort(([a], [b]) => a - b)) {
      const slice = document.createElement("button");
      slice.type = "button";
      slice.className = "radial-menu-slice";
      slice.setAttribute("role", "menuitem");
      slice.setAttribute("aria-label", entry.label);
      slice.style.setProperty("--radial-angle", `${(slot * 360) / slots}deg`);
      slice.dataset.slot = String(slot);
      const pressed = entry.el?.getAttribute("aria-pressed");
      if (pressed != null) slice.setAttribute("aria-pressed", pressed);
      if (entry.el?.hasAttribute("data-radial-danger")) slice.dataset.danger = "";
      slice.appendChild(entry.icon);
      if (entry.enabled) {
        slice.addEventListener("click", () => activate(slot));
        // Mouse hover only: a touch names a slice only while dragging onto it (`highlight`).
        slice.addEventListener("pointerenter", (e) => {
          if (e.pointerType === "mouse") describe(slot);
        });
        slice.addEventListener("pointerleave", (e) => {
          if (e.pointerType === "mouse") describe(state?.active ?? null);
        });
      } else {
        slice.disabled = true;
      }
      children.push(slice);
    }

    const hubEl = document.createElement("span");
    hubEl.className = "radial-menu-hub";
    hubEl.textContent = label;
    children.push(hubEl);

    ring.replaceChildren(...children);
    ring.setAttribute("role", "menu");
    ring.setAttribute("aria-label", label);

    const coarse = matchMedia("(pointer: coarse)").matches;
    const radius = Math.max(
      coarse ? RADIUS_COARSE : RADIUS_FINE,
      Math.ceil((slots * (coarse ? PITCH_COARSE : PITCH_FINE)) / (2 * Math.PI)),
    );
    const reach = radius + EDGE_PAD;
    const center = {
      x: Math.max(reach, Math.min(x, window.innerWidth - reach)),
      y: Math.max(reach, Math.min(y, window.innerHeight - reach)),
    };
    ring.style.setProperty("--radial-radius", `${radius}px`);
    ring.style.left = `${center.x}px`;
    ring.style.top = `${center.y}px`;

    ring.showModal();
    if (opts.keyboard) {
      ring
        .querySelector<HTMLElement>(".radial-menu-slice:not(:disabled)")
        ?.focus({ preventScroll: true });
    } else {
      ring.focus({ preventScroll: true });
    }

    const pressing = !!opts.pressing && opts.pointerId != null;
    if (pressing) {
      try {
        ring.setPointerCapture(opts.pointerId!);
      } catch {
        // No capture: moves stop arriving and the ring stays open for a tap.
      }
    }

    state = {
      target,
      entries,
      slots,
      center,
      origin: { x, y },
      pressing,
      pointerId: opts.pointerId ?? null,
      dragged: false,
      active: null,
    };
    return true;
  }

  function close() {
    if (ring.open) ring.close();
  }

  function activate(slot: number) {
    const entry = state?.entries.get(slot);
    // Closing first: the modal ring leaves the rest of the page inert, and an inert control
    // must not be clicked.
    close();
    if (!entry?.el || !entry.enabled) return;
    const live = entry.el.isConnected ? entry.el : document.getElementById(entry.el.id);
    if (!live || live.matches(":disabled, [aria-disabled='true']")) return;
    activating = true;
    try {
      live.click();
    } finally {
      activating = false;
    }
  }

  function highlight(slot: number | null) {
    if (!state || state.active === slot) return;
    state.active = slot;
    for (const slice of ring.querySelectorAll<HTMLElement>(".radial-menu-slice")) {
      slice.toggleAttribute("data-active", Number(slice.dataset.slot) === slot);
    }
    describe(slot);
  }

  /** The hub names `slot`'s action, or the target when `slot` is null. */
  function describe(slot: number | null) {
    const hubEl = ring.querySelector<HTMLElement>(".radial-menu-hub");
    if (!state || !hubEl) return;
    hubEl.textContent =
      slot === null ? (state.target.dataset.radialMenu ?? "") : state.entries.get(slot)!.label;
  }

  const onClose = () => {
    state = null;
    ring.replaceChildren();
    releaseTouch();
  };

  const onRingKeydown = (e: KeyboardEvent) => {
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
    if (!step || !state) return;
    e.preventDefault();
    const buttons = Array.from(
      ring.querySelectorAll<HTMLButtonElement>(".radial-menu-slice:not(:disabled)"),
    );
    if (buttons.length === 0) return;
    const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
    const next =
      index === -1
        ? step > 0
          ? 0
          : buttons.length - 1
        : (index + step + buttons.length) % buttons.length;
    buttons[next].focus();
  };

  const onContextMenu = (e: MouseEvent) => {
    if (ring.open || swallowContextMenu) {
      swallowContextMenu = false;
      e.preventDefault();
      return;
    }

    const origin = e.target instanceof Element ? e.target : null;
    const target = menuTarget(origin, e);
    if (!origin || !target) return;

    if (lastPointerType !== "mouse") {
      if (origin.closest(TOUCH_SKIP)) return;
      const press = pending;
      cancelPending();
      const opened = press
        ? open(press.target, press.x, press.y, {
            pressing: true,
            pointerId: press.pointerId,
            touch: true,
          })
        : open(target, e.clientX, e.clientY, { touch: true });
      if (opened) {
        holdTouch();
        e.preventDefault();
        suppressClickUntil = Date.now() + CLICK_SUPPRESS_MS;
        document.getSelection()?.removeAllRanges();
      }
      return;
    }

    // A keyboard menu key, or a Ctrl+click (macOS); a right-press opened the ring on pointerdown.
    let opened: boolean;
    if (e.clientX === 0 && e.clientY === 0) {
      const rect = target.getBoundingClientRect();
      opened = open(target, rect.left + rect.width / 2, rect.top + rect.height / 2, {
        keyboard: true,
      });
    } else {
      const pointerId = e instanceof PointerEvent ? e.pointerId : 1;
      opened = open(target, e.clientX, e.clientY, { pressing: e.buttons !== 0, pointerId });
    }
    if (opened) e.preventDefault();
  };

  const onPointerDown = (e: PointerEvent) => {
    lastPointerType = e.pointerType;
    swallowContextMenu = false;
    const origin = e.target instanceof Element ? e.target : null;

    if (ring.open) {
      // A right-press on the open ring picks the usable slice under it, and anywhere else
      // dismisses the ring; its contextmenu must not reopen one.
      if (e.pointerType === "mouse" && e.button === 2) {
        swallowContextMenu = true;
        const slice = origin?.closest<HTMLButtonElement>(".radial-menu-slice");
        if (slice && !slice.disabled) {
          activate(Number(slice.dataset.slot));
        } else {
          close();
        }
      } else if (e.target === ring) {
        close();
      }
      return;
    }

    // Mouse: the ring opens on the right button's press on every platform, so press-drag-release
    // works like a touch long-press (Windows fires contextmenu only on release).
    if (e.pointerType === "mouse") {
      if (e.button !== 2) return;
      const target = menuTarget(origin, e);
      if (target && open(target, e.clientX, e.clientY, { pressing: true, pointerId: e.pointerId })) {
        swallowContextMenu = true;
      }
      return;
    }

    if (!e.isPrimary) return;
    const target = origin?.closest<HTMLElement>("[data-radial-menu]");
    if (!origin || !target || origin.closest(TOUCH_SKIP)) return;

    cancelPending();
    holdTouch();
    const { pointerId, clientX: x, clientY: y } = e;
    pending = {
      pointerId,
      x,
      y,
      target,
      timer: window.setTimeout(() => {
        pending = null;
        if (open(target, x, y, { pressing: true, pointerId, touch: true })) {
          suppressClickUntil = Date.now() + CLICK_SUPPRESS_MS;
          document.getSelection()?.removeAllRanges();
        }
      }, LONG_PRESS_MS),
    };
  };

  const onPointerMove = (e: PointerEvent) => {
    if (pending && e.pointerId === pending.pointerId) {
      if (Math.hypot(e.clientX - pending.x, e.clientY - pending.y) > MOVE_TOLERANCE_PX) {
        cancelPending();
      }
      return;
    }

    if (!state || !state.pressing || e.pointerId !== state.pointerId) return;

    if (!state.dragged) {
      const travel = Math.hypot(e.clientX - state.origin.x, e.clientY - state.origin.y);
      if (travel < DEAD_ZONE_PX) return;
      state.dragged = true;
    }

    const dx = e.clientX - state.center.x;
    const dy = e.clientY - state.center.y;
    if (Math.hypot(dx, dy) < CENTER_CANCEL_PX) {
      highlight(null);
      return;
    }
    const angle = ((Math.atan2(dx, -dy) * 180) / Math.PI + 360) % 360;
    const slot = Math.round((angle * state.slots) / 360) % state.slots;
    highlight(state.entries.get(slot)?.enabled ? slot : null);
  };

  const onPointerEnd = (e: PointerEvent) => {
    if (pending && e.pointerId === pending.pointerId) cancelPending();
    if (!ring.open) releaseTouch();

    if (!state || !state.pressing || e.pointerId !== state.pointerId) return;

    if (state.dragged) {
      if (state.active !== null) {
        activate(state.active);
      } else {
        close();
      }
      return;
    }

    state.pressing = false;
    try {
      if (ring.hasPointerCapture(e.pointerId)) ring.releasePointerCapture(e.pointerId);
    } catch {
      // Already released.
    }
  };

  const onClick = (e: MouseEvent) => {
    if (activating || Date.now() >= suppressClickUntil) return;
    if (e.target instanceof Node && ring.contains(e.target)) return;
    e.preventDefault();
    e.stopPropagation();
    suppressClickUntil = 0;
  };

  function onTouchMove(e: TouchEvent) {
    if (ring.open) e.preventDefault();
  }

  // Only a pending long-press ends on scroll: the open ring stays put while the page scrolls
  // under it (the chat's auto-scroll while a reply streams); wheel, resize and a backdrop tap
  // close it, and touch scrolling is blocked while it is open.
  const onScroll = () => {
    cancelPending();
  };

  ring.addEventListener("close", onClose);
  ring.addEventListener("keydown", onRingKeydown);
  document.addEventListener("contextmenu", onContextMenu);
  document.addEventListener("pointerdown", onPointerDown, { capture: true, passive: true });
  document.addEventListener("pointermove", onPointerMove, { passive: true });
  document.addEventListener("pointerup", onPointerEnd);
  document.addEventListener("pointercancel", onPointerEnd);
  document.addEventListener("click", onClick, true);
  document.addEventListener("wheel", close, { passive: true });
  document.addEventListener("scroll", onScroll, true);
  window.addEventListener("resize", close);

  return () => {
    cancelPending();
    document.removeEventListener("contextmenu", onContextMenu);
    document.removeEventListener("pointerdown", onPointerDown, true);
    document.removeEventListener("pointermove", onPointerMove);
    document.removeEventListener("pointerup", onPointerEnd);
    document.removeEventListener("pointercancel", onPointerEnd);
    document.removeEventListener("click", onClick, true);
    document.removeEventListener("touchmove", onTouchMove);
    document.removeEventListener("wheel", close);
    document.removeEventListener("scroll", onScroll, true);
    window.removeEventListener("resize", close);
    close();
    ring.remove();
  };
}

type RadialMenuHook = Hook & { teardown?: () => void };

export const RadialMenu: RadialMenuHook = {
  mounted() {
    this.teardown = setup(this.el);
  },
  destroyed() {
    this.teardown?.();
  },
};
