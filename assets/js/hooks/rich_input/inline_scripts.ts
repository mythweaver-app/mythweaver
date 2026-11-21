import { defineLanguageFacet, Language, languageDataProp, StreamLanguage } from "@codemirror/language";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import type { EditorState, Extension } from "@codemirror/state";
import { StateField } from "@codemirror/state";
import { Decoration, EditorView } from "@codemirror/view";
import {
  type Input,
  NodeSet,
  NodeType,
  Parser,
  type PartialParse,
  type ParseWrapper,
  parseMixed,
  Tree,
  type TreeFragment,
} from "@lezer/common";
import { styleTags, tags } from "@lezer/highlight";

/**
 * One `{! … !}` block, as `Mythweaver.Scripts.Inline.prepare/1` splits them: the first `!}` after a
 * `{!` closes it, and there is no escape. An unclosed block (still being typed) runs to the end.
 * `from..to` covers the delimiters, `bodyFrom..bodyTo` the Lua between them.
 */
type InlineScript = { from: number; to: number; bodyFrom: number; bodyTo: number; closed: boolean };

export function findInlineScripts(text: string): InlineScript[] {
  const blocks: InlineScript[] = [];
  for (let at = 0; ; ) {
    const open = text.indexOf("{!", at);
    if (open < 0) return blocks;
    const close = text.indexOf("!}", open + 2);
    if (close < 0) {
      blocks.push({ from: open, to: text.length, bodyFrom: open + 2, bodyTo: text.length, closed: false });
      return blocks;
    }
    blocks.push({ from: open, to: close + 2, bodyFrom: open + 2, bodyTo: close, closed: true });
    at = close + 2;
  }
}

const blocksField = StateField.define<InlineScript[]>({
  create: (state) => findInlineScripts(state.doc.toString()),
  update: (blocks, tr) => (tr.docChanged ? findInlineScripts(tr.state.doc.toString()) : blocks),
});

/** The Lua body around `pos` (either edge included), or null outside every block. */
export function inlineScriptAt(state: EditorState, pos: number): { from: number; to: number } | null {
  const block = state.field(blocksField, false)?.find((b) => pos >= b.bodyFrom && pos <= b.bodyTo);
  return block ? { from: block.bodyFrom, to: block.bodyTo } : null;
}

// Lua identifiers are not prose: no spellcheck squiggles inside a block.
const mark = Decoration.mark({ class: "cm-inline-script", attributes: { spellcheck: "false" } });

/** Tracks the blocks and marks each (`.cm-inline-script`, styled in `theme.ts`). */
export const inlineScripts: Extension = [
  blocksField,
  EditorView.decorations.compute([blocksField], (state) =>
    Decoration.set(state.field(blocksField).map((b) => mark.range(b.from, b.to))),
  ),
];

const data = defineLanguageFacet();

// `extend` returns new types carrying the highlight props; trees must be built from those.
const [DOCUMENT, PROSE, SCRIPT, MARK, BODY] = new NodeSet([
  NodeType.define({ id: 0, name: "InlineScriptDocument", top: true, props: [[languageDataProp, data]] }),
  NodeType.define({ id: 1, name: "Prose" }),
  NodeType.define({ id: 2, name: "InlineScript" }),
  NodeType.define({ id: 3, name: "InlineScriptMark" }),
  NodeType.define({ id: 4, name: "InlineScriptBody" }),
]).extend(styleTags({ InlineScriptMark: tags.brace })).types;

const leaf = (type: NodeType, length: number) => new Tree(type, [], [], length);

/** `text` split into `Prose` and `InlineScript` (`{!` mark, Lua body, `!}` mark). */
function build(text: string): Tree {
  const children: Tree[] = [];
  const positions: number[] = [];
  const push = (tree: Tree, at: number) => {
    children.push(tree);
    positions.push(at);
  };

  let at = 0;
  for (const b of findInlineScripts(text)) {
    if (b.from > at) push(leaf(PROSE, b.from - at), at);
    const parts = [leaf(MARK, 2)];
    const offsets = [0];
    if (b.bodyTo > b.bodyFrom) {
      parts.push(leaf(BODY, b.bodyTo - b.bodyFrom));
      offsets.push(2);
    }
    if (b.to > b.bodyTo) {
      parts.push(leaf(MARK, 2));
      offsets.push(b.bodyTo - b.from);
    }
    push(new Tree(SCRIPT, parts, offsets, b.to - b.from), b.from);
    at = b.to;
  }
  if (text.length > at) push(leaf(PROSE, text.length - at), at);
  return new Tree(DOCUMENT, children, positions, text.length);
}

/** Builds the outer tree in one step: a message-sized text needs no incremental parse. */
class OuterParse implements PartialParse {
  parsedPos: number;
  stoppedAt: number | null = null;

  constructor(
    private readonly input: Input,
    private readonly from: number,
    private readonly to: number,
  ) {
    this.parsedPos = from;
  }

  advance(): Tree {
    this.parsedPos = this.to;
    return build(this.input.read(this.from, this.to));
  }

  stopAt(pos: number) {
    this.stoppedAt = pos;
  }
}

/** The outer layer; `wrap` mounts the inner languages on it. */
class InlineScriptParser extends Parser {
  constructor(private readonly wrap: ParseWrapper) {
    super();
  }

  createParse(
    input: Input,
    fragments: readonly TreeFragment[],
    ranges: readonly { from: number; to: number }[],
  ): PartialParse {
    const outer = new OuterParse(input, ranges[0].from, ranges[ranges.length - 1].to);
    return this.wrap(outer, input, fragments, ranges);
  }
}

const luaParser = StreamLanguage.define(lua).parser;

/**
 * `template` (Liquid over Markdown) with `{! … !}` blocks parsed as Lua: the template language is
 * overlaid on the prose between blocks, so it never sees a block's text, and each body gets its own
 * Lua tree for highlighting and for completion's string/comment checks.
 */
export function withInlineScripts(template: Language): Language {
  const wrap = parseMixed((node) => {
    if (node.type === DOCUMENT) return { parser: template.parser, overlay: (n) => n.type === PROSE };
    if (node.type === BODY) return { parser: luaParser };
    return null;
  });
  return new Language(data, new InlineScriptParser(wrap), [], "liquid");
}
