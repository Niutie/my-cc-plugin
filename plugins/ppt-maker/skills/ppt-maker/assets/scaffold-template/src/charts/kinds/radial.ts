/* ─────────────────────────────────────────────────────────────────────
 * charts/kinds/radial.ts — pie, donut, radar.
 *
 * Arcs are built as explicit cubic-bézier paths rather than SVG arc
 * commands, because PowerPoint's custGeom speaks bézier and a shared
 * primitive list is the whole point. Quarter-segment béziers with the
 * 0.5522847 magic constant are accurate to about a thousandth of the
 * radius — invisible at any slide size.
 * ───────────────────────────────────────────────────────────────────── */

import type { Rect } from "../../deck/layout";
import { CHART_TYPE } from "../../deck/typography";
import type { ChartSpec } from "../../deck/types";
import { legendPrimitives } from "../frame";
import { paint, type PathPoint, type Primitive } from "../primitives";
import { formatValue } from "../scale";
import type { ChartBuild } from "../registry";

const KAPPA = 0.5522847498307936;

interface Pt {
  x: number;
  y: number;
}

function polar(cx: number, cy: number, r: number, angle: number): Pt {
  return { x: cx + r * Math.cos(angle), y: cy + r * Math.sin(angle) };
}

/** Arc from `from` to `to` radians, appended as cubic segments. */
function arcPoints(
  cx: number,
  cy: number,
  r: number,
  from: number,
  to: number,
  startWithMove: boolean,
): PathPoint[] {
  const out: PathPoint[] = [];
  const sweep = to - from;
  const segments = Math.max(1, Math.ceil(Math.abs(sweep) / (Math.PI / 2)));
  const step = sweep / segments;
  const k = (KAPPA * Math.abs(step)) / (Math.PI / 2) * Math.sign(step);

  let angle = from;
  let p = polar(cx, cy, r, angle);
  if (startWithMove) out.push({ x: p.x, y: p.y, move: true });

  for (let i = 0; i < segments; i += 1) {
    const next = angle + step;
    const q = polar(cx, cy, r, next);
    out.push({
      x: q.x,
      y: q.y,
      curve: {
        x1: p.x - k * r * Math.sin(angle),
        y1: p.y + k * r * Math.cos(angle),
        x2: q.x + k * r * Math.sin(next),
        y2: q.y - k * r * Math.cos(next),
      },
    });
    angle = next;
    p = q;
  }
  return out;
}

/* ── pie / donut ─────────────────────────────────────────────────── */

function pieLike(
  spec: ChartSpec,
  box: Rect,
  innerRatio: number,
): ChartBuild {
  const series = spec.series[0];
  if (!series) return { primitives: [] };

  const legendH = spec.legend ? 38 : 0;
  const plotH = box.h - legendH;
  const r = Math.min(box.w, plotH) / 2 - 18;
  const cx = box.x + box.w / 2;
  const cy = box.y + plotH / 2;
  const inner = r * innerRatio;

  const values = series.data.map((v) => (typeof v === "number" ? Math.max(0, v) : 0));
  const total = values.reduce((a, b) => a + b, 0);
  if (total <= 0) return { primitives: [] };

  const out: Primitive[] = [];
  // Start at 12 o'clock and go clockwise — the reading order everyone
  // expects from a share-of-total chart.
  let angle = -Math.PI / 2;

  values.forEach((value, i) => {
    const sweep = (value / total) * Math.PI * 2;
    if (sweep <= 0) return;
    const end = angle + sweep;

    const pts: PathPoint[] = [];
    if (inner > 0) {
      pts.push(...arcPoints(cx, cy, r, angle, end, true));
      const innerEnd = polar(cx, cy, inner, end);
      pts.push({ x: innerEnd.x, y: innerEnd.y });
      pts.push(...arcPoints(cx, cy, inner, end, angle, false));
    } else {
      // Straight edge from the centre out to where the arc starts. Without
      // it the first cubic segment runs from the centre and the wedge
      // renders as a petal.
      const armStart = polar(cx, cy, r, angle);
      pts.push({ x: cx, y: cy, move: true });
      pts.push({ x: armStart.x, y: armStart.y });
      pts.push(...arcPoints(cx, cy, r, angle, end, false));
    }
    out.push({ kind: "path", pts, close: true, fill: paint.series(i) });

    if (spec.showValues) {
      const mid = angle + sweep / 2;
      const lr = inner > 0 ? (r + inner) / 2 : r * 0.62;
      const p = polar(cx, cy, lr, mid);
      out.push({
        kind: "text",
        x: p.x - 60,
        y: p.y - 14,
        w: 120,
        h: 28,
        text: `${Math.round((value / total) * 100)}%`,
        sizePx: CHART_TYPE.valueLabel.sizePx,
        weight: CHART_TYPE.valueLabel.weight,
        // Slice fills are saturated, so labels sit on the surface colour
        // rather than the text colour, which would vanish on dark slices.
        color: paint.surface,
        align: "center",
        valign: "middle",
        family: "mono",
      });
    }
    angle = end;
  });

  if (inner > 0 && spec.categories.length) {
    out.push({
      kind: "text",
      x: cx - inner,
      y: cy - 30,
      w: inner * 2,
      h: 60,
      text: formatValue(total, spec.unit),
      sizePx: 40,
      weight: 600,
      color: paint.text,
      align: "center",
      valign: "middle",
      family: "display",
    });
  }

  if (spec.legend) {
    // A pie's legend keys the CATEGORIES, not the series — there is only
    // ever one series, and its slices are what need naming.
    out.push(
      ...legendPrimitives(
        {
          ...spec,
          series: spec.categories.map((name) => ({ name, data: [] })),
        },
        { x: box.x, y: box.y + box.h - legendH, w: box.w, h: legendH },
      ),
    );
  }

  return { primitives: out };
}

export function pie(spec: ChartSpec, box: Rect): ChartBuild {
  return pieLike(spec, box, 0);
}

export function donut(spec: ChartSpec, box: Rect): ChartBuild {
  return pieLike(spec, box, 0.58);
}

/* ── radar ───────────────────────────────────────────────────────── */

export function radar(spec: ChartSpec, box: Rect): ChartBuild {
  const axes = spec.categories.length;
  if (axes < 3) return { primitives: [] };

  const legendH = spec.legend ? 38 : 0;
  const plotH = box.h - legendH;
  const r = Math.min(box.w, plotH) / 2 - 60;
  const cx = box.x + box.w / 2;
  const cy = box.y + plotH / 2;

  const values = spec.series
    .flatMap((s) => s.data)
    .filter((v): v is number => typeof v === "number");
  const max = Math.max(1, ...values);
  const angleAt = (i: number) => -Math.PI / 2 + (i / axes) * Math.PI * 2;
  const at = (i: number, v: number) => polar(cx, cy, (v / max) * r, angleAt(i));

  const out: Primitive[] = [];

  // Web: concentric rings + spokes. Rings are polygons, not circles —
  // a circular web reads as a target, a polygonal one reads as axes.
  for (const ring of [0.25, 0.5, 0.75, 1]) {
    const pts: PathPoint[] = [];
    for (let i = 0; i < axes; i += 1) {
      const p = polar(cx, cy, r * ring, angleAt(i));
      pts.push({ x: p.x, y: p.y, move: i === 0 });
    }
    out.push({ kind: "path", pts, close: true, stroke: paint.grid, strokeW: 1 });
  }
  for (let i = 0; i < axes; i += 1) {
    const p = polar(cx, cy, r, angleAt(i));
    out.push({
      kind: "path",
      pts: [
        { x: cx, y: cy, move: true },
        { x: p.x, y: p.y },
      ],
      stroke: paint.grid,
      strokeW: 1,
    });
    const label = polar(cx, cy, r + 30, angleAt(i));
    out.push({
      kind: "text",
      x: label.x - 70,
      y: label.y - 14,
      w: 140,
      h: 28,
      text: spec.categories[i],
      sizePx: CHART_TYPE.axisLabel.sizePx,
      color: paint.label,
      align: "center",
      valign: "middle",
      family: "body",
    });
  }

  spec.series.forEach((series, si) => {
    const pts: PathPoint[] = [];
    for (let i = 0; i < axes; i += 1) {
      const v = series.data[i];
      const p = at(i, typeof v === "number" ? v : 0);
      pts.push({ x: p.x, y: p.y, move: i === 0 });
    }
    out.push({
      kind: "path",
      pts,
      close: true,
      fill: paint.series(si),
      opacity: 0.25,
      stroke: paint.series(si),
      strokeW: 3,
    });
  });

  if (spec.legend) {
    out.push(
      ...legendPrimitives(spec, {
        x: box.x,
        y: box.y + box.h - legendH,
        w: box.w,
        h: legendH,
      }),
    );
  }

  return { primitives: out };
}
