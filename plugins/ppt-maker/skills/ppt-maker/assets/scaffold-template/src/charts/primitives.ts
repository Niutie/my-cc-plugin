/* ─────────────────────────────────────────────────────────────────────
 * charts/primitives.ts — the vector layer shared by both renderers.
 *
 * Every chart compiles to a flat list of primitives in absolute stage
 * px. The browser paints them as SVG; the exporter paints them as
 * PowerPoint shapes (custGeom for anything that isn't a box). Because
 * both consume the SAME list, a chart is drawn once and rendered twice.
 *
 * Colours are never literals here — a chart names a ROLE and each
 * renderer resolves it (CSS custom property in the browser, hex from
 * the parsed theme in the exporter). That is what keeps a chart on
 * theme across all 24 palettes without a per-theme branch.
 * ───────────────────────────────────────────────────────────────────── */

import type { ThemeTokens } from "../deck/theme";

/* ── paint ───────────────────────────────────────────────────────── */

export type Paint =
  | { role: "series"; index: number }
  | { role: "seq"; index: number }
  | {
      role:
        | "accent"
        | "pos"
        | "neg"
        | "grid"
        | "axis"
        | "label"
        | "text"
        | "textMute"
        | "textFaint"
        | "surface"
        | "surface2"
        | "rule";
    };

export const paint = {
  series: (index: number): Paint => ({ role: "series", index }),
  seq: (index: number): Paint => ({ role: "seq", index }),
  accent: { role: "accent" } as Paint,
  pos: { role: "pos" } as Paint,
  neg: { role: "neg" } as Paint,
  grid: { role: "grid" } as Paint,
  axis: { role: "axis" } as Paint,
  label: { role: "label" } as Paint,
  text: { role: "text" } as Paint,
  textMute: { role: "textMute" } as Paint,
  textFaint: { role: "textFaint" } as Paint,
  surface: { role: "surface" } as Paint,
  surface2: { role: "surface2" } as Paint,
  rule: { role: "rule" } as Paint,
};

const CSS_VAR: Record<string, string> = {
  accent: "var(--accent)",
  pos: "var(--chart-pos)",
  neg: "var(--chart-neg)",
  grid: "var(--chart-grid, var(--rule))",
  axis: "var(--chart-axis, var(--text-mute))",
  label: "var(--chart-label, var(--text-mute))",
  text: "var(--text)",
  textMute: "var(--text-mute)",
  textFaint: "var(--text-faint)",
  surface: "var(--surface)",
  surface2: "var(--surface-2)",
  rule: "var(--rule)",
};

/**
 * Browser side.
 *
 * Series indices CLAMP rather than wrap. A theme has six distinguishable
 * hues; wrapping would paint series 7 the same as series 1 and quietly
 * tell the reader they are the same thing. Clamping makes the last two
 * look alike instead — still wrong, but wrong in a way that reads as
 * "too many series", which is what actually happened. validate-deck
 * rejects it before either can ship.
 */
export function paintCss(p: Paint): string {
  if (p.role === "series") {
    return `var(--chart-series-${Math.min(p.index, 7) + 1})`;
  }
  if (p.role === "seq") return `var(--chart-seq-${Math.min(p.index, 4) + 1})`;
  return CSS_VAR[p.role];
}

/** Exporter side. `#RRGGBB`. */
export function paintHex(p: Paint, theme: ThemeTokens): string {
  switch (p.role) {
    case "series":
      return theme.chart.series[
        Math.min(p.index, theme.chart.series.length - 1)
      ];
    case "seq":
      return theme.chart.seq[Math.min(p.index, theme.chart.seq.length - 1)];
    case "accent":
      return theme.accent;
    case "pos":
      return theme.chart.pos;
    case "neg":
      return theme.chart.neg;
    case "grid":
      return theme.chart.grid;
    case "axis":
      return theme.chart.axis;
    case "label":
      return theme.chart.label;
    case "text":
      return theme.text;
    case "textMute":
      return theme.textMute;
    case "textFaint":
      return theme.textFaint;
    case "surface":
      return theme.surface;
    case "surface2":
      return theme.surface2;
    case "rule":
      return theme.rule;
  }
}

/* ── primitives ──────────────────────────────────────────────────── */

export interface PathPoint {
  x: number;
  y: number;
  /** Start a new sub-path here instead of drawing to it. */
  move?: boolean;
  /** Cubic bézier into this point. Used by sankey ribbons and curves. */
  curve?: { x1: number; y1: number; x2: number; y2: number };
}

interface Fillable {
  fill?: Paint;
  stroke?: Paint;
  strokeW?: number;
  /** 0–1 opacity. PowerPoint gets it as a fill transparency percentage. */
  opacity?: number;
}

export interface RectPrim extends Fillable {
  kind: "rect";
  x: number;
  y: number;
  w: number;
  h: number;
  /** Corner radius in px. */
  radius?: number;
}

export interface EllipsePrim extends Fillable {
  kind: "ellipse";
  x: number;
  y: number;
  w: number;
  h: number;
}

/**
 * Axis-aligned only. Anything diagonal must be a `path`, because the
 * exporter maps this straight onto PowerPoint's `line` shape, which has
 * no honest representation for a rotated segment without flip flags.
 */
export interface LinePrim {
  kind: "line";
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  stroke: Paint;
  strokeW?: number;
  dash?: boolean;
}

export interface PathPrim extends Fillable {
  kind: "path";
  pts: PathPoint[];
  close?: boolean;
}

export interface TextPrim {
  kind: "text";
  x: number;
  y: number;
  w: number;
  h: number;
  text: string;
  sizePx: number;
  weight?: number;
  color: Paint;
  align?: "left" | "center" | "right";
  valign?: "top" | "middle" | "bottom";
  family?: "display" | "body" | "mono";
  /** Rotation in degrees, for cramped category labels. */
  rotate?: number;
}

export type Primitive =
  | RectPrim
  | EllipsePrim
  | LinePrim
  | PathPrim
  | TextPrim;

/* ── helpers used by chart builders ──────────────────────────────── */

export function isAxisAligned(p: LinePrim): boolean {
  return p.x1 === p.x2 || p.y1 === p.y2;
}

/** Bounding box of a path, needed because PowerPoint's custGeom points
 *  are relative to the shape's own frame. */
export function pathBounds(pts: PathPoint[]): {
  x: number;
  y: number;
  w: number;
  h: number;
} {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const pt of pts) {
    const xs = pt.curve ? [pt.x, pt.curve.x1, pt.curve.x2] : [pt.x];
    const ys = pt.curve ? [pt.y, pt.curve.y1, pt.curve.y2] : [pt.y];
    for (const x of xs) {
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
    }
    for (const y of ys) {
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (!Number.isFinite(minX)) return { x: 0, y: 0, w: 0, h: 0 };
  return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
}

/** SVG `d` for a path primitive. */
export function pathToSvg(prim: PathPrim): string {
  const parts: string[] = [];
  prim.pts.forEach((pt, i) => {
    if (pt.move || i === 0) {
      parts.push(`M ${pt.x} ${pt.y}`);
    } else if (pt.curve) {
      parts.push(
        `C ${pt.curve.x1} ${pt.curve.y1} ${pt.curve.x2} ${pt.curve.y2} ${pt.x} ${pt.y}`,
      );
    } else {
      parts.push(`L ${pt.x} ${pt.y}`);
    }
  });
  if (prim.close) parts.push("Z");
  return parts.join(" ");
}

/** A rounded rectangle as an explicit polygon-ish path, for the few
 *  places a chart needs a shape PowerPoint's `roundRect` can't express
 *  (e.g. a bar rounded on one end only). */
export function polygon(
  points: Array<[number, number]>,
  opts: Fillable & { close?: boolean } = {},
): PathPrim {
  return {
    kind: "path",
    pts: points.map(([x, y], i) => ({ x, y, move: i === 0 })),
    close: opts.close ?? true,
    fill: opts.fill,
    stroke: opts.stroke,
    strokeW: opts.strokeW,
    opacity: opts.opacity,
  };
}
