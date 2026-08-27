/* ─────────────────────────────────────────────────────────────────────
 * archetypes/openers.ts — cover-hero, cover-split, statement,
 * agenda-numbered, closing.
 *
 * The pages that carry no data. Their whole job is pace: an opener sets
 * the room, a statement stops it, a closing lands it. So they are
 * deliberately sparse — the temptation to fill a cover with three
 * supporting bullets is exactly what makes decks feel like forms.
 * ───────────────────────────────────────────────────────────────────── */

import {
  compact,
  g,
  itemsAsRows,
  list,
  rule,
  shape,
  text,
} from "./build";
import { propBool, propEnum, propNumber, type Archetype } from "./types";

const ALIGN = ["left", "center"] as const;

export const coverHero: Archetype = {
  id: "cover-hero",
  name: { zh: "封面 · 大标题", en: "Cover · hero" },
  family: "hero",
  roles: ["cover"],
  capacity: { titleChars: 34, summaryChars: 52, takeawayChars: 60, items: { min: 0, max: 0 } },
  controls: [
    {
      key: "align",
      type: "select",
      label: { zh: "对齐", en: "Alignment" },
      default: "left",
      options: [
        { value: "left", label: { zh: "左对齐", en: "Left" } },
        { value: "center", label: { zh: "居中", en: "Centred" } },
      ],
    },
    { key: "showKicker", type: "toggle", label: { zh: "显示眉标", en: "Kicker" }, default: true },
    { key: "showTakeaway", type: "toggle", label: { zh: "显示结论行", en: "Takeaway" }, default: true },
    { key: "showRule", type: "toggle", label: { zh: "强调分割线", en: "Accent rule" }, default: true },
  ],
  build(props, content) {
    const p = content.presentation;
    const align = propEnum(props, "align", "left", ALIGN);
    const showTakeaway = propBool(props, "showTakeaway", true) && !!p.takeaway;
    return {
      background: "surface",
      elements: compact([
        propBool(props, "showKicker", true) &&
          text("kicker", "kicker", g(1, 1, 8, 1), content.meta?.kicker ?? "", {
            align,
            valign: "bottom",
          }),
        text("title", "title", g(1, 2, 10, 2), p.title, { align, valign: "top" }),
        p.summary &&
          text("summary", "subtitle", g(1, 4, 8, 1), p.summary, { align, valign: "top" }),
        showTakeaway && propBool(props, "showRule", true) && rule("rule", g(1, 7, 4, 1), { accent: true }),
        showTakeaway &&
          text("takeaway", "body", g(1, 8, 9, 1), p.takeaway ?? "", {
            align,
            valign: "middle",
          }),
      ]),
    };
  },
};

export const coverSplit: Archetype = {
  id: "cover-split",
  name: { zh: "封面 · 左右分屏", en: "Cover · split" },
  family: "split",
  roles: ["cover", "statement"],
  capacity: { titleChars: 26, summaryChars: 46, takeawayChars: 48, items: { min: 0, max: 0 } },
  controls: [
    {
      key: "panelSide",
      type: "select",
      label: { zh: "色块位置", en: "Panel side" },
      default: "right",
      options: [
        { value: "right", label: { zh: "右侧", en: "Right" } },
        { value: "left", label: { zh: "左侧", en: "Left" } },
      ],
    },
    {
      key: "panelFill",
      type: "select",
      label: { zh: "色块填充", en: "Panel fill" },
      default: "accent",
      options: [
        { value: "accent", label: { zh: "强调色", en: "Accent" } },
        { value: "surface-2", label: { zh: "浅底", en: "Tint" } },
      ],
    },
  ],
  build(props, content) {
    const p = content.presentation;
    const right = propEnum(props, "panelSide", "right", ["right", "left"] as const) === "right";
    const fill = propEnum(props, "panelFill", "accent", ["accent", "surface-2"] as const);
    // The panel bleeds to the frame edge; the text column keeps the
    // stage padding. That asymmetry is the whole point of a split cover.
    const panel = right ? g(7, 1, 6, 8) : g(1, 1, 6, 8);
    const textCol = right ? 1 : 7;
    return {
      background: "surface",
      elements: compact([
        shape("panel", panel, { fill, bleed: true }),
        text("kicker", "kicker", g(textCol, 2, 5, 1), content.meta?.kicker ?? "", {
          valign: "bottom",
        }),
        text("title", "title", g(textCol, 3, 5, 2), p.title, { valign: "top" }),
        p.summary && text("summary", "subtitle", g(textCol, 5, 5, 1), p.summary, { valign: "top" }),
        p.takeaway && text("takeaway", "body", g(textCol, 7, 5, 1), p.takeaway, { valign: "top" }),
      ]),
    };
  },
};

export const statement: Archetype = {
  id: "statement",
  name: { zh: "金句 · 单句主张", en: "Statement" },
  family: "hero",
  roles: ["statement", "result", "closing"],
  capacity: { titleChars: 60, summaryChars: 40, items: { min: 0, max: 0 } },
  controls: [
    { key: "attribute", type: "toggle", label: { zh: "显示出处", en: "Attribution" }, default: true },
    {
      key: "align",
      type: "select",
      label: { zh: "对齐", en: "Alignment" },
      default: "left",
      options: [
        { value: "left", label: { zh: "左对齐", en: "Left" } },
        { value: "center", label: { zh: "居中", en: "Centred" } },
      ],
    },
  ],
  build(props, content) {
    const p = content.presentation;
    const align = propEnum(props, "align", "left", ALIGN);
    return {
      background: "surface",
      elements: compact([
        text("quote", "quote", g(1, 3, 10, 3), p.title, { align, valign: "middle" }),
        propBool(props, "attribute", true) &&
          p.summary &&
          text("attribution", "caption", g(1, 6, 6, 1), p.summary, { align, valign: "top" }),
      ]),
    };
  },
};

export const agendaNumbered: Archetype = {
  id: "agenda-numbered",
  name: { zh: "目录 · 编号列表", en: "Agenda · numbered" },
  family: "editorial",
  roles: ["agenda"],
  capacity: {
    titleChars: 24,
    items: { min: 2, max: 8 },
    itemLabelChars: 26,
    itemDetailChars: 40,
  },
  controls: [
    {
      key: "columns",
      type: "range",
      label: { zh: "分栏", en: "Columns" },
      default: 1,
      min: 1,
      max: 2,
      step: 1,
    },
    {
      key: "visibleCount",
      type: "range",
      label: { zh: "显示条目", en: "Visible items" },
      default: 6,
      min: 2,
      max: 8,
      step: 1,
      bindsArray: "items",
    },
    { key: "showDetail", type: "toggle", label: { zh: "显示说明", en: "Show detail" }, default: true },
  ],
  build(props, content) {
    const p = content.presentation;
    const columns = propNumber(props, "columns", 1, 1, 2);
    const visible = propNumber(props, "visibleCount", 6, 2, 8);
    const showDetail = propBool(props, "showDetail", true);
    const rows = itemsAsRows((p.items ?? []).slice(0, visible)).map((r) =>
      showDetail ? r : { ...r, detail: undefined },
    );
    return {
      background: "surface",
      elements: compact([
        text("kicker", "kicker", g(1, 1, 6, 1), content.meta?.kicker ?? "", { valign: "bottom" }),
        text("title", "title", g(1, 2, 8, 1), p.title, { valign: "top" }),
        list("items", g(1, 3, 12, 6), "numbered", rows, columns),
      ]),
    };
  },
};

export const closing: Archetype = {
  id: "closing",
  name: { zh: "结尾页", en: "Closing" },
  family: "hero",
  roles: ["closing", "actions"],
  capacity: { titleChars: 30, takeawayChars: 60, items: { min: 0, max: 3 }, itemLabelChars: 22 },
  controls: [
    {
      key: "visibleCount",
      type: "range",
      label: { zh: "下一步条数", en: "Next steps" },
      default: 3,
      min: 0,
      max: 3,
      step: 1,
      bindsArray: "items",
    },
  ],
  build(props, content) {
    const p = content.presentation;
    const visible = propNumber(props, "visibleCount", 3, 0, 3);
    const rows = itemsAsRows((p.items ?? []).slice(0, visible));
    return {
      background: "surface",
      elements: compact([
        text("title", "title", g(1, 3, 9, 2), p.title, { valign: "middle" }),
        p.takeaway && text("takeaway", "subtitle", g(1, 5, 8, 1), p.takeaway, { valign: "top" }),
        rows.length > 0 && rule("rule", g(1, 6, 12, 1)),
        rows.length > 0 && list("next", g(1, 7, 12, 2), "rule", rows, rows.length),
      ]),
    };
  },
};
