import {
  type Completion,
  type CompletionResult,
  type CompletionSource,
  startCompletion,
} from "@codemirror/autocomplete";
import { liquidCompletionSource } from "@codemirror/lang-liquid";
import { syntaxTree } from "@codemirror/language";
import type { EditorState, Extension } from "@codemirror/state";
import { EditorView, hoverTooltip } from "@codemirror/view";
import type { SyntaxNode } from "@lezer/common";
import { docTooltip } from "./hover";
import type { LuaCompletionData } from "./lua";

/** Whether `pos` is in text that is not a template (an inline `{! … !}` script). */
export type NotTemplate = (state: EditorState, pos: number) => boolean;

const never: NotTemplate = () => false;

/**
 * Wire format of `Mythweaver.Prompts.Completions.template/1`. The composer adds `inline_lua`
 * (`Mythweaver.Scripts.Completions.lua(:inline)`), which turns on Lua editing inside `{! … !}`.
 */
export type TemplateCompletionData = {
  variables: Completion[];
  properties: Record<string, Completion[]>;
  tags: Completion[];
  filters: Completion[];
  inline_lua?: LuaCompletionData;
};

/**
 * lang-liquid's built-in tag list includes these, but Solid has no `include`/`liquid` and
 * `Mythweaver.Templates.tags/0` deletes `render`.
 */
const UNSUPPORTED_TAGS: Record<string, true> = { render: true, include: true, liquid: true };

const tag = (label: string, detail: string, info: string): Completion => ({
  label,
  type: "keyword",
  detail,
  info,
});

/** Solid's standard tags, documented; lang-liquid lists them bare. `detail` follows the name. */
const TAGS: Completion[] = [
  tag("assign", "name = value", "Sets a variable for the rest of this render."),
  tag("capture", "name", "Renders the block into a string variable, up to {% endcapture %}."),
  tag("case", "value", "Branches on value: {% when a, b %} … {% else %} … {% endcase %}."),
  tag("when", "value [, value]", "A branch of {% case %}, taken when the value equals one listed."),
  tag("comment", "", "Everything up to {% endcomment %} is left out of the output."),
  tag("cycle", "a, b, …", "Outputs the next of its values each time it runs, e.g. alternating in a loop."),
  tag("decrement", "name", "Decreases a counter and outputs it. Counters are separate from assign."),
  tag("increment", "name", "Outputs a counter, then increases it. Counters are separate from assign."),
  tag("echo", "value", "Outputs value, like {{ value }}; filters work too."),
  tag(
    "for",
    "item in array",
    "Repeats the block per item, up to {% endfor %}. Takes limit:, offset: and reversed; {% else %} renders for an empty array; forloop.* describes the iteration.",
  ),
  tag("break", "", "Stops the enclosing for loop."),
  tag("continue", "", "Skips to the next iteration of the enclosing for loop."),
  tag(
    "if",
    "condition",
    "Renders the block when condition is truthy; {% elsif %} and {% else %} add branches. Conditions use == != < > <= >= contains and or.",
  ),
  tag("elsif", "condition", "Another branch of {% if %}, tried when the ones before it failed."),
  tag("else", "", "The fallback branch of if, unless, case or for (an empty array)."),
  tag("unless", "condition", "Renders the block when condition is falsy."),
  tag("raw", "", "Outputs its content up to {% endraw %} without processing Liquid in it."),
  tag("tablerow", "item in array", "Renders HTML table rows, one cell per item; cols: sets the width."),
];

const filter = (label: string, detail: string, info: string): Completion => ({
  label,
  type: "function",
  detail,
  info,
});

/** Solid's standard filters, documented; lang-liquid lists them bare. `detail` follows the name. */
const FILTERS: Completion[] = [
  filter("abs", "", "The absolute value."),
  filter("append", ": text", "Adds text to the end."),
  filter("at_least", ": n", "The value, raised to n if it is smaller."),
  filter("at_most", ": n", "The value, lowered to n if it is larger."),
  filter("capitalize", "", "Uppercases the first character and lowercases the rest."),
  filter("ceil", "", "Rounds up to an integer."),
  filter("compact", "", "Drops nil items from an array."),
  filter("concat", ": array", "Joins two arrays into one."),
  filter("date", ": format", 'Formats a date (or "now") with strftime codes, e.g. "%Y-%m-%d".'),
  filter("default", ": value", "value when the input is nil, false or empty; else the input."),
  filter("divided_by", ": n", "Divides by n; integer division when both are integers."),
  filter("downcase", "", "Lowercases the text."),
  filter("escape", "", "Escapes HTML special characters."),
  filter("escape_once", "", "Escapes HTML without escaping existing entities again."),
  filter("first", "", "The first item of an array."),
  filter("floor", "", "Rounds down to an integer."),
  filter("join", ": separator", "Joins an array's items into text."),
  filter("last", "", "The last item of an array."),
  filter("lstrip", "", "Removes leading whitespace."),
  filter("map", ": property", "Each item's property, as an array."),
  filter("minus", ": n", "Subtracts n."),
  filter("modulo", ": n", "The remainder after dividing by n."),
  filter("newline_to_br", "", "Inserts <br /> before each newline."),
  filter("plus", ": n", "Adds n."),
  filter("prepend", ": text", "Adds text to the start."),
  filter("remove", ": search", "Removes every occurrence of search."),
  filter("remove_first", ": search", "Removes the first occurrence of search."),
  filter("replace", ": search, replacement", "Replaces every occurrence of search."),
  filter("replace_first", ": search, replacement", "Replaces the first occurrence of search."),
  filter("reverse", "", "Reverses an array."),
  filter("round", "[: digits]", "Rounds to that many decimal places (default 0)."),
  filter("rstrip", "", "Removes trailing whitespace."),
  filter("size", "", "The number of items in an array, or characters in text."),
  filter("slice", ": start [, length]", "length items or characters from start (0-based; negative counts from the end)."),
  filter("sort", "[: property]", "Sorts an array, uppercase before lowercase."),
  filter("sort_natural", "[: property]", "Sorts an array, ignoring case."),
  filter("split", ": separator", "Splits text into an array."),
  filter("strip", "", "Removes leading and trailing whitespace."),
  filter("strip_html", "", "Removes HTML tags."),
  filter("strip_newlines", "", "Removes newlines."),
  filter("sum", "[: property]", "Adds up an array's numbers."),
  filter("times", ": n", "Multiplies by n."),
  filter("truncate", ": length [, ellipsis]", 'Shortens to length characters, counting the ellipsis (default "...").'),
  filter("truncatewords", ": words [, ellipsis]", 'Keeps that many words, then adds the ellipsis (default "...").'),
  filter("uniq", "", "Drops duplicate items."),
  filter("upcase", "", "Uppercases the text."),
  filter("url_decode", "", "Decodes URL-encoded text."),
  filter("url_encode", "", "URL-encodes the text."),
  filter("where", ": property [, value]", "The items whose property equals value, or is truthy without one."),
];

const loop = (label: string, detail: string, info: string): Completion => ({
  label,
  type: "property",
  detail,
  info,
});

const FORLOOP_INFO = "The current {% for %} loop's iteration.";

const FORLOOP: Completion[] = [
  loop("first", "bool", "true on the first iteration."),
  loop("index", "number", "The iteration, counting from 1."),
  loop("index0", "number", "The iteration, counting from 0."),
  loop("last", "bool", "true on the last iteration."),
  loop("length", "number", "The number of iterations."),
  loop("rindex", "number", "Iterations left, counting this one."),
  loop("rindex0", "number", "Iterations left after this one."),
];

const TEMPLATE_NODES: Record<string, true> = { Interpolation: true, Tag: true, EndTag: true };

function insideTemplate(state: EditorState, pos: number): boolean {
  for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(pos, -1); n; n = n.parent) {
    if (TEMPLATE_NODES[n.name]) return true;
  }
  return false;
}

const SET_TAG = /\{%-?\s*(setvar|setglobalvar)\s+([A-Za-z_][A-Za-z0-9_]{0,63})/g;

/** Names this text writes itself. `vars.*` falls back to globals, so globals count for both. */
function docVariableNames(state: EditorState): { vars: Set<string>; globals: Set<string> } {
  const vars = new Set<string>();
  const globals = new Set<string>();
  for (const [, tag, name] of state.doc.toString().matchAll(SET_TAG)) {
    vars.add(name);
    if (tag === "setglobalvar") globals.add(name);
  }
  return { vars, globals };
}

/** The properties of `path`, plus the `vars`/`globals` this text sets itself. */
function propertyOptions(
  d: TemplateCompletionData | null,
  path: readonly string[],
  state: EditorState,
): readonly Completion[] {
  const key = path.join(".");
  // Own keys only, so a typed `constructor.` never reaches `Object.prototype`.
  const options = d && Object.hasOwn(d.properties, key) ? d.properties[key] : [];
  if (path.length !== 1 || (path[0] !== "vars" && path[0] !== "globals")) return options;

  const names = docVariableNames(state);
  const known = new Set(options.map((o) => o.label));
  const extra = [...(path[0] === "vars" ? names.vars : names.globals)]
    .filter((label) => !known.has(label))
    .map((label) => ({ label, type: "variable", detail: "set in this text" }));
  return extra.length ? options.concat(extra) : options;
}

export function templateCompletionSource(getData: () => TemplateCompletionData | null): CompletionSource {
  return (context) => {
    if (!insideTemplate(context.state, context.pos)) return null;

    const d = getData();
    // Ours come first: lang-liquid appends its bare built-ins, and the first of a label wins below.
    const source = liquidCompletionSource({
      variables: d?.variables ?? [],
      tags: [...(d?.tags ?? []), ...TAGS],
      filters: [...(d?.filters ?? []), ...FILTERS],
      properties: (path, state) => propertyOptions(d, path, state),
    });

    const result: CompletionResult | null = source(context);
    if (!result) return null;
    const seen = new Set<string>();
    return {
      ...result,
      options: result.options.filter((o) => {
        if (o.type === "keyword" && UNSUPPORTED_TAGS[o.label]) return false;
        if (seen.has(o.label)) return false;
        seen.add(o.label);
        return true;
      }),
    };
  };
}

const TRIGGER = /(\{[{%]-?|\|)\s*$/;

/**
 * lang-liquid only completes right after `{{`, `{%` or `|` when the request is explicit, so typing
 * one of those starts completion by hand, except where `skip` says the text is not a template.
 * Deferred: no dispatch inside an update.
 */
export function templateTrigger(skip: NotTemplate = never): Extension {
  return EditorView.updateListener.of((u) => {
    if (!u.docChanged || !u.transactions.some((tr) => tr.isUserEvent("input.type"))) return;
    const head = u.state.selection.main.head;
    if (TRIGGER.test(u.state.sliceDoc(Math.max(0, head - 6), head)) && !skip(u.state, head)) {
      queueMicrotask(() => startCompletion(u.view));
    }
  });
}

/**
 * The path of the object `member` reads (`["anchors", "character"]` for
 * `anchors.character.name`), as lang-liquid resolves it for completion; null when it is not a
 * plain variable path.
 */
function objectPath(state: EditorState, member: SyntaxNode): string[] | null {
  const path: string[] = [];
  for (let node = member; ; ) {
    const obj = node.getChild("Expression");
    if (!obj) return null;
    if (obj.name === "VariableName" || obj.name === "forloop") {
      path.unshift(state.sliceDoc(obj.from, obj.to));
      return path;
    }
    if (obj.name === "MemberExpression") {
      const name = obj.getChild("PropertyName");
      if (name) path.unshift(state.sliceDoc(name.from, name.to));
    } else if (obj.name === "SubscriptExpression") {
      const key = obj.getChildren("Expression")[1];
      path.unshift(key?.name === "StringLiteral" ? state.sliceDoc(key.from + 1, key.to - 1) : "[]");
    } else {
      return null;
    }
    node = obj;
  }
}

type Doc = { title: string; info: unknown };

/** The documentation for the template node under the pointer, or null. */
function describe(state: EditorState, node: SyntaxNode, d: TemplateCompletionData | null): Doc | null {
  const label = state.sliceDoc(node.from, node.to);
  const parent = node.parent;

  if (node.name === "FilterName") {
    const found = [...(d?.filters ?? []), ...FILTERS].find((o) => o.label === label);
    return found ? { title: `| ${label}${found.detail ?? ""}`, info: found.info } : null;
  }

  // A tag's name is the node right after `{%`: `TagName` for custom tags, a keyword for built-ins.
  if ((parent?.name === "Tag" || parent?.name === "EndTag") && node.prevSibling?.name === "{%") {
    const opened = label.startsWith("end") ? label.slice(3) : null;
    const found = [...(d?.tags ?? []), ...TAGS].find((o) => o.label === (opened ?? label));
    if (!found) return null;
    if (opened) return { title: `{% ${label} %}`, info: `Ends the {% ${opened} %} block.` };
    return { title: `{% ${label}${found.detail ? ` ${found.detail}` : ""} %}`, info: found.info };
  }

  if (node.name === "PropertyName" && parent?.name === "MemberExpression") {
    const path = objectPath(state, parent);
    if (!path) return null;
    const options = path.length === 1 && path[0] === "forloop" ? FORLOOP : propertyOptions(d, path, state);
    const found = options.find((o) => o.label === label);
    if (!found) return null;
    const name = [...path, label].join(".").replaceAll(".[]", "[]");
    return { title: found.detail ? `${name}: ${found.detail}` : name, info: found.info };
  }

  if (node.name === "VariableName" || node.name === "forloop") {
    if (label === "forloop") return { title: "forloop", info: FORLOOP_INFO };
    const found = (d?.variables ?? []).find((o) => o.label === label);
    return found ? { title: label, info: found.info } : null;
  }

  return null;
}

/**
 * Hovering a variable, property path, filter or tag name inside `{{ }}`/`{% %}` shows its type or
 * arguments and description, from the same data autocomplete offers.
 */
export function templateHover(getData: () => TemplateCompletionData | null): Extension {
  return hoverTooltip((view, pos, side) => {
    const node = syntaxTree(view.state).resolveInner(pos, side);
    const doc = describe(view.state, node, getData());
    return doc ? docTooltip(node.from, node.to, doc.title, doc.info) : null;
  });
}
