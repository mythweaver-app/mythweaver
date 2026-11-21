import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { EditorView } from "@codemirror/view";
import { tags } from "@lezer/highlight";
import { dialogueTag } from "./languages";

const MONO = "var(--font-monospace-code, ui-monospace, monospace)";

/** Chrome lives on the `.rich-input` wrapper (`editor.ex`); this only themes CodeMirror's parts. */
export const editorTheme = EditorView.theme({
  "&": {
    color: "inherit",
    backgroundColor: "transparent",
    fontSize: "inherit",
    lineHeight: "1.5",
    maxHeight: "calc(var(--rich-input-max-rows) * 1lh)",
  },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": { fontFamily: "inherit", lineHeight: "inherit", overflow: "auto" },
  "&[data-language=json] .cm-scroller, &[data-language=lua] .cm-scroller, &[data-language=css] .cm-scroller":
    { fontFamily: MONO },
  // A `{! … !}` script in a message (`inline_scripts.ts`): code, not prose.
  ".cm-inline-script": { fontFamily: MONO },
  ".cm-content": {
    padding: "0",
    minHeight: "calc(var(--rich-input-rows) * 1lh)",
    caretColor: "var(--foreground)",
  },
  ".cm-line": { padding: "0" },
  ".cm-gutters": {
    backgroundColor: "transparent",
    color: "var(--muted-foreground)",
    borderRight: "1px solid var(--border)",
    marginRight: "var(--size-2)",
  },
  ".cm-lineNumbers .cm-gutterElement": {
    padding: "0 var(--size-2) 0 0",
    minWidth: "2ch",
    fontVariantNumeric: "tabular-nums",
  },
  ".cm-activeLineGutter": { backgroundColor: "transparent", color: "var(--foreground)" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--foreground)" },
  "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection":
    { backgroundColor: "color-mix(in oklch, var(--primary-accent) 25%, transparent)" },
  ".cm-placeholder": { color: "var(--muted-foreground)" },
  ".cm-matchingBracket": {
    backgroundColor: "color-mix(in oklch, var(--primary-accent) 18%, transparent)",
    outline: "none",
  },
  ".cm-tooltip": {
    backgroundColor: "var(--surface-4)",
    color: "var(--foreground)",
    border: "1px solid var(--border)",
    borderRadius: "var(--radius-2)",
    boxShadow: "var(--elevation-lg)",
  },
  ".cm-tooltip-autocomplete > ul > li[aria-selected]": {
    backgroundColor: "var(--primary)",
    color: "var(--primary-foreground)",
  },
  ".cm-completionDetail": {
    color: "var(--muted-foreground)",
    fontStyle: "normal",
    marginLeft: "var(--size-2)",
  },
  ".cm-completionInfo": { padding: "var(--size-2)", maxWidth: "24rem" },
  ".cm-completionMatchedText": { textDecoration: "none", fontWeight: "700" },
  ".cm-doc-hover": { padding: "var(--size-2)", maxWidth: "28rem" },
  ".cm-doc-hover > code": { fontFamily: MONO, whiteSpace: "pre-wrap" },
  ".cm-doc-hover > p": { margin: "var(--size-1) 0 0", color: "var(--muted-foreground)" },
  ".cm-panels": { backgroundColor: "var(--surface-3)", color: "var(--foreground)" },
  ".cm-panels-top": { borderBottom: "1px solid var(--border)" },
  ".cm-panel.cm-search": { padding: "var(--size-1) var(--size-2)", fontSize: "var(--font-size-0)" },
  // The app styles `label` as a block; CodeMirror lays its options out inline.
  ".cm-panel.cm-search label": {
    display: "inline-flex",
    alignItems: "center",
    gap: "var(--size-1)",
    marginInline: "var(--size-1)",
  },
  ".cm-textfield": {
    backgroundColor: "var(--surface-1)",
    color: "var(--foreground)",
    border: "1px solid var(--border)",
    borderRadius: "var(--radius-2)",
  },
  ".cm-button": {
    backgroundImage: "none",
    backgroundColor: "var(--surface-5)",
    color: "var(--foreground)",
    border: "1px solid var(--border)",
    borderRadius: "var(--radius-2)",
  },
  ".cm-searchMatch": { backgroundColor: "color-mix(in oklch, var(--primary-accent) 30%, transparent)" },
  ".cm-searchMatch.cm-searchMatch-selected": {
    backgroundColor: "color-mix(in oklch, var(--primary-accent) 55%, transparent)",
  },
});

// Order matters: later rules win, so markup marks come last to beat inherited emphasis/dialogue.
export const highlight = syntaxHighlighting(
  HighlightStyle.define([
    { tag: [tags.heading, tags.strong], fontWeight: "700" },
    { tag: tags.emphasis, fontStyle: "italic", color: "var(--syntax-action)" },
    { tag: dialogueTag, color: "var(--syntax-dialogue)" },
    { tag: tags.strikethrough, textDecoration: "line-through" },
    { tag: tags.link, color: "var(--link)" },
    { tag: tags.url, color: "var(--link)", textDecoration: "underline" },
    { tag: tags.monospace, fontFamily: MONO },
    { tag: tags.quote, color: "var(--muted-foreground)" },
    {
      tag: [tags.keyword, tags.definitionKeyword, tags.moduleKeyword, tags.operatorKeyword],
      color: "var(--syntax-template)",
      fontWeight: "600",
    },
    { tag: tags.brace, color: "var(--syntax-delimiter)", fontWeight: "600" },
    { tag: tags.controlKeyword, color: "var(--syntax-control)", fontWeight: "600" },
    { tag: [tags.variableName, tags.propertyName, tags.attributeName], color: "var(--syntax-template)" },
    { tag: tags.function(tags.variableName), color: "var(--syntax-function)" },
    { tag: tags.string, color: "var(--syntax-dialogue)" },
    { tag: [tags.number, tags.bool, tags.null, tags.atom], color: "var(--primary-accent)" },
    {
      tag: [tags.comment, tags.lineComment, tags.blockComment],
      color: "var(--muted-foreground)",
      fontStyle: "italic",
    },
    { tag: tags.invalid, color: "var(--destructive)" },
    {
      tag: [
        tags.processingInstruction,
        tags.contentSeparator,
        tags.punctuation,
        tags.derefOperator,
        tags.compareOperator,
        tags.logicOperator,
        tags.definitionOperator,
      ],
      color: "var(--syntax-markup)",
    },
  ]),
);
