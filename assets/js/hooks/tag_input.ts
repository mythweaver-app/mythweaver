import type { Hook, HookInterface } from "phoenix_live_view";
import { t } from "../i18n";

/**
 * The app's one tag chip input, for every tag field and tag filter
 * (`MythweaverWeb.CoreComponents.TagInput.tag_input/1`).
 *
 * DOM contract:
 *   * The root carries `phx-hook="TagInput"`, an `id`, `data-name` (the list input name, e.g.
 *     `tags[mine][]`), `data-mode` (`tags` | `filter` | `keywords`), optional `data-max` and
 *     `data-vocabulary` (JSON `[{text, ideal, uses}]`, read on each keystroke so a re-render's list
 *     is always current).
 *   * `input[data-tag-sentinel]`: an empty hidden input of that name, so a list with every chip
 *     removed still reaches the server.
 *   * `#<id>-chips`: one `li[data-tag]` per value, each holding a hidden input of that name and a
 *     `[data-tag-remove]` button. The server renders these.
 *   * `template[data-tag-template]`: one such `li`, blank, that a committed value is shown in at
 *     once, before the server's re-render replaces it with its own chip.
 *   * `#<id>-entry` (no `name`, so it never posts) and `#<id>-suggestions` (`role="listbox"`), in a
 *     `phx-update="ignore"` wrapper.
 *
 * Typing never fires the form's `phx-change`: the entry's `input`/`change` events stop here.
 * Committing (Enter, `,`, Tab on a highlighted suggestion, or clicking one) appends a provisional
 * chip, whose hidden input carries the value, and fires `input` from it, which LiveView sends as
 * the form's change; its re-render swaps in the server's chip (ideal, implied, regex marks), or
 * drops the value. Removing a chip (its button, or Backspace in an empty entry) fires `input` from
 * the sentinel. A form submit commits half-typed text first, so Save never drops it.
 *
 * An empty entry suggests the most-used tags (`uses`), when it gains focus and again after each
 * commit or removal; typed text matches prefix-first in vocabulary order.
 *
 * Filter mode keeps a leading `-` (exclude) on a picked suggestion and also offers `ns:*`
 * wildcards. Keywords mode (lore keywords) keeps a comma typed inside a `/regex/` as text, so only
 * Enter commits one, and splits a pasted comma- or line-separated list into several keywords,
 * committed with one change. Shared by a dozen templates, hence an external hook rather than a
 * colocated one.
 */
type Entry = { text: string; ideal: string | null; uses?: number };

type State = {
  entry: HTMLInputElement;
  list: HTMLUListElement;
  options: string[];
  active: number;
  form: HTMLFormElement | null;
  onSubmit: () => void;
};

type Self = State & HookInterface;

const MAX_SUGGESTIONS = 10;

function values(self: Self): string[] {
  const name = self.el.dataset.name ?? "";
  return Array.from(self.el.querySelectorAll<HTMLInputElement>("input[type=hidden]"))
    .filter((i) => i.name === name && i.value !== "")
    .map((i) => i.value);
}

function vocabulary(self: Self): Entry[] {
  try {
    return JSON.parse(self.el.dataset.vocabulary ?? "[]") as Entry[];
  } catch {
    return [];
  }
}

// The typed text split into its exclude sign (filter mode only) and the query.
function typed(self: Self): { sign: string; query: string } {
  const raw = self.entry.value.trimStart();
  if (self.el.dataset.mode === "filter" && raw.startsWith("-")) return { sign: "-", query: raw.slice(1).trim().toLowerCase() };
  return { sign: "", query: raw.trim().toLowerCase() };
}

function suggestions(self: Self): Entry[] {
  const { query } = typed(self);
  const present = new Set(values(self).map((v) => v.replace(/^-/, "")));
  const vocab = vocabulary(self).filter((e) => !present.has(e.text));

  if (query === "") {
    return vocab
      .slice()
      .sort((a, b) => (b.uses ?? 0) - (a.uses ?? 0))
      .slice(0, MAX_SUGGESTIONS);
  }

  const prefix = vocab.filter((e) => e.text.startsWith(query));
  const inner = vocab.filter((e) => !e.text.startsWith(query) && e.text.includes(query));
  let found = [...prefix, ...inner];

  if (self.el.dataset.mode === "filter") {
    const namespaces = new Set(
      vocabulary(self)
        .filter((e) => e.text.includes(":"))
        .map((e) => e.text.slice(0, e.text.indexOf(":"))),
    );
    const wildcards = Array.from(namespaces)
      .filter((ns) => `${ns}:`.startsWith(query) && !present.has(`${ns}:*`))
      .sort()
      .map((ns) => ({ text: `${ns}:*`, ideal: null }));
    found = [...wildcards, ...found];
  }

  return found.slice(0, MAX_SUGGESTIONS);
}

function close(self: Self) {
  self.list.hidden = true;
  self.list.replaceChildren();
  self.options = [];
  self.active = -1;
  self.entry.setAttribute("aria-expanded", "false");
  self.entry.removeAttribute("aria-activedescendant");
}

function highlight(self: Self, index: number) {
  self.active = index;
  Array.from(self.list.children).forEach((li, i) => li.setAttribute("aria-selected", String(i === index)));
  const li = self.list.children[index] as HTMLElement | undefined;
  if (li) {
    self.entry.setAttribute("aria-activedescendant", li.id);
    li.scrollIntoView({ block: "nearest" });
  } else {
    self.entry.removeAttribute("aria-activedescendant");
  }
}

function refresh(self: Self) {
  const found = suggestions(self);
  if (found.length === 0) return close(self);

  self.options = found.map((e) => e.text);
  self.list.replaceChildren(
    ...found.map((e, i) => {
      const li = document.createElement("li");
      li.id = `${self.el.id}-suggestion-${i}`;
      li.setAttribute("role", "option");
      li.dataset.value = e.text;
      li.textContent = e.text;
      if (e.ideal) {
        const ideal = document.createElement("span");
        ideal.className = "tag-input-suggestion-ideal";
        ideal.textContent = `→ ${e.ideal}`;
        li.append(ideal);
      }
      return li;
    }),
  );
  self.list.hidden = false;
  self.entry.setAttribute("aria-expanded", "true");
  highlight(self, -1);
}

function fireChange(input: HTMLInputElement) {
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

// Appends `value` as a provisional chip and returns its hidden input, or null when the value is
// blank or already present.
function addChip(self: Self, value: string): HTMLInputElement | null {
  if (value === "" || value === "-" || values(self).includes(value)) return null;

  const list = self.el.querySelector<HTMLUListElement>(`#${CSS.escape(self.el.id)}-chips`)!;
  if (self.el.dataset.max === "1") list.querySelectorAll(":scope > li").forEach((li) => li.remove());

  const template = self.el.querySelector<HTMLTemplateElement>("template[data-tag-template]")!;
  const li = template.content.firstElementChild!.cloneNode(true) as HTMLLIElement;
  li.dataset.tag = value;
  li.querySelector(".tag-chip-name")!.textContent = value;
  li.querySelector("[data-tag-remove]")!.setAttribute("aria-label", t("tag_remove", { tag_name: value }));
  const input = li.querySelector<HTMLInputElement>("input[type=hidden]")!;
  input.value = value;
  list.append(li);
  return input;
}

// Adds `text` as a provisional chip; `notify: false` when a submit is about to carry it anyway.
function commit(self: Self, text: string, notify = true) {
  self.entry.value = "";
  close(self);
  const input = addChip(self, text.trim());
  if (input && notify) fireChange(input);
  if (document.activeElement === self.entry) refresh(self);
}

function commitTyped(self: Self, notify = true) {
  const { sign } = typed(self);
  const picked = self.options[self.active];
  commit(self, picked ? sign + picked : self.entry.value, notify);
}

// Removes a chip (server or provisional) and tells the form through the sentinel, which always posts.
function removeValue(self: Self, el: Element) {
  el.remove();
  const sentinel = self.el.querySelector<HTMLInputElement>("input[data-tag-sentinel]");
  if (sentinel) fireChange(sentinel);
  if (document.activeElement === self.entry) refresh(self);
}

function removeLast(self: Self) {
  const chips = self.el.querySelectorAll(`#${CSS.escape(self.el.id)}-chips > li`);
  const last = chips[chips.length - 1];
  if (last) removeValue(self, last);
}

export const TagInput: Hook<State> = {
  mounted(this: Self) {
    this.entry = this.el.querySelector<HTMLInputElement>(`#${CSS.escape(this.el.id)}-entry`)!;
    this.list = this.el.querySelector<HTMLUListElement>(`#${CSS.escape(this.el.id)}-suggestions`)!;
    this.options = [];
    this.active = -1;

    // Typing is local: only a committed tag reaches the form's `phx-change`.
    for (const type of ["input", "change"]) {
      this.entry.addEventListener(type, (e) => {
        e.stopPropagation();
        if (type === "input") refresh(this);
      });
    }

    this.entry.addEventListener("keydown", (e) => {
      const open = !this.list.hidden && this.options.length > 0;

      switch (e.key) {
        case "Enter":
          e.preventDefault();
          commitTyped(this);
          break;
        case ",":
          // A comma inside a keyword regex (`/a{1,3}/`) is part of it.
          if (this.el.dataset.mode === "keywords" && this.entry.value.trimStart().startsWith("/")) break;
          e.preventDefault();
          commit(this, this.entry.value);
          break;
        case "Tab":
          if (open && this.active >= 0) {
            e.preventDefault();
            commitTyped(this);
          }
          break;
        case "Backspace":
          if (this.entry.value === "") {
            e.preventDefault();
            removeLast(this);
          }
          break;
        case "ArrowDown":
          e.preventDefault();
          if (open) highlight(this, (this.active + 1) % this.options.length);
          else refresh(this);
          break;
        case "ArrowUp":
          if (open) {
            e.preventDefault();
            highlight(this, this.active <= 0 ? this.options.length - 1 : this.active - 1);
          }
          break;
        case "Escape":
          if (open) {
            e.preventDefault();
            e.stopPropagation();
            close(this);
          }
          break;
      }
    });

    this.entry.addEventListener("focus", () => refresh(this));
    this.entry.addEventListener("blur", () => close(this));

    // A keyword list pasted from elsewhere ("dragon, wyrm") becomes one chip per keyword. A
    // pasted regex, or a paste into a half-typed one, stays as typed text.
    this.entry.addEventListener("paste", (e) => {
      if (this.el.dataset.mode !== "keywords") return;
      const text = e.clipboardData?.getData("text") ?? "";
      const typedSoFar = this.entry.value.trimStart();
      if (!/[,\n]/.test(text) || text.trimStart().startsWith("/") || typedSoFar.startsWith("/")) return;

      e.preventDefault();
      const added = (typedSoFar + text)
        .split(/[,\n]/)
        .map((part) => addChip(this, part.trim()))
        .filter((input): input is HTMLInputElement => input !== null);
      this.entry.value = "";
      close(this);
      const last = added[added.length - 1];
      if (last) fireChange(last);
    });

    // `mousedown` keeps focus in the entry, so its blur does not close the list first.
    this.list.addEventListener("mousedown", (e) => {
      const li = (e.target as Element | null)?.closest<HTMLElement>("li[data-value]");
      if (!li) return;
      e.preventDefault();
      commit(this, typed(this).sign + (li.dataset.value ?? ""));
    });

    this.el.addEventListener("click", (e) => {
      const button = (e.target as Element | null)?.closest("[data-tag-remove]");
      if (!button || !this.el.contains(button)) return;
      e.preventDefault();
      const li = button.closest("li");
      if (li) removeValue(this, li);
      this.entry.focus();
    });

    // On the form element, so it runs before LiveView's window-level submit listener reads it.
    this.form = this.el.closest("form");
    this.onSubmit = () => {
      if (this.entry.value.trim() !== "") commitTyped(this, false);
    };
    this.form?.addEventListener("submit", this.onSubmit);
  },

  destroyed(this: Self) {
    this.form?.removeEventListener("submit", this.onSubmit);
  },
};
