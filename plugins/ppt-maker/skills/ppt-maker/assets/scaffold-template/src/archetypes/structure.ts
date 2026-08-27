/* ─────────────────────────────────────────────────────────────────────
 * archetypes/structure.ts — timeline-steps, process-flow, matrix-2x2,
 * list-cards, case-detail.
 *
 * The pages that carry a SHAPE of an argument rather than a number.
 * Each one has to be visibly its own family in the geometry: a timeline
 * must run along an axis, a process must show direction, a matrix must
 * have quadrants. Drawing all three as a row of cards — which is what
 * happens by default — is the single most recognisable tell of a
 * generated deck, and `list-cards` is the only one here allowed to do
 * it on purpose.
 * ───────────────────────────────────────────────────────────────────── */

import type { Element } from "../deck/types";
import {
  compact,
  g,
  itemsAsRows,
  list,
  metric,
  rule,
  shape,
  text,
} from "./build";
import { propBool, propEnum, propNumber, type Archetype } from "./types";

export const timelineSteps: Archetype = {
  id: "timeline-steps",
  name: { zh: "时间线 · 横向节点", en: "Timeline · steps" },
  family: "timeline",
  roles: ["process", "trend", "actions"],
  capacity: {
    titleChars: 24,
    takeawayChars: 54,
    items: { min: 3, max: 5 },
    itemLabelChars: 16,
    itemDetailChars: 46,
  },
  controls: [
    {
      key: "visibleCount",
      type: "range",
      label: { zh: "节点数量", en: "Steps" },
      default: 4,
      min: 3,
      max: 5,
      step: 1,
      bindsArray: "items",
    },
    { key: "showAxis", type: "toggle", label: { zh: "时间轴线", en: "Axis line" }, default: true },
    { key: "showMarkers", type: "toggle", label: { zh: "节点标记", en: "Node markers" }, default: true },
  ],
  build(props, content) {
    const p = content.presentation;
    const visible = propNumber(props, "visibleCount", 4, 3, 5);
    const items = (p.items ?? []).slice(0, visible);
    const span = Math.floor(12 / Math.max(1, items.length));

    const nodes: Element[] = items.flatMap((item, i) => {
      const col = 1 + i * span;
      const out: Element[] = [];
      if (propBool(props, "showMarkers", true)) {
        // A small filled square on the axis — the marker is what makes
        // the row read as points in time rather than four paragraphs.
        out.push(
          shape(`dot${i}`, g(col, 4, 1, 1), {
            fill: "accent",
            shape: "rect",
            // A full grid cell would be a 122px block. The marker is a
            // tick hanging off the axis, so it is sized in px and pinned
            // to the cell's top-left corner where the axis line runs.
            size: { w: 12, h: 12 },
            anchor: "top-left",
          }),
        );
      }
      out.push(
        text(`when${i}`, "kicker", g(col, 3, span, 1), item.displayValue ?? "", {
          valign: "bottom",
        }),
      );
      out.push(
        text(`what${i}`, "subtitle", g(col, 5, span, 1), item.label, { valign: "top" }),
      );
      if (item.detail) {
        out.push(
          text(`why${i}`, "caption", g(col, 6, span, 2), item.detail, { valign: "top" }),
        );
      }
      return out;
    });

    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 9, 1), p.title, { valign: "top" }),
        propBool(props, "showAxis", true) && rule("axis", g(1, 4, 12, 1), { accent: true }),
        ...nodes,
        p.takeaway && text("takeaway", "body", g(1, 8, 11, 1), p.takeaway, { valign: "middle" }),
      ]),
    };
  },
};

export const processFlow: Archetype = {
  id: "process-flow",
  name: { zh: "流程 · 编号阶梯", en: "Process · flow" },
  family: "process",
  roles: ["process", "actions"],
  capacity: {
    titleChars: 24,
    takeawayChars: 54,
    items: { min: 3, max: 6 },
    itemLabelChars: 20,
    itemDetailChars: 52,
  },
  controls: [
    {
      key: "visibleCount",
      type: "range",
      label: { zh: "步骤数量", en: "Steps" },
      default: 4,
      min: 3,
      max: 6,
      step: 1,
      bindsArray: "items",
    },
    {
      key: "direction",
      type: "select",
      label: { zh: "排列方向", en: "Direction" },
      default: "vertical",
      options: [
        { value: "vertical", label: { zh: "自上而下", en: "Top-down" } },
        { value: "horizontal", label: { zh: "从左到右", en: "Left-right" } },
      ],
    },
  ],
  build(props, content) {
    const p = content.presentation;
    const visible = propNumber(props, "visibleCount", 4, 3, 6);
    const items = itemsAsRows((p.items ?? []).slice(0, visible));
    const vertical =
      propEnum(props, "direction", "vertical", ["vertical", "horizontal"] as const) ===
      "vertical";

    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 9, 1), p.title, { valign: "top" }),
        // Numbered rows carry the direction: 01 → 02 → 03 reads as a
        // sequence even without arrows, and arrows in PowerPoint export
        // as one more thing to go stale.
        list(
          "steps",
          vertical ? g(1, 3, 8, 5) : g(1, 3, 12, 4),
          "numbered",
          items,
          vertical ? 1 : items.length,
        ),
        p.takeaway && text("takeaway", "body", g(1, 8, 11, 1), p.takeaway, { valign: "middle" }),
      ]),
    };
  },
};

export const matrix2x2: Archetype = {
  id: "matrix-2x2",
  name: { zh: "矩阵 · 四象限", en: "Matrix · 2×2" },
  family: "matrix",
  roles: ["matrix", "comparison", "risks"],
  capacity: {
    titleChars: 22,
    items: { min: 4, max: 4 },
    itemLabelChars: 18,
    itemDetailChars: 46,
  },
  controls: [
    { key: "showAxes", type: "toggle", label: { zh: "坐标轴标签", en: "Axis labels" }, default: true },
    {
      key: "style",
      type: "select",
      label: { zh: "象限样式", en: "Quadrant style" },
      default: "card",
      options: [
        { value: "card", label: { zh: "色块", en: "Filled" } },
        { value: "rule", label: { zh: "细线", en: "Ruled" } },
      ],
    },
  ],
  build(props, content) {
    const p = content.presentation;
    const items = (p.items ?? []).slice(0, 4);
    const style = propEnum(props, "style", "card", ["card", "rule"] as const);
    const showAxes = propBool(props, "showAxes", true);
    // The axis caption needs its own row. Without this the bottom
    // quadrants run to row 8 and the caption lands inside them.
    const axisLabel = showAxes ? content.meta?.xAxis : undefined;
    const quadH = axisLabel ? 2 : 3;

    // Reading order is top-left, top-right, bottom-left, bottom-right —
    // the order people scan, so items[0] should be the headline quadrant.
    const cells: Array<[number, number]> = [
      [1, 3],
      [7, 3],
      [1, 6],
      [7, 6],
    ];

    const quadrants: Element[] = items.flatMap((item, i) => {
      const [col, row] = cells[i];
      const out: Element[] = [];
      if (style === "card") {
        out.push(
          shape(`q${i}`, g(col, row, 6, i < 2 ? 3 : quadH), {
            fill: i === 0 ? "accent-soft" : "surface-2",
          }),
        );
      }
      out.push(
        text(`ql${i}`, "subtitle", g(col, row, 5, 1), item.label, { valign: "middle" }),
      );
      if (item.detail) {
        out.push(
          text(`qd${i}`, "body", g(col, row + 1, 5, 2), item.detail, { valign: "top" }),
        );
      }
      return out;
    });

    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 9, 1), p.title, { valign: "top" }),
        ...quadrants,
        style === "rule" && rule("hAxis", g(1, 6, 12, 1)),
        style === "rule" &&
          rule("vAxis", g(6, 3, 1, axisLabel ? 5 : 6), { vertical: true }),
        axisLabel &&
          text("xAxis", "caption", g(1, 8, 12, 1), axisLabel, {
            align: "center",
            valign: "middle",
          }),
      ]),
    };
  },
};

export const listCards: Archetype = {
  id: "list-cards",
  name: { zh: "要点 · 卡片网格", en: "Points · card grid" },
  family: "editorial",
  roles: ["breakdown", "statement", "actions", "risks"],
  capacity: {
    titleChars: 24,
    takeawayChars: 54,
    items: { min: 2, max: 6 },
    itemLabelChars: 18,
    itemDetailChars: 60,
  },
  controls: [
    {
      key: "columns",
      type: "range",
      label: { zh: "每行几张", en: "Columns" },
      default: 3,
      min: 2,
      max: 3,
      step: 1,
    },
    {
      key: "visibleCount",
      type: "range",
      label: { zh: "卡片数量", en: "Cards" },
      default: 3,
      min: 2,
      max: 6,
      step: 1,
      bindsArray: "items",
    },
  ],
  build(props, content) {
    const p = content.presentation;
    const visible = propNumber(props, "visibleCount", 3, 2, 6);
    const columns = propNumber(props, "columns", 3, 2, 3);
    const rows = itemsAsRows((p.items ?? []).slice(0, visible));
    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 9, 1), p.title, { valign: "top" }),
        list("cards", g(1, 3, 12, 5), "card", rows, columns),
        p.takeaway && text("takeaway", "body", g(1, 8, 11, 1), p.takeaway, { valign: "middle" }),
      ]),
    };
  },
};

export const caseDetail: Archetype = {
  id: "case-detail",
  name: { zh: "案例 · 单点深挖", en: "Case · detail" },
  family: "editorial",
  roles: ["case", "result"],
  capacity: {
    titleChars: 26,
    summaryChars: 60,
    takeawayChars: 150,
    items: { min: 1, max: 3 },
    itemLabelChars: 14,
  },
  controls: [
    {
      key: "visibleCount",
      type: "range",
      label: { zh: "结果指标数", en: "Result metrics" },
      default: 2,
      min: 1,
      max: 3,
      step: 1,
      bindsArray: "items",
    },
    { key: "showRule", type: "toggle", label: { zh: "中缝分割线", en: "Divider" }, default: true },
  ],
  build(props, content) {
    const p = content.presentation;
    const visible = propNumber(props, "visibleCount", 2, 1, 3);
    const items = (p.items ?? []).slice(0, visible);
    // Stacked, not side by side: two hero numerals in half a column each
    // collide the moment either has more than three characters.
    const rowSpan = Math.floor(6 / Math.max(1, items.length));

    const metrics: Element[] = items.map((item, i) =>
      metric(item.id ?? `r${i}`, g(8, 3 + i * rowSpan, 5, rowSpan), item.displayValue ?? String(item.value ?? ""), {
        label: item.label,
        unit: item.unit,
        accent: i === 0,
      }),
    );

    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 6, 2), p.title, { valign: "top" }),
        p.summary && text("summary", "subtitle", g(1, 4, 6, 1), p.summary, { valign: "top" }),
        p.takeaway && text("body", "body", g(1, 5, 6, 4), p.takeaway, { valign: "top" }),
        propBool(props, "showRule", true) && rule("divider", g(7, 2, 1, 6), { vertical: true }),
        ...metrics,
      ]),
    };
  },
};
