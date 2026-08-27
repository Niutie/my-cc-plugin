/* ─────────────────────────────────────────────────────────────────────
 * charts/registry.ts — every chart kind, and how each one exports.
 *
 * A kind ALWAYS has a `build` — the vector primitives the browser
 * paints and the exporter falls back to. A kind MAY also declare
 * `native`, meaning PowerPoint has a real chart object for it.
 *
 * Native vs vector is a genuine trade, not an optimisation:
 *
 *   native  the recipient opens the data sheet and edits the numbers,
 *           but PowerPoint draws the marks, so the styling is an
 *           approximation of the SVG.
 *   vector  pixel-for-pixel the same drawing as the browser, made of
 *           real PowerPoint shapes — but the numbers are baked in.
 *
 * Default is native where it exists, because "my colleague can update
 * the figures" is usually worth more than exact bar corners. A deck
 * overrides per chart with `render: "vector"`.
 * ───────────────────────────────────────────────────────────────────── */

import type { Rect } from "../deck/layout";
import type { ChartKind, ChartSpec } from "../deck/types";
import type { Primitive } from "./primitives";

import { bar, dumbbell, gantt } from "./kinds/horizontal";
import { donut, pie, radar } from "./kinds/radial";
import {
  bubble,
  funnel,
  heatmap,
  marimekko,
  sankey,
  scatter,
  treemap,
} from "./kinds/shapes";
import { area, column, line, slope, waterfall } from "./kinds/vertical";

export interface ChartBuild {
  primitives: Primitive[];
  /** The value range the SVG settled on, pinned onto native charts so
   *  both renderings share one axis. */
  axis?: { min: number; max: number };
}

export type ChartBuilder = (spec: ChartSpec, box: Rect) => ChartBuild;

export interface NativeMapping {
  /** pptxgenjs ChartType. */
  type: "area" | "bar" | "bubble" | "doughnut" | "line" | "pie" | "radar" | "scatter";
  opts?: Record<string, unknown>;
}

export interface ChartDef {
  build: ChartBuilder;
  native?: NativeMapping;
  /** Shown in errors and in the archetype capacity checks. */
  minSeries: number;
  /** A one-line note the review step can quote back at a bad choice. */
  reads: string;
}

export const CHARTS: Record<ChartKind, ChartDef> = {
  column: {
    build: column,
    native: { type: "bar", opts: { barDir: "col" } },
    minSeries: 1,
    reads: "比大小，类目少于 8 个时用",
  },
  bar: {
    build: bar,
    native: { type: "bar", opts: { barDir: "bar" } },
    minSeries: 1,
    reads: "比大小且类目名字长时用，横排不用转标签",
  },
  line: {
    build: line,
    native: { type: "line" },
    minSeries: 1,
    reads: "看趋势，横轴必须是连续的时间或序数",
  },
  area: {
    build: area,
    native: { type: "area" },
    minSeries: 1,
    reads: "看总量的累积与构成变化",
  },
  pie: {
    build: pie,
    native: { type: "pie" },
    minSeries: 1,
    reads: "看占比，切片超过 5 片就该换条形",
  },
  donut: {
    build: donut,
    native: { type: "doughnut" },
    minSeries: 1,
    reads: "看占比且中心要放总数",
  },
  radar: {
    build: radar,
    native: { type: "radar" },
    minSeries: 1,
    reads: "看多维能力画像，维度 3~8 个",
  },
  // Vector-only below: PowerPoint has no native equivalent, or its data
  // model doesn't match ours closely enough to export honestly.
  scatter: {
    build: scatter,
    minSeries: 1,
    reads: "看两个变量的相关性",
  },
  bubble: {
    build: bubble,
    minSeries: 2,
    reads: "看两个变量的相关性，外加第三个变量做气泡大小",
  },
  waterfall: {
    build: waterfall,
    minSeries: 1,
    reads: "拆解一个总量是怎么从起点走到终点的",
  },
  funnel: {
    build: funnel,
    minSeries: 1,
    reads: "看逐级转化的流失",
  },
  heatmap: {
    build: heatmap,
    minSeries: 2,
    reads: "看两个维度交叉后的密度分布",
  },
  treemap: {
    build: treemap,
    minSeries: 1,
    reads: "看层级占比，项目多且量级悬殊时用",
  },
  sankey: {
    build: sankey,
    minSeries: 1,
    reads: "看资源从哪里流到哪里",
  },
  gantt: {
    build: gantt,
    minSeries: 2,
    reads: "看排期，两条序列分别是开始与结束",
  },
  slope: {
    build: slope,
    minSeries: 1,
    reads: "看两个时点之间谁涨谁跌、名次怎么换",
  },
  dumbbell: {
    build: dumbbell,
    minSeries: 2,
    reads: "看每一项的前后差距本身",
  },
  marimekko: {
    build: marimekko,
    minSeries: 2,
    reads: "同时看类目的体量（列宽）和内部构成（分段）",
  },
};

export function chartDef(kind: ChartKind): ChartDef {
  const def = CHARTS[kind];
  if (!def) throw new Error(`unknown chart kind "${kind}"`);
  return def;
}

/** Whether this chart will be a native PowerPoint chart on export. */
export function exportsNative(spec: ChartSpec): boolean {
  const def = chartDef(spec.kind);
  return Boolean(def.native) && spec.render !== "vector";
}
