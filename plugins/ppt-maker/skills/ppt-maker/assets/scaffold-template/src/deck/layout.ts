/* ─────────────────────────────────────────────────────────────────────
 * deck/layout.ts — the one geometry engine.
 *
 * Both renderers import THIS. Neither is allowed to compute a position
 * of its own; if the HTML and the PPTX ever disagree about where a box
 * sits, it is a bug in this file, not a discrepancy to reconcile
 * downstream.
 *
 *   stage      1920 × 1080 px   ==   13.333 × 7.5 in   (PowerPoint 16:9)
 *   scale      1920 / 13.333    ==   144 px per inch   (exact)
 *   EMU        1 in             ==   914400 EMU        (OOXML unit)
 *
 * The 144 px/inch factor is what makes the whole dual-render idea work:
 * every px coordinate converts to inches with no rounding policy to
 * argue about.
 * ───────────────────────────────────────────────────────────────────── */

import type { Anchor, GridRect } from "./types";

export const FRAME = { w: 1920, h: 1080 } as const;
export const GRID = { cols: 12, rows: 8 } as const;

/** Gap between grid cells, in stage px. */
export const GUTTER = 24;

export const PX_PER_INCH = 144;
export const EMU_PER_INCH = 914400;

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/**
 * Stage padding, in px. Comes from the theme's `--stage-pad-x/y` so a
 * roomy theme (dune, 140×100) and a dense one (training-center, 96×72)
 * breathe differently — and export follows the same numbers.
 */
export interface Padding {
  x: number;
  y: number;
}

export const DEFAULT_PADDING: Padding = { x: 96, y: 72 };

/** The area the 12×8 grid spans, once padding is removed. */
export function contentBox(pad: Padding): Rect {
  return {
    x: pad.x,
    y: pad.y,
    w: FRAME.w - pad.x * 2,
    h: FRAME.h - pad.y * 2,
  };
}

export interface Cell {
  w: number;
  h: number;
}

export function cellSize(pad: Padding): Cell {
  const box = contentBox(pad);
  return {
    w: (box.w - GUTTER * (GRID.cols - 1)) / GRID.cols,
    h: (box.h - GUTTER * (GRID.rows - 1)) / GRID.rows,
  };
}

/**
 * Grid rect → stage px. `bleed` places against the raw frame instead of
 * the padded content box, for full-width bands and cover art.
 */
export function place(grid: GridRect, pad: Padding, bleed = false): Rect {
  const origin = bleed ? { x: 0, y: 0 } : { x: pad.x, y: pad.y };
  const cell = bleed ? bleedCellSize() : cellSize(pad);
  return {
    x: origin.x + (grid.column - 1) * (cell.w + GUTTER),
    y: origin.y + (grid.row - 1) * (cell.h + GUTTER),
    w: grid.width * cell.w + (grid.width - 1) * GUTTER,
    h: grid.height * cell.h + (grid.height - 1) * GUTTER,
  };
}

function bleedCellSize(): Cell {
  return {
    w: (FRAME.w - GUTTER * (GRID.cols - 1)) / GRID.cols,
    h: (FRAME.h - GUTTER * (GRID.rows - 1)) / GRID.rows,
  };
}

/**
 * THE element placement entry point. Both renderers call this and
 * nothing else — grid placement, bleed and in-cell sizing resolved in
 * one place so they cannot drift apart.
 */
export function elementRect(
  el: {
    grid: GridRect;
    bleed?: boolean;
    size?: { w?: number; h?: number };
    anchor?: Anchor;
  },
  pad: Padding,
): Rect {
  const cell = place(el.grid, pad, el.bleed);
  if (!el.size?.w && !el.size?.h) return cell;

  const w = Math.min(el.size.w ?? cell.w, cell.w);
  const h = Math.min(el.size.h ?? cell.h, cell.h);
  const anchor = el.anchor ?? "center";
  const [vertical, horizontal] = splitAnchor(anchor);

  const x =
    horizontal === "start"
      ? cell.x
      : horizontal === "end"
        ? cell.x + cell.w - w
        : cell.x + (cell.w - w) / 2;
  const y =
    vertical === "start"
      ? cell.y
      : vertical === "end"
        ? cell.y + cell.h - h
        : cell.y + (cell.h - h) / 2;

  return { x, y, w, h };
}

type Edge = "start" | "middle" | "end";

function splitAnchor(anchor: Anchor): [Edge, Edge] {
  switch (anchor) {
    case "top-left":
      return ["start", "start"];
    case "top":
      return ["start", "middle"];
    case "top-right":
      return ["start", "end"];
    case "left":
      return ["middle", "start"];
    case "right":
      return ["middle", "end"];
    case "bottom-left":
      return ["end", "start"];
    case "bottom":
      return ["end", "middle"];
    case "bottom-right":
      return ["end", "end"];
    default:
      return ["middle", "middle"];
  }
}

/** Stage px → inches, for pptxgenjs. */
export function toIn(px: number): number {
  return px / PX_PER_INCH;
}

/** Stage px → EMU, for asserting against raw OOXML in tests. */
export function toEmu(px: number): number {
  return Math.round((px / PX_PER_INCH) * EMU_PER_INCH);
}

export function rectToIn(r: Rect): Rect {
  return { x: toIn(r.x), y: toIn(r.y), w: toIn(r.w), h: toIn(r.h) };
}

/** Slide size in inches — pptxgenjs `defineLayout`. */
export const PPTX_LAYOUT = {
  name: "PPT_MAKER_16x9",
  width: toIn(FRAME.w),
  height: toIn(FRAME.h),
} as const;

/**
 * Validate a grid rect stays on the board. Returns a reason string, or
 * null when the rect is fine. Called by the deck validator so a bad
 * composition is caught before either renderer sees it.
 */
export function gridError(grid: GridRect): string | null {
  const { column, row, width, height } = grid;
  if (!Number.isInteger(column) || !Number.isInteger(row)) {
    return "grid column/row must be integers";
  }
  if (!Number.isInteger(width) || !Number.isInteger(height)) {
    return "grid width/height must be integers";
  }
  if (width < 1 || height < 1) return "grid width/height must be >= 1";
  if (column < 1 || row < 1) return "grid column/row are 1-indexed";
  if (column + width - 1 > GRID.cols) {
    return `grid overflows the ${GRID.cols}-column board`;
  }
  if (row + height - 1 > GRID.rows) {
    return `grid overflows the ${GRID.rows}-row board`;
  }
  return null;
}
