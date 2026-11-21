import type { Hook, HookInterface } from "phoenix_live_view";
import { t } from "../i18n";

/**
 * Unsaved-changes guard for a form whose edits only apply on submit (Save/Apply).
 *
 * DOM contract: `this.el` is the `<form>`. It carries `data-saved` whenever the server rendered it
 * from saved values (after load or a successful save: a fresh changeset, `is_nil(@form.action)`),
 * and drops it while it shows the user's edits (a `phx-change` validate or a refused save). A form
 * without `phx-change` always shows saved values, so it always carries `data-saved`.
 *
 * Saved values: on a `data-saved` render each control's rendered value is its saved value: the
 * `value`/`checked`/`selected` attributes (`defaultValue` and friends), or `<.editor>`'s
 * `data-value`, since its textarea sits under `phx-update="ignore"`. LiveView does not patch the
 * attributes of the focused control, so that one keeps its previous saved value, or takes its live
 * value when this render is the one right after a save. Renders without `data-saved` keep the saved
 * values as they were.
 *
 * Marking: a field whose live value differs from its saved value gets `data-unsaved`, on the control
 * (on `<.editor>`'s box for its hidden textarea) and on its labels, and the form itself carries
 * `data-unsaved` while any field (hidden ones included) does, which turns its `<.form_actions>` row
 * into a sticky bar. The attribute is kept across patches with `ignoreAttributes`, so LiveView's
 * morph neither strips a mark nor revives a cleared one; it is recomputed on every edit and every
 * update.
 *
 * Leaving: while any guarded form has unsaved fields, LiveView link navigation and back/forward
 * (`phx:before-navigate`) ask first and are cancelled when declined, closing the tab or reloading
 * gets the browser's `beforeunload` prompt, and dismissing the `<.modal>` around the form
 * (`modal:before-close`) asks too. Server-side navigation (`push_patch`/`push_navigate`) is not
 * asked about: the server already decided it, e.g. after a save.
 *
 * Saving: ⌘Enter (Ctrl+Enter off Apple platforms) anywhere in the form submits it, as its Save
 * button would. It listens in the capture phase so it runs before `<.editor>`'s CodeMirror, whose
 * own Mod-Enter would insert a blank line.
 *
 * Controls inside a `[data-unsaved-ignore]` element (a multi-select's search and tag filter) are
 * view state, not fields: never compared, never marked.
 *
 * Shared by the chat settings, chat memory settings, participant settings, memory profile and
 * account forms, hence an external hook rather than a colocated one.
 */
type Control = HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement;
type Values = Map<string, string>;

type State = {
  saved: boolean;
  baseline: Values;
  dirty: boolean;
  marked: Set<Element>;
  kept: WeakSet<Element>;
  dialog: HTMLDialogElement | null;
  onEdit: () => void;
  onBeforeClose: (e: Event) => void;
  rebase(justSaved: boolean): void;
  refresh(): void;
};

type Self = State & HookInterface<HTMLFormElement>;

const MARK = "data-unsaved";
const NOT_VALUES: Record<string, true> = { submit: true, button: true, reset: true, image: true, file: true };

const guarded = new Set<Self>();
// Set once the user agreed to drop the edits for the navigation under way, so a full page load it
// turns into does not ask a second time; cleared when that navigation ends or the user edits again.
let discarding = false;

const onBeforeNavigate = (e: Event) => {
  if (!Array.from(guarded).some((hook) => hook.dirty)) return;
  if (window.confirm(t("unsaved_changes"))) discarding = true;
  else e.preventDefault();
};

const onBeforeUnload = (e: BeforeUnloadEvent) => {
  if (discarding || !Array.from(guarded).some((hook) => hook.dirty)) return;
  e.preventDefault();
  e.returnValue = "";
};

const onLoadingStop = () => {
  discarding = false;
};

const PRIMARY = /Mac|iPhone|iPad/.test(navigator.platform) ? "metaKey" : "ctrlKey";

const onSubmitKey = (e: KeyboardEvent) => {
  if (e.key !== "Enter" || !e[PRIMARY] || e.shiftKey || e.altKey || e.isComposing || e.repeat) return;
  e.preventDefault();
  e.stopPropagation();
  (e.currentTarget as HTMLFormElement).requestSubmit();
};

function isControl(el: Element | null): el is Control {
  return (
    el instanceof HTMLInputElement ||
    el instanceof HTMLSelectElement ||
    el instanceof HTMLTextAreaElement
  );
}

function controls(form: HTMLFormElement): Control[] {
  return Array.from(form.elements).filter(
    (el): el is Control =>
      isControl(el) &&
      el.name !== "" &&
      !el.disabled &&
      !NOT_VALUES[el.type] &&
      !el.closest("[data-unsaved-ignore]"),
  );
}

function isCheckable(el: Control): el is HTMLInputElement {
  return el instanceof HTMLInputElement && (el.type === "checkbox" || el.type === "radio");
}

function liveValues(el: Control): string[] {
  if (isCheckable(el)) return el.checked ? [el.value] : [];
  if (el instanceof HTMLSelectElement) return Array.from(el.selectedOptions, (o) => o.value);
  return [el.value];
}

function renderedValues(el: Control): string[] {
  if (isCheckable(el)) return el.defaultChecked ? [el.value] : [];
  if (el instanceof HTMLSelectElement) {
    const options = Array.from(el.options);
    const chosen = options.filter((o) => o.defaultSelected).map((o) => o.value);
    if (el.multiple) return chosen;
    // A single select with no `selected` option shows its first enabled one; with several, the last.
    if (chosen.length === 0) {
      const first = options.find((o) => !o.disabled);
      return first ? [first.value] : [];
    }
    return chosen.slice(-1);
  }
  if (el instanceof HTMLTextAreaElement) {
    const editor = el.closest<HTMLElement>(".rich-input");
    if (editor?.dataset.value !== undefined) return [editor.dataset.value];
  }
  return [el.defaultValue];
}

// Every named control's values, joined per name (a checkbox's hidden "false" and the box itself, a
// multi-select's hidden "" and its options).
function read(form: HTMLFormElement, values: (el: Control) => string[]): Values {
  const byName = new Map<string, string[]>();
  for (const el of controls(form)) {
    byName.set(el.name, [...(byName.get(el.name) ?? []), ...values(el)]);
  }
  return new Map(Array.from(byName, ([name, list]) => [name, JSON.stringify(list)]));
}

export const UnsavedChanges: Hook<State, HTMLFormElement> = {
  mounted(this: Self) {
    this.marked = new Set();
    this.kept = new WeakSet();
    this.dirty = false;
    this.saved = this.el.hasAttribute("data-saved");
    this.js().ignoreAttributes(this.el, MARK);
    // A form mounted showing edits (a refused save) has no saved values to read: it starts clean.
    this.baseline = read(this.el, liveValues);
    if (this.saved) this.rebase(false);

    this.onEdit = () => {
      discarding = false;
      this.refresh();
    };
    this.el.addEventListener("input", this.onEdit);
    this.el.addEventListener("change", this.onEdit);
    this.el.addEventListener("keydown", onSubmitKey, { capture: true });

    this.dialog = this.el.closest("dialog");
    this.onBeforeClose = (e) => {
      if (this.dirty && !window.confirm(t("unsaved_changes"))) e.preventDefault();
    };
    this.dialog?.addEventListener("modal:before-close", this.onBeforeClose);

    if (guarded.size === 0) {
      window.addEventListener("phx:before-navigate", onBeforeNavigate);
      window.addEventListener("beforeunload", onBeforeUnload);
      window.addEventListener("phx:page-loading-stop", onLoadingStop);
    }
    guarded.add(this);
    this.refresh();
  },

  updated(this: Self) {
    const saved = this.el.hasAttribute("data-saved");
    if (saved) this.rebase(!this.saved);
    this.saved = saved;
    // Compare once the rest of this patch has run: hooks inside the form, such as `<.editor>`, update
    // after this one and only then write the server's value into their textarea (no input event), so
    // comparing now would mark a field the server just replaced, e.g. on patching to another record.
    queueMicrotask(() => {
      if (guarded.has(this)) this.refresh();
    });
  },

  destroyed(this: Self) {
    this.el.removeEventListener("input", this.onEdit);
    this.el.removeEventListener("change", this.onEdit);
    this.el.removeEventListener("keydown", onSubmitKey, { capture: true });
    this.dialog?.removeEventListener("modal:before-close", this.onBeforeClose);
    for (const el of this.marked) el.removeAttribute(MARK);
    this.el.removeAttribute(MARK);
    guarded.delete(this);
    if (guarded.size === 0) {
      window.removeEventListener("phx:before-navigate", onBeforeNavigate);
      window.removeEventListener("beforeunload", onBeforeUnload);
      window.removeEventListener("phx:page-loading-stop", onLoadingStop);
      discarding = false;
    }
  },

  rebase(this: Self, justSaved: boolean) {
    const form = this.el;
    const baseline = read(form, renderedValues);
    const focused = document.activeElement;
    if (isControl(focused) && focused.form === form && baseline.has(focused.name)) {
      const kept = justSaved ? read(form, liveValues).get(focused.name) : this.baseline.get(focused.name);
      if (kept !== undefined) baseline.set(focused.name, kept);
    }
    this.baseline = baseline;
  },

  refresh(this: Self) {
    const form = this.el;
    const live = read(form, liveValues);
    const changed = new Set<string>();
    for (const [name, value] of this.baseline) {
      const now = live.get(name);
      if (now !== undefined && now !== value) changed.add(name);
    }
    this.dirty = changed.size > 0;
    form.toggleAttribute(MARK, this.dirty);

    const targets = new Set<Element>();
    for (const el of controls(form)) {
      if (!changed.has(el.name) || el.type === "hidden") continue;
      targets.add(el.closest(".rich-input") ?? el);
      for (const label of el.labels ?? []) targets.add(label);
    }

    for (const el of this.marked) if (!targets.has(el)) el.removeAttribute(MARK);
    for (const el of targets) {
      if (!this.kept.has(el)) {
        this.js().ignoreAttributes(el as HTMLElement, MARK);
        this.kept.add(el);
      }
      el.setAttribute(MARK, "");
    }
    this.marked = targets;
  },
};
