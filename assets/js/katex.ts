// Renders the math `MythweaverWeb.Markdown` emits: empty `.katex-inline` / `.katex-block` elements
// carrying `data-latex` and `data-math-style`. The server always sends them empty, so every
// LiveView patch that touches one (a streamed token, a swipe, an edit) strips the rendered
// children, and an empty one is exactly one that needs (re)rendering. A document-wide observer
// covers every surface that shows markdown without a hook per formula or per view.
import katex from "katex";

const SELECTOR = ".katex-inline, .katex-block";

function render(el: HTMLElement) {
  const latex = el.dataset.latex;
  if (!latex || el.firstChild) return;
  katex.render(latex, el, {
    displayMode: el.dataset.mathStyle === "display",
    throwOnError: false,
    // Message text is user- and model-written: no `\href`, `\htmlClass` and friends.
    trust: false,
  });
}

function scan(root: ParentNode) {
  if (root instanceof HTMLElement && root.matches(SELECTOR)) render(root);
  root.querySelectorAll<HTMLElement>(SELECTOR).forEach(render);
}

new MutationObserver((records) => {
  for (const record of records) {
    const target = record.target;
    if (target instanceof HTMLElement && target.matches(SELECTOR)) render(target);
    record.addedNodes.forEach((node) => {
      if (node instanceof HTMLElement) scan(node);
    });
  }
}).observe(document.documentElement, { childList: true, subtree: true });

scan(document);
