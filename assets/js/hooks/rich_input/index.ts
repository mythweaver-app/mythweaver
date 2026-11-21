import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { bracketMatching, indentOnInput } from "@codemirror/language";
import { search, searchKeymap } from "@codemirror/search";
import { Compartment, EditorState, type Extension } from "@codemirror/state";
import {
  drawSelection,
  EditorView,
  highlightActiveLineGutter,
  highlightSpecialChars,
  keymap,
  lineNumbers,
  placeholder,
} from "@codemirror/view";
import type { Hook, HookInterface } from "phoenix_live_view";
import { submitKeymap } from "./commands";
import { type Language, languageExtensions } from "./languages";
import { editorTheme, highlight } from "./theme";

/**
 * CodeMirror source editor behind `<.editor>` (`core_components/editor.ex`).
 *
 * DOM contract: `this.el` is the wrapper carrying `data-value`, `data-language` and the optional
 * `data-completions`, `data-placeholder`, `data-autofocus`, `data-caret` (with optional
 * `data-caret-end`, an initial selection), `data-submit-on-enter`,
 * `data-submit-on-escape`, `data-line-numbers`, `data-spellcheck`, `data-label`
 * and `aria-invalid`.
 * Inside it the `[data-rich-input-view]` div is `phx-update="ignore"` and holds the named hidden
 * `<textarea>` the form serializes, so LiveView never patches the value under the editor.
 * A `rich-input:replace` `CustomEvent` dispatched on `this.el` (`detail.value`) replaces the whole
 * text as an undoable local edit, so it reaches the textarea and `phx-change` as typing does.
 * A `rich-input:focus` event focuses the editor, keeping its selection, or at the end when the
 * caret never left the start.
 *
 * Value sync: every local edit is copied into the textarea (with a bubbling `input` for
 * `phx-change`) and remembered in `pending`. A `data-value` the server sends back is applied only
 * when it is neither the current text nor one of those echoes: a record switch, a cleared form, a
 * reloaded draft.
 */
type State = {
  view: EditorView;
  textarea: HTMLTextAreaElement;
  mount: HTMLElement;
  /** Parsed `data-completions`; `languageExtensions` knows its shape per language. */
  completions: unknown;
  completionsJson: string | undefined;
  invalid: boolean;
  pending: Set<string>;
  lastServer: string;
  aria: Compartment;
  form: HTMLFormElement | null;
  label: HTMLElement | null;
  onSubmit: () => void;
  onLabelClick: (e: Event) => void;
  onMouseDown: (e: MouseEvent) => void;
  onReplace: (e: Event) => void;
  onFocus: () => void;
  extensions(): Extension[];
  ariaAttrs(): Record<string, string>;
  remember(v: string): void;
  reset(v: string): void;
};

type Self = State & HookInterface;

const PENDING_LIMIT = 200;

export const RichInput: Hook<State> = {
  mounted(this: Self) {
    const data = this.el.dataset;
    this.textarea = this.el.querySelector("textarea")!;
    this.mount = this.el.querySelector<HTMLElement>("[data-rich-input-view]")!;
    this.completionsJson = data.completions;
    this.completions = data.completions ? JSON.parse(data.completions) : null;
    this.invalid = this.el.hasAttribute("aria-invalid");
    this.pending = new Set();
    this.lastServer = data.value ?? "";
    this.aria = new Compartment();

    this.view = new EditorView({
      parent: this.mount,
      state: EditorState.create({ doc: this.lastServer, extensions: this.extensions() }),
    });
    this.textarea.value = this.lastServer;

    // An editor that opens focused, or at a caret, reveals its cursor centered, and at least the
    // wrapper's CSS `scroll-margin-top` from every edge (CodeMirror falls back to the nearest edge
    // in each outer scroller once an inner one has centered it, where a sticky header can hide it).
    const autofocus = data.autofocus !== undefined;
    if (autofocus) this.view.focus();
    const caret = Number.parseInt(data.caret ?? "", 10);
    if (autofocus || Number.isInteger(caret)) {
      const length = this.view.state.doc.length;
      const end = Number.parseInt(data.caretEnd ?? "", 10);
      const anchor = Number.isInteger(caret) ? Math.min(caret, length) : 0;
      const head = Number.isInteger(end) ? Math.min(end, length) : anchor;
      const yMargin = Number.parseFloat(getComputedStyle(this.el).scrollMarginTop) || 5;
      this.view.dispatch({
        selection: { anchor, head },
        effects: EditorView.scrollIntoView(head, { y: "center", yMargin }),
      });
    }

    // On the form, so it runs before LiveView's document-level submit handler serializes it.
    this.form = this.el.closest("form");
    this.onSubmit = () => {
      this.textarea.value = this.view.state.doc.toString();
      this.pending.clear();
    };
    this.form?.addEventListener("submit", this.onSubmit);

    this.label = data.label ? document.getElementById(data.label) : null;
    this.onLabelClick = (e) => {
      e.preventDefault();
      this.view.focus();
    };
    this.label?.addEventListener("click", this.onLabelClick);

    // A click in the wrapper's padding, outside CodeMirror's own content.
    this.onMouseDown = (e) => {
      if (e.target !== this.el) return;
      e.preventDefault();
      this.view.focus();
    };
    this.el.addEventListener("mousedown", this.onMouseDown);

    this.onReplace = (e) => {
      const v = (e as CustomEvent<{ value: string }>).detail.value;
      this.view.dispatch({
        changes: { from: 0, to: this.view.state.doc.length, insert: v },
        selection: { anchor: v.length },
        scrollIntoView: true,
      });
    };
    this.el.addEventListener("rich-input:replace", this.onReplace);

    this.onFocus = () => {
      const { main } = this.view.state.selection;
      if (!this.view.hasFocus && main.empty && main.head === 0)
        this.view.dispatch({ selection: { anchor: this.view.state.doc.length } });
      this.view.focus();
    };
    this.el.addEventListener("rich-input:focus", this.onFocus);
  },

  updated(this: Self) {
    const data = this.el.dataset;
    const server = data.value ?? "";
    if (server !== this.lastServer) {
      this.lastServer = server;
      if (server === this.view.state.doc.toString()) this.pending.clear();
      else if (!this.pending.has(server)) this.reset(server);
    }

    if (data.completions !== this.completionsJson) {
      this.completionsJson = data.completions;
      this.completions = data.completions ? JSON.parse(data.completions) : null;
    }

    const invalid = this.el.hasAttribute("aria-invalid");
    if (invalid !== this.invalid) {
      this.invalid = invalid;
      this.view.dispatch({
        effects: this.aria.reconfigure(EditorView.contentAttributes.of(this.ariaAttrs())),
      });
    }
  },

  destroyed(this: Self) {
    this.form?.removeEventListener("submit", this.onSubmit);
    this.label?.removeEventListener("click", this.onLabelClick);
    this.el.removeEventListener("mousedown", this.onMouseDown);
    this.el.removeEventListener("rich-input:replace", this.onReplace);
    this.el.removeEventListener("rich-input:focus", this.onFocus);

    // A live navigation destroys the outgoing page's hooks when it starts, but that page stays on
    // screen until the new one's join reply replaces it (`replaceMain`). Tearing the editor down
    // then would blank every field of a form still in view, so it waits for its element to leave
    // the document: the navigation's `phx:page-loading-stop` fires after the swap.
    const release = () => {
      if (this.el.isConnected) return;
      window.removeEventListener("phx:page-loading-stop", release);
      this.view.destroy();
    };
    if (this.el.isConnected) window.addEventListener("phx:page-loading-stop", release);
    else release();
  },

  extensions(this: Self): Extension[] {
    const data = this.el.dataset;
    const language = (data.language ?? "markdown") as Language;
    const enter = data.submitOnEnter !== undefined;
    const escape = data.submitOnEscape !== undefined;

    return [
      editorTheme,
      highlight,
      history(),
      drawSelection(),
      highlightSpecialChars(),
      indentOnInput(),
      bracketMatching(),
      closeBrackets(),
      EditorView.lineWrapping,
      search({ top: true }),
      EditorView.editorAttributes.of({ "data-language": language }),
      data.placeholder ? placeholder(data.placeholder) : [],
      data.lineNumbers !== undefined ? [lineNumbers(), highlightActiveLineGutter()] : [],
      // CodeMirror turns all of these off by default.
      data.spellcheck !== undefined
        ? EditorView.contentAttributes.of({
            spellcheck: "true",
            autocorrect: "on",
            autocapitalize: "sentences",
          })
        : [],
      this.aria.of(EditorView.contentAttributes.of(this.ariaAttrs())),
      ...languageExtensions(language, () => this.completions),
      // After `languageExtensions`, so an open completion menu takes Enter/Escape first.
      enter || escape ? submitKeymap({ enter, escape }) : [],
      // Tab leaves prose fields; code languages bind it (`codeTabKeymap`) in `languageExtensions`.
      keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap]),
      EditorView.updateListener.of((u) => {
        if (!u.docChanged) return;
        const v = u.state.doc.toString();
        this.textarea.value = v;
        this.remember(v);
        this.textarea.dispatchEvent(new Event("input", { bubbles: true }));
      }),
    ];
  },

  ariaAttrs(this: Self): Record<string, string> {
    const attrs: Record<string, string> = {};
    if (this.el.dataset.label) attrs["aria-labelledby"] = this.el.dataset.label;
    if (this.invalid) attrs["aria-invalid"] = "true";
    return attrs;
  },

  remember(this: Self, v: string) {
    this.pending.add(v);
    if (this.pending.size > PENDING_LIMIT) {
      this.pending.delete(this.pending.values().next().value!);
    }
  },

  /** Replaces the document and drops undo history: the text belongs to a different record now. */
  reset(this: Self, v: string) {
    this.view.setState(EditorState.create({ doc: v, extensions: this.extensions() }));
    this.textarea.value = v;
    this.pending.clear();
  },
};
