import type { Completion, CompletionSource } from "@codemirror/autocomplete";
import { syntaxTree } from "@codemirror/language";
import type { EditorState, Extension } from "@codemirror/state";
import { hoverTooltip } from "@codemirror/view";
import { docTooltip } from "./hover";

/** Wire format of `Mythweaver.Scripts.Completions.lua/1`: `event`, `mw.*` and `regex.*`. */
export type LuaCompletionData = {
  globals: Completion[];
  members: Record<string, Completion[]>;
};

const KEYWORDS: Completion[] = (
  "and break do else elseif end false for function goto if in local nil not or repeat return " +
  "then true until while"
)
  .split(" ")
  .map((label) => ({ label, type: "keyword" }));

const fn = (label: string, detail: string, info: string): Completion => ({
  label,
  type: "function",
  detail,
  info,
});

const constant = (label: string, info: string): Completion => ({ label, type: "constant", info });

/** The base library as the script sandbox leaves it: no `load`, `require` or `dofile`. */
const BASE: Completion[] = [
  fn("assert", "(v [, message])", "Raises message when v is false or nil; otherwise returns its arguments."),
  fn("error", "(message [, level])", "Raises message as an error; pcall catches it."),
  fn("getmetatable", "(t)", "t's metatable, or nil."),
  fn("ipairs", "(t)", "Iterates t[1], t[2], … up to the first nil: for i, v in ipairs(t) do … end"),
  fn("next", "(t [, key])", "The entry after key in t (the first without one); nil at the end."),
  fn("pairs", "(t)", "Iterates every key of t, in no set order: for k, v in pairs(t) do … end"),
  fn("pcall", "(f, ...)", "Calls f(...) catching errors: true plus its results, or false and the message."),
  fn(
    "print",
    "(...)",
    "Reports its arguments, tab-separated, with the run's script errors (up to 20 lines); handy for debugging.",
  ),
  fn("rawequal", "(a, b)", "a == b without metamethods."),
  fn("rawget", "(t, key)", "t[key] without metamethods."),
  fn("rawlen", "(v)", "#v without metamethods."),
  fn("rawset", "(t, key, value)", "t[key] = value without metamethods."),
  fn("select", "(n, ...)", 'The arguments from the nth on; select("#", ...) counts them.'),
  fn("setmetatable", "(t, mt)", "Sets t's metatable and returns t."),
  fn("tonumber", "(v [, base])", "v as a number, or nil when it is not one."),
  fn("tostring", "(v)", "v as a string."),
  fn("type", "(v)", '"nil", "number", "string", "boolean", "table" or "function".'),
  fn("unpack", "(t [, i [, j]])", "t[i] through t[j] as separate values."),
  fn("xpcall", "(f, handler, ...)", "pcall where handler(message) shapes the error."),
];

/** `[name, function detail, method detail, info]`; a null method detail means no `s:name` form. */
const STRING: [string, string, string | null, string][] = [
  ["byte", "(s [, i [, j]])", "([i [, j]])", "The byte codes of s[i] through s[j]."],
  ["char", "(...)", null, "A string of the given byte codes."],
  [
    "find",
    "(s, pattern [, init [, plain]])",
    "(pattern [, init [, plain]])",
    "Start and end of the first Lua-pattern match, then its captures; nil when none. regex.match has full PCRE.",
  ],
  ["format", "(fmt, ...)", "(...)", "printf-style formatting: %s, %d, %5.2f, %q, %x, %%."],
  ["gmatch", "(s, pattern)", "(pattern)", "Iterates each Lua-pattern match: for word in s:gmatch(\"%a+\") do … end"],
  [
    "gsub",
    "(s, pattern, repl [, n])",
    "(pattern, repl [, n])",
    "Replaces Lua-pattern matches (%1 in repl is a capture); returns the new string and the count. regex.replace has full PCRE.",
  ],
  ["len", "(s)", "()", "The length in bytes; same as #s."],
  ["lower", "(s)", "()", "s in lowercase (ASCII)."],
  [
    "match",
    "(s, pattern [, init])",
    "(pattern [, init])",
    "The captures of the first Lua-pattern match (or the whole match); nil when none.",
  ],
  ["rep", "(s, n [, sep])", "(n [, sep])", "s repeated n times, joined by sep."],
  ["reverse", "(s)", "()", "s with its bytes reversed."],
  ["sub", "(s, i [, j])", "(i [, j])", "Bytes i through j; negative indexes count from the end."],
  ["upper", "(s)", "()", "s in uppercase (ASCII)."],
];

/** Members of the standard tables, keyed like `LuaCompletionData.members`. */
const LIBRARY: Record<string, Completion[]> = {
  string: STRING.map(([label, detail, , info]) => fn(label, detail, info)),
  table: [
    fn("concat", "(t [, sep [, i [, j]]])", "Joins the strings or numbers t[i] through t[j] with sep."),
    fn("insert", "(t, [pos,] value)", "Inserts value at pos (default: the end), shifting later items up."),
    fn("move", "(a1, f, e, t [, a2])", "Copies a1[f..e] into a2 (default a1) from index t."),
    fn("pack", "(...)", "A table of the arguments, with n set to their count."),
    fn("remove", "(t [, pos])", "Removes and returns t[pos] (default: the last item), shifting later items down."),
    fn("sort", "(t [, comp])", "Sorts t in place; comp(a, b) returns true when a goes first."),
    fn("unpack", "(t [, i [, j]])", "t[i] through t[j] as separate values."),
  ],
  math: [
    fn("abs", "(x)", "|x|."),
    fn("acos", "(x)", "Arc cosine, in radians."),
    fn("asin", "(x)", "Arc sine, in radians."),
    fn("atan", "(y [, x])", "Arc tangent of y/x, in radians, using both signs for the quadrant."),
    fn("ceil", "(x)", "The smallest integer ≥ x."),
    fn("cos", "(x)", "Cosine of x radians."),
    fn("deg", "(x)", "x radians in degrees."),
    fn("exp", "(x)", "e^x."),
    fn("floor", "(x)", "The largest integer ≤ x."),
    fn("fmod", "(x, y)", "The remainder of x / y, rounding the quotient towards zero."),
    constant("huge", "Infinity."),
    fn("log", "(x [, base])", "The logarithm of x (default base e)."),
    fn("max", "(x, ...)", "The largest argument."),
    constant("maxinteger", "The largest integer."),
    fn("min", "(x, ...)", "The smallest argument."),
    constant("mininteger", "The smallest integer."),
    fn("modf", "(x)", "The integral and fractional parts of x."),
    constant("pi", "π."),
    fn("rad", "(x)", "x degrees in radians."),
    fn("random", "([m [, n]])", "A float in [0, 1); an integer in [1, m]; or an integer in [m, n]."),
    fn("randomseed", "(x)", "Seeds math.random."),
    fn("sin", "(x)", "Sine of x radians."),
    fn("sqrt", "(x)", "√x."),
    fn("tan", "(x)", "Tangent of x radians."),
    fn("tointeger", "(x)", "x as an integer when it has an exact one; otherwise nil."),
    fn("type", "(x)", '"integer", "float", or nil for a non-number.'),
    fn("ult", "(m, n)", "Whether m < n as unsigned integers."),
  ],
  utf8: [
    fn("char", "(...)", "A UTF-8 string of the given code points."),
    constant("charpattern", "A Lua pattern matching one UTF-8 character."),
    fn("codepoint", "(s [, i [, j]])", "The code points of the characters starting at bytes i through j."),
    fn("codes", "(s)", "Iterates each character: for pos, code in utf8.codes(s) do … end"),
    fn("len", "(s [, i [, j]])", "The number of characters (not bytes), or nil and the first invalid byte."),
    fn("offset", "(s, n [, i])", "The byte position where the nth character (counting from byte i) starts."),
  ],
  os: [
    fn("clock", "()", "CPU seconds used so far."),
    fn("date", "([format [, time]])", 'The date as a string ("%Y-%m-%d"), or a table with "*t".'),
    fn("difftime", "(t2, t1)", "t2 - t1 in seconds."),
    fn("time", "([t])", "The current time in seconds since the epoch, or the time a date table describes."),
  ],
};

const LIBRARY_GLOBALS: Completion[] = Object.keys(LIBRARY).map((label) => ({
  label,
  type: "namespace",
}));

/** `s:name(...)`: only strings have methods among the values scripts see. */
const STRING_METHODS: Completion[] = STRING.flatMap(([label, , detail, info]) =>
  detail === null ? [] : [{ label, type: "method", detail, info }],
);

const NAME = "[A-Za-z_][A-Za-z0-9_]*";
const NAMES = `${NAME}(?:\\s*,\\s*${NAME})*`;

const DECLARATIONS = [
  new RegExp(`\\blocal\\s+(?:function\\s+)?(${NAMES})`, "g"),
  new RegExp(`\\bfor\\s+(${NAMES})\\s*(?:=|in\\b)`, "g"),
  new RegExp(`\\bfunction\\s+(${NAME})\\s*\\(`, "g"),
  /\bfunction\b[^(\n]*\(([^)]*)\)/g,
];

const KEYWORD: Record<string, true> = Object.fromEntries(KEYWORDS.map((k) => [k.label, true]));

/** Names `text` declares: locals, loop variables, functions and parameters. */
function declaredNames(text: string, typed: string): Completion[] {
  const names = new Set<string>();
  for (const pattern of DECLARATIONS) {
    for (const [, list] of text.matchAll(pattern)) {
      for (const name of list.split(",")) {
        const n = name.trim();
        if (n && n !== "..." && n !== typed && KEYWORD[n] !== true) names.add(n);
      }
    }
  }
  return [...names].map((label) => ({ label, type: "variable", detail: "local", boost: 1 }));
}

/** Lua tokens CodeMirror's legacy mode names `string`/`comment` (`string-2` for long strings). */
const QUIET_NODE = /^(string|comment)/;

/**
 * Where Lua is: null for a whole-document Lua editor, or a function giving the Lua span around
 * `pos` (null outside one) when Lua is embedded in other text.
 */
export type LuaRegion = ((state: EditorState, pos: number) => { from: number; to: number } | null) | null;

/** Whether `pos` is in a Lua string or comment; `resolveInner` reaches an embedded block's Lua tree. */
function quiet(state: EditorState, pos: number, side: -1 | 1): boolean {
  return QUIET_NODE.test(syntaxTree(state).resolveInner(pos, side).name);
}

/** A dotted chain ending at the cursor: `mw.messages.ge`, `m.text:up`, `pai`. */
const CHAIN = /(?:[A-Za-z_][A-Za-z0-9_]*[.:])*[A-Za-z0-9_]*$/;

const WORD = /^\w*$/;

type Scope = { from: number; options: readonly Completion[]; bare: boolean };

/**
 * What the last name of `chain` (which starts at doc offset `from`) can be: `from` moves to that
 * name, and `bare` marks a name with no receiver. Null when the receiver is unknown.
 */
function scopeOf(
  state: EditorState,
  from: number,
  chain: string,
  data: LuaCompletionData | null,
): Scope | null {
  const sep = Math.max(chain.lastIndexOf("."), chain.lastIndexOf(":"));

  if (sep >= 0) {
    const nameFrom = from + sep + 1;
    if (chain[sep] === ":") return { from: nameFrom, options: STRING_METHODS, bare: false };
    const path = chain.slice(0, sep);
    // Own keys only, so a typed `constructor.` never reaches `Object.prototype`.
    if (Object.hasOwn(LIBRARY, path)) return { from: nameFrom, options: LIBRARY[path], bare: false };
    if (data && Object.hasOwn(data.members, path)) {
      return { from: nameFrom, options: data.members[path], bare: false };
    }
    return null;
  }

  if (/^\d/.test(chain)) return null;
  // After `x[1].` or `("s"):`, the receiver is unknown, unless the dots are `..` concatenation.
  const before = state.sliceDoc(Math.max(0, from - 2), from);
  if (before.endsWith(":")) return { from, options: STRING_METHODS, bare: false };
  if (before.endsWith(".") && before !== "..") return null;
  return { from, options: [...BASE, ...LIBRARY_GLOBALS, ...(data?.globals ?? [])], bare: true };
}

export function luaCompletionSource(
  getData: () => LuaCompletionData | null,
  region: LuaRegion = null,
): CompletionSource {
  return (context) => {
    const { state, pos } = context;
    const span = region ? region(state, pos) : { from: 0, to: state.doc.length };
    if (!span || quiet(state, pos, -1)) return null;

    const chain = context.matchBefore(CHAIN);
    if (!chain || (chain.from === chain.to && !context.explicit)) return null;

    const scope = scopeOf(state, chain.from, chain.text, getData());
    if (!scope) return null;

    const options = scope.bare
      ? [...KEYWORDS, ...scope.options, ...declaredNames(state.sliceDoc(span.from, span.to), chain.text)]
      : scope.options;
    return { from: scope.from, options, validFor: WORD };
  };
}

/**
 * Hovering a known name (`mw.messages.get`, `event.text`, `string.gsub`, `s:upper`, `pairs`)
 * shows its signature or type and description, from the same options autocomplete offers.
 */
export function luaHover(getData: () => LuaCompletionData | null, region: LuaRegion = null): Extension {
  return hoverTooltip((view, pos, side) => {
    const { state } = view;
    if (region && !region(state, pos)) return null;
    const line = state.doc.lineAt(pos);
    let start = pos - line.from;
    let end = start;
    while (start > 0 && /\w/.test(line.text[start - 1])) start--;
    while (end < line.text.length && /\w/.test(line.text[end])) end++;
    // Nothing under the pointer, or it sits just past either end of the word.
    if (start === end) return null;
    if ((side < 0 && pos === line.from + start) || (side > 0 && pos === line.from + end)) return null;
    if (quiet(state, line.from + start, 1)) return null;

    const chain = CHAIN.exec(line.text.slice(0, end))?.[0] ?? "";
    const chainFrom = line.from + end - chain.length;
    const scope = scopeOf(state, chainFrom, chain, getData());
    const label = line.text.slice(start, end);
    const option = scope?.options.find((o) => o.label === label);
    if (!option) return null;

    const chained = line.text.slice(end - chain.length, end);
    // `("x"):upper` has no named receiver; show the string method as `s:upper`.
    const name = option.type === "method" && !chained.includes(":") ? `s:${chained}` : chained;
    const callable = option.type === "function" || option.type === "method";
    const title = callable
      ? `${name}${option.detail ?? ""}`
      : option.detail
        ? `${name}: ${option.detail}`
        : name;
    return docTooltip(line.from + start, line.from + end, title, option.info);
  });
}
