/* ─────────────────────────────────────────────────────────────────────
 * deck/blocks.ts — sub-element geometry, shared by both renderers.
 *
 * A metric is three stacked pieces; a list is N rows each holding two.
 * The browser could get those positions from flexbox and PowerPoint
 * could get them from stacked text boxes — and they would drift, page by
 * page, in ways nobody notices until a client opens the .pptx.
 *
 * So neither renderer is allowed to lay out sub-pieces on its own. Both
 * call the functions here and place the rects they are handed. Flexbox
 * appears nowhere in the slide renderer for this reason.
 * ───────────────────────────────────────────────────────────────────── */

import type { Rect } from "./layout";
import { LIST, METRIC } from "./typography";
import type { ListEl, MetricEl } from "./types";

function lineHeight(sizePx: number, multiplier: number): number {
  return Math.round(sizePx * multiplier);
}

/** Vertical gaps inside a metric block, in px. */
const METRIC_GAP = { afterLabel: 14, beforeDetail: 16 } as const;

/** A detail line is budgeted at two lines; longer text is a capacity error. */
const METRIC_DETAIL_LINES = 2;

export interface MetricBlocks {
  label?: Rect;
  value: Rect;
  /** The value's font size after fitting — see `fitValueSize`. */
  valueSize: number;
  unitSize: number;
  detail?: Rect;
}

/**
 * Rough advance width of a string at a given size.
 *
 * Latin digits in a tabular face run about 0.55em; CJK is square, so
 * one glyph is one em. Approximate, but it only has to be good enough
 * to decide whether 128px overflows a two-column box — and it has to be
 * the SAME approximation in both renderers, which is why it lives here
 * rather than being measured in the browser.
 */
export function advance(text: string, sizePx: number): number {
  let em = 0;
  for (const ch of text) {
    em += /[\u3000-\u9fff\uff00-\uffef]/.test(ch) ? 1 : 0.55;
  }
  return em * sizePx;
}

/**
 * Shrink a metric until it fits its box. A 128px hero number in a
 * quarter-width cell silently overlaps its neighbour, and neither
 * renderer would notice — this is the one place that can prevent it.
 */
function fitValueSize(el: MetricEl, box: Rect): number {
  const text = el.value + (el.unit ?? "");
  let size = METRIC.value.sizePx;
  while (size > 40 && advance(text, size) > box.w) {
    size -= 4;
  }
  return size;
}

export function metricBlocks(el: MetricEl, box: Rect): MetricBlocks {
  const hasLabel = Boolean(el.label);
  const hasDetail = Boolean(el.detail);

  const valueSize = fitValueSize(el, box);
  const unitSize = Math.round(
    METRIC.unit.sizePx * (valueSize / METRIC.value.sizePx),
  );
  const labelH = lineHeight(METRIC.label.sizePx, METRIC.label.lineHeight);
  const valueH = lineHeight(valueSize, METRIC.value.lineHeight);
  const detailH =
    lineHeight(METRIC.detail.sizePx, METRIC.detail.lineHeight) *
    METRIC_DETAIL_LINES;

  const total =
    (hasLabel ? labelH + METRIC_GAP.afterLabel : 0) +
    valueH +
    (hasDetail ? METRIC_GAP.beforeDetail + detailH : 0);

  let y = box.y + Math.max(0, (box.h - total) / 2);
  const blocks: MetricBlocks = {
    value: { x: box.x, y, w: box.w, h: valueH },
    valueSize,
    unitSize,
  };

  if (hasLabel) {
    blocks.label = { x: box.x, y, w: box.w, h: labelH };
    y += labelH + METRIC_GAP.afterLabel;
    blocks.value = { x: box.x, y, w: box.w, h: valueH };
  }
  y += valueH;

  if (hasDetail) {
    y += METRIC_GAP.beforeDetail;
    // Detail sits under a loud number, so it gets a narrower measure —
    // full-width detail under a 128px numeral reads as a second column.
    blocks.detail = { x: box.x, y, w: box.w * 0.88, h: detailH };
  }

  return blocks;
}

export interface ListRow {
  index: number;
  /** The whole row, including card padding if the style has any. */
  box: Rect;
  /** Where the marker glyph (bullet / number) goes, if any. */
  marker?: Rect;
  label: Rect;
  detail?: Rect;
}

export function listRows(el: ListEl, box: Rect): ListRow[] {
  const columns = Math.max(1, el.columns ?? 1);
  const rowCount = Math.ceil(el.items.length / columns);
  if (rowCount === 0) return [];

  const colW = (box.w - LIST.gap * (columns - 1)) / columns;
  const rowH = (box.h - LIST.gap * (rowCount - 1)) / rowCount;

  const pad = el.style === "card" ? LIST.cardPad : 0;
  // A `rule` list draws a hairline on top of each row, so its text has
  // to clear the line rather than sit on it.
  const ruleClearance = el.style === "rule" ? 12 : 0;
  const markerW =
    el.style === "numbered" ? LIST.markerWidth : el.style === "bullet" ? 30 : 0;

  const labelH = lineHeight(LIST.label.sizePx, LIST.label.lineHeight);
  const detailH = lineHeight(LIST.detail.sizePx, LIST.detail.lineHeight);

  return el.items.map((item, i) => {
    const col = i % columns;
    const row = Math.floor(i / columns);
    const cellX = box.x + col * (colW + LIST.gap);
    const cellY = box.y + row * (rowH + LIST.gap);
    const cell: Rect = { x: cellX, y: cellY, w: colW, h: rowH };

    const innerX = cellX + pad + markerW;
    const innerW = colW - pad * 2 - markerW;
    const stackH = labelH + (item.detail ? detailH + 6 : 0);
    // A card can be much taller than its text; centring then leaves the
    // words floating in the middle of an empty box. Cards top-align,
    // everything else centres.
    const innerY =
      el.style === "rule"
        ? cellY + ruleClearance
        : el.style === "card"
          ? cellY + pad
          : cellY + Math.max(pad, (rowH - stackH) / 2);

    const out: ListRow = {
      index: i,
      box: cell,
      label: { x: innerX, y: innerY, w: innerW, h: labelH },
    };
    if (markerW > 0) {
      out.marker = { x: cellX + pad, y: innerY, w: markerW, h: labelH };
    }
    if (item.detail) {
      out.detail = {
        x: innerX,
        y: innerY + labelH + 6,
        w: innerW,
        h: detailH,
      };
    }
    return out;
  });
}
