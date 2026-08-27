/* ─────────────────────────────────────────────────────────────────────
 * charts/frame.ts — the cartesian frame every axis chart shares.
 *
 * Axes, gridlines, category labels and the legend are laid out ONCE
 * here. A chart builder gets back the plot rect plus scale functions and
 * only has to draw its own marks. That is why column / bar / line /
 * area / scatter / waterfall / slope / dumbbell all sit on exactly the
 * same baseline and tick grid instead of each inventing its own.
 * ───────────────────────────────────────────────────────────────────── */

import type { Rect } from "../deck/layout";
import { CHART_TYPE } from "../deck/typography";
import type { ChartSpec } from "../deck/types";
import { paint, type Primitive } from "./primitives";
import { formatValue, niceTicks } from "./scale";

export const GUTTER = {
  /** Room for value-axis labels. */
  axis: 76,
  /** Room for category labels under the plot. */
  categories: 40,
  /** Headroom so a top value label isn't clipped. */
  top: 28,
  right: 8,
  legend: 38,
} as const;

export interface Scales {
  /** Value → absolute y px. */
  y(value: number): number;
  /** Category index → centre x px of its band. */
  cx(index: number): number;
  /** Width of one category band. */
  bandW: number;
  min: number;
  max: number;
}

export interface Frame {
  plot: Rect;
  legend: Rect | null;
  scales: Scales;
  /** Gridlines, axis labels, category labels, legend — draw these first. */
  chrome: Primitive[];
}

export interface FrameOptions {
  /** Skip the value axis entirely (pie, treemap, sankey…). */
  valueAxis?: boolean;
  /** Skip category labels (scatter uses a numeric x axis instead). */
  categoryLabels?: boolean;
  /** Force the value range instead of deriving it from the data. */
  range?: { min: number; max: number };
  /** Extra left inset when the chart draws its own row labels. */
  leftInset?: number;
}

export function cartesianFrame(
  spec: ChartSpec,
  box: Rect,
  options: FrameOptions = {},
): Frame {
  const {
    valueAxis = true,
    categoryLabels = true,
    range,
    leftInset,
  } = options;

  const legendH = spec.legend ? GUTTER.legend : 0;
  const left = leftInset ?? (valueAxis ? GUTTER.axis : 0);
  const bottom = categoryLabels ? GUTTER.categories : 0;

  const plot: Rect = {
    x: box.x + left,
    y: box.y + GUTTER.top,
    w: Math.max(1, box.w - left - GUTTER.right),
    h: Math.max(1, box.h - GUTTER.top - bottom - legendH),
  };

  const legend: Rect | null = spec.legend
    ? { x: plot.x, y: box.y + box.h - legendH, w: plot.w, h: legendH }
    : null;

  const values = spec.series
    .flatMap((s) => s.data)
    .filter((v): v is number => typeof v === "number");
  const dataMin = values.length ? Math.min(...values) : 0;
  const dataMax = values.length ? Math.max(...values) : 1;
  // Bars are read as "how tall", which is only honest from zero. A deck
  // that genuinely needs a cropped axis says so with `baseline`, making
  // it a visible choice rather than an accident.
  const baseline = spec.baseline ?? 0;
  const ticks = range
    ? { ...range, values: niceTicks(range.min, range.max).values }
    : niceTicks(Math.min(baseline, dataMin), Math.max(baseline, dataMax));

  const min = ticks.min;
  const max = ticks.max;
  const span = max - min || 1;
  const y = (v: number) => plot.y + plot.h - ((v - min) / span) * plot.h;

  const catCount = Math.max(1, spec.categories.length);
  const bandW = plot.w / catCount;
  const cx = (i: number) => plot.x + (i + 0.5) * bandW;

  const chrome: Primitive[] = [];

  if (valueAxis) {
    for (const value of ticks.values) {
      const ty = y(value);
      chrome.push({
        kind: "line",
        x1: plot.x,
        y1: ty,
        x2: plot.x + plot.w,
        y2: ty,
        stroke: paint.grid,
        strokeW: 1,
      });
      chrome.push({
        kind: "text",
        x: box.x,
        y: ty - 14,
        w: left - 16,
        h: 28,
        text: formatValue(value, spec.unit),
        sizePx: CHART_TYPE.axisLabel.sizePx,
        color: paint.label,
        align: "right",
        valign: "middle",
        family: "mono",
      });
    }
  }

  if (categoryLabels) {
    spec.categories.forEach((label, i) => {
      chrome.push({
        kind: "text",
        x: cx(i) - bandW / 2,
        y: plot.y + plot.h + 8,
        w: bandW,
        h: 26,
        text: label,
        sizePx: CHART_TYPE.axisLabel.sizePx,
        color: paint.label,
        align: "center",
        valign: "top",
        family: "body",
      });
    });
  }

  if (legend) {
    chrome.push(...legendPrimitives(spec, legend));
  }

  return { plot, legend, scales: { y, cx, bandW, min, max }, chrome };
}

/* ── horizontal frame: categories run down the left, value across ──
 * Bars, dumbbells and gantt rows all read left-to-right against a
 * shared category column, so they get their own frame rather than a
 * rotated version of the vertical one — rotation would put the value
 * labels on their side, which nobody can read.
 * ───────────────────────────────────────────────────────────────── */

export interface RowFrame {
  plot: Rect;
  legend: Rect | null;
  /** Value → absolute x px. */
  x(value: number): number;
  /** Category index → absolute y px of its row centre. */
  cy(index: number): number;
  rowH: number;
  min: number;
  max: number;
  chrome: Primitive[];
}

export interface RowFrameOptions {
  /** Width reserved for the category names. */
  labelW?: number;
  range?: { min: number; max: number };
  /** Draw vertical gridlines at each tick. */
  gridlines?: boolean;
}

export function rowFrame(
  spec: ChartSpec,
  box: Rect,
  options: RowFrameOptions = {},
): RowFrame {
  const { labelW = 150, range, gridlines = true } = options;
  const legendH = spec.legend ? GUTTER.legend : 0;

  const plot: Rect = {
    x: box.x + labelW,
    y: box.y + 8,
    w: Math.max(1, box.w - labelW - GUTTER.right - 40),
    h: Math.max(1, box.h - 8 - GUTTER.categories - legendH),
  };
  const legend: Rect | null = spec.legend
    ? { x: plot.x, y: box.y + box.h - legendH, w: plot.w, h: legendH }
    : null;

  const values = spec.series
    .flatMap((s) => s.data)
    .filter((v): v is number => typeof v === "number");
  const baseline = spec.baseline ?? 0;
  const ticks = range
    ? { ...range, values: niceTicks(range.min, range.max).values }
    : niceTicks(
        Math.min(baseline, values.length ? Math.min(...values) : 0),
        Math.max(baseline, values.length ? Math.max(...values) : 1),
      );

  const min = ticks.min;
  const max = ticks.max;
  const span = max - min || 1;
  const x = (v: number) => plot.x + ((v - min) / span) * plot.w;

  const rows = Math.max(1, spec.categories.length);
  const rowH = plot.h / rows;
  const cy = (i: number) => plot.y + (i + 0.5) * rowH;

  const chrome: Primitive[] = [];

  if (gridlines) {
    for (const value of ticks.values) {
      const tx = x(value);
      chrome.push({
        kind: "line",
        x1: tx,
        y1: plot.y,
        x2: tx,
        y2: plot.y + plot.h,
        stroke: paint.grid,
        strokeW: 1,
      });
      chrome.push({
        kind: "text",
        x: tx - 50,
        y: plot.y + plot.h + 8,
        w: 100,
        h: 26,
        text: formatValue(value, spec.unit),
        sizePx: CHART_TYPE.axisLabel.sizePx,
        color: paint.label,
        align: "center",
        valign: "top",
        family: "mono",
      });
    }
  }

  spec.categories.forEach((label, i) => {
    chrome.push({
      kind: "text",
      x: box.x,
      y: cy(i) - rowH / 2,
      w: labelW - 20,
      h: rowH,
      text: label,
      sizePx: CHART_TYPE.axisLabel.sizePx,
      color: paint.label,
      align: "right",
      valign: "middle",
      family: "body",
    });
  });

  if (legend) chrome.push(...legendPrimitives(spec, legend));

  return { plot, legend, x, cy, rowH, min, max, chrome };
}

export function legendPrimitives(spec: ChartSpec, legend: Rect): Primitive[] {
  const out: Primitive[] = [];
  const swatch = 14;
  const step = legend.w / Math.max(1, spec.series.length);
  spec.series.forEach((series, i) => {
    const x = legend.x + i * step;
    const cy = legend.y + legend.h / 2;
    out.push({
      kind: "rect",
      x,
      y: cy - swatch / 2,
      w: swatch,
      h: swatch,
      fill: paint.series(i),
    });
    out.push({
      kind: "text",
      x: x + swatch + 10,
      y: cy - 13,
      w: step - swatch - 10,
      h: 26,
      text: series.name,
      sizePx: CHART_TYPE.legend.sizePx,
      color: paint.label,
      align: "left",
      valign: "middle",
      family: "body",
    });
  });
  return out;
}

/** The axis line a chart draws at its zero (or range floor). */
export function baselinePrimitive(frame: Frame): Primitive {
  const zeroY = frame.scales.y(
    Math.max(frame.scales.min, Math.min(frame.scales.max, 0)),
  );
  return {
    kind: "line",
    x1: frame.plot.x,
    y1: zeroY,
    x2: frame.plot.x + frame.plot.w,
    y2: zeroY,
    stroke: paint.axis,
    strokeW: 1,
  };
}

/**
 * Split a category band into N side-by-side slots, one per series.
 * Shared so grouped bars, dumbbells and slope charts all align.
 */
export function bandSlots(
  bandW: number,
  seriesCount: number,
): { pad: number; slotW: number; gap: number } {
  const pad = Math.min(bandW * 0.18, 26);
  const inner = Math.max(8, bandW - pad * 2);
  const gap = seriesCount > 1 ? Math.min(8, inner * 0.06) : 0;
  const slotW = Math.max(4, (inner - gap * (seriesCount - 1)) / seriesCount);
  return { pad, slotW, gap };
}

export function valueLabel(
  text: string,
  x: number,
  y: number,
  w: number,
): Primitive {
  return {
    kind: "text",
    x: x - w / 2,
    y: y - 26,
    w,
    h: 24,
    text,
    sizePx: CHART_TYPE.valueLabel.sizePx,
    weight: CHART_TYPE.valueLabel.weight,
    color: paint.text,
    align: "center",
    valign: "bottom",
    family: "mono",
  };
}
