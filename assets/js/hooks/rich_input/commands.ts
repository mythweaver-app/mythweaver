import { acceptCompletion } from "@codemirror/autocomplete";
import { indentLess, indentMore, insertNewlineAndIndent, insertTab } from "@codemirror/commands";
import { indentUnit } from "@codemirror/language";
import { insertNewlineContinueMarkup } from "@codemirror/lang-markdown";
import { EditorSelection, type EditorState, Facet, Prec, type StateCommand } from "@codemirror/state";
import { type EditorView, type KeyBinding, keymap } from "@codemirror/view";

type Marker = "**" | "*";

/** Length of the run of `ch` at the end (`atEnd`) or start of `text`. */
function runLength(text: string, ch: string, atEnd: boolean): number {
  let n = 0;
  while (n < text.length && text[atEnd ? text.length - 1 - n : n] === ch) n++;
  return n;
}

/**
 * Whether a run of `r` marker chars on both sides means `marker` is applied. `*` and `**` share a
 * char, so italic is active at 1 or 3 (`***` is both) and bold at 2 or more.
 */
function markerActive(marker: Marker, r: number): boolean {
  return marker === "*" ? r === 1 || r === 3 : r >= 2;
}

// Four chars of context is enough to tell 1/2/3-runs apart from longer ones.
const LOOK = 4;

/**
 * Wraps each range in `marker`, or unwraps it when the marker already sits just outside or at the
 * edges of the selection. An empty range gets a marker pair with the cursor between.
 */
export function toggleWrap(marker: Marker): StateCommand {
  const ch = marker[0];
  const m = marker.length;

  return ({ state, dispatch }) => {
    const spec = state.changeByRange((range) => {
      const { from, to } = range;
      if (range.empty) {
        return { changes: { from, insert: marker + marker }, range: EditorSelection.cursor(from + m) };
      }

      const outside = Math.min(
        runLength(state.sliceDoc(Math.max(0, from - LOOK), from), ch, true),
        runLength(state.sliceDoc(to, to + LOOK), ch, false),
      );
      if (markerActive(marker, outside)) {
        return {
          changes: [
            { from: from - m, to: from },
            { from: to, to: to + m },
          ],
          range: EditorSelection.range(from - m, to - m),
        };
      }

      const text = state.sliceDoc(from, to);
      const inside = Math.min(runLength(text, ch, false), runLength(text, ch, true));
      if (text.length >= 2 * m && markerActive(marker, inside)) {
        return {
          changes: [
            { from, to: from + m },
            { from: to - m, to },
          ],
          range: EditorSelection.range(from, to - 2 * m),
        };
      }

      return {
        changes: [
          { from, insert: marker },
          { from: to, insert: marker },
        ],
        range: EditorSelection.range(from + m, to + m),
      };
    });

    dispatch(state.update(spec, { scrollIntoView: true, userEvent: "input" }));
    return true;
  };
}

/** Mod-B/I. `Prec.high`: `defaultKeymap` binds Mod-i to `selectParentSyntax`. */
export const formatKeymap = Prec.high(
  keymap.of([
    { key: "Mod-b", run: toggleWrap("**"), preventDefault: true },
    { key: "Mod-i", run: toggleWrap("*"), preventDefault: true },
  ]),
);

/** Indents a selection; otherwise inserts one indent unit at each cursor, as code editors do. */
const insertIndent: StateCommand = ({ state, dispatch }) => {
  if (state.selection.ranges.some((r) => !r.empty)) return indentMore({ state, dispatch });
  dispatch(
    state.update(state.replaceSelection(state.facet(indentUnit)), {
      scrollIntoView: true,
      userEvent: "input",
    }),
  );
  return true;
};

/**
 * Tab accepts an open completion, else indents; Shift-Tab dedents. For code editors only: prose
 * fields keep Tab for leaving the field. CodeMirror's tab-focus mode still lets the keyboard out:
 * Escape then Tab moves focus on.
 */
export const codeTabKeymap = keymap.of([
  { key: "Tab", run: acceptCompletion },
  { key: "Tab", run: insertIndent, shift: indentLess },
]);

/**
 * Tab inside a block (`inBlock` at the cursor) accepts an open completion, else inserts a tab
 * character, or indents a selection; Shift-Tab dedents. Outside a block both return false, so the
 * browser moves focus as in any prose field.
 */
export function blockTabKeymap(inBlock: (state: EditorState, pos: number) => boolean) {
  const here = (v: EditorView) => inBlock(v.state, v.state.selection.main.head);
  return keymap.of([
    {
      key: "Tab",
      run: (v) => here(v) && (acceptCompletion(v) || insertTab(v)),
      shift: (v) => here(v) && indentLess(v),
    },
  ]);
}

/**
 * Whether Enter should add a line instead of submitting: a language provides one while the text has
 * a block still open (`open_blocks.ts`), so a multi-line block can be typed out before sending.
 */
export const holdSubmit = Facet.define<(state: EditorState) => boolean>();

/**
 * Enter (non-blank, no block held open) and/or Escape submit the enclosing form. Must come after
 * `autocompletion()` in the extension list: both are highest precedence, so the earlier completion
 * keymap wins and an open menu takes Enter/Escape first.
 *
 * A caller's CSS can turn Enter back into a newline with `--rich-input-enter: newline` on the
 * editor (the chat composer does on coarse pointers, whose touch keyboards have no easy
 * Shift+Enter); the form's own submit button sends then.
 */
export function submitKeymap({ enter, escape }: { enter: boolean; escape: boolean }) {
  const bindings: KeyBinding[] = [];
  if (enter) {
    bindings.push({
      key: "Enter",
      run: (v) => {
        if (
          v.state.facet(holdSubmit).some((held) => held(v.state)) ||
          getComputedStyle(v.dom).getPropertyValue("--rich-input-enter").trim() === "newline"
        ) {
          return insertNewlineContinueMarkup(v) || insertNewlineAndIndent(v);
        }
        if (v.state.doc.toString().trim() !== "") v.dom.closest("form")?.requestSubmit();
        return true;
      },
      shift: insertNewlineContinueMarkup,
    });
  }
  if (escape) {
    bindings.push({
      key: "Escape",
      run: (v) => {
        v.dom.closest("form")?.requestSubmit();
        return true;
      },
    });
  }
  return Prec.highest(keymap.of(bindings));
}
