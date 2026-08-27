/* ─────────────────────────────────────────────────────────────────────
 * charts/kinds/horizontal.ts — bar, dumbbell, gantt.
 *
 * Long category names are the reason these exist: rotating labels under
 * a column chart is the single most common way a deck becomes
 * unreadable. Anything with wordy categories belongs here.
 * ───────────────────────────────────────────────────────────────────── */

import type { Rect } from "../../deck/layout";
import { CHART_TYPE } from "../../deck/typography";
import type { ChartSpec } from "../../deck/types";
import { rowFrame } from "../frame";
import { paint, type Primitive } from "../primitives";
import { formatValue } from "../scale";
import type { ChartBuild } from "../registry";

/* ── bar ─────────────────────────────────────────────────────────── */

export function bar(spec: ChartSpec, box: Rect): ChartBuild {
  const frame = rowFrame(spec, box);
  const out: Primitive[] = [...frame.chrome];
  const count = Math.max(1, spec.series.length);
  const pad = Math.min(frame.rowH * 0.2, 18);
  const slotH = Math.max(4, (frame.rowH - pad * 2) / count);
  const zeroX = frame.x(Math.max(frame.min, Math.min(frame.max, 0)));

  spec.series.forEach((series, si) => {
    series.data.forEach((value, ci) => {
      if (typeof value !== "number") return;
      const y = frame.cy(ci) - frame.rowH / 2 + pad + si * slotH;
      const vx = frame.x(value);
      out.push({
        kind: "rect",
        x: Math.min(vx, zeroX),
        y,
        w: Math.max(1, Math.abs(vx - zeroX)),
        h: slotH,
        fill: paint.series(si),
      });
      if (spec.showValues) {
        out.push({
          kind: "text",
          x: vx + (value >= 0 ? 12 : -132),
          y: y + slotH / 2 - 14,
          w: 120,
          h: 28,
          text: formatValue(value, spec.unit),
          sizePx: CHART_TYPE.valueLabel.sizePx,
          weight: CHART_TYPE.valueLabel.weight,
          color: paint.text,
          align: value >= 0 ? "left" : "right",
          valign: "middle",
          family: "mono",
        });
      }
    });
  });

  out.push({
    kind: "line",
    x1: zeroX,
    y1: frame.plot.y,
    x2: zeroX,
    y2: frame.plot.y + frame.plot.h,
    stroke: paint.axis,
    strokeW: 1,
  });
  return { primitives: out, axis: { min: frame.min, max: frame.max } };
}

/* ── dumbbell ────────────────────────────────────────────────────── */

/**
 * Two series, one row per category: a connector between "before" and
 * "after". Reads the GAP, which a grouped bar chart makes you compute
 * in your head.
 */
export function dumbbell(spec: ChartSpec, box: Rect): ChartBuild {
  const frame = rowFrame(spec, box);
  const out: Primitive[] = [...frame.chrome];
  const r = 9;

  spec.categories.forEach((_, ci) => {
    const points = spec.series
      .map((s, si) => ({ si, value: s.data[ci] }))
      .filter((p): p is { si: number; value: number } =>
        typeof p.value === "number",
      );
    if (points.length < 2) return;

    const y = frame.cy(ci);
    const xs = points.map((p) => frame.x(p.value));
    out.push({
      kind: "line",
      x1: Math.min(...xs),
      y1: y,
      x2: Math.max(...xs),
      y2: y,
      stroke: paint.rule,
      strokeW: 3,
    });
    for (const p of points) {
      const x = frame.x(p.value);
      out.push({
        kind: "ellipse",
        x: x - r,
        y: y - r,
        w: r * 2,
        h: r * 2,
        fill: paint.series(p.si),
      });
    }
    if (spec.showValues) {
      const last = points[points.length - 1];
      out.push({
        kind: "text",
        x: frame.x(last.value) + 16,
        y: y - 14,
        w: 120,
        h: 28,
        text: formatValue(last.value, spec.unit),
        sizePx: CHART_TYPE.valueLabel.sizePx,
        weight: CHART_TYPE.valueLabel.weight,
        color: paint.text,
        align: "left",
        valign: "middle",
        family: "mono",
      });
    }
  });

  return { primitives: out, axis: { min: frame.min, max: frame.max } };
}

/* ── gantt ───────────────────────────────────────────────────────── */

/**
 * Two series read as [start, end] on a shared numeric timeline —
 * series[0].data[i] is the start of row i, series[1].data[i] its end.
 * Units are whatever the deck's timeline is (weeks, sprints, months);
 * the axis just numbers them.
 */
export function gantt(spec: ChartSpec, box: Rect): ChartBuild {
  const starts = spec.series[0];
  const ends = spec.series[1];
  if (!starts || !ends) return { primitives: [] };

  // The value range must cover both endpoints, and a gantt never starts
  // at zero just because zero exists — it starts where work starts.
  const all = [...starts.data, ...ends.data].filter(
    (v): v is number => typeof v === "number",
  );
  const frame = rowFrame({ ...spec, legend: false }, box, {
    range: { min: Math.min(...all), max: Math.max(...all) },
  });
  const out: Primitive[] = [...frame.chrome];
  const barH = Math.max(10, Math.min(frame.rowH * 0.5, 34));

  spec.categories.forEach((_, ci) => {
    const a = starts.data[ci];
    const b = ends.data[ci];
    if (typeof a !== "number" || typeof b !== "number") return;
    const x1 = frame.x(Math.min(a, b));
    const x2 = frame.x(Math.max(a, b));
    out.push({
      kind: "rect",
      x: x1,
      y: frame.cy(ci) - barH / 2,
      w: Math.max(2, x2 - x1),
      h: barH,
      // A gantt's rows are phases of one thing, not different things —
      // a sequential ramp reads as progression, rotating categorical
      // colours reads as "these are unrelated".
      fill: paint.seq(
        1 + Math.round((ci / Math.max(1, spec.categories.length - 1)) * 3),
      ),
      radius: barH / 2,
    });
    if (spec.showValues) {
      out.push({
        kind: "text",
        x: x2 + 14,
        y: frame.cy(ci) - 14,
        w: 140,
        h: 28,
        text: `${formatValue(a, spec.unit)} → ${formatValue(b, spec.unit)}`,
        sizePx: CHART_TYPE.axisLabel.sizePx,
        color: paint.textMute,
        align: "left",
        valign: "middle",
        family: "mono",
      });
    }
  });

  return { primitives: out, axis: { min: frame.min, max: frame.max } };
}
