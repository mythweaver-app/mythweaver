import type { Tooltip } from "@codemirror/view";

/** A hover tooltip over `pos..end`: `title` set as code, then `info` when it is text. */
export function docTooltip(pos: number, end: number, title: string, info: unknown): Tooltip {
  return {
    pos,
    end,
    above: true,
    create() {
      const dom = document.createElement("div");
      dom.className = "cm-doc-hover";
      dom.appendChild(document.createElement("code")).textContent = title;
      if (typeof info === "string") dom.appendChild(document.createElement("p")).textContent = info;
      return { dom };
    },
  };
}
