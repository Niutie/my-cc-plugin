/* ─────────────────────────────────────────────────────────────────────
 * archetypes/models.ts — the eight analysis frameworks.
 *
 * SWOT / PEST / BCG / 波特五力 / 商业模式画布 / 双钻 / AARRR / 飞轮.
 *
 * These are archetypes with a FIXED skeleton: the framework decides how
 * many cells there are and what each one is called, and the deck只填内容.
 * That is the opposite of the rest of the registry, where content picks
 * the layout — and it is correct here, because the whole value of a
 * framework is that the audience already knows the shape.
 *
 * Two consequences, both deliberate:
 *   • `items` count is exact, not a range. A SWOT with three quadrants
 *     is not a SWOT.
 *   • The cell headings come from the framework, not the content. The
 *     deck supplies what goes IN "Strengths", never a replacement word
 *     for "Strengths".
 * ───────────────────────────────────────────────────────────────────── */

import type { Element } from "../deck/types";
import { compact, g, shape, text } from "./build";
import { propBool, type Archetype, type Bilingual } from "./types";

/* ── shared: fixed-cell grid models ──────────────────────────────── */

interface Cell {
  heading: Bilingual;
  column: number;
  row: number;
  width: number;
  height: number;
}

/**
 * Build a framework whose cells are fixed. `items[i]` fills `cells[i]`,
 * in the order the framework is conventionally read.
 */
function cellModel(config: {
  id: string;
  name: Bilingual;
  family: Archetype["family"];
  roles: string[];
  cells: Cell[];
  /** Which cell (if any) gets the accent tint. */
  accentIndex?: number;
  axisX?: Bilingual;
  axisY?: Bilingual;
}): Archetype {
  const count = config.cells.length;
  return {
    id: config.id,
    name: config.name,
    family: config.family,
    roles: config.roles,
    capacity: {
      titleChars: 24,
      // Exact, not a range: a framework with a missing cell is not that
      // framework any more, and silently leaving one blank is worse than
      // refusing the page.
      items: { min: count, max: count },
      itemLabelChars: 20,
      itemDetailChars: 64,
    },
    controls: [
      { key: "showHeadings", type: "toggle", label: { zh: "显示框架标题", en: "Framework headings" }, default: true },
      { key: "tint", type: "toggle", label: { zh: "单元底色", en: "Cell tint" }, default: true },
      { key: "showAxes", type: "toggle", label: { zh: "坐标轴说明", en: "Axis captions" }, default: true },
    ],
    build(props, content, ctx) {
      const p = content.presentation;
      const items = (p.items ?? []).slice(0, count);
      const headings = propBool(props, "showHeadings", true);
      const tint = propBool(props, "tint", true);
      const showAxes = propBool(props, "showAxes", true) && Boolean(config.axisX);
      const lang = ctx.lang;

      const cells: Element[] = config.cells.flatMap((cell, i) => {
        const item = items[i];
        const out: Element[] = [];
        if (tint) {
          out.push(
            shape(`c${i}`, g(cell.column, cell.row, cell.width, cell.height), {
              fill: i === config.accentIndex ? "accent-soft" : "surface-2",
            }),
          );
        }
        if (headings) {
          out.push(
            text(
              `h${i}`,
              "kicker",
              g(cell.column, cell.row, cell.width, 1),
              cell.heading[lang],
              { valign: "middle" },
            ),
          );
        }
        if (item) {
          out.push(
            text(
              `l${i}`,
              "subtitle",
              g(cell.column, cell.row + (headings ? 1 : 0), cell.width, 1),
              item.label,
              { valign: "middle" },
            ),
          );
          if (item.detail && cell.height > (headings ? 2 : 1)) {
            out.push(
              text(
                `d${i}`,
                "caption",
                g(
                  cell.column,
                  cell.row + (headings ? 2 : 1),
                  cell.width,
                  cell.height - (headings ? 2 : 1),
                ),
                item.detail,
                { valign: "top" },
              ),
            );
          }
        }
        return out;
      });

      return {
        background: "surface",
        elements: compact([
          text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
          text("title", "title", g(1, 2, 9, 1), p.title, { valign: "top" }),
          ...cells,
          showAxes &&
            config.axisX &&
            text("axisX", "caption", g(1, 8, 12, 1), config.axisX[lang], {
              align: "center",
              valign: "middle",
            }),
        ]),
      };
    },
  };
}

/* ── SWOT ────────────────────────────────────────────────────────── */

export const swot = cellModel({
  id: "model-swot",
  name: { zh: "SWOT 分析", en: "SWOT" },
  family: "matrix",
  roles: ["matrix", "comparison", "risks"],
  accentIndex: 0,
  cells: [
    { heading: { zh: "S · 优势", en: "S · Strengths" }, column: 1, row: 3, width: 6, height: 3 },
    { heading: { zh: "W · 劣势", en: "W · Weaknesses" }, column: 7, row: 3, width: 6, height: 3 },
    { heading: { zh: "O · 机会", en: "O · Opportunities" }, column: 1, row: 6, width: 6, height: 3 },
    { heading: { zh: "T · 威胁", en: "T · Threats" }, column: 7, row: 6, width: 6, height: 3 },
  ],
});

/* ── PEST ────────────────────────────────────────────────────────── */

export const pest = cellModel({
  id: "model-pest",
  name: { zh: "PEST 分析", en: "PEST" },
  family: "matrix",
  roles: ["matrix", "context", "risks"],
  cells: [
    { heading: { zh: "P · 政策", en: "P · Political" }, column: 1, row: 3, width: 6, height: 3 },
    { heading: { zh: "E · 经济", en: "E · Economic" }, column: 7, row: 3, width: 6, height: 3 },
    { heading: { zh: "S · 社会", en: "S · Social" }, column: 1, row: 6, width: 6, height: 3 },
    { heading: { zh: "T · 技术", en: "T · Technological" }, column: 7, row: 6, width: 6, height: 3 },
  ],
});

/* ── BCG ─────────────────────────────────────────────────────────── */

export const bcg = cellModel({
  id: "model-bcg",
  name: { zh: "BCG 矩阵", en: "BCG matrix" },
  family: "matrix",
  roles: ["matrix", "comparison"],
  accentIndex: 0,
  axisX: { zh: "相对市场份额 →", en: "Relative market share →" },
  cells: [
    { heading: { zh: "明星 · Star", en: "Star" }, column: 1, row: 3, width: 6, height: 2 },
    { heading: { zh: "问号 · Question", en: "Question mark" }, column: 7, row: 3, width: 6, height: 2 },
    { heading: { zh: "现金牛 · Cash cow", en: "Cash cow" }, column: 1, row: 5, width: 6, height: 3 },
    { heading: { zh: "瘦狗 · Dog", en: "Dog" }, column: 7, row: 5, width: 6, height: 3 },
  ],
});

/* ── 商业模式画布 ────────────────────────────────────────────────── */

export const businessModelCanvas = cellModel({
  id: "model-bmc",
  name: { zh: "商业模式画布", en: "Business model canvas" },
  family: "matrix",
  roles: ["matrix", "context"],
  accentIndex: 4,
  cells: [
    { heading: { zh: "重要伙伴", en: "Key partners" }, column: 1, row: 3, width: 2, height: 4 },
    { heading: { zh: "关键业务", en: "Key activities" }, column: 3, row: 3, width: 2, height: 2 },
    { heading: { zh: "核心资源", en: "Key resources" }, column: 3, row: 5, width: 2, height: 2 },
    { heading: { zh: "价值主张", en: "Value proposition" }, column: 5, row: 3, width: 3, height: 4 },
    { heading: { zh: "客户关系", en: "Customer relations" }, column: 8, row: 3, width: 2, height: 2 },
    { heading: { zh: "渠道通路", en: "Channels" }, column: 8, row: 5, width: 2, height: 2 },
    { heading: { zh: "客户细分", en: "Customer segments" }, column: 10, row: 3, width: 3, height: 4 },
    { heading: { zh: "成本结构", en: "Cost structure" }, column: 1, row: 7, width: 6, height: 2 },
    { heading: { zh: "收入来源", en: "Revenue streams" }, column: 7, row: 7, width: 6, height: 2 },
  ],
});

/* ── 波特五力 ────────────────────────────────────────────────────── */

export const porterFiveForces: Archetype = {
  id: "model-porter",
  name: { zh: "波特五力", en: "Porter's five forces" },
  family: "relationship",
  roles: ["relationship", "risks", "matrix"],
  capacity: {
    titleChars: 22,
    items: { min: 5, max: 5 },
    itemLabelChars: 18,
    itemDetailChars: 40,
  },
  controls: [
    { key: "tint", type: "toggle", label: { zh: "单元底色", en: "Cell tint" }, default: true },
    { key: "showHeadings", type: "toggle", label: { zh: "显示力名", en: "Force names" }, default: true },
  ],
  build(props, content, ctx) {
    const p = content.presentation;
    const items = (p.items ?? []).slice(0, 5);
    const tint = propBool(props, "tint", true);
    const headings = propBool(props, "showHeadings", true);
    const zh = ctx.lang === "zh";

    // Rivalry in the centre, the four pressures around it. The geometry
    // IS the argument here — a five-row list says nothing about which
    // force pushes on which.
    const slots: Array<{ name: string; c: number; r: number; w: number; h: number }> = [
      { name: zh ? "同业竞争" : "Rivalry", c: 5, r: 5, w: 4, h: 2 },
      { name: zh ? "新进入者" : "New entrants", c: 5, r: 3, w: 4, h: 2 },
      { name: zh ? "替代品" : "Substitutes", c: 5, r: 7, w: 4, h: 2 },
      { name: zh ? "供应商议价" : "Supplier power", c: 1, r: 5, w: 4, h: 2 },
      { name: zh ? "购买者议价" : "Buyer power", c: 9, r: 5, w: 4, h: 2 },
    ];

    const cells: Element[] = slots.flatMap((slot, i) => {
      const item = items[i];
      const out: Element[] = [];
      if (tint) {
        out.push(
          shape(`f${i}`, g(slot.c, slot.r, slot.w, slot.h), {
            fill: i === 0 ? "accent-soft" : "surface-2",
          }),
        );
      }
      if (headings) {
        out.push(
          text(`fh${i}`, "kicker", g(slot.c, slot.r, slot.w, 1), slot.name, {
            align: "center",
            valign: "middle",
          }),
        );
      }
      if (item) {
        out.push(
          text(`fl${i}`, "body", g(slot.c, slot.r + 1, slot.w, 1), item.label, {
            align: "center",
            valign: "middle",
          }),
        );
      }
      return out;
    });

    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 9, 1), p.title, { valign: "top" }),
        ...cells,
      ]),
    };
  },
};

/* ── 双钻 ────────────────────────────────────────────────────────── */

export const doubleDiamond: Archetype = {
  id: "model-double-diamond",
  name: { zh: "双钻模型", en: "Double diamond" },
  family: "process",
  roles: ["process", "actions"],
  capacity: {
    titleChars: 22,
    items: { min: 4, max: 4 },
    itemLabelChars: 16,
    itemDetailChars: 44,
  },
  controls: [
    { key: "showDiamonds", type: "toggle", label: { zh: "菱形图形", en: "Diamonds" }, default: true },
  ],
  build(props, content, ctx) {
    const p = content.presentation;
    const items = (p.items ?? []).slice(0, 4);
    const zh = ctx.lang === "zh";
    const phases = zh
      ? ["发散 · 探索", "收敛 · 定义", "发散 · 构思", "收敛 · 交付"]
      : ["Discover", "Define", "Develop", "Deliver"];

    // Two diamonds, each spanning two phases — the shape is what tells
    // you where you are widening and where you are narrowing.
    const diamonds: Element[] = propBool(props, "showDiamonds", true)
      ? [
          shape("d1", g(1, 3, 6, 3), { shape: "diamond", fill: "accent-soft" }),
          shape("d2", g(7, 3, 6, 3), { shape: "diamond", fill: "surface-2" }),
        ]
      : [];

    const labels: Element[] = phases.flatMap((phase, i) => {
      const col = 1 + i * 3;
      const item = items[i];
      const out: Element[] = [
        text(`p${i}`, "kicker", g(col, 6, 3, 1), phase, {
          align: "center",
          valign: "middle",
        }),
      ];
      if (item) {
        out.push(
          text(`pl${i}`, "subtitle", g(col, 7, 3, 1), item.label, {
            align: "center",
            valign: "top",
          }),
        );
        if (item.detail) {
          out.push(
            text(`pd${i}`, "caption", g(col, 8, 3, 1), item.detail, {
              align: "center",
              valign: "top",
            }),
          );
        }
      }
      return out;
    });

    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 9, 1), p.title, { valign: "top" }),
        ...diamonds,
        ...labels,
      ]),
    };
  },
};

/* ── AARRR ───────────────────────────────────────────────────────── */

export const aarrr: Archetype = {
  id: "model-aarrr",
  name: { zh: "AARRR 海盗指标", en: "AARRR funnel" },
  family: "process",
  roles: ["process", "distribution", "metrics"],
  capacity: {
    titleChars: 22,
    items: { min: 5, max: 5 },
    itemLabelChars: 16,
  },
  controls: [
    { key: "showValues", type: "toggle", label: { zh: "显示指标值", en: "Show values" }, default: true },
  ],
  build(props, content, ctx) {
    const p = content.presentation;
    const items = (p.items ?? []).slice(0, 5);
    const zh = ctx.lang === "zh";
    const stages = zh
      ? ["获取", "激活", "留存", "推荐", "收入"]
      : ["Acquisition", "Activation", "Retention", "Referral", "Revenue"];
    const showValues = propBool(props, "showValues", true);

    // Chevrons, not a funnel chart: AARRR is a sequence of stages a user
    // moves THROUGH, and the arrow shape says that. A funnel would imply
    // the five numbers are subsets of one total, which they are not.
    const bands: Element[] = stages.flatMap((stage, i) => {
      const row = 3 + i;
      const item = items[i];
      return compact([
        shape(`s${i}`, g(1, row, 12, 1), {
          shape: "chevron",
          fill: i === 0 ? "accent-soft" : "surface-2",
        }),
        text(`sn${i}`, "kicker", g(2, row, 3, 1), stage, { valign: "middle" }),
        item && text(`sl${i}`, "subtitle", g(5, row, 5, 1), item.label, { valign: "middle" }),
        item &&
          showValues &&
          text(
            `sv${i}`,
            "subtitle",
            g(10, row, 2, 1),
            item.displayValue ?? (item.value !== undefined ? String(item.value) : ""),
            { align: "right", valign: "middle", accent: i === 0 },
          ),
      ]);
    });

    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 9, 1), p.title, { valign: "top" }),
        ...bands,
      ]),
    };
  },
};

/* ── 飞轮 ────────────────────────────────────────────────────────── */

export const flywheel: Archetype = {
  id: "model-flywheel",
  name: { zh: "飞轮模型", en: "Flywheel" },
  family: "relationship",
  roles: ["relationship", "process"],
  capacity: {
    titleChars: 22,
    items: { min: 3, max: 4 },
    itemLabelChars: 16,
    itemDetailChars: 40,
  },
  controls: [
    { key: "showRing", type: "toggle", label: { zh: "圆环", en: "Ring" }, default: true },
    { key: "showHub", type: "toggle", label: { zh: "中心标签", en: "Hub label" }, default: true },
  ],
  build(props, content) {
    const p = content.presentation;
    const items = (p.items ?? []).slice(0, 4);

    // Four stations around a hub. The ring is what makes it a flywheel
    // rather than four boxes: the reader has to see that the last stage
    // feeds the first.
    // Stations sit OUTSIDE the ring (rows 4–7), one per compass point.
    // A station overlapping the ring reads as a label on the circle
    // rather than a stage the circle passes through.
    const slots: Array<{ c: number; r: number; w: number; h: number }> = [
      { c: 5, r: 3, w: 4, h: 1 },
      { c: 9, r: 5, w: 4, h: 1 },
      { c: 5, r: 8, w: 4, h: 1 },
      { c: 1, r: 5, w: 4, h: 1 },
    ];

    const stations: Element[] = items.flatMap((item, i) => {
      const slot = slots[i];
      return compact([
        shape(`ring${i}`, g(slot.c, slot.r, slot.w, slot.h), { fill: "surface-2" }),
        text(`sl${i}`, "subtitle", g(slot.c, slot.r, slot.w, 1), item.label, {
          align: "center",
          valign: "middle",
        }),
      ]);
    });

    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 9, 1), p.title, { valign: "top" }),
        propBool(props, "showRing", true) &&
          shape("wheel", g(4, 4, 6, 4), { shape: "ellipse", stroke: "accent", fill: "none" }),
        propBool(props, "showHub", true) &&
          text("hub", "kicker", g(5, 5, 4, 2), p.summary ?? "", {
            align: "center",
            valign: "middle",
          }),
        ...stations,

      ]),
    };
  },
};

export const MODEL_ARCHETYPES: Archetype[] = [
  swot,
  pest,
  bcg,
  businessModelCanvas,
  porterFiveForces,
  doubleDiamond,
  aarrr,
  flywheel,
];
