// The docs site's script: MiniSearch search in the header, the table of contents' scroll-spy, and
// closing the nav drawer when one of its links is followed.
import MiniSearch from "minisearch";

type Entry = { id: number; url: string; page: string; section: string | null; heading: string | null; text: string };
type Result = Entry & { terms: string[] };

const basePath = document.body.dataset.basePath ?? "";

// ---- Search ----------------------------------------------------------------------------------

const input = document.querySelector<HTMLInputElement>("#docs-search-input");
const list = document.querySelector<HTMLUListElement>("#docs-search-results");

if (input && list) setUpSearch(input, list);

function setUpSearch(input: HTMLInputElement, list: HTMLUListElement) {
  let index: Promise<MiniSearch<Entry> | null> | null = null;
  let results: Result[] = [];
  let selected = -1;

  const load = () =>
    (index ??= fetch(`${basePath}/search-index.json`)
      .then((response) => {
        if (!response.ok) throw new Error(`search index: HTTP ${response.status}`);
        return response.json() as Promise<Entry[]>;
      })
      .then((entries) => {
        const search = new MiniSearch<Entry>({
          fields: ["heading", "page", "text"],
          storeFields: ["url", "page", "section", "heading", "text"],
          searchOptions: { boost: { heading: 3, page: 2 }, prefix: true, fuzzy: 0.2, combineWith: "AND" },
        });
        search.addAll(entries);
        return search;
      })
      .catch((error) => {
        console.error(error);
        return null;
      }));

  const open = (show: boolean) => {
    list.hidden = !show;
    input.setAttribute("aria-expanded", String(show));
  };

  const message = (text: string) => {
    results = [];
    selected = -1;
    const item = document.createElement("li");
    item.className = "docs-result-empty";
    item.textContent = text;
    list.replaceChildren(item);
    open(true);
  };

  const select = (n: number) => {
    selected = n;
    list.querySelectorAll<HTMLLIElement>("li[role=option]").forEach((item, i) => {
      item.setAttribute("aria-selected", String(i === n));
      if (i === n) item.scrollIntoView({ block: "nearest" });
    });
  };

  const update = async () => {
    const query = input.value.trim();
    if (query.length < 2) {
      open(false);
      return;
    }
    const search = await load();
    if (query !== input.value.trim()) return;
    if (!search) return message("Search is unavailable.");

    results = search.search(query).slice(0, 10) as unknown as Result[];
    if (results.length === 0) return message(`No results for “${query}”`);

    list.replaceChildren(...results.map(renderResult));
    select(0);
    open(true);
  };

  input.addEventListener("focus", () => void load(), { once: true });
  input.addEventListener("input", () => void update());

  input.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      if (results.length === 0) return;
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      select((selected + step + results.length) % results.length);
    } else if (event.key === "Enter") {
      const result = results[selected] ?? results[0];
      if (result) {
        event.preventDefault();
        window.location.href = result.url;
      }
    } else if (event.key === "Escape") {
      input.value = "";
      open(false);
      input.blur();
    }
  });

  document.addEventListener("keydown", (event) => {
    const target = event.target as HTMLElement | null;
    const typing = target?.closest("input, textarea, select, [contenteditable]");
    if (event.key === "/" && !typing && !event.metaKey && !event.ctrlKey && !event.altKey) {
      event.preventDefault();
      input.focus();
    }
  });

  document.addEventListener("click", (event) => {
    if (!(event.target as Element).closest("#docs-search")) open(false);
  });

  list.addEventListener("mousemove", (event) => {
    const item = (event.target as Element).closest<HTMLLIElement>("li[role=option]");
    if (item) select(Number(item.dataset.index));
  });
}

function renderResult(result: Result, i: number): HTMLLIElement {
  const item = document.createElement("li");
  item.setAttribute("role", "option");
  item.dataset.index = String(i);

  const link = document.createElement("a");
  link.href = result.url;

  const heading = document.createElement("span");
  heading.className = "docs-result-heading";
  heading.append(...highlight(result.heading ?? result.page, result.terms));

  const path = document.createElement("span");
  path.className = "docs-result-path";
  path.textContent = result.section ? `${result.section} › ${result.page}` : result.page;

  link.append(heading, path);

  const snippet = snippetOf(result.text, result.terms);
  if (snippet) {
    const text = document.createElement("span");
    text.className = "docs-result-snippet";
    text.append(...highlight(snippet, result.terms));
    link.append(text);
  }

  item.append(link);
  return item;
}

// One case-insensitive alternation of the matched terms, longest first so a prefix never wins.
const termPattern = (terms: string[]) =>
  terms.length
    ? new RegExp(
        terms
          .map((term) => term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
          .sort((a, b) => b.length - a.length)
          .join("|"),
        "gi",
      )
    : null;

// About 120 characters of `text` around its first matched term.
function snippetOf(text: string, terms: string[]): string {
  if (!text) return "";
  const match = termPattern(terms)?.exec(text);
  const at = match ? match.index : 0;
  const start = Math.max(0, at - 40);
  const end = Math.min(text.length, start + 120);
  return `${start > 0 ? "…" : ""}${text.slice(start, end)}${end < text.length ? "…" : ""}`;
}

// Text nodes with each matched term in a `<mark>`; index text never goes through innerHTML.
function highlight(text: string, terms: string[]): Node[] {
  const pattern = termPattern(terms);
  if (!pattern) return [document.createTextNode(text)];
  const nodes: Node[] = [];
  let last = 0;
  for (const match of text.matchAll(pattern)) {
    if (match.index > last) nodes.push(document.createTextNode(text.slice(last, match.index)));
    const mark = document.createElement("mark");
    mark.textContent = match[0];
    nodes.push(mark);
    last = match.index + match[0].length;
  }
  if (last < text.length) nodes.push(document.createTextNode(text.slice(last)));
  return nodes;
}

// ---- Table of contents scroll-spy --------------------------------------------------------------

const tocLinks = new Map<string, HTMLAnchorElement>();
document.querySelectorAll<HTMLAnchorElement>("#docs-toc a[href^='#']").forEach((link) => {
  tocLinks.set(decodeURIComponent(link.hash.slice(1)), link);
});

if (tocLinks.size > 0) {
  const headings = [...document.querySelectorAll<HTMLElement>("#docs-article h2[id], #docs-article h3[id]")];
  const visible = new Set<string>();

  const mark = () => {
    // The first heading on screen, else the last one scrolled past.
    const top = headings.find((h) => visible.has(h.id)) ??
      headings.filter((h) => h.getBoundingClientRect().top < 0).at(-1) ??
      headings[0];
    tocLinks.forEach((link, id) => {
      if (id === top?.id) link.setAttribute("aria-current", "true");
      else link.removeAttribute("aria-current");
    });
  };

  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) visible.add(entry.target.id);
        else visible.delete(entry.target.id);
      }
      mark();
    },
    { rootMargin: "-56px 0px -40% 0px" },
  );
  headings.forEach((heading) => observer.observe(heading));
}

// ---- Nav drawer --------------------------------------------------------------------------------

const nav = document.querySelector<HTMLElement>("#docs-nav");
nav?.addEventListener("click", (event) => {
  if ((event.target as Element).closest("a") && nav.matches(":popover-open")) nav.hidePopover();
});
