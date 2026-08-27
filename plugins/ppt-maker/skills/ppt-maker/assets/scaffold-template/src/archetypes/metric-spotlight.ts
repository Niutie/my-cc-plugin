/* ─────────────────────────────────────────────────────────────────────
 * archetypes/metric-spotlight.ts
 *
 * One number carries the page; everything else supports it.
 *
 *   ┌──────────────────────────────────────────────┐
 *   │ KICKER                                       │  r1
 *   │ Title, up to two lines                       │  r2–3
 *   │                                              │
 *   │  1,240        ┆  ▸ secondary                 │  r4–6
 *   │  hero metric  ┆  ▸ secondary                 │
 *   │               ┆  ▸ secondary                 │
 *   │ ──────────────────────────────────────────── │  r7
 *   │ takeaway                                     │  r8
 *   └──────────────────────────────────────────────┘
 *
 * The hero number is items[0]; secondaries are items[1..n] capped by the
 * `secondaryCount` control. Items beyond the cap are NOT dropped
 * silently — the validator rejects the page if a `required` fact falls
 * outside the visible slots.
 * ───────────────────────────────────────────────────────────────────── */

import type { CompileContext } from "../deck/compile";
import type { Composition, Element, SlideContent } from "../deck/types";
import {
  propBool,
  propEnum,
  propNumber,
  type Archetype,
} from "./types";

const ALIGN = ["left", "center"] as const;

export const metricSpotlight: Archetype = {
  id: "metric-spotlight",
  name: { zh: "单数字聚焦", en: "Metric spotlight" },
  family: "metric-spotlight",
  roles: ["metrics", "result", "statement"],

  capacity: {
    titleChars: 28,
    summaryChars: 60,
    takeawayChars: 46,
    items: { min: 1, max: 4 },
    itemLabelChars: 18,
    itemDetailChars: 34,
  },

  controls: [
    {
      key: "secondaryCount",
      type: "range",
      label: { zh: "副指标数量", en: "Secondary metrics" },
      hint: {
        zh: "主数字右侧显示几条副指标。",
        en: "How many supporting metrics sit beside the hero number.",
      },
      default: 3,
      min: 0,
      max: 3,
      step: 1,
      bindsArray: "items",
    },
    {
      key: "align",
      type: "select",
      label: { zh: "对齐方式", en: "Alignment" },
      default: "left",
      options: [
        { value: "left", label: { zh: "左对齐", en: "Left" } },
        { value: "center", label: { zh: "居中", en: "Centred" } },
      ],
    },
    {
      key: "showKicker",
      type: "toggle",
      label: { zh: "显示眉标", en: "Show kicker" },
      default: true,
    },
    {
      key: "showTakeaway",
      type: "toggle",
      label: { zh: "显示结论行", en: "Show takeaway" },
      default: true,
    },
    {
      key: "accentValue",
      type: "toggle",
      label: { zh: "主数字用强调色", en: "Accent the hero number" },
      default: true,
    },
    {
      key: "showRule",
      type: "toggle",
      label: { zh: "结论上方分割线", en: "Rule above takeaway" },
      default: true,
    },
  ],

  build(props, content: SlideContent, _ctx: CompileContext): Composition {
    const p = content.presentation;
    const items = p.items ?? [];
    const hero = items[0];
    const secondaryCount = propNumber(props, "secondaryCount", 3, 0, 3);
    const align = propEnum(props, "align", "left", ALIGN);
    const showKicker = propBool(props, "showKicker", true);
    const showTakeaway = propBool(props, "showTakeaway", true) && !!p.takeaway;
    const accentValue = propBool(props, "accentValue", true);
    const showRule = propBool(props, "showRule", true);

    const secondaries = items.slice(1, 1 + secondaryCount);
    const hasSecondaries = secondaries.length > 0;
    const heroWidth = hasSecondaries ? 6 : 12;

    const elements: Element[] = [];

    if (showKicker) {
      elements.push({
        id: "kicker",
        type: "text",
        role: "kicker",
        grid: { column: 1, row: 1, width: 8, height: 1 },
        text: content.meta?.kicker ?? p.titleShort ?? "",
        align,
        valign: "bottom",
      });
    }

    elements.push({
      id: "title",
      type: "text",
      role: "title",
      grid: { column: 1, row: 2, width: 10, height: 2 },
      text: p.title,
      align,
      valign: "top",
    });

    elements.push({
      id: "hero",
      type: "metric",
      grid: { column: 1, row: 4, width: heroWidth, height: 3 },
      value: hero?.displayValue ?? String(hero?.value ?? ""),
      unit: hero?.unit,
      label: hero?.label,
      detail: hero?.detail,
      align,
      accent: accentValue,
    });

    if (hasSecondaries) {
      elements.push({
        id: "secondaries",
        type: "list",
        style: "rule",
        grid: { column: 8, row: 4, width: 5, height: 3 },
        items: secondaries.map((item, i) => ({
          id: item.id ?? `s${i}`,
          label: item.displayValue ?? String(item.value ?? ""),
          detail: item.label,
        })),
      });
    }

    if (showTakeaway) {
      if (showRule) {
        elements.push({
          id: "rule",
          type: "shape",
          shape: "line",
          stroke: "rule",
          grid: { column: 1, row: 7, width: 12, height: 1 },
        });
      }
      elements.push({
        id: "takeaway",
        type: "text",
        role: "body",
        grid: { column: 1, row: 8, width: 10, height: 1 },
        text: p.takeaway ?? "",
        align,
        valign: "middle",
      });
    }

    return { background: "surface", elements };
  },
};
