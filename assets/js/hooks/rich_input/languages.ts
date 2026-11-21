import { autocompletion, type CompletionSource } from "@codemirror/autocomplete";
import { json } from "@codemirror/lang-json";
import { liquid } from "@codemirror/lang-liquid";
import { commonmarkLanguage, markdown } from "@codemirror/lang-markdown";
import { indentUnit, LanguageSupport, StreamLanguage } from "@codemirror/language";
import { css } from "@codemirror/legacy-modes/mode/css";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import { type EditorState, type Extension, Prec } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { Tag } from "@lezer/highlight";
import { GFM, type MarkdownConfig } from "@lezer/markdown";
import { blockTabKeymap, codeTabKeymap, formatKeymap, holdSubmit } from "./commands";
import { inlineScriptAt, inlineScripts, withInlineScripts } from "./inline_scripts";
import { hasOpenBlock, insideBlock } from "./open_blocks";
import {
  type TemplateCompletionData,
  templateCompletionSource,
  templateHover,
  templateTrigger,
} from "./liquid";
import { type LuaCompletionData, luaCompletionSource, luaHover } from "./lua";

export type Language = "markdown" | "liquid" | "json" | "lua" | "css";

/** Highlight tag for quoted role-play dialogue; styled in `theme.ts`. */
export const dialogueTag = Tag.define();

const QUOTE = 34;
const LEFT_QUOTE = 0x201c;
const RIGHT_QUOTE = 0x201d;

const DialogueDelim = { resolve: "Dialogue", mark: "DialogueMark" };

const DIALOGUE_SPACE = /\s/;

/** Feet and inches before a `"` (`6'10"`, `5′ 11"`): that `"` is an inch mark, not a quote. */
const INCHES = /\d['\u2032] ?\d+$/;

/**
 * `"dialogue"` as an inline span. Straight quotes open before a non-space and close after one;
 * curly quotes are directional. The delimiter mechanism nests emphasis inside dialogue, and an
 * unmatched quote produces no node. An inch mark is plain text, as is `\"` (the built-in `Escape`
 * parser runs first). `MythweaverWeb.Markdown` renders by the same rules.
 */
const Dialogue: MarkdownConfig = {
  defineNodes: [
    { name: "Dialogue", style: { "Dialogue/...": dialogueTag } },
    { name: "DialogueMark" },
  ],
  parseInline: [
    {
      name: "Dialogue",
      before: "Emphasis",
      parse(cx, next, pos) {
        if (next === QUOTE) {
          if (INCHES.test(cx.slice(Math.max(cx.offset, pos - 16), pos))) return -1;
          const after = cx.slice(pos + 1, pos + 2);
          const before = cx.slice(pos - 1, pos);
          const canOpen = after !== "" && !DIALOGUE_SPACE.test(after);
          const canClose = before !== "" && !DIALOGUE_SPACE.test(before);
          return cx.addDelimiter(DialogueDelim, pos, pos + 1, canOpen, canClose);
        }
        if (next === LEFT_QUOTE) return cx.addDelimiter(DialogueDelim, pos, pos + 1, true, false);
        if (next === RIGHT_QUOTE) return cx.addDelimiter(DialogueDelim, pos, pos + 1, false, true);
        return -1;
      },
    },
  ],
};

/**
 * CommonMark + GFM rather than `markdownLanguage`, which adds single-`~` subscript, `^`
 * superscript and emoji; RP text uses `~` freely.
 */
function markdownSupport(): { support: LanguageSupport; brackets: Extension } {
  const support = markdown({
    base: commonmarkLanguage,
    extensions: [GFM, Dialogue],
    completeHTMLTags: false,
  });
  // No `'` (apostrophes) and no `*` (list bullets). `Prec.high` beats the `{brackets: ["{"]}`
  // lang-liquid attaches to the same language-data facet.
  const brackets = Prec.high(
    support.language.data.of({ closeBrackets: { brackets: ["(", "[", "{", '"', "`"] } }),
  );
  return { support, brackets };
}

/**
 * lang-liquid's `closePercentBrace` turns `{%` into `{%|%}`, but nothing steps over that closer when
 * the tag is typed out by hand, so `{% if x %}` would leave a stray `%}`. Typing `%` before `%}`, or
 * `}` between `%` and `}`, moves the cursor over the existing char instead.
 */
const skipTagClose = EditorView.inputHandler.of((view, from, to, text) => {
  if (from !== to || (text !== "%" && text !== "}")) return false;
  const { state } = view;
  const skip =
    text === "%"
      ? state.sliceDoc(from, from + 2) === "%}"
      : state.sliceDoc(from - 1, from + 1) === "%}";
  if (!skip) return false;
  view.dispatch({ selection: { anchor: from + 1 }, scrollIntoView: true, userEvent: "select" });
  return true;
});

/** `getData` returns the parsed `data-completions`; its shape is the one `language` is sent with. */
export function languageExtensions(language: Language, getData: () => unknown): Extension[] {
  if (language === "json") return [json(), codeTabKeymap];
  if (language === "css") return [StreamLanguage.define(css), codeTabKeymap];

  if (language === "lua") {
    const getLuaData = getData as () => LuaCompletionData | null;
    return [
      StreamLanguage.define(lua),
      autocompletion({ override: [luaCompletionSource(getLuaData)] }),
      luaHover(getLuaData),
      codeTabKeymap,
    ];
  }

  const { support, brackets } = markdownSupport();
  if (language === "markdown") return [support, brackets, formatKeymap];

  const getTemplateData = getData as () => TemplateCompletionData | null;
  const templateSource = templateCompletionSource(getTemplateData);
  // Decided once: only the composer sends `inline_lua`, and it always does.
  const getInlineLua = () => getTemplateData()?.inline_lua ?? null;
  const inline = getInlineLua() !== null;
  const inScript = (state: EditorState, pos: number) => inlineScriptAt(state, pos) !== null;
  const luaSource = luaCompletionSource(getInlineLua, inlineScriptAt);
  const source: CompletionSource = inline
    ? (context) => (inScript(context.state, context.pos) ? luaSource(context) : templateSource(context))
    : templateSource;

  const template = liquid({ base: support });

  return [
    inline ? new LanguageSupport(withInlineScripts(template.language), template.support) : template,
    brackets,
    // `override` makes ours the only source: lang-liquid's own one is unguarded and would offer
    // variables on every word of prose.
    autocompletion({ override: [source] }),
    inline ? [inlineScripts, luaHover(getInlineLua, inlineScriptAt)] : [],
    templateHover(getTemplateData),
    templateTrigger(inline ? inScript : undefined),
    skipTagClose,
    holdSubmit.of((state) => hasOpenBlock(state.doc.toString(), inline)),
    // The composer only (the editor that runs `{! !}`): elsewhere Tab keeps leaving the field. A tab
    // indent unit so Shift-Tab and Enter's auto-indent match the tabs Tab inserts.
    inline
      ? [blockTabKeymap((state, pos) => insideBlock(state.doc.toString(), pos, true)), indentUnit.of("\t")]
      : [],
    formatKeymap,
  ];
}
