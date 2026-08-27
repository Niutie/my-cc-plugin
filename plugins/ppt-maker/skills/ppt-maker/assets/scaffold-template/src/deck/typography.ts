/* ─────────────────────────────────────────────────────────────────────
 * deck/typography.ts — the shared type scale.
 *
 * A text role resolves to ONE spec here, and both renderers read it.
 * The HTML renderer uses the px values directly; the PPTX renderer
 * converts with `pt = px / 2` — exact, because the stage runs at
 * 144 px/inch and a point is 1/72 inch.
 *
 * No `vw`, no `clamp()`, no `em` anywhere in a deck. The stage is a
 * fixed 1920×1080 canvas that gets transform-scaled as a whole, so a
 * viewport-relative unit would (a) double-shrink on screen and (b) have
 * no meaning at all in PowerPoint.
 * ───────────────────────────────────────────────────────────────────── */

import type { TextRole } from "./types";

export interface TypeSpec {
  /** Stage px. Divide by 2 for PowerPoint points. */
  sizePx: number;
  weight: number;
  /** Multiplier, not px. */
  lineHeight: number;
  /** em, negative = tighter. */
  tracking: number;
  /** Which theme font family token to use. */
  family: "display" | "body" | "mono";
  /** Which theme colour token to use by default. */
  color: "text" | "text-2" | "text-mute";
  uppercase?: boolean;
}

export const TYPE: Record<TextRole, TypeSpec> = {
  title: {
    sizePx: 76,
    weight: 600,
    lineHeight: 1.1,
    tracking: -0.02,
    family: "display",
    color: "text",
  },
  subtitle: {
    sizePx: 34,
    weight: 400,
    lineHeight: 1.35,
    tracking: -0.01,
    family: "body",
    color: "text-2",
  },
  body: {
    sizePx: 24,
    weight: 400,
    lineHeight: 1.55,
    tracking: 0,
    family: "body",
    color: "text-2",
  },
  kicker: {
    sizePx: 16,
    weight: 600,
    lineHeight: 1.2,
    tracking: 0.14,
    family: "mono",
    color: "text-mute",
    uppercase: true,
  },
  caption: {
    sizePx: 16,
    weight: 400,
    lineHeight: 1.4,
    tracking: 0,
    family: "body",
    color: "text-mute",
  },
  quote: {
    sizePx: 44,
    weight: 400,
    lineHeight: 1.3,
    tracking: -0.01,
    family: "display",
    color: "text",
  },
};

/** Metric numerals get their own scale — they are the loudest thing on a page. */
export const METRIC = {
  value: { sizePx: 128, lineHeight: 0.95, tracking: -0.04, weight: 400 },
  unit: { sizePx: 36, lineHeight: 1, tracking: -0.01 },
  label: { sizePx: 18, lineHeight: 1.2, tracking: 0.1 },
  detail: { sizePx: 18, lineHeight: 1.4, tracking: 0 },
} as const;

export const LIST = {
  label: { sizePx: 26, weight: 600, lineHeight: 1.3 },
  detail: { sizePx: 19, weight: 400, lineHeight: 1.45 },
  /** Vertical gap between list rows, in px. */
  gap: 22,
  /** Card padding, in px. */
  cardPad: 24,
  markerWidth: 44,
} as const;

export const CHART_TYPE = {
  axisLabel: { sizePx: 16, weight: 400 },
  valueLabel: { sizePx: 17, weight: 600 },
  legend: { sizePx: 16, weight: 400 },
  caption: { sizePx: 15, weight: 400 },
} as const;

/** Stage px → PowerPoint points. Exact at 144 px/inch. */
export function pxToPt(px: number): number {
  return px / 2;
}
