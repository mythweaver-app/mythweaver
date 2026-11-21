import {
  axisBottom,
  axisLeft,
  max,
  pointer,
  scaleBand,
  scaleLinear,
  select,
  type ScaleBand,
  type ScaleLinear,
  type Selection,
} from "d3";
import type { Hook, HookInterface } from "phoenix_live_view";
import { locale, t, tn } from "../i18n";

/**
 * The app's D3 charts. The server builds each chart's whole spec, and this hook only draws it.
 *
 * DOM contract:
 *   * The container carries `phx-hook="Chart"`, an `id`, and `phx-update="ignore"` (the hook owns
 *     its children). LiveView still patches an ignored element's `data-*` attributes, and a changed
 *     dataset calls `updated()`, so a new spec redraws the chart.
 *   * `data-chart` is the spec as JSON (`Spec` below). `data-label` is the chart's accessible name.
 *   * Colors are CSS color expressions chosen by the server (`var(--chart-3)`), so a chart follows
 *     the color scheme with no redraw. Every other style comes from the page's CSS: `.chart-axis`,
 *     `.chart-grid`, `.chart-whisker`, the hover rule (`.chart-rule`, `.chart-rule-band`) and the
 *     tooltip (`.chart-tip` and its parts). The container must be `position: relative`, since the
 *     tooltip is placed inside it.
 *
 * Two kinds:
 *   * `stacked`: one bar per category, stacked by series. Vertical for days (`dates: true`, whose
 *     ISO keys the browser labels in its own locale), horizontal for named categories.
 *   * `range`: one horizontal bar per series at `value`, with an optional whisker to `high`.
 *
 * Hovering anywhere over the plot picks the nearest category: a vertical chart draws a rule
 * through it, a horizontal one shades its row, and a tooltip lists its values exactly. It redraws
 * when its width changes.
 */
type Unit = "tokens" | "usd" | "ms" | "tps" | "count";
type Series = { key: string; name: string; color: string };

type StackedSpec = {
  type: "stacked";
  orientation: "vertical" | "horizontal";
  unit: Unit;
  dates?: boolean;
  categories: { key: string; label?: string }[];
  series: Series[];
  points: { category: string; series: string; value: number; parts?: [string, number][] }[];
};

type RangeSpec = {
  type: "range";
  unit: Unit;
  series: Series[];
  points: { series: string; value: number; high?: number | null }[];
};

type Spec = StackedSpec | RangeSpec;

type G = Selection<SVGGElement, unknown, null, undefined>;

type TipRow = { name: string; color: string; value: string; note?: string };
type Tip = { title: string; rows: TipRow[]; total?: string };

// What a drawn chart tells the hover layer: its category axis, plot box, and each category's tooltip.
type Drawn = {
  height: number;
  band: ScaleBand<string>;
  vertical: boolean;
  plot: { left: number; right: number; top: number; bottom: number };
  tip: (key: string) => Tip;
};

// All in the page's regional format (`assets/js/i18n.ts`), like the server-formatted numbers.
const integer = new Intl.NumberFormat(locale(), { maximumFractionDigits: 0 });
const usd = new Intl.NumberFormat(locale(), {
  style: "currency",
  currency: "USD",
  maximumSignificantDigits: 4,
});
const compact = new Intl.NumberFormat(locale(), { notation: "compact", maximumFractionDigits: 1 });
const usdCompact = new Intl.NumberFormat(locale(), {
  style: "currency",
  currency: "USD",
  notation: "compact",
  maximumSignificantDigits: 3,
});
const secondsTick = new Intl.NumberFormat(locale(), {
  style: "unit",
  unit: "second",
  unitDisplay: "narrow",
  maximumSignificantDigits: 2,
});
const speed = new Intl.NumberFormat(locale(), { minimumFractionDigits: 1, maximumFractionDigits: 1 });

// Axis ticks are short; tooltips are exact.
const tick: Record<Unit, (n: number) => string> = {
  tokens: (n) => compact.format(n),
  usd: (n) => usdCompact.format(n),
  ms: (n) => secondsTick.format(n / 1000),
  tps: (n) => compact.format(n),
  count: (n) => integer.format(n),
};

const exact: Record<Unit, (n: number) => string> = {
  tokens: (n) => tn("chart_tokens", n, "token_count"),
  usd: (n) => usd.format(n),
  ms: (n) =>
    new Intl.NumberFormat(locale(), {
      style: "unit",
      unit: "second",
      unitDisplay: "short",
      maximumFractionDigits: n < 10_000 ? 2 : 1,
    }).format(n / 1000),
  tps: (n) => t("chart_tokens_per_second", { speed: speed.format(n) }),
  count: (n) => tn("chart_runs", n, "run_count"),
};

const ROW = 28;
const MAX_LABEL = 24;
const TIP_OFFSET = 12;

function dateLabel(iso: string, style: "short" | "long"): string {
  // Midday keeps the ISO date on the same calendar day in every zone.
  const at = new Date(`${iso}T12:00:00`);
  return new Intl.DateTimeFormat(
    locale(),
    style === "short" ? { month: "short", day: "numeric" } : { dateStyle: "medium" },
  ).format(at);
}

function drawStacked(svg: G, spec: StackedSpec, width: number): Drawn {
  const series = new Map(spec.series.map((s, i) => [s.key, { ...s, order: i }]));
  const label = (key: string, style: "short" | "long") => {
    if (spec.dates) return dateLabel(key, style);
    return spec.categories.find((c) => c.key === key)?.label ?? key;
  };

  // Each category stacks its points in series order, so every bar layers its series the same way.
  const points = [...spec.points].sort(
    (a, b) => (series.get(a.series)?.order ?? 0) - (series.get(b.series)?.order ?? 0),
  );
  const offsets = new Map<string, number>();
  const stacked = points.map((p) => {
    const start = offsets.get(p.category) ?? 0;
    offsets.set(p.category, start + p.value);
    return { ...p, start, end: start + p.value };
  });
  const top = max(offsets.values()) ?? 0;
  const keys = spec.categories.map((c) => c.key);
  const vertical = spec.orientation === "vertical";

  const margin = vertical
    ? { top: 8, right: 8, bottom: 28, left: 56 }
    : { top: 4, right: 16, bottom: 28, left: 150 };
  const height = vertical ? 240 : keys.length * ROW + margin.top + margin.bottom;
  const plot = { left: margin.left, right: width - margin.right, top: margin.top, bottom: height - margin.bottom };

  const band = scaleBand<string>()
    .domain(keys)
    .range(vertical ? [plot.left, plot.right] : [plot.top, plot.bottom])
    .padding(0.2);
  const value = scaleLinear()
    .domain([0, top || 1])
    .nice()
    .range(vertical ? [plot.bottom, plot.top] : [plot.left, plot.right]);

  grid(svg, value, vertical, vertical ? [plot.left, plot.right] : [plot.top, plot.bottom]);

  svg
    .append("g")
    .selectAll("rect")
    .data(stacked)
    .join("rect")
    .attr("x", (d) => (vertical ? band(d.category)! : value(d.start)))
    .attr("y", (d) => (vertical ? value(d.end) : band(d.category)!))
    .attr("width", (d) => (vertical ? band.bandwidth() : value(d.end) - value(d.start)))
    .attr("height", (d) => (vertical ? value(d.start) - value(d.end) : band.bandwidth()))
    .style("fill", (d) => series.get(d.series)?.color ?? "currentColor");

  if (vertical) {
    // As many day labels as fit, evenly spaced.
    const every = Math.max(1, Math.ceil(keys.length / Math.max(1, Math.floor(width / 64))));
    xAxis(svg, plot.bottom, band, keys.filter((_k, i) => i % every === 0), (k) => label(k, "short"));
    yAxis(svg, plot.left, value, tick[spec.unit]);
  } else {
    xAxis(svg, plot.bottom, value, null, tick[spec.unit]);
    yAxis(svg, plot.left, band, (k) => label(k, "short"));
  }

  const tip = (key: string): Tip => {
    const rows = stacked
      .filter((p) => p.category === key && p.value > 0)
      .map((p) => ({
        name: series.get(p.series)?.name ?? p.series,
        color: series.get(p.series)?.color ?? "currentColor",
        value: exact[spec.unit](p.value),
        note: p.parts?.map(([name, n]) => `${integer.format(n)} ${name}`).join(" · "),
      }));
    const sum = offsets.get(key) ?? 0;
    return { title: label(key, "long"), rows, total: rows.length > 1 ? exact[spec.unit](sum) : undefined };
  };

  return { height, band, vertical, plot, tip };
}

function drawRange(svg: G, spec: RangeSpec, width: number): Drawn {
  const series = new Map(spec.series.map((s) => [s.key, s]));
  const margin = { top: 4, right: 16, bottom: 28, left: 150 };
  const keys = spec.points.map((p) => p.series);
  const height = keys.length * ROW + margin.top + margin.bottom;
  const plot = { left: margin.left, right: width - margin.right, top: margin.top, bottom: height - margin.bottom };
  const top = max(spec.points, (p) => Math.max(p.value, p.high ?? 0)) ?? 0;

  const band = scaleBand<string>().domain(keys).range([plot.top, plot.bottom]).padding(0.2);
  const value = scaleLinear()
    .domain([0, top || 1])
    .nice()
    .range([plot.left, plot.right]);

  grid(svg, value, false, [plot.top, plot.bottom]);

  const rows = svg.append("g").selectAll("g").data(spec.points).join("g");

  rows
    .append("rect")
    .attr("x", value(0))
    .attr("y", (d) => band(d.series)!)
    .attr("width", (d) => value(d.value) - value(0))
    .attr("height", band.bandwidth())
    .style("fill", (d) => series.get(d.series)?.color ?? "currentColor");

  const whiskers = rows.filter((d) => d.high != null && d.high > d.value);
  const mid = (d: { series: string }) => band(d.series)! + band.bandwidth() / 2;

  whiskers
    .append("line")
    .attr("class", "chart-whisker")
    .attr("x1", (d) => value(d.value))
    .attr("x2", (d) => value(d.high!))
    .attr("y1", mid)
    .attr("y2", mid);

  whiskers
    .append("line")
    .attr("class", "chart-whisker")
    .attr("x1", (d) => value(d.high!))
    .attr("x2", (d) => value(d.high!))
    .attr("y1", (d) => mid(d) - band.bandwidth() / 4)
    .attr("y2", (d) => mid(d) + band.bandwidth() / 4);

  xAxis(svg, plot.bottom, value, null, tick[spec.unit]);
  yAxis(svg, plot.left, band, (k) => series.get(k)?.name ?? k);

  const tip = (key: string): Tip => {
    const point = spec.points.find((p) => p.series === key)!;
    const s = series.get(key);
    return {
      title: s?.name ?? key,
      rows: [
        {
          name: t("chart_median"),
          color: s?.color ?? "currentColor",
          value: exact[spec.unit](point.value),
          note:
            point.high != null
              ? t("chart_95th_percentile", { percentile_value: exact[spec.unit](point.high) })
              : undefined,
        },
      ],
    };
  };

  return { height, band, vertical: false, plot, tip };
}

function grid(svg: G, value: ScaleLinear<number, number>, vertical: boolean, [from, to]: [number, number]) {
  svg
    .append("g")
    .attr("class", "chart-grid")
    .selectAll("line")
    .data(value.ticks(5))
    .join("line")
    .attr(vertical ? "x1" : "y1", from)
    .attr(vertical ? "x2" : "y2", to)
    .attr(vertical ? "y1" : "x1", (t) => value(t))
    .attr(vertical ? "y2" : "x2", (t) => value(t));
}

function xAxis(
  svg: G,
  y: number,
  scale: ScaleBand<string> | ScaleLinear<number, number>,
  values: string[] | null,
  label: (v: never) => string,
) {
  const axis =
    "bandwidth" in scale
      ? axisBottom(scale).tickValues(values ?? scale.domain()).tickFormat(label as (v: string) => string)
      : axisBottom(scale).ticks(5).tickFormat(label as (v: number | { valueOf(): number }) => string);

  svg
    .append("g")
    .attr("class", "chart-axis")
    .attr("transform", `translate(0,${y})`)
    .call(axis as never);
}

// A band axis's category labels are cut to `MAX_LABEL` characters; the tooltip has the full name.
function yAxis(svg: G, x: number, scale: ScaleBand<string> | ScaleLinear<number, number>, label: (v: never) => string) {
  const axis =
    "bandwidth" in scale
      ? axisLeft(scale)
          .tickSize(0)
          .tickPadding(8)
          .tickFormat((k) => {
            const text = (label as (v: string) => string)(k);
            return text.length > MAX_LABEL ? `${text.slice(0, MAX_LABEL - 1)}…` : text;
          })
      : axisLeft(scale).ticks(5).tickFormat(label as (v: number | { valueOf(): number }) => string);

  svg
    .append("g")
    .attr("class", "chart-axis")
    .attr("transform", `translate(${x},0)`)
    .call(axis as never);
}

// The tooltip's contents, built with `textContent` only: names are user-entered.
function fillTip(el: HTMLElement, tip: Tip) {
  const part = (tag: string, cls: string, text = "") => {
    const node = document.createElement(tag);
    node.className = cls;
    node.textContent = text;
    return node;
  };

  const nodes: HTMLElement[] = [part("div", "chart-tip-title", tip.title)];

  for (const row of tip.rows) {
    const line = part("div", "chart-tip-row");
    const swatch = part("span", "chart-tip-swatch");
    swatch.style.background = row.color;
    line.append(swatch, part("span", "chart-tip-name", row.name), part("span", "chart-tip-value", row.value));
    nodes.push(line);
    if (row.note) nodes.push(part("div", "chart-tip-note", row.note));
  }

  if (tip.total) {
    const line = part("div", "chart-tip-row chart-tip-total");
    line.append(part("span", "chart-tip-name", t("chart_total")), part("span", "chart-tip-value", tip.total));
    nodes.push(line);
  }

  el.replaceChildren(...nodes);
}

// The hover rule and tooltip. An invisible rect over the plot takes the pointer, so hovering a gap
// between bars still picks the nearest category.
function hover(el: HTMLElement, svg: G, drawn: Drawn) {
  const { band, vertical, plot } = drawn;
  const step = band.step();
  const center = (key: string) => band(key)! + band.bandwidth() / 2;

  const rule = vertical
    ? svg.append("line").attr("class", "chart-rule").attr("y1", plot.top).attr("y2", plot.bottom)
    : svg
        .insert("rect", ":first-child")
        .attr("class", "chart-rule-band")
        .attr("x", plot.left)
        .attr("width", plot.right - plot.left)
        .attr("height", step);
  rule.style("visibility", "hidden");

  const tipEl = document.createElement("div");
  tipEl.className = "chart-tip";
  tipEl.hidden = true;
  el.append(tipEl);

  let current: string | null = null;

  svg
    .append("rect")
    .attr("x", plot.left)
    .attr("y", plot.top)
    .attr("width", plot.right - plot.left)
    .attr("height", plot.bottom - plot.top)
    .style("fill", "transparent")
    .on("pointermove", (event: PointerEvent) => {
      const [x, y] = pointer(event, svg.node());
      const at = vertical ? x : y;
      const key = band.domain().reduce((best, k) => (Math.abs(center(k) - at) < Math.abs(center(best) - at) ? k : best));

      if (key !== current) {
        current = key;
        if (vertical) rule.attr("x1", center(key)).attr("x2", center(key));
        else rule.attr("y", center(key) - step / 2);
        rule.style("visibility", "visible");
        fillTip(tipEl, drawn.tip(key));
        tipEl.hidden = false;
      }

      // Beside the pointer, flipped to the other side where it would leave the chart.
      const { clientWidth: w, clientHeight: h } = el;
      const left = x + TIP_OFFSET + tipEl.offsetWidth > w ? x - TIP_OFFSET - tipEl.offsetWidth : x + TIP_OFFSET;
      const top = y + TIP_OFFSET + tipEl.offsetHeight > h ? y - TIP_OFFSET - tipEl.offsetHeight : y + TIP_OFFSET;
      tipEl.style.left = `${Math.max(0, left)}px`;
      tipEl.style.top = `${Math.max(0, top)}px`;
    })
    .on("pointerleave", () => {
      current = null;
      rule.style("visibility", "hidden");
      tipEl.hidden = true;
    });
}

function draw(el: HTMLElement): number {
  const width = el.clientWidth;
  const raw = el.dataset.chart;
  el.replaceChildren();
  if (!raw || width === 0) return width;

  const spec = JSON.parse(raw) as Spec;
  const svg = select(el)
    .append("svg")
    .attr("width", width)
    .attr("role", "img")
    .attr("aria-label", el.dataset.label ?? "");
  const g = svg.append("g");

  const drawn = spec.type === "stacked" ? drawStacked(g, spec, width) : drawRange(g, spec, width);
  svg.attr("height", drawn.height).attr("viewBox", `0 0 ${width} ${drawn.height}`);
  hover(el, g, drawn);
  return width;
}

type State = { observer: ResizeObserver; width: number };

type Self = State & HookInterface;

export const Chart: Hook<State> = {
  mounted(this: Self) {
    this.width = draw(this.el);
    this.observer = new ResizeObserver(() => {
      if (this.el.clientWidth !== this.width) this.width = draw(this.el);
    });
    this.observer.observe(this.el);
  },

  updated(this: Self) {
    this.width = draw(this.el);
  },

  destroyed(this: Self) {
    this.observer.disconnect();
  },
};
