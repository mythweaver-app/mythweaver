import Sortable, { type SortableEvent } from "sortablejs";
import type { Hook } from "phoenix_live_view";

/**
 * The app's one drag-and-drop implementation. `sortable/2` sets up every drag in the app, the
 * `SortableList` hook below and the lore tree (`lore_tree.ts`, which adds moving and copying
 * between folders). The markup and styles live in `MythweaverWeb.CoreComponents.DragHandle`.
 *
 *   * A row drags only by its `<.drag_handle>` (`[data-drag-handle]`). A click anywhere else in
 *     the row stays a plain click.
 *   * The dragged row itself moves through the lists and is the drop indicator (`.drag-ghost`).
 *     No floating copy follows the pointer.
 *   * The pointer shows `grabbing` for the whole drag (`:root.drag-active`), or `alias` while a
 *     drag will copy (`:root.drag-copy`, set by the caller). The page can't set the cursor during
 *     native HTML drag and drop, so this uses SortableJS's fallback drag. Its floating copy goes on
 *     `<body>`, where the row's scoped styles don't reach and LiveView's patches can't trip over
 *     its duplicate id, and `.drag-fallback` hides it.
 *   * There is no keyboard alternative.
 *
 * `onStart`/`onEnd` given in `options` run after the shared ones.
 */
export function sortable(el: HTMLElement, options: Sortable.Options = {}): Sortable {
  const { onStart, onEnd, ...rest } = options;
  const root = document.documentElement;

  return new Sortable(el, {
    handle: "[data-drag-handle]",
    ghostClass: "drag-ghost",
    fallbackClass: "drag-fallback",
    forceFallback: true,
    fallbackOnBody: true,
    animation: 150,
    ...rest,
    onStart: (evt: SortableEvent) => {
      root.classList.add("drag-active");
      onStart?.(evt);
    },
    // `destroy()` mid-drag ends the drag too, so the cursor classes never outlive it.
    onEnd: (evt: SortableEvent) => {
      root.classList.remove("drag-active", "drag-copy");
      onEnd?.(evt);
    },
  });
}

/**
 * Drag-to-reorder for a list whose direct children each carry `data-id`. Each row needs a
 * `<.drag_handle>`.
 *
 * Configured from the container:
 *   * `data-sortable-event`    (required) the server event. It receives `{ids}`, the full DOM order.
 *   * `data-sortable-disabled` (optional) `"true"` turns dragging off and hides the handles. It is
 *     re-read on every update, so the server can switch it (the lore book's entry table does
 *     while a column sort is shown).
 *
 * The server owns the order. It persists the permutation and re-renders, or re-renders the old
 * order to snap a refused drag back. It's an external hook rather than a colocated one because the
 * chat participant rail, the prompt editor's block list, the lore book's entries and the model
 * editor's sampler order all share it.
 */
type SortableHook = Hook & { sortable?: Sortable };

export const SortableList: SortableHook = {
  mounted() {
    const event = this.el.dataset.sortableEvent!;

    this.sortable = sortable(this.el, {
      disabled: this.el.dataset.sortableDisabled === "true",
      onEnd: (evt: SortableEvent) => {
        if (evt.oldIndex === evt.newIndex) return;
        this.pushEvent(event, {
          ids: Array.from(this.el.children, (row) => (row as HTMLElement).dataset.id),
        });
      },
    });
  },
  updated() {
    this.sortable?.option("disabled", this.el.dataset.sortableDisabled === "true");
  },
  destroyed() {
    this.sortable?.destroy();
  },
};
