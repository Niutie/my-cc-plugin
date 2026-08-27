/* ─────────────────────────────────────────────────────────────────────
 * charts/kinds/vertical.ts — column, waterfall, line, area, slope.
 *
 * All five hang off `cartesianFrame`, so they share one tick grid and
 * one baseline. A deck that puts a column page next to a line page gets
 * two charts that actually line up.
 * ───────────────────────────────────────────────────────────────────── */

import type { Rect } from "../../deck/layout";
import { CHART_TYPE } from "../../deck/typography";
import type { ChartSpec } from "../../deck/types";
import {
  bandSlots,
  baselinePrimitive,
  cartesianFrame,
  valueLabel,
} from "../frame";
import { paint, type PathPoint, type Primitive } from "../primitives";
import { formatValue } from "../scale";
import type { ChartBuild } from "../registry";

/* ── column ──────────────────────────────────────────────────────── */

export function column(spec: ChartSpec, box: Rect): ChartBuild {
  const frame = cartesianFrame(spec, box);
  const out: Primitive[] = [...frame.chrome];
  const { pad, slotW, gap } = bandSlots(frame.scales.bandW, spec.series.length);
  const zeroY = frame.scales.y(
    Math.max(frame.scales.min, Math.min(frame.scales.max, 0)),
  );

  spec.series.forEach((series, si) => {
    series.data.forEach((value, ci) => {
      if (typeof value !== "number") return;
      const bandX = frame.scales.cx(ci) - frame.scales.bandW / 2 + pad;
      const x = bandX + si * (slotW + gap);
      const top = frame.scales.y(value);
      out.push({
        kind: "rect",
        x,
        y: Math.min(top, zeroY),
        w: slotW,
        h: Math.max(1, Math.abs(zeroY - top)),
        fill: paint.series(si),
      });
      if (spec.showValues) {
        out.push(
          valueLabel(formatValue(value, spec.unit), x + slotW / 2, Math.min(top, zeroY), slotW + 40),
        );
      }
    });
  });

  out.push(baselinePrimitive(frame));
  return { primitives: out, axis: { min: frame.scales.min, max: frame.scales.max } };
}

/* ── waterfall ───────────────────────────────────────────────────── */

/**
 * Single series only: each value is a delta, and the bars stack from
 * where the previous one left off. The last category may be marked as a
 * total by giving it the label prefix "=" — a running total bar starts
 * from zero instead of from the previous top.
 */
export function waterfall(spec: ChartSpec, box: Rect): ChartBuild {
  const series = spec.series[0];
  if (!series) return { primitives: [] };

  // The axis must span the cumulative path, not the individual deltas —
  // otherwise every bar overflows the plot.
  let running = 0;
  const steps = series.data.map((raw, i) => {
    const value = typeof raw === "number" ? raw : 0;
    const isTotal = spec.categories[i]?.startsWith("=");
    const from = isTotal ? 0 : running;
    const to = isTotal ? value : running + value;
    running = to;
    return { from, to, value, isTotal };
  });
  const bounds = steps.flatMap((s) => [s.from, s.to]).concat(0);

  const frame = cartesianFrame(
    { ...spec, categories: spec.categories.map((c) => c.replace(/^=/, "")) },
    box,
    { range: { min: Math.min(...bounds), max: Math.max(...bounds) } },
  );
  const out: Primitive[] = [...frame.chrome];
  const { pad } = bandSlots(frame.scales.bandW, 1);
  const barW = frame.scales.bandW - pad * 2;

  steps.forEach((step, i) => {
    const x = frame.scales.cx(i) - barW / 2;
    const yTop = frame.scales.y(Math.max(step.from, step.to));
    const yBot = frame.scales.y(Math.min(step.from, step.to));
    out.push({
      kind: "rect",
      x,
      y: yTop,
      w: barW,
      h: Math.max(1, yBot - yTop),
      fill: step.isTotal
        ? paint.accent
        : step.value >= 0
          ? paint.pos
          : paint.neg,
    });
    // The connector is what makes a waterfall readable — without it the
    // bars are just floating rectangles.
    if (i < steps.length - 1 && !steps[i + 1].isTotal) {
      const y = frame.scales.y(step.to);
      out.push({
        kind: "line",
        x1: x + barW,
        y1: y,
        x2: frame.scales.cx(i + 1) - barW / 2,
        y2: y,
        // Not `rule` — a hairline at gridline strength disappears next to
        // the bars, and then the waterfall stops reading as a chain.
        stroke: paint.textFaint,
        strokeW: 1.5,
        dash: true,
      });
    }
    if (spec.showValues) {
      const label = step.isTotal
        ? formatValue(step.to, spec.unit)
        : `${step.value > 0 ? "+" : ""}${formatValue(step.value, spec.unit)}`;
      out.push(valueLabel(label, x + barW / 2, yTop, barW + 40));
    }
  });

  out.push(baselinePrimitive(frame));
  return { primitives: out, axis: { min: frame.scales.min, max: frame.scales.max } };
}

/* ── line / area ─────────────────────────────────────────────────── */

function seriesPath(
  spec: ChartSpec,
  frame: ReturnType<typeof cartesianFrame>,
  seriesIndex: number,
): PathPoint[] {
  const pts: PathPoint[] = [];
  let started = false;
  spec.series[seriesIndex].data.forEach((value, ci) => {
    if (typeof value !== "number") {
      // A null is a real gap, not a zero — break the line rather than
      // drawing a plunge to the axis that never happened.
      started = false;
      return;
    }
    pts.push({ x: frame.scales.cx(ci), y: frame.scales.y(value), move: !started });
    started = true;
  });
  return pts;
}

export function line(spec: ChartSpec, box: Rect): ChartBuild {
  const frame = cartesianFrame(spec, box);
  const out: Primitive[] = [...frame.chrome];

  spec.series.forEach((series, si) => {
    const pts = seriesPath(spec, frame, si);
    if (pts.length) {
      out.push({
        kind: "path",
        pts,
        stroke: paint.series(si),
        strokeW: 3,
      });
    }
    series.data.forEach((value, ci) => {
      if (typeof value !== "number") return;
      const cx = frame.scales.cx(ci);
      const cy = frame.scales.y(value);
      out.push({
        kind: "ellipse",
        x: cx - 5,
        y: cy - 5,
        w: 10,
        h: 10,
        fill: paint.series(si),
      });
      if (spec.showValues) {
        out.push(valueLabel(formatValue(value, spec.unit), cx, cy - 6, 90));
      }
    });
  });

  out.push(baselinePrimitive(frame));
  return { primitives: out, axis: { min: frame.scales.min, max: frame.scales.max } };
}

export function area(spec: ChartSpec, box: Rect): ChartBuild {
  const frame = cartesianFrame(spec, box);
  const out: Primitive[] = [...frame.chrome];
  const floor = frame.scales.y(
    Math.max(frame.scales.min, Math.min(frame.scales.max, 0)),
  );

  spec.series.forEach((_series, si) => {
    const pts = seriesPath(spec, frame, si);
    if (!pts.length) return;
    const filled: PathPoint[] = [
      { x: pts[0].x, y: floor, move: true },
      ...pts.map((p) => ({ x: p.x, y: p.y })),
      { x: pts[pts.length - 1].x, y: floor },
    ];
    out.push({
      kind: "path",
      pts: filled,
      close: true,
      fill: paint.series(si),
      // Stacked areas hide each other at full strength; the fade keeps
      // every band legible without inventing a second hue.
      opacity: spec.series.length > 1 ? 0.55 : 0.85,
    });
    out.push({ kind: "path", pts, stroke: paint.series(si), strokeW: 3 });
  });

  out.push(baselinePrimitive(frame));
  return { primitives: out, axis: { min: frame.scales.min, max: frame.scales.max } };
}

/* ── slope ───────────────────────────────────────────────────────── */

/**
 * Two columns, one line per series: the classic "what changed between
 * these two moments" chart. Categories are the two endpoints; each
 * series is one subject.
 */
export function slope(spec: ChartSpec, box: Rect): ChartBuild {
  // A slope chart carries every number on the line itself: the subject
  // and its start value on the left, its end value on the right. So it
  // wants none of the usual chrome — a value axis would collide with the
  // left labels, band-centred category labels don't line up with the two
  // columns, and a legend would just repeat the left labels.
  const frame = cartesianFrame(
    { ...spec, legend: false },
    box,
    { leftInset: 170, categoryLabels: false, valueAxis: false },
  );
  const out: Primitive[] = [...frame.chrome];
  const first = frame.plot.x + 40;
  const last = frame.plot.x + frame.plot.w - 40;

  // Endpoint names go above the columns, clear of the lines.
  spec.categories.slice(0, 2).forEach((name, i) => {
    out.push({
      kind: "text",
      x: (i === 0 ? first : last) - 90,
      y: frame.plot.y - 34,
      w: 180,
      h: 28,
      text: name,
      sizePx: CHART_TYPE.axisLabel.sizePx,
      weight: 600,
      color: paint.label,
      align: "center",
      valign: "middle",
      family: "body",
    });
  });

  spec.series.forEach((series, si) => {
    const a = series.data[0];
    const b = series.data[series.data.length - 1];
    if (typeof a !== "number" || typeof b !== "number") return;
    const ya = frame.scales.y(a);
    const yb = frame.scales.y(b);

    out.push({
      kind: "path",
      pts: [
        { x: first, y: ya, move: true },
        { x: last, y: yb },
      ],
      stroke: paint.series(si),
      strokeW: 3,
    });
    for (const [x, y] of [
      [first, ya],
      [last, yb],
    ] as const) {
      out.push({
        kind: "ellipse",
        x: x - 6,
        y: y - 6,
        w: 12,
        h: 12,
        fill: paint.series(si),
      });
    }
    out.push({
      kind: "text",
      x: box.x,
      y: ya - 15,
      w: 130,
      h: 30,
      text: `${series.name}  ${formatValue(a, spec.unit)}`,
      sizePx: CHART_TYPE.axisLabel.sizePx,
      color: paint.label,
      align: "right",
      valign: "middle",
      family: "body",
    });
    out.push({
      kind: "text",
      x: last + 16,
      y: yb - 15,
      w: 140,
      h: 30,
      text: formatValue(b, spec.unit),
      sizePx: CHART_TYPE.valueLabel.sizePx,
      weight: CHART_TYPE.valueLabel.weight,
      color: paint.text,
      align: "left",
      valign: "middle",
      family: "mono",
    });
  });

  return { primitives: out, axis: { min: frame.scales.min, max: frame.scales.max } };
}
