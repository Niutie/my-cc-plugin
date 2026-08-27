/* ─────────────────────────────────────────────────────────────────────
 * charts/kinds/shapes.ts — funnel, treemap, marimekko, heatmap, sankey,
 * scatter, bubble.
 *
 * The ones PowerPoint has no native chart for (plus the two xy charts
 * it does). All of these are pure geometry over the shared primitive
 * layer, so they export as real PowerPoint shapes rather than a picture.
 * ───────────────────────────────────────────────────────────────────── */

import type { Rect } from "../../deck/layout";
import { CHART_TYPE } from "../../deck/typography";
import type { ChartSpec } from "../../deck/types";
import { cartesianFrame, legendPrimitives } from "../frame";
import { paint, polygon, type PathPoint, type Primitive } from "../primitives";
import { formatValue, niceTicks } from "../scale";
import type { ChartBuild } from "../registry";

function label(
  text: string,
  r: Rect,
  color = paint.text,
  size = CHART_TYPE.axisLabel.sizePx,
  weight?: number,
): Primitive {
  return {
    kind: "text",
    x: r.x,
    y: r.y,
    w: r.w,
    h: r.h,
    text,
    sizePx: size,
    weight,
    color,
    align: "left",
    valign: "middle",
    family: "body",
  };
}

/* ── funnel ──────────────────────────────────────────────────────── */

/** Single series; each stage is a trapezoid whose width tracks its value. */
export function funnel(spec: ChartSpec, box: Rect): ChartBuild {
  const series = spec.series[0];
  if (!series) return { primitives: [] };

  const values = series.data.map((v) => (typeof v === "number" ? Math.max(0, v) : 0));
  const top = Math.max(...values, 1);
  const labelW = 220;
  const plot: Rect = {
    x: box.x + labelW,
    y: box.y + 8,
    w: box.w - labelW - 160,
    h: box.h - 16,
  };
  const stageH = plot.h / Math.max(1, values.length);
  const gap = Math.min(8, stageH * 0.12);
  const cx = plot.x + plot.w / 2;

  const out: Primitive[] = [];
  values.forEach((value, i) => {
    const wTop = (value / top) * plot.w;
    const next = values[i + 1] ?? value;
    const wBot = (next / top) * plot.w;
    const y = plot.y + i * stageH;
    const y2 = y + stageH - gap;

    out.push(
      polygon(
        [
          [cx - wTop / 2, y],
          [cx + wTop / 2, y],
          [cx + wBot / 2, y2],
          [cx - wBot / 2, y2],
        ],
        { fill: paint.seq(Math.min(4, values.length - 1 - i)) },
      ),
    );
    out.push(
      label(spec.categories[i] ?? "", {
        x: box.x,
        y,
        w: labelW - 20,
        h: stageH - gap,
      }),
    );
    out.push({
      kind: "text",
      x: plot.x + plot.w + 20,
      y,
      w: 140,
      h: stageH - gap,
      text: formatValue(value, spec.unit),
      sizePx: CHART_TYPE.valueLabel.sizePx,
      weight: CHART_TYPE.valueLabel.weight,
      color: paint.text,
      align: "left",
      valign: "middle",
      family: "mono",
    });
    // Conversion between stages is the number a funnel exists to show.
    if (i > 0 && values[i - 1] > 0) {
      out.push({
        kind: "text",
        x: plot.x + plot.w + 20,
        y: y - stageH / 2,
        w: 140,
        h: stageH,
        text: `${Math.round((value / values[i - 1]) * 100)}%`,
        sizePx: CHART_TYPE.axisLabel.sizePx,
        color: paint.textMute,
        align: "left",
        valign: "middle",
        family: "mono",
      });
    }
  });

  return { primitives: out };
}

/* ── treemap ─────────────────────────────────────────────────────── */

/** Squarified-ish slice-and-dice: alternate split direction per row so
 *  tiles stay closer to square than a plain strip layout. */
export function treemap(spec: ChartSpec, box: Rect): ChartBuild {
  const series = spec.series[0];
  if (!series) return { primitives: [] };

  const items = spec.categories
    .map((name, i) => ({
      name,
      value: typeof series.data[i] === "number" ? (series.data[i] as number) : 0,
      index: i,
    }))
    .filter((d) => d.value > 0)
    .sort((a, b) => b.value - a.value);
  if (!items.length) return { primitives: [] };

  const out: Primitive[] = [];
  const gap = 4;
  let rect: Rect = { ...box };
  let remaining = items.reduce((a, b) => a + b.value, 0);

  items.forEach((item, i) => {
    const share = item.value / remaining;
    const horizontal = rect.w >= rect.h;
    const tile: Rect = horizontal
      ? { x: rect.x, y: rect.y, w: rect.w * share, h: rect.h }
      : { x: rect.x, y: rect.y, w: rect.w, h: rect.h * share };

    const last = i === items.length - 1;
    const drawn = last ? rect : tile;

    out.push({
      kind: "rect",
      x: drawn.x,
      y: drawn.y,
      w: Math.max(1, drawn.w - gap),
      h: Math.max(1, drawn.h - gap),
      fill: paint.seq(4 - Math.min(4, Math.floor((i / items.length) * 5))),
    });
    // Only label tiles with room; a 30px sliver with text in it is worse
    // than a 30px sliver.
    if (drawn.w > 90 && drawn.h > 54) {
      out.push({
        kind: "text",
        x: drawn.x + 14,
        y: drawn.y + 12,
        w: drawn.w - 28,
        h: 26,
        text: item.name,
        sizePx: CHART_TYPE.axisLabel.sizePx,
        color: paint.surface,
        align: "left",
        valign: "top",
        family: "body",
      });
      out.push({
        kind: "text",
        x: drawn.x + 14,
        y: drawn.y + 38,
        w: drawn.w - 28,
        h: 30,
        text: formatValue(item.value, spec.unit),
        sizePx: CHART_TYPE.valueLabel.sizePx,
        weight: CHART_TYPE.valueLabel.weight,
        color: paint.surface,
        align: "left",
        valign: "top",
        family: "mono",
      });
    }

    remaining -= item.value;
    rect = horizontal
      ? { x: rect.x + tile.w, y: rect.y, w: rect.w - tile.w, h: rect.h }
      : { x: rect.x, y: rect.y + tile.h, w: rect.w, h: rect.h - tile.h };
  });

  return { primitives: out };
}

/* ── marimekko ───────────────────────────────────────────────────── */

/** Column widths encode the category total, segment heights encode the
 *  series share — two dimensions in one chart. */
export function marimekko(spec: ChartSpec, box: Rect): ChartBuild {
  const cols = spec.categories.length;
  if (!cols) return { primitives: [] };

  const legendH = spec.legend ? 38 : 0;
  const plot: Rect = {
    x: box.x,
    y: box.y + 8,
    w: box.w,
    h: box.h - 8 - 40 - legendH,
  };

  const totals = spec.categories.map((_, ci) =>
    spec.series.reduce(
      (sum, s) => sum + (typeof s.data[ci] === "number" ? (s.data[ci] as number) : 0),
      0,
    ),
  );
  const grand = totals.reduce((a, b) => a + b, 0);
  if (grand <= 0) return { primitives: [] };

  const out: Primitive[] = [];
  const gap = 6;
  let x = plot.x;

  spec.categories.forEach((name, ci) => {
    const colW = (totals[ci] / grand) * plot.w - gap;
    let y = plot.y;
    spec.series.forEach((s, si) => {
      const v = typeof s.data[ci] === "number" ? (s.data[ci] as number) : 0;
      if (totals[ci] <= 0) return;
      const h = (v / totals[ci]) * plot.h;
      out.push({
        kind: "rect",
        x,
        y,
        w: Math.max(1, colW),
        h: Math.max(1, h),
        fill: paint.series(si),
      });
      if (spec.showValues && h > 30 && colW > 60) {
        out.push({
          kind: "text",
          x,
          y: y + h / 2 - 13,
          w: colW,
          h: 26,
          text: `${Math.round((v / totals[ci]) * 100)}%`,
          sizePx: CHART_TYPE.axisLabel.sizePx,
          color: paint.surface,
          align: "center",
          valign: "middle",
          family: "mono",
        });
      }
      y += h;
    });
    out.push({
      kind: "text",
      x,
      y: plot.y + plot.h + 8,
      w: Math.max(1, colW),
      h: 28,
      text: name,
      sizePx: CHART_TYPE.axisLabel.sizePx,
      color: paint.label,
      align: "center",
      valign: "top",
      family: "body",
    });
    x += colW + gap;
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

/* ── heatmap ─────────────────────────────────────────────────────── */

/** Rows = series, columns = categories, colour = value on the theme's
 *  sequential ramp. */
export function heatmap(spec: ChartSpec, box: Rect): ChartBuild {
  const cols = spec.categories.length;
  const rows = spec.series.length;
  if (!cols || !rows) return { primitives: [] };

  const labelW = 150;
  const headerH = 34;
  const plot: Rect = {
    x: box.x + labelW,
    y: box.y + headerH,
    w: box.w - labelW,
    h: box.h - headerH,
  };
  const cw = plot.w / cols;
  const ch = plot.h / rows;
  const gap = 3;

  const values = spec.series
    .flatMap((s) => s.data)
    .filter((v): v is number => typeof v === "number");
  const min = Math.min(...values, 0);
  const max = Math.max(...values, 1);
  const bucket = (v: number) =>
    Math.min(4, Math.max(0, Math.round(((v - min) / (max - min || 1)) * 4)));

  const out: Primitive[] = [];

  spec.categories.forEach((name, ci) => {
    out.push({
      kind: "text",
      x: plot.x + ci * cw,
      y: box.y,
      w: cw,
      h: headerH,
      text: name,
      sizePx: CHART_TYPE.axisLabel.sizePx,
      color: paint.label,
      align: "center",
      valign: "middle",
      family: "body",
    });
  });

  spec.series.forEach((s, ri) => {
    out.push({
      kind: "text",
      x: box.x,
      y: plot.y + ri * ch,
      w: labelW - 20,
      h: ch,
      text: s.name,
      sizePx: CHART_TYPE.axisLabel.sizePx,
      color: paint.label,
      align: "right",
      valign: "middle",
      family: "body",
    });
    s.data.forEach((raw, ci) => {
      if (typeof raw !== "number") return;
      const level = bucket(raw);
      out.push({
        kind: "rect",
        x: plot.x + ci * cw,
        y: plot.y + ri * ch,
        w: cw - gap,
        h: ch - gap,
        fill: paint.seq(level),
      });
      if (spec.showValues) {
        out.push({
          kind: "text",
          x: plot.x + ci * cw,
          y: plot.y + ri * ch,
          w: cw - gap,
          h: ch - gap,
          text: formatValue(raw, spec.unit),
          sizePx: CHART_TYPE.axisLabel.sizePx,
          // Past the midpoint of the ramp the tile is dark enough that
          // ink-coloured text disappears into it.
          color: level >= 3 ? paint.surface : paint.text,
          align: "center",
          valign: "middle",
          family: "mono",
        });
      }
    });
  });

  return { primitives: out };
}

/* ── sankey ──────────────────────────────────────────────────────── */

/**
 * A single-stage flow: every category is a source node on the left,
 * every series is a target node on the right, and `series[t].data[s]`
 * is the flow from source s to target t.
 */
export function sankey(spec: ChartSpec, box: Rect): ChartBuild {
  const sources = spec.categories.length;
  const targets = spec.series.length;
  if (!sources || !targets) return { primitives: [] };

  const nodeW = 22;
  const labelW = 160;
  const plot: Rect = {
    x: box.x + labelW,
    y: box.y + 10,
    w: box.w - labelW * 2,
    h: box.h - 20,
  };

  const flow = (s: number, t: number) => {
    const v = spec.series[t].data[s];
    return typeof v === "number" ? Math.max(0, v) : 0;
  };
  const sourceTotals = spec.categories.map((_, s) =>
    spec.series.reduce((sum, _t, t) => sum + flow(s, t), 0),
  );
  const targetTotals = spec.series.map((_, t) =>
    spec.categories.reduce((sum, _s, s) => sum + flow(s, t), 0),
  );
  const grand = sourceTotals.reduce((a, b) => a + b, 0);
  if (grand <= 0) return { primitives: [] };

  const nodeGap = 14;
  const usableL = plot.h - nodeGap * Math.max(0, sources - 1);
  const usableR = plot.h - nodeGap * Math.max(0, targets - 1);
  const scaleL = usableL / grand;
  const scaleR = usableR / grand;

  const out: Primitive[] = [];
  const leftY: number[] = [];
  const rightY: number[] = [];

  let y = plot.y;
  sourceTotals.forEach((total, s) => {
    leftY[s] = y;
    const h = total * scaleL;
    out.push({
      kind: "rect",
      x: plot.x,
      y,
      w: nodeW,
      h: Math.max(2, h),
      fill: paint.series(s),
    });
    out.push({
      kind: "text",
      x: box.x,
      y: y + h / 2 - 15,
      w: labelW - 18,
      h: 30,
      text: spec.categories[s],
      sizePx: CHART_TYPE.axisLabel.sizePx,
      color: paint.label,
      align: "right",
      valign: "middle",
      family: "body",
    });
    y += h + nodeGap;
  });

  y = plot.y;
  targetTotals.forEach((total, t) => {
    rightY[t] = y;
    const h = total * scaleR;
    out.push({
      kind: "rect",
      x: plot.x + plot.w - nodeW,
      y,
      w: nodeW,
      h: Math.max(2, h),
      fill: paint.textMute,
    });
    out.push({
      kind: "text",
      x: plot.x + plot.w + 18,
      y: y + h / 2 - 15,
      w: labelW - 18,
      h: 30,
      text: `${spec.series[t].name}  ${formatValue(total, spec.unit)}`,
      sizePx: CHART_TYPE.axisLabel.sizePx,
      color: paint.label,
      align: "left",
      valign: "middle",
      family: "body",
    });
    y += h + nodeGap;
  });

  // Ribbons, drawn source-major so each source's outflows stay stacked
  // in the same order on both ends — crossing ribbons are the point,
  // tangled ones are a bug.
  const leftCursor = [...leftY];
  const rightCursor = [...rightY];
  const x1 = plot.x + nodeW;
  const x2 = plot.x + plot.w - nodeW;
  const bend = (x2 - x1) * 0.45;

  for (let s = 0; s < sources; s += 1) {
    for (let t = 0; t < targets; t += 1) {
      const v = flow(s, t);
      if (v <= 0) continue;
      const hL = v * scaleL;
      const hR = v * scaleR;
      const aTop = leftCursor[s];
      const bTop = rightCursor[t];

      const pts: PathPoint[] = [
        { x: x1, y: aTop, move: true },
        {
          x: x2,
          y: bTop,
          curve: { x1: x1 + bend, y1: aTop, x2: x2 - bend, y2: bTop },
        },
        { x: x2, y: bTop + hR },
        {
          x: x1,
          y: aTop + hL,
          curve: {
            x1: x2 - bend,
            y1: bTop + hR,
            x2: x1 + bend,
            y2: aTop + hL,
          },
        },
      ];
      out.push({
        kind: "path",
        pts,
        close: true,
        fill: paint.series(s),
        opacity: 0.42,
      });

      leftCursor[s] += hL;
      rightCursor[t] += hR;
    }
  }

  return { primitives: out };
}

/* ── scatter / bubble ────────────────────────────────────────────── */

/**
 * `categories` carries the x values as strings (they are numeric on a
 * scatter), `series[0]` the y values, and for a bubble chart
 * `series[1]` the radius weights.
 */
function xyLike(spec: ChartSpec, box: Rect, sized: boolean): ChartBuild {
  const ys = spec.series[0];
  if (!ys) return { primitives: [] };

  const xs = spec.categories.map((c) => Number.parseFloat(c));
  const xTicks = niceTicks(Math.min(...xs, 0), Math.max(...xs, 1));
  // No legend here. On a scatter the series ARE the axes, and on a
  // bubble the second series is the dot size — a swatch labelled "体量"
  // next to a colour that encodes nothing is worse than no legend.
  const frame = cartesianFrame({ ...spec, legend: false }, box, {
    categoryLabels: false,
  });
  const out: Primitive[] = [...frame.chrome];

  const xAt = (v: number) =>
    frame.plot.x +
    ((v - xTicks.min) / (xTicks.max - xTicks.min || 1)) * frame.plot.w;

  for (const t of xTicks.values) {
    const tx = xAt(t);
    out.push({
      kind: "line",
      x1: tx,
      y1: frame.plot.y,
      x2: tx,
      y2: frame.plot.y + frame.plot.h,
      stroke: paint.grid,
      strokeW: 1,
    });
    out.push({
      kind: "text",
      x: tx - 50,
      y: frame.plot.y + frame.plot.h + 8,
      w: 100,
      h: 26,
      text: formatValue(t),
      sizePx: CHART_TYPE.axisLabel.sizePx,
      color: paint.label,
      align: "center",
      valign: "top",
      family: "mono",
    });
  }

  const weights = sized
    ? (spec.series[1]?.data ?? []).map((v) => (typeof v === "number" ? v : 1))
    : [];
  const maxW = Math.max(1, ...weights);

  ys.data.forEach((yv, i) => {
    if (typeof yv !== "number" || !Number.isFinite(xs[i])) return;
    // Bubble area, not radius, encodes the weight — scaling the radius
    // linearly exaggerates big values by the square.
    const r = sized
      ? 8 + Math.sqrt((weights[i] ?? 1) / maxW) * 34
      : 8;
    const cx = xAt(xs[i]);
    const cy = frame.scales.y(yv);
    out.push({
      kind: "ellipse",
      x: cx - r,
      y: cy - r,
      w: r * 2,
      h: r * 2,
      fill: paint.series(0),
      opacity: sized ? 0.55 : 0.9,
    });
  });

  return { primitives: out, axis: { min: frame.scales.min, max: frame.scales.max } };
}

export function scatter(spec: ChartSpec, box: Rect): ChartBuild {
  return xyLike(spec, box, false);
}

export function bubble(spec: ChartSpec, box: Rect): ChartBuild {
  return xyLike(spec, box, true);
}
