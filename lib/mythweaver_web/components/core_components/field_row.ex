defmodule MythweaverWeb.CoreComponents.FieldRow do
  @moduledoc """
  One line of form fields, SillyTavern-style: small fields share a line and wrap when the panel is
  narrow. Each `:field` slot is one cell; `size` picks how it shares the line:

    * `"normal"` (default): an equal share, at least ~7rem
    * `"wide"`: about four shares, for names and keyword lists
    * `"fit"`: its own width, for a lone checkbox
    * `"column"`: a column of checkboxes that drops to its own line before a label would wrap

  Labels never wrap: a cell is at least as wide as its label, and the row wraps a whole cell to the
  next line instead (at the `--phone` breakpoint, labels wrap again rather than overflow). Wrapped lines
  are balanced (the `.FieldRow` hook): the row keeps as few lines as plain wrapping would, but
  spreads the cells evenly over them (11 cells on two lines go 6+5, not 10+1), each line's cells
  sharing its width by their size's share. Cells bottom-align (`align="start"` top-aligns them, for
  cells with help text under the control; `align="stretch"` gives a line's cells one height, for
  boxes side by side such as `MythweaverWeb.MultiSelect`s), and text inputs and single selects
  inside a row share one height. Multi-selects share a fixed height so a row of lists lines up.
  """

  use Phoenix.Component

  attr :id, :string, required: true, doc: "DOM id, for the balancing hook"

  attr :align, :string,
    values: ~w(end start stretch),
    default: "end",
    doc:
      "`end` bottom-aligns cells; `start` top-aligns them, for cells with help text under their control; `stretch` makes a line's cells equally tall"

  slot :field, required: true do
    attr :size, :string, values: ~w(normal wide fit column)
    attr :class, :any, doc: "layout hook for the caller"
  end

  def field_row(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: the cells hold the caller's `<.input>`s, nested-component roots carrying
      `phx-r` that the default exclusive bound cuts off. Only the root `div.field-row` carries this
      block's marker (so it is the one `:scope` rule); the cells are plain descendants.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.field-row:scope {
        display: flex;
        flex-wrap: wrap;
        align-items: flex-end;
        gap: var(--size-2) var(--size-3);
      }

      div.field-row--start:scope {
        align-items: flex-start;
      }

      div.field-row--stretch:scope {
        align-items: stretch;
      }

      /* `--field-row-floor` is a size's narrowest share; `--field-row-basis` is the hook's
         balanced width, set inline. */
      .field-row-cell {
        --field-row-floor: 7rem;
        flex: 1 1 var(--field-row-basis, var(--field-row-floor));
        min-inline-size: min-content;
      }

      .field-row-cell--wide {
        --field-row-floor: 14rem;
        flex-grow: 4;
      }

      .field-row-cell--fit {
        --field-row-floor: auto;
        flex: 0 0 auto;
      }

      .field-row-cell--column {
        --field-row-floor: 16rem;
        flex-shrink: 0;
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      /* The hook reads each cell's narrowest width here: its floor, or its label if wider. */
      div.field-row--measuring:scope > .field-row-cell {
        flex: none;
        inline-size: var(--field-row-floor);
      }

      label {
        display: block;
        white-space: nowrap;
      }

      /* A lone checkbox sits level with the inputs beside it, not with their labels. */
      .field-row-cell--fit input[type="checkbox"] {
        margin-block: var(--size-2);
      }

      /* Text inputs and single selects render at different natural heights. */
      input.input,
      select.input:not([multiple]) {
        box-sizing: border-box;
        block-size: calc(1lh + 2 * var(--size-2) + 2px);
      }

      select.input[multiple] {
        block-size: 9rem;
      }

      @media (--phone) {
        label {
          white-space: normal;
        }

        .field-row-cell {
          min-inline-size: 0;
        }
      }
    </style>
    <div
      id={@id}
      class={["field-row", @align != "end" && "field-row--#{@align}"]}
      phx-hook=".FieldRow"
    >
      <div
        :for={field <- @field}
        class={["field-row-cell", "field-row-cell--#{field[:size] || "normal"}", field[:class]]}
      >
        {render_slot(field)}
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".FieldRow">
      // Balances the wrapped lines. Plain wrapping fills each line greedily, which can strand one
      // cell on the last line (10+1). This keeps the greedy line count, which is the fewest the
      // cells fit in, but picks the split whose narrowest share is widest (6+5), then sets every
      // cell's width so its line breaks there: each line's width shared by flex-grow weight, never
      // below a cell's floor or label. `fit` cells (weight 0) keep their own width.

      // Width left unassigned on each line, so rounding never pushes a cell to the next line;
      // flex-grow fills it.
      const SLACK_PX = 1;

      export default {
        mounted() {
          this.kept = new WeakSet();
          this.width = null;
          this.resize = new ResizeObserver(() => {
            if (this.el.clientWidth !== this.width) this.layout();
          });
          this.resize.observe(this.el);
          // Cells come and go with the caller's `:if`s.
          this.cells = new MutationObserver(() => this.layout());
          this.cells.observe(this.el, { childList: true });
          // Labels are measured; a late web font changes their width.
          document.fonts?.ready.then(() => this.layout());
        },

        updated() {
          this.layout();
        },

        destroyed() {
          this.resize.disconnect();
          this.cells.disconnect();
        },

        layout() {
          const row = this.el;
          const width = row.clientWidth;
          this.width = width;
          const cells = [...row.children].filter((el) =>
            el.classList.contains("field-row-cell"),
          );
          // Hidden (a closed modal or section): the resize observer runs again once it shows.
          if (width === 0 || cells.length === 0) return;

          for (const cell of cells) {
            if (!this.kept.has(cell)) {
              // The server never renders `style`; without this a patch would strip the widths.
              this.js().ignoreAttributes(cell, ["style"]);
              this.kept.add(cell);
            }
            cell.style.removeProperty("--field-row-basis");
          }

          const gap = parseFloat(getComputedStyle(row).columnGap) || 0;
          const weights = cells.map(
            (cell) => parseFloat(getComputedStyle(cell).flexGrow) || 0,
          );
          row.classList.add("field-row--measuring");
          const floors = cells.map((cell) => cell.getBoundingClientRect().width);
          row.classList.remove("field-row--measuring");

          const lines = this.split(floors, weights, width, gap);
          if (!lines) return;

          for (const [from, to] of lines) {
            const widths = this.share(floors, weights, width, gap, from, to);
            for (let i = from; i < to; i++) {
              if (weights[i] > 0) {
                cells[i].style.setProperty(
                  "--field-row-basis",
                  `${Math.floor(widths[i - from] * 100) / 100}px`,
                );
              }
            }
          }
        },

        // The most even split into the greedy line count: [[from, to], …] cell index ranges.
        split(floors, weights, width, gap) {
          const n = floors.length;
          const fits = (from, to) => {
            let used = gap * (to - from - 1);
            for (let i = from; i < to; i++) used += floors[i];
            // A cell wider than the row still gets a line of its own.
            return to - from === 1 || used <= width - SLACK_PX;
          };

          let count = 0;
          for (let from = 0; from < n; count++) {
            let to = from + 1;
            while (to < n && fits(from, to + 1)) to++;
            from = to;
          }

          // best[l][j]: the best split of the first j cells into l lines, scored by its narrowest
          // and widest share of one weight.
          const best = Array.from({ length: count + 1 }, () =>
            new Array(n + 1).fill(null),
          );
          best[0][0] = { min: Infinity, max: 0, lines: [] };
          for (let l = 1; l <= count; l++) {
            for (let to = l; to <= n; to++) {
              // Longest first line first, so a tie goes 6+5 rather than 5+6.
              for (let from = to - 1; from >= l - 1; from--) {
                const prev = best[l - 1][from];
                if (!prev || !fits(from, to)) continue;
                const [min, max] = this.units(floors, weights, width, gap, from, to);
                const candidate = {
                  min: Math.min(prev.min, min),
                  max: Math.max(prev.max, max),
                  lines: [...prev.lines, [from, to]],
                };
                if (this.better(candidate, best[l][to])) best[l][to] = candidate;
              }
            }
          }

          return best[count][n]?.lines;
        },

        better(candidate, current) {
          if (!current) return true;
          if (candidate.min > current.min + 0.5) return true;
          return (
            Math.abs(candidate.min - current.min) <= 0.5 &&
            candidate.max < current.max - 0.5
          );
        },

        // A line's narrowest and widest width per unit of weight.
        units(floors, weights, width, gap, from, to) {
          const widths = this.share(floors, weights, width, gap, from, to);
          let min = Infinity;
          let max = 0;
          for (let i = from; i < to; i++) {
            if (weights[i] === 0) continue;
            const unit = widths[i - from] / weights[i];
            min = Math.min(min, unit);
            max = Math.max(max, unit);
          }
          // A line of `fit` cells only has no share and does not count.
          return min === Infinity ? [Infinity, 0] : [min, max];
        },

        // Shares a line's width by weight. A cell whose floor exceeds its share keeps its floor and
        // the rest share what is left, until every share covers its floor.
        share(floors, weights, width, gap, from, to) {
          const widths = floors.slice(from, to);
          let room = width - SLACK_PX - gap * (to - from - 1);
          let open = [];
          for (let i = from; i < to; i++) {
            if (weights[i] > 0) open.push(i);
            else room -= floors[i];
          }

          while (open.length > 0) {
            const weight = open.reduce((sum, i) => sum + weights[i], 0);
            const unit = room / weight;
            const over = open.filter((i) => floors[i] > unit * weights[i]);
            if (over.length === 0) {
              for (const i of open) widths[i - from] = unit * weights[i];
              break;
            }
            for (const i of over) room -= floors[i];
            open = open.filter((i) => !over.includes(i));
          }

          return widths;
        },
      };
    </script>
    """
  end
end
