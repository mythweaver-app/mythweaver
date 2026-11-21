import type { Hook, HookInterface } from "phoenix_live_view";

/**
 * The app's one shift-click range selection, for every list of select checkboxes.
 *
 * The rule: shift-clicking an unchecked box checks it and every box between it and the nearest
 * other checked box, in DOM (display) order; on a tie the earlier box wins. Any other click is a
 * plain toggle and goes through untouched: no shift, a box being unchecked, or no other box
 * checked. Only the container's own boxes count, so a range never reaches into another list.
 *
 * DOM contract:
 *   * The list's container carries `phx-hook="RangeSelect"` and an `id`.
 *   * Each box that takes part carries `data-range-id`, the row's id. Other checkboxes inside the
 *     container (a select-all box, a per-row setting) don't, and are ignored.
 *   * `data-range-event` on the container (optional) is for a list whose selection the server
 *     keeps, with a `phx-click` on each box. A range click is then sent as that one event with
 *     `{ids}`, every box in the range, the clicked one included, and the box's own `phx-click` is
 *     not sent. The server adds them all to its selection, ignoring ids it doesn't list.
 *     The server does not re-render the rows for a toggle or range (the browser already set the
 *     boxes); for Select all and Clear it pushes `bulk_checks` with every selected `ids` entry,
 *     and the hook sets each of its boxes to match. Re-rendering streamed rows would replace
 *     their content, losing the focused box and the list's scroll position. Boxes sharing a
 *     `data-range-id` (one row shown twice) are kept in step on every click.
 *   * Without `data-range-event` the boxes sit in a form: the range is checked during the click,
 *     before the clicked box's input event, so the form's `phx-change` (or its submit) carries the
 *     whole range at once.
 *
 * A click on a box's `<label>` reaches the box as a second, synthetic click that may drop
 * `shiftKey`, so the shift state is also taken from the `pointerdown`. That `pointerdown` is
 * cancelled on a box or its label, or shift-click would also select the text between.
 *
 * Shared by the chat's message selection, the lore book's entry table, the memory panel's source
 * and message pickers, every `MythweaverWeb.MultiSelect`, and every list's bulk select mode
 * (`MythweaverWeb.Bulk`, whose `data-range-id`s are `<list>:<id>`), hence an external hook rather
 * than a colocated one.
 */
type State = { shift: boolean };

type Self = State & HookInterface;

const BOX = "input[type=checkbox][data-range-id]";

// The box a pointer press lands on, directly or through its label.
function pressedBox(target: EventTarget | null): HTMLInputElement | null {
  const control = target instanceof Element ? (target.closest("label")?.control ?? target) : null;
  return control instanceof HTMLInputElement && control.matches(BOX) ? control : null;
}

// The boxes from `box` to the nearest other checked one, both included, or [] when none is checked.
function rangeOf(boxes: HTMLInputElement[], box: HTMLInputElement): HTMLInputElement[] {
  const to = boxes.indexOf(box);
  let from = -1;

  boxes.forEach((other, i) => {
    if (other === box || !other.checked) return;
    if (from < 0 || Math.abs(i - to) < Math.abs(from - to)) from = i;
  });

  if (from < 0 || to < 0) return [];
  return boxes.slice(Math.min(from, to), Math.max(from, to) + 1);
}

// A row listed twice (a lore entry in two books) has a box per copy, sharing its `data-range-id`.
// The rows are not re-rendered on a click, so every copy takes the state of the changed ones here.
function mirror(container: HTMLElement, changed: HTMLInputElement[]) {
  const state = new Map(changed.map((b) => [b.dataset.rangeId, b.checked]));
  for (const b of container.querySelectorAll<HTMLInputElement>(BOX)) {
    const checked = state.get(b.dataset.rangeId);
    if (checked !== undefined) b.checked = checked;
  }
}

export const RangeSelect: Hook<State> = {
  mounted(this: Self) {
    this.shift = false;

    // Only the `MythweaverWeb.Bulk` lists: another selection on the page keeps its own boxes.
    if (this.el.dataset.rangeEvent === "bulk_range") {
      this.handleEvent("bulk_checks", ({ ids }: { ids: string[] }) => {
        const selected = new Set(ids);
        for (const box of this.el.querySelectorAll<HTMLInputElement>(BOX)) {
          box.checked = selected.has(box.dataset.rangeId ?? "");
        }
      });
    }

    this.el.addEventListener(
      "pointerdown",
      (e) => {
        this.shift = e.shiftKey;
        if (e.shiftKey && pressedBox(e.target)) e.preventDefault();
      },
      true,
    );

    this.el.addEventListener("click", (e) => {
      const box = e.target;
      if (!(box instanceof HTMLInputElement) || !box.matches(BOX)) return;

      const shift = e.shiftKey || this.shift;
      this.shift = false;
      // The browser has already toggled the box, so a checked box was unchecked before.
      if (!shift || !box.checked) {
        mirror(this.el, [box]);
        return;
      }

      const range = rangeOf(Array.from(this.el.querySelectorAll<HTMLInputElement>(BOX)), box);
      if (range.length === 0) {
        mirror(this.el, [box]);
        return;
      }

      for (const b of range) b.checked = true;
      mirror(this.el, range);
      window.getSelection()?.removeAllRanges();

      const event = this.el.dataset.rangeEvent;
      if (!event) return;
      // Stopping it here keeps LiveView's window-level click binding from also sending the box's
      // own `phx-click`.
      e.stopPropagation();
      this.pushEvent(event, { ids: range.map((b) => b.dataset.rangeId) });
    });
  },
};
