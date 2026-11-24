defmodule MythweaverWeb.CoreComponents.Markdown do
  @moduledoc """
  Rendered message prose: `markdown/1` turns markdown source into sanitized HTML through
  `MythweaverWeb.Markdown` and owns every prose style, so bodies, reasoning and scratchpads read the
  same.

  Quoted dialogue takes `--prose-dialogue` and `*action*` emphasis `--prose-action`
  (`assets/css/tokens.css`), the two theme hooks. Each rendered text run carries its source offset as
  `data-o`, which the message body's double-click-to-edit maps back to an editor position.

  The rendered HTML carries no scope marker but sits under this component's root, so the scoped
  rules below reach it with bare selectors; a caller cannot style the root (it is `phx-r`) and keeps
  its own wrapper element around `<.markdown>`.

  With an `id`, the colocated `.StreamReveal` hook reveals a reply still arriving at a steady pace:
  the text past the reveal point is transparent and its own caret (`.md-reveal-caret`) stands in for
  the server's `.md-caret`.
  """

  use Phoenix.Component

  attr :text, :string, default: nil, doc: "markdown source"

  attr :streaming, :boolean,
    default: false,
    doc: "close syntax still open at the end: a reply that is arriving"

  attr :caret, :boolean, default: false, doc: "end with the blinking in-flight cursor"

  attr :id, :string,
    default: nil,
    doc: "with an id, a reply still arriving is revealed at a steady pace (the .StreamReveal hook)"

  attr :rest, :global

  def markdown(assigns) do
    ~H"""
    <%!-- Highlights paint outside any scope. --%>
    <style :type={MythweaverWeb.ColocatedCSS}>
      ::highlight(stream-unrevealed) {
        color: transparent;
      }
    </style>
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div:scope {
        overflow-wrap: anywhere;
      }
      div:scope:has(> .md-reveal-caret) {
        position: relative;
      }
      div:scope > :first-child,
      div:scope > .md-reveal-caret:first-child + * {
        margin-block-start: 0;
      }
      div:scope > :last-child {
        margin-block-end: 0;
      }
      p,
      ul,
      ol,
      blockquote,
      pre,
      table,
      hr {
        margin-block: 0 var(--size-3);
      }
      h1,
      h2,
      h3,
      h4,
      h5,
      h6 {
        margin-block: var(--size-3) var(--size-2);
        line-height: 1.25;
        font-weight: 700;
      }
      h1 {
        font-size: 1.4em;
      }
      h2 {
        font-size: 1.25em;
      }
      h3 {
        font-size: 1.1em;
      }
      h4,
      h5,
      h6 {
        font-size: 1em;
      }
      ul,
      ol {
        padding-inline-start: var(--size-5);
      }
      blockquote {
        margin-inline: 0;
        padding-inline-start: var(--size-3);
        border-inline-start: 2px solid var(--border);
        color: var(--muted-foreground);
      }
      code {
        font-family: var(--font-monospace-code, ui-monospace, monospace);
        font-size: 0.9em;
      }
      :not(pre) > code {
        padding-inline: 0.25em;
        border-radius: var(--radius-1);
        background: var(--surface-3);
      }
      pre {
        padding: var(--size-2);
        border-radius: var(--radius-2);
        background: var(--surface-1);
        white-space: pre-wrap;
      }
      a {
        color: var(--link);
      }
      em {
        font-style: italic;
        color: var(--prose-action);
      }
      .md-dialogue {
        color: var(--prose-dialogue);
      }
      table {
        border-collapse: collapse;
      }
      th,
      td {
        padding: var(--size-1) var(--size-2);
        border: 1px solid var(--border-grey);
      }
      hr {
        border: none;
        border-block-start: 1px solid var(--border-grey);
      }
      img {
        max-inline-size: 100%;
      }
      /* The in-flight cursor. Pure CSS: `caret` is server-rendered state. */
      .md-caret {
        display: inline-block;
        width: 1ch;
        height: 1em;
        vertical-align: text-bottom;
        background: currentColor;
        animation: md-caret-blink 1s step-end infinite;
      }
      @keyframes md-caret-blink {
        50% {
          opacity: 0;
        }
      }
      /* The paced reveal's cursor stands in for `.md-caret`, which keeps its place in the layout. */
      div:scope:has(> .md-reveal-caret:not([hidden])) .md-caret {
        visibility: hidden;
      }
      .md-reveal-caret {
        position: absolute;
        inset: 0 auto auto 0;
        width: 1ch;
        height: 1em;
        background: currentColor;
        pointer-events: none;
      }
    </style>
    <%!--
      LiveView expands a colocated hook's `.StreamReveal` only in a literal `phx-hook`; this one is
      attached only with an `id`, so its expanded name is written out.
    --%>
    <div
      class="markdown"
      id={@id}
      phx-hook={@id && "MythweaverWeb.CoreComponents.Markdown.StreamReveal"}
      data-streaming={@id && to_string(@streaming)}
      {@rest}
    >
      <span
        :if={@id && @caret}
        id={"#{@id}-caret"}
        class="md-reveal-caret"
        phx-update="ignore"
        hidden
        aria-hidden="true"
      ></span>
      {Phoenix.HTML.raw(MythweaverWeb.Markdown.to_html(@text, streaming: @streaming, caret: @caret))}
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".StreamReveal">
      /**
       * Reveals a reply still arriving at a steady, adaptive pace instead of in network-sized
       * bursts: text past the reveal point stays in the layout but paints transparent, and a caret
       * of the hook's own marks the reveal point.
       *
       * DOM contract (`markdown/1` with an `id`):
       *   * The root carries this hook, an `id` and `data-streaming` (`"true"` while the reply is
       *     arriving).
       *   * While the server draws its in-flight caret, the root's first child is
       *     `<span class="md-reveal-caret" hidden phx-update="ignore">`; the hook unhides and
       *     positions it, and the component's CSS hides the server's `.md-caret` while it shows.
       *   * The global `::highlight(stream-unrevealed)` rule makes the unrevealed text transparent.
       *
       * The pace clears the backlog in `CATCH_UP_S` but never drops under `MIN_CPS`, and never
       * trails more than `MAX_BACKLOG` characters behind. Progress is kept per root id across
       * remounts while the reply streams. A root that mounts mid-reply (a tab opened late, a
       * continue) shows the text already there at once; a fresh reply starts from its blank body.
       * Without the CSS Custom Highlight API the hook does nothing and the text and server caret
       * show as they arrive.
       *
       * Known: element-drawn chrome past the reveal point (list bullets, inline-code backgrounds,
       * blockquote borders, images) shows before its text, and the last catch-up after the reply
       * finishes has no caret.
       */
      const HIGHLIGHT = "stream-unrevealed";
      // Seconds allowed to clear the backlog.
      const CATCH_UP_S = 0.2;
      // The slowest reveal, in characters per second.
      const MIN_CPS = 60;
      // Characters; the reveal never trails further behind than this.
      const MAX_BACKLOG = 400;
      // Caps one frame's step after a background tab.
      const MAX_DT_S = 0.1;

      // Revealed characters (UTF-16 units) per root id, so a remounted hook resumes.
      const progress = new Map();
      // One highlight for every root; each hook keeps only its own range in it.
      let shared = null;

      // The CSS Custom Highlight API.
      const SUPPORTED =
        typeof CSS !== "undefined" &&
        "highlights" in CSS &&
        typeof StaticRange !== "undefined";

      function highlight() {
        if (!shared) {
          shared = new Highlight();
          CSS.highlights.set(HIGHLIGHT, shared);
        }
        return shared;
      }

      function streaming(self) {
        return self.el.dataset.streaming === "true";
      }

      const isLowSurrogate = (code) => code >= 0xdc00 && code <= 0xdfff;

      // The visible text and its length in UTF-16 units: whitespace-only nodes (between blocks,
      // before the spaced caret) are skipped so the pace never stalls on characters nobody sees,
      // and so is KaTeX's screen-reader copy.
      function textNodes(root) {
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
          acceptNode: (n) =>
            /\S/.test(n.data) && !n.parentElement?.closest(".katex-mathml")
              ? NodeFilter.FILTER_ACCEPT
              : NodeFilter.FILTER_REJECT,
        });
        const nodes = [];
        let total = 0;
        while (walker.nextNode()) {
          const node = walker.currentNode;
          nodes.push(node);
          total += node.length;
        }
        return { nodes, total };
      }

      function start(self) {
        if (!SUPPORTED) return;
        const id = self.el.id;
        if (!progress.has(id) && !streaming(self)) return;
        const { nodes, total } = textNodes(self.el);
        if (!progress.has(id)) progress.set(id, total);

        // A patch just landed: hide its new text before the browser paints it.
        paint(self, nodes, total, Math.min(progress.get(id), total));

        if (self.frame === null) {
          self.last = performance.now();
          self.frame = requestAnimationFrame((now) => tick(self, now));
        }
      }

      function tick(self, now) {
        self.frame = null;
        const id = self.el.id;
        const { nodes, total } = textNodes(self.el);
        // A frame's timestamp is its start, which can precede the `performance.now()` that
        // `start` took.
        const dt = Math.min(Math.max(now - self.last, 0) / 1000, MAX_DT_S);
        self.last = now;

        let shown = Math.max(
          Math.min(progress.get(id) ?? total, total),
          total - MAX_BACKLOG,
        );
        if (shown < total)
          shown = Math.min(
            total,
            shown + Math.max(MIN_CPS, (total - shown) / CATCH_UP_S) * dt,
          );

        progress.set(id, shown);
        paint(self, nodes, total, shown);

        if (shown >= total) {
          if (!streaming(self)) {
            progress.delete(id);
            unpaint(self);
          }
          return;
        }

        self.frame = requestAnimationFrame((t) => tick(self, t));
      }

      function paint(self, nodes, total, shown) {
        const n = Math.floor(shown);
        if (n >= total || nodes.length === 0) {
          unpaint(self);
          return;
        }

        // The node holding the boundary; a boundary between two nodes stays in the earlier one.
        let i = 0;
        let off = n;
        while (off > nodes[i].length) {
          off -= nodes[i].length;
          i++;
        }
        const node = nodes[i];
        if (off < node.length && isLowSurrogate(node.data.charCodeAt(off))) off++;

        const range = new StaticRange({
          startContainer: node,
          startOffset: off,
          endContainer: self.el,
          endOffset: self.el.childNodes.length,
        });
        const h = highlight();
        if (self.range) h.delete(self.range);
        h.add(range);
        self.range = range;

        const caret = self.el.querySelector(":scope > .md-reveal-caret");
        if (!caret) return;
        caret.hidden = false;

        // The last revealed character, or the first one before anything is revealed.
        const measure = document.createRange();
        if (off === 0) {
          const end =
            node.length > 1 && isLowSurrogate(node.data.charCodeAt(1)) ? 2 : 1;
          measure.setStart(node, 0);
          measure.setEnd(node, Math.min(end, node.length));
        } else {
          const from =
            off >= 2 && isLowSurrogate(node.data.charCodeAt(off - 1))
              ? off - 2
              : off - 1;
          measure.setStart(node, from);
          measure.setEnd(node, off);
        }
        const rects = measure.getClientRects();
        const rect = off === 0 ? rects[0] : rects[rects.length - 1];
        // A character at a line wrap can have no box; the caret keeps its last place.
        if (!rect) return;

        const box = self.el.getBoundingClientRect();
        const x = (off === 0 ? rect.left : rect.right) - box.left;
        // Bottom-aligned like `.md-caret`'s `vertical-align: text-bottom`.
        const y = rect.bottom - box.top - caret.offsetHeight;
        caret.style.translate = `${x}px ${y}px`;
      }

      function unpaint(self) {
        if (self.range) {
          shared?.delete(self.range);
          self.range = null;
        }
        const caret = self.el.querySelector(":scope > .md-reveal-caret");
        if (caret) caret.hidden = true;
      }

      export default {
        mounted() {
          this.frame = null;
          this.last = 0;
          this.range = null;
          // A reply that finished while its row was unmounted shows at once.
          if (SUPPORTED && !streaming(this)) progress.delete(this.el.id);
          start(this);
        },

        updated() {
          start(this);
        },

        destroyed() {
          if (this.frame !== null) cancelAnimationFrame(this.frame);
          this.frame = null;
          if (!SUPPORTED) return;
          unpaint(this);
          if (!streaming(this)) progress.delete(this.el.id);
        },
      };
    </script>
    """
  end
end
