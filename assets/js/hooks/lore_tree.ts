import type Sortable from "sortablejs";
import type { SortableEvent } from "sortablejs";
import { sortable } from "./sortable_list";
import type { Hook } from "phoenix_live_view";

/**
 * The lore page's tree: book folders (`details[data-folder-key]`) of entry rows
 * (`li[data-entry-id]` inside `ul[data-tree-folder][data-book-id]`, `""` for Unlinked).
 *
 * Folder open state is the client's: the server never renders `open`, this hook restores it from
 * `localStorage[data-storage-key]` and keeps LiveView patches from stripping it.
 *
 * Dragging uses the app's one drag implementation (`sortable/2` in `sortable_list.ts`), so rows
 * drag only by their `<.drag_handle>` and a click on a row's link always opens it. Dragging a
 * row to another folder pushes `place_entry` with `{entry_id, from, to, copy, ids}`. Holding the
 * OS primary modifier (Cmd on macOS, Ctrl elsewhere) during the drag sets `copy`, so the entry
 * stays in its source folder too, and shows the copy cursor (`:root.drag-copy`). The dragged node
 * is put back before the push, so the server's re-render is the only thing that moves it.
 */
const PRIMARY = /Mac|iPhone|iPad/.test(navigator.platform) ? "metaKey" : "ctrlKey";

type LoreTreeHook = Hook & {
  sortables: Sortable[];
  copy: boolean;
  onModifier?: (e: KeyboardEvent | PointerEvent) => void;
  restore(): void;
  bind(): void;
  unbind(): void;
  stopDrag(): void;
};

export const LoreTree: LoreTreeHook = {
  sortables: [],
  copy: false,

  mounted() {
    this.sortables = [];
    this.restore();

    // `toggle` does not bubble, so listen in the capture phase.
    this.el.addEventListener(
      "toggle",
      () => {
        const keys = Array.from(
          (this.el as HTMLElement).querySelectorAll<HTMLDetailsElement>("details[data-folder-key][open]"),
          (el) => el.dataset.folderKey,
        );
        localStorage.setItem(this.el.dataset.storageKey!, JSON.stringify(keys));
      },
      true,
    );

    this.bind();
  },

  updated() {
    this.restore();
    this.unbind();
    this.bind();
  },

  destroyed() {
    this.unbind();
    this.stopDrag();
  },

  // Only folders not seen before: a known folder keeps whatever the user did since.
  restore() {
    let stored: unknown[] = [];
    try {
      const parsed = JSON.parse(localStorage.getItem(this.el.dataset.storageKey!) ?? "[]");
      if (Array.isArray(parsed)) stored = parsed;
    } catch {
      stored = [];
    }

    (this.el as HTMLElement)
      .querySelectorAll<HTMLDetailsElement>("details[data-folder-key]:not([data-tree-ready])")
      .forEach((el) => {
        this.js().ignoreAttributes(el, ["open"]);
        el.open = stored.includes(el.dataset.folderKey);
        el.dataset.treeReady = "1";
      });
  },

  bind() {
    (this.el as HTMLElement).querySelectorAll<HTMLElement>("ul[data-tree-folder]").forEach((ul) => {
      this.sortables.push(
        sortable(ul, {
          group: "lore-tree",
          draggable: "li[data-entry-id]",
          onStart: () => {
            this.copy = false;
            this.onModifier = (e) => {
              this.copy = e[PRIMARY];
              document.documentElement.classList.toggle("drag-copy", this.copy);
            };
            window.addEventListener("keydown", this.onModifier);
            window.addEventListener("keyup", this.onModifier);
            window.addEventListener("pointermove", this.onModifier);
          },
          onEnd: (evt: SortableEvent) => {
            const copy = this.copy;
            this.stopDrag();
            if (evt.from === evt.to && evt.oldIndex === evt.newIndex) return;

            const ids = Array.from(
              (evt.to as HTMLElement).querySelectorAll<HTMLElement>("li[data-entry-id]"),
              (li) => li.dataset.entryId,
            );
            const entry = evt.item.dataset.entryId;

            evt.from.insertBefore(evt.item, evt.from.children[evt.oldIndex!] ?? null);

            this.pushEvent("place_entry", {
              entry_id: entry,
              from: evt.from.dataset.bookId,
              to: evt.to.dataset.bookId,
              copy,
              ids,
            });
          },
        }),
      );
    });
  },

  unbind() {
    this.sortables.forEach((s) => s.destroy());
    this.sortables = [];
  },

  stopDrag() {
    if (this.onModifier) {
      window.removeEventListener("keydown", this.onModifier);
      window.removeEventListener("keyup", this.onModifier);
      window.removeEventListener("pointermove", this.onModifier);
      this.onModifier = undefined;
    }
    document.documentElement.classList.remove("drag-copy");
  },
};
