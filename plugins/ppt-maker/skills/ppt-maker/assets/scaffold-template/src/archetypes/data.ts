/* ─────────────────────────────────────────────────────────────────────
 * archetypes/data.ts — metric-wall, chart-led, chart-full,
 * comparison-split.
 *
 * The pages that carry numbers. Each one declares `needsValues`, so the
 * capacity check refuses content that has labels but no figures — a
 * chart page built from prose is the most common way a generated deck
 * lies about having data.
 * ───────────────────────────────────────────────────────────────────── */

import type { ChartKind, Element } from "../deck/types";
import {
  chart,
  compact,
  g,
  itemsAsChart,
  itemsAsRows,
  list,
  metric,
  rule,
  text,
} from "./build";
import { propBool, propEnum, propNumber, type Archetype } from "./types";

const CHART_CHOICES = ["column", "bar", "line", "area", "donut", "waterfall"] as const;

export const metricWall: Archetype = {
  id: "metric-wall",
  name: { zh: "指标墙", en: "Metric wall" },
  family: "metric-spotlight",
  roles: ["metrics", "result"],
  capacity: {
    titleChars: 24,
    takeawayChars: 52,
    items: { min: 2, max: 4 },
    itemLabelChars: 14,
    itemDetailChars: 30,
    needsValues: false,
  },
  controls: [
    {
      key: "visibleCount",
      type: "range",
      label: { zh: "指标数量", en: "Metrics" },
      default: 4,
      min: 2,
      max: 4,
      step: 1,
      bindsArray: "items",
    },
    { key: "showDetail", type: "toggle", label: { zh: "显示注解", en: "Show detail" }, default: true },
    { key: "accentFirst", type: "toggle", label: { zh: "首个用强调色", en: "Accent the first" }, default: true },
    { key: "showTakeaway", type: "toggle", label: { zh: "显示结论行", en: "Takeaway" }, default: true },
  ],
  build(props, content) {
    const p = content.presentation;
    const visible = propNumber(props, "visibleCount", 4, 2, 4);
    const showDetail = propBool(props, "showDetail", true);
    const accentFirst = propBool(props, "accentFirst", true);
    const showTakeaway = propBool(props, "showTakeaway", true) && !!p.takeaway;
    const items = (p.items ?? []).slice(0, visible);
    // 12 columns divide evenly by 2, 3 and 4 — the metric wall never
    // needs a ragged last cell.
    const span = Math.floor(12 / Math.max(1, items.length));

    const metrics: Element[] = items.map((item, i) =>
      metric(item.id ?? `m${i}`, g(1 + i * span, 4, span, 3), item.displayValue ?? String(item.value ?? ""), {
        label: item.label,
        unit: item.unit,
        detail: showDetail ? item.detail : undefined,
        accent: accentFirst && i === 0,
      }),
    );

    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 9, 1), p.title, { valign: "top" }),
        p.summary && text("summary", "subtitle", g(1, 3, 8, 1), p.summary, { valign: "top" }),
        ...metrics,
        showTakeaway && rule("rule", g(1, 7, 12, 1)),
        showTakeaway && text("takeaway", "body", g(1, 8, 10, 1), p.takeaway ?? "", { valign: "middle" }),
      ]),
    };
  },
};

export const chartLed: Archetype = {
  id: "chart-led",
  name: { zh: "图表主导 · 左文右图", en: "Chart-led · split" },
  family: "chart-led",
  roles: ["trend", "distribution", "comparison", "metrics"],
  capacity: {
    titleChars: 20,
    takeawayChars: 130,
    items: { min: 2, max: 12 },
    needsValues: true,
  },
  controls: [
    {
      key: "chartKind",
      type: "select",
      label: { zh: "图表类型", en: "Chart type" },
      default: "column",
      options: CHART_CHOICES.map((value) => ({
        value,
        label: { zh: value, en: value },
      })),
    },
    { key: "showValues", type: "toggle", label: { zh: "显示数值", en: "Value labels" }, default: true },
    {
      key: "chartSide",
      type: "select",
      label: { zh: "图表位置", en: "Chart side" },
      default: "right",
      options: [
        { value: "right", label: { zh: "右侧", en: "Right" } },
        { value: "left", label: { zh: "左侧", en: "Left" } },
      ],
    },
  ],
  build(props, content) {
    const p = content.presentation;
    const kind = propEnum(props, "chartKind", "column", CHART_CHOICES) as ChartKind;
    const right = propEnum(props, "chartSide", "right", ["right", "left"] as const) === "right";
    const spec = itemsAsChart(p.items ?? [], kind, p.summary ?? p.title, {
      showValues: propBool(props, "showValues", true),
    });
    const textCol = right ? 1 : 7;
    const chartCol = right ? 6 : 1;

    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(textCol, 1, 4, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(textCol, 2, 4, 2), p.title, { valign: "top" }),
        p.takeaway && text("takeaway", "body", g(textCol, 5, 4, 3), p.takeaway, { valign: "top" }),
        spec && chart("chart", g(chartCol, 1, 7, 8), spec),
      ]),
    };
  },
};

export const chartFull: Archetype = {
  id: "chart-full",
  name: { zh: "图表主导 · 满幅", en: "Chart-led · full width" },
  family: "chart-led",
  roles: ["trend", "distribution", "comparison"],
  capacity: {
    titleChars: 26,
    takeawayChars: 70,
    items: { min: 3, max: 16 },
    needsValues: true,
  },
  controls: [
    {
      key: "chartKind",
      type: "select",
      label: { zh: "图表类型", en: "Chart type" },
      default: "column",
      options: CHART_CHOICES.map((value) => ({ value, label: { zh: value, en: value } })),
    },
    { key: "showValues", type: "toggle", label: { zh: "显示数值", en: "Value labels" }, default: true },
    { key: "showTakeaway", type: "toggle", label: { zh: "底部结论", en: "Takeaway" }, default: true },
  ],
  build(props, content) {
    const p = content.presentation;
    const kind = propEnum(props, "chartKind", "column", CHART_CHOICES) as ChartKind;
    const showTakeaway = propBool(props, "showTakeaway", true) && !!p.takeaway;
    const spec = itemsAsChart(p.items ?? [], kind, p.summary ?? p.title, {
      showValues: propBool(props, "showValues", true),
    });
    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 9, 1), p.title, { valign: "top" }),
        spec && chart("chart", g(1, 3, 12, showTakeaway ? 5 : 6), spec),
        showTakeaway && text("takeaway", "body", g(1, 8, 11, 1), p.takeaway ?? "", { valign: "middle" }),
      ]),
    };
  },
};

export const comparisonSplit: Archetype = {
  id: "comparison-split",
  name: { zh: "对比 · 双栏", en: "Comparison · split" },
  family: "comparison",
  roles: ["comparison", "case", "risks"],
  capacity: {
    titleChars: 24,
    takeawayChars: 56,
    items: { min: 2, max: 8 },
    itemLabelChars: 22,
    itemDetailChars: 44,
  },
  controls: [
    {
      key: "leftLabel",
      type: "select",
      label: { zh: "左栏标题来源", en: "Left heading" },
      default: "meta",
      options: [
        { value: "meta", label: { zh: "取自 meta.leftLabel", en: "From meta" } },
        { value: "none", label: { zh: "不显示", en: "None" } },
      ],
    },
    { key: "divider", type: "toggle", label: { zh: "中缝分割线", en: "Centre divider" }, default: true },
    {
      key: "style",
      type: "select",
      label: { zh: "条目样式", en: "Item style" },
      default: "rule",
      options: [
        { value: "rule", label: { zh: "分隔线", en: "Ruled" } },
        { value: "card", label: { zh: "卡片", en: "Cards" } },
      ],
    },
  ],
  build(props, content) {
    const p = content.presentation;
    const items = p.items ?? [];
    // Odd counts lean left: the first column is the one people read.
    const half = Math.ceil(items.length / 2);
    const style = propEnum(props, "style", "rule", ["rule", "card"] as const);
    const headings = propEnum(props, "leftLabel", "meta", ["meta", "none"] as const) === "meta";

    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 9, 1), p.title, { valign: "top" }),
        headings &&
          content.meta?.leftLabel &&
          text("leftHead", "subtitle", g(1, 3, 5, 1), content.meta.leftLabel, { valign: "bottom" }),
        headings &&
          content.meta?.rightLabel &&
          text("rightHead", "subtitle", g(7, 3, 5, 1), content.meta.rightLabel, { valign: "bottom" }),
        list("left", g(1, 4, 5, 4), style, itemsAsRows(items.slice(0, half))),
        list("right", g(7, 4, 5, 4), style, itemsAsRows(items.slice(half))),
        propBool(props, "divider", true) && rule("divider", g(6, 4, 1, 4), { vertical: true }),
        p.takeaway && text("takeaway", "body", g(1, 8, 11, 1), p.takeaway, { valign: "middle" }),
      ]),
    };
  },
};
