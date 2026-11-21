import { findInlineScripts } from "./inline_scripts";

/** Liquid tags that need an `end…` (Solid's standard set; `setvar`/`setglobalvar` are simple). */
const BLOCK_TAGS: Record<string, true> = {
  if: true,
  unless: true,
  case: true,
  for: true,
  tablerow: true,
  capture: true,
  comment: true,
  raw: true,
};

const TAG_NAME = /^-?\s*([A-Za-z_]\w*)/;

/** Whether `text` leaves a `{{ }}`, `{% %}` or a block tag without its `end…` open. */
function openLiquid(text: string): boolean {
  const stack: string[] = [];
  for (let at = 0; ; ) {
    const open = text.slice(at).search(/\{[{%]/);
    if (open < 0) return stack.length > 0;
    const start = at + open;
    const output = text[start + 1] === "{";
    const close = text.indexOf(output ? "}}" : "%}", start + 2);
    if (close < 0) return true;
    at = close + 2;
    if (output) continue;

    const name = TAG_NAME.exec(text.slice(start + 2, close))?.[1] ?? "";
    if (name === "raw" || name === "comment") {
      // Their bodies are not parsed: skip straight to the matching end tag.
      const end = new RegExp(`\\{%-?\\s*end${name}\\s*-?%\\}`, "g");
      end.lastIndex = at;
      if (!end.exec(text)) return true;
      at = end.lastIndex;
    } else if (BLOCK_TAGS[name]) {
      stack.push(name);
    } else if (name.startsWith("end") && stack[stack.length - 1] === name.slice(3)) {
      stack.pop();
    }
  }
}

const FENCE = /^ {0,3}(`{3,}|~{3,})/;

/** Whether `text` has a Markdown ``` or ~~~ code fence that is not closed. */
function openFence(text: string): boolean {
  let fence: string | null = null;
  for (const line of text.split("\n")) {
    const marker = FENCE.exec(line)?.[1];
    if (!marker) continue;
    if (fence === null) fence = marker;
    else if (marker[0] === fence[0] && marker.length >= fence.length && line.trim() === marker) fence = null;
  }
  return fence !== null;
}

/**
 * Whether the composer's text has a block still open, so Enter adds a line instead of sending:
 * an unclosed `{! … !}` script (when `inlineScripts`), a Liquid `{{`/`{%` or block tag, or a
 * Markdown code fence. Liquid inside a script is Lua, as on the server, so scripts are cut out first.
 */
export function hasOpenBlock(text: string, inlineScripts: boolean): boolean {
  let prose = text;
  if (inlineScripts) {
    const blocks = findInlineScripts(text);
    if (blocks.some((b) => !b.closed)) return true;
    let at = 0;
    prose = "";
    for (const b of blocks) {
      prose += text.slice(at, b.from);
      at = b.to;
    }
    prose += text.slice(at);
  }
  return openFence(prose) || openLiquid(prose);
}

/** Whether `pos` sits inside a block: the text before it leaves one open. */
export function insideBlock(text: string, pos: number, inlineScripts: boolean): boolean {
  return hasOpenBlock(text.slice(0, pos), inlineScripts);
}
