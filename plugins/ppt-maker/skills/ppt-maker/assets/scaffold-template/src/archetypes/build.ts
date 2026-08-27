/* ─────────────────────────────────────────────────────────────────────
 * archetypes/build.ts — element constructors.
 *
 * Archetypes are read far more often than they are written: the review
 * step, the console and anyone adding a layout all have to see the
 * SHAPE of a page at a glance. These helpers exist so a build() reads
 * as a list of "what goes where" rather than a wall of object literals.
 * ───────────────────────────────────────────────────────────────────── */

import type {
  ChartSpec,
  Element,
  GridRect,
  Item,
  ListItem,
  MetricEl,
  ShapeEl,
  TextEl,
  TextRole,
} from "../deck/types";

/** `g(1, 2, 6, 3)` — column, row, width, height, all 1-indexed. */
export function g(
  column: number,
  row: number,
  width: number,
  height: number,
): GridRect {
  return { column, row, width, height };
}

export function text(
  id: string,
  role: TextRole,
  grid: GridRect,
  content: string,
  opts: Partial<Omit<TextEl, "id" | "type" | "role" | "grid" | "text">> = {},
): TextEl {
  return { id, type: "text", role, grid, text: content, ...opts };
}

export function metric(
  id: string,
  grid: GridRect,
  value: string,
  opts: Partial<Omit<MetricEl, "id" | "type" | "grid" | "value">> = {},
): MetricEl {
  return { id, type: "metric", grid, value, ...opts };
}

export function list(
  id: string,
  grid: GridRect,
  style: "bullet" | "numbered" | "card" | "rule",
  items: ListItem[],
  columns?: number,
): Element {
  return { id, type: "list", grid, style, items, ...(columns ? { columns } : {}) };
}

export function shape(
  id: string,
  grid: GridRect,
  opts: Partial<Omit<ShapeEl, "id" | "type" | "grid">> = {},
): ShapeEl {
  return { id, type: "shape", grid, shape: "rect", ...opts };
}

export function rule(
  id: string,
  grid: GridRect,
  opts: { accent?: boolean; vertical?: boolean } = {},
): ShapeEl {
  return {
    id,
    type: "shape",
    grid,
    shape: "line",
    stroke: opts.accent ? "accent" : "rule",
    ...(opts.vertical ? { orient: "vertical" as const } : {}),
  };
}

export function chart(
  id: string,
  grid: GridRect,
  spec: ChartSpec,
  caption?: string,
): Element {
  return { id, type: "chart", grid, chart: spec, ...(caption ? { caption } : {}) };
}

/**
 * Drop the elements an archetype decided not to render.
 *
 * Accepts any falsy value, so a build() can guard with the content
 * itself — `p.summary && text(...)` — instead of restating the check as
 * a boolean. An absent optional string yields `undefined` or `""`, and
 * both mean the same thing here: nothing to draw.
 */
export function compact(
  elements: Array<Element | null | false | undefined | "">,
): Element[] {
  return elements.filter((e): e is Element => Boolean(e));
}

/* ── item projections ────────────────────────────────────────────── */

/**
 * Canonical items → list rows, showing the VALUE first when there is
 * one. A metric row reads "38% / 复购率", not "复购率 / 38%" — the number
 * is what the eye is hunting for.
 */
export function itemsAsMetricRows(items: Item[]): ListItem[] {
  return items.map((item, i) => ({
    id: item.id ?? `i${i}`,
    label: item.displayValue ?? (item.value !== undefined ? String(item.value) : item.label),
    detail: item.displayValue || item.value !== undefined ? item.label : item.detail,
  }));
}

/** Canonical items → list rows for prose content (label leads). */
export function itemsAsRows(items: Item[]): ListItem[] {
  return items.map((item, i) => ({
    id: item.id ?? `i${i}`,
    label: item.label,
    detail: item.detail ?? item.displayValue,
  }));
}

/**
 * Canonical items → a chart spec. Only items carrying a real numeric
 * `value` make it in; a chart built from labels alone is a lie.
 */
export function itemsAsChart(
  items: Item[],
  kind: ChartSpec["kind"],
  seriesName: string,
  extra: Partial<ChartSpec> = {},
): ChartSpec | null {
  const usable = items.filter((i) => typeof i.value === "number");
  if (usable.length < 2) return null;
  return {
    kind,
    categories: usable.map((i) => i.label),
    series: [{ name: seriesName, data: usable.map((i) => i.value as number) }],
    unit: usable[0]?.unit,
    ...extra,
  };
}

/** Split items into N roughly equal columns, left-to-right. */
export function columnsOf<T>(items: T[], columns: number): T[][] {
  const per = Math.ceil(items.length / columns);
  return Array.from({ length: columns }, (_, c) =>
    items.slice(c * per, (c + 1) * per),
  );
}
