#!/usr/bin/env tsx
/* ─────────────────────────────────────────────────────────────────────
 * export-pptx.ts — deck.json → editable .pptx
 *
 * This is the second renderer. It imports the SAME compile step, the
 * SAME grid placement and the SAME sub-element geometry the browser
 * uses, then converts stage px to inches at 144 px/inch. It never
 * inspects rendered HTML — there is no DOM walker here, and there must
 * never be one.
 *
 * Charts export as NATIVE PowerPoint charts where an equivalent exists,
 * so the recipient can open the data sheet and edit the numbers. The
 * value axis is pinned to the same min/max the SVG computed, so the
 * two renderings read the same even though PowerPoint draws its own
 * bars.
 *
 * Usage:
 *   npm run export:pptx                        → dist/deck.pptx
 *   npm run export:pptx -- --out out/deck.pptx
 *   npm run export:pptx -- --mode=comparison   → every variant, 4N pages
 * ───────────────────────────────────────────────────────────────────── */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import PptxGenJS from "pptxgenjs";

import {
  paintHex,
  pathBounds,
  type Primitive,
} from "../src/charts/primitives";
import { chartDef, exportsNative } from "../src/charts/registry";
import { listRows, metricBlocks } from "../src/deck/blocks";
import { compileVariant } from "../src/deck/compile";
import {
  PPTX_LAYOUT,
  elementRect,
  toIn,
  type Padding,
  type Rect,
} from "../src/deck/layout";
import {
  DEFAULT_PPTX_FONTS,
  fontSet,
  parseThemeTokens,
  type FontSet,
  type PptxFonts,
  type ThemeTokens,
} from "../src/deck/theme";
import { LIST, METRIC, TYPE, pxToPt } from "../src/deck/typography";
import type {
  ChartEl,
  Composition,
  Deck,
  Element,
  ListEl,
  MetricEl,
  ShapeEl,
  TextEl,
} from "../src/deck/types";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");

/* ── CLI ─────────────────────────────────────────────────────────── */

interface Options {
  out: string;
  mode: "selected" | "comparison";
}

function parseArgs(argv: string[]): Options {
  const opts: Options = { out: "dist/deck.pptx", mode: "selected" };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--out") opts.out = argv[++i] ?? opts.out;
    else if (arg.startsWith("--out=")) opts.out = arg.slice(6);
    else if (arg.startsWith("--mode=")) {
      const mode = arg.slice(7);
      if (mode !== "selected" && mode !== "comparison") {
        throw new Error(`--mode must be selected|comparison, got "${mode}"`);
      }
      opts.mode = mode;
    }
  }
  return opts;
}

/* ── theme ───────────────────────────────────────────────────────── */

function loadTheme(deck: Deck): ThemeTokens {
  const cssPath = path.join(ROOT, "src/styles/tokens.css");
  if (!fs.existsSync(cssPath)) {
    throw new Error(`missing ${cssPath} — run the scaffold with a theme`);
  }
  const css = fs.readFileSync(cssPath, "utf8");

  let fonts: PptxFonts = DEFAULT_PPTX_FONTS;
  const metaPath = path.join(ROOT, "src/styles/theme.json");
  if (fs.existsSync(metaPath)) {
    const meta = JSON.parse(fs.readFileSync(metaPath, "utf8")) as {
      pptxFonts?: Partial<PptxFonts>;
    };
    // PowerPoint does not embed fonts. A theme declares what a normal
    // Office install can actually resolve; anything it omits falls back
    // to a family that ships with Office everywhere.
    fonts = { ...DEFAULT_PPTX_FONTS, ...(meta.pptxFonts ?? {}) };
  }

  // tokens.css on disk is what actually renders. If deck.meta.theme
  // disagrees with .theme, the deck is mislabelled — say so instead of
  // silently exporting under the wrong name.
  const installedPath = path.join(ROOT, ".theme");
  const installed = fs.existsSync(installedPath)
    ? fs.readFileSync(installedPath, "utf8").trim()
    : deck.meta.theme;
  if (installed !== deck.meta.theme) {
    console.warn(
      `! deck.meta.theme is "${deck.meta.theme}" but "${installed}" is installed in src/styles/.\n` +
        `  Rendering with "${installed}". Fix deck.meta.theme, or reinstall the theme you meant.`,
    );
  }

  return parseThemeTokens(installed, css, fonts);
}

/**
 * pptxgenjs supports custom geometry at runtime (CUSTOM_GEOMETRY =
 * "custGeom") but its SHAPE_NAME union omits it. Narrowed here once,
 * with the reason, rather than casting at each call site.
 */
const CUST_GEOM = "custGeom" as Parameters<Slide["addShape"]>[0];

/** pptxgenjs wants bare hex digits. */
function hex(color: string): string {
  return color.replace(/^#/, "").toUpperCase();
}

/* ── element writers ─────────────────────────────────────────────── */

type Slide = ReturnType<PptxGenJS["addSlide"]>;

interface Ctx {
  pres: PptxGenJS;
  slide: Slide;
  theme: ThemeTokens;
  padding: Padding;
  /** Font families resolved for the deck's language. */
  fonts: FontSet;
}

function box(rect: Rect) {
  return { x: toIn(rect.x), y: toIn(rect.y), w: toIn(rect.w), h: toIn(rect.h) };
}

function fontFor(ctx: Ctx, family: "display" | "body" | "mono"): string {
  return ctx.fonts[family];
}

function writeText(ctx: Ctx, el: TextEl, rect: Rect): void {
  const spec = TYPE[el.role];
  const text = spec.uppercase ? el.text.toUpperCase() : el.text;
  if (!text) return;

  // Display roles honour the theme's weight knob. PowerPoint text runs
  // are bold-or-not, so a 200-weight theme lands on "not bold" — the
  // closest PowerPoint can get to extra-light.
  const weight =
    el.role === "title" || el.role === "quote"
      ? (ctx.theme.titleWeight ?? spec.weight)
      : spec.weight;

  ctx.slide.addText(text, {
    ...box(rect),
    fontFace: fontFor(ctx, spec.family),
    fontSize: pxToPt(spec.sizePx),
    bold: weight >= 600,
    color: hex(el.accent ? ctx.theme.accent : colorToken(ctx.theme, spec.color)),
    align: el.align ?? "left",
    valign: el.valign === "middle" ? "middle" : el.valign === "bottom" ? "bottom" : "top",
    // Tracking is an em fraction on screen; PowerPoint wants points.
    charSpacing: spec.tracking * pxToPt(spec.sizePx),
    lineSpacing: spec.lineHeight * pxToPt(spec.sizePx),
    margin: 0,
    wrap: true,
  });
}

function colorToken(
  theme: ThemeTokens,
  role: "text" | "text-2" | "text-mute",
): string {
  if (role === "text") return theme.text;
  if (role === "text-2") return theme.text2;
  return theme.textMute;
}

function writeMetric(ctx: Ctx, el: MetricEl, rect: Rect): void {
  const blocks = metricBlocks(el, rect);
  const align = el.align ?? "left";

  if (blocks.label && el.label) {
    ctx.slide.addText(el.label.toUpperCase(), {
      ...box(blocks.label),
      fontFace: fontFor(ctx, "mono"),
      fontSize: pxToPt(METRIC.label.sizePx),
      color: hex(ctx.theme.textMute),
      charSpacing: METRIC.label.tracking * pxToPt(METRIC.label.sizePx),
      align,
      valign: "middle",
      margin: 0,
    });
  }

  // The unit rides the number as a smaller run in the same paragraph, so
  // the baseline stays shared exactly as it does in the browser.
  const runs: PptxGenJS.TextProps[] = [
    {
      text: el.value,
      options: { fontSize: pxToPt(blocks.valueSize) },
    },
  ];
  if (el.unit) {
    runs.push({
      text: el.unit,
      options: { fontSize: pxToPt(blocks.unitSize) },
    });
  }

  ctx.slide.addText(runs, {
    ...box(blocks.value),
    fontFace: fontFor(ctx, "display"),
    bold: (ctx.theme.heroNumWeight ?? METRIC.value.weight) >= 600,
    color: hex(el.accent ? ctx.theme.accent : ctx.theme.text),
    charSpacing: METRIC.value.tracking * pxToPt(blocks.valueSize),
    align,
    valign: "middle",
    margin: 0,
    wrap: false,
  });

  if (blocks.detail && el.detail) {
    ctx.slide.addText(el.detail, {
      ...box(blocks.detail),
      fontFace: fontFor(ctx, "body"),
      fontSize: pxToPt(METRIC.detail.sizePx),
      color: hex(ctx.theme.textMute),
      lineSpacing: METRIC.detail.lineHeight * pxToPt(METRIC.detail.sizePx),
      align,
      valign: "top",
      margin: 0,
      wrap: true,
    });
  }
}

function writeList(ctx: Ctx, el: ListEl, rect: Rect): void {
  for (const row of listRows(el, rect)) {
    const item = el.items[row.index];

    if (el.style === "card") {
      ctx.slide.addShape("rect", {
        ...box(row.box),
        fill: { color: hex(ctx.theme.surface2) },
        line: { type: "none" },
        rectRadius: ctx.theme.radiusCard > 0 ? toIn(ctx.theme.radiusCard) : undefined,
      });
    }
    if (el.style === "rule") {
      ctx.slide.addShape("line", {
        ...box({ ...row.box, h: 0 }),
        line: { color: hex(ctx.theme.rule), width: ctx.theme.ruleWidth },
      });
    }
    if (row.marker) {
      ctx.slide.addText(
        el.style === "numbered" ? String(row.index + 1).padStart(2, "0") : "•",
        {
          ...box(row.marker),
          fontFace: fontFor(ctx, "mono"),
          fontSize: pxToPt(LIST.label.sizePx),
          color: hex(ctx.theme.accent),
          valign: "middle",
          margin: 0,
        },
      );
    }

    ctx.slide.addText(item.label, {
      ...box(row.label),
      fontFace: fontFor(ctx, "display"),
      fontSize: pxToPt(LIST.label.sizePx),
      bold: LIST.label.weight >= 600,
      color: hex(ctx.theme.text),
      valign: "middle",
      margin: 0,
    });

    if (row.detail && item.detail) {
      ctx.slide.addText(item.detail, {
        ...box(row.detail),
        fontFace: fontFor(ctx, "body"),
        fontSize: pxToPt(LIST.detail.sizePx),
        color: hex(ctx.theme.textMute),
        valign: "middle",
        margin: 0,
      });
    }
  }
}

function writeShape(ctx: Ctx, el: ShapeEl, rect: Rect): void {
  const stroke =
    el.stroke === "accent"
      ? ctx.theme.accent
      : el.stroke === "rule"
        ? ctx.theme.rule
        : null;

  if (el.shape === "line") {
    const seg =
      el.orient === "vertical"
        ? { x: rect.x + rect.w / 2, y: rect.y, w: 0, h: rect.h }
        : { ...rect, h: 0 };
    ctx.slide.addShape("line", {
      ...box(seg),
      line: {
        color: hex(stroke ?? ctx.theme.rule),
        width: ctx.theme.ruleWidth,
      },
    });
    return;
  }

  const fillMap: Record<string, string> = {
    surface: ctx.theme.surface,
    "surface-2": ctx.theme.surface2,
    shell: ctx.theme.shell,
    accent: ctx.theme.accent,
    "accent-soft": ctx.theme.accentSoft,
  };
  const fill = el.fill && el.fill !== "none" ? fillMap[el.fill] : null;

  // The DSL's shape names are PowerPoint preset geometry names, so this
  // is a pass-through rather than a mapping table that can go stale.
  ctx.slide.addShape(el.shape, {
    ...box(rect),
    fill: fill ? { color: hex(fill) } : { type: "none" },
    line: stroke
      ? { color: hex(stroke), width: ctx.theme.ruleWidth }
      : { type: "none" },
    rectRadius:
      el.shape === "rect" && ctx.theme.radiusCard > 0
        ? toIn(ctx.theme.radiusCard)
        : undefined,
  });
}

function writeChart(ctx: Ctx, el: ChartEl, rect: Rect): void {
  if (exportsNative(el.chart)) writeNativeChart(ctx, el, rect);
  else writeVectorChart(ctx, el, rect);

  if (el.caption) {
    ctx.slide.addText(el.caption, {
      x: toIn(rect.x),
      y: toIn(rect.y + rect.h),
      w: toIn(rect.w),
      h: toIn(24),
      fontFace: fontFor(ctx, "body"),
      fontSize: pxToPt(15),
      color: hex(ctx.theme.textMute),
      margin: 0,
    });
  }
}

/** A real PowerPoint chart — the recipient can edit the numbers. */
function writeNativeChart(ctx: Ctx, el: ChartEl, rect: Rect): void {
  const spec = el.chart;
  const def = chartDef(spec.kind);
  const native = def.native!;
  // Pin PowerPoint's value axis to the range the SVG settled on, so the
  // two renderings read at the same proportions even though PowerPoint
  // draws the marks itself.
  const axis = def.build(spec, rect).axis;

  const data = spec.series.map((series) => ({
    name: series.name,
    labels: spec.categories,
    values: series.data.map((v) => (typeof v === "number" ? v : null)),
  }));

  ctx.slide.addChart(native.type, data, {
    ...box(rect),
    ...(native.opts ?? {}),
    ...(axis ? { valAxisMinVal: axis.min, valAxisMaxVal: axis.max } : {}),
    chartColors: spec.series.map((_, i) =>
      hex(ctx.theme.chart.series[i % ctx.theme.chart.series.length]),
    ),
    showValue: Boolean(spec.showValues),
    dataLabelColor: hex(ctx.theme.text),
    dataLabelFontFace: fontFor(ctx, "mono"),
    dataLabelFontSize: pxToPt(17),
    showLegend: Boolean(spec.legend),
    legendPos: "b",
    legendColor: hex(ctx.theme.textMute),
    legendFontFace: fontFor(ctx, "body"),
    legendFontSize: pxToPt(16),
    catAxisLabelColor: hex(ctx.theme.chart.label),
    catAxisLabelFontFace: fontFor(ctx, "body"),
    catAxisLabelFontSize: pxToPt(16),
    catAxisLineShow: false,
    valAxisLabelColor: hex(ctx.theme.chart.label),
    valAxisLabelFontFace: fontFor(ctx, "mono"),
    valAxisLabelFontSize: pxToPt(16),
    valAxisLineShow: false,
    valGridLine: { color: hex(ctx.theme.chart.grid), style: "solid", size: 1 },
    catGridLine: { style: "none" },
    border: { pt: 0, color: hex(ctx.theme.surface) },
    fill: hex(ctx.theme.surface),
  });
}

/** Real PowerPoint shapes, identical to the SVG. Used for the kinds
 *  PowerPoint has no chart object for. */
function writeVectorChart(ctx: Ctx, el: ChartEl, rect: Rect): void {
  for (const prim of chartDef(el.chart.kind).build(el.chart, rect).primitives) {
    writePrimitive(ctx, prim);
  }
}

function writePrimitive(ctx: Ctx, prim: Primitive): void {
  const fill = (p: Primitive & { fill?: unknown; opacity?: number }) => {
    const f = (p as { fill?: Parameters<typeof paintHex>[0] }).fill;
    if (!f) return { type: "none" as const };
    return {
      color: hex(paintHex(f, ctx.theme)),
      // PowerPoint speaks transparency, not opacity.
      ...(p.opacity !== undefined
        ? { transparency: Math.round((1 - p.opacity) * 100) }
        : {}),
    };
  };
  const stroke = (p: { stroke?: Parameters<typeof paintHex>[0]; strokeW?: number }) =>
    p.stroke
      ? { color: hex(paintHex(p.stroke, ctx.theme)), width: p.strokeW ?? 1 }
      : { type: "none" as const };

  switch (prim.kind) {
    case "rect":
      ctx.slide.addShape("rect", {
        ...box(prim),
        fill: fill(prim),
        line: stroke(prim),
        ...(prim.radius
          ? { rectRadius: Math.min(0.5, prim.radius / Math.max(prim.w, prim.h)) }
          : {}),
      });
      return;

    case "ellipse":
      ctx.slide.addShape("ellipse", {
        ...box(prim),
        fill: fill(prim),
        line: stroke(prim),
      });
      return;

    case "line":
      ctx.slide.addShape("line", {
        x: toIn(Math.min(prim.x1, prim.x2)),
        y: toIn(Math.min(prim.y1, prim.y2)),
        w: toIn(Math.abs(prim.x2 - prim.x1)),
        h: toIn(Math.abs(prim.y2 - prim.y1)),
        line: {
          color: hex(paintHex(prim.stroke, ctx.theme)),
          width: prim.strokeW ?? 1,
          ...(prim.dash ? { dashType: "dash" as const } : {}),
        },
      });
      return;

    case "path": {
      // custGeom points are relative to the shape's own frame, so the
      // path is placed at its bounding box and rebased into it.
      const b = pathBounds(prim.pts);
      ctx.slide.addShape(CUST_GEOM, {
        x: toIn(b.x),
        y: toIn(b.y),
        w: toIn(Math.max(b.w, 1)),
        h: toIn(Math.max(b.h, 1)),
        fill: fill(prim),
        line: stroke(prim),
        points: [
          ...prim.pts.map((pt) =>
            pt.curve
              ? {
                  x: toIn(pt.x - b.x),
                  y: toIn(pt.y - b.y),
                  curve: {
                    type: "cubic" as const,
                    x1: toIn(pt.curve.x1 - b.x),
                    y1: toIn(pt.curve.y1 - b.y),
                    x2: toIn(pt.curve.x2 - b.x),
                    y2: toIn(pt.curve.y2 - b.y),
                  },
                }
              : {
                  x: toIn(pt.x - b.x),
                  y: toIn(pt.y - b.y),
                  ...(pt.move ? { moveTo: true } : {}),
                },
          ),
          ...(prim.close ? [{ close: true as const }] : []),
        ],
      });
      return;
    }

    case "text":
      ctx.slide.addText(prim.text, {
        ...box(prim),
        fontFace: fontFor(ctx, prim.family ?? "body"),
        fontSize: pxToPt(prim.sizePx),
        bold: (prim.weight ?? 400) >= 600,
        color: hex(paintHex(prim.color, ctx.theme)),
        align: prim.align ?? "left",
        valign: prim.valign ?? "middle",
        rotate: prim.rotate,
        margin: 0,
        wrap: false,
      });
      return;
  }
}

function writeElement(ctx: Ctx, el: Element): void {
  const rect = elementRect(el, ctx.padding);
  switch (el.type) {
    case "text":
      return writeText(ctx, el, rect);
    case "metric":
      return writeMetric(ctx, el, rect);
    case "list":
      return writeList(ctx, el, rect);
    case "shape":
      return writeShape(ctx, el, rect);
    case "chart":
      return writeChart(ctx, el, rect);
  }
}

function backgroundColor(theme: ThemeTokens, composition: Composition): string {
  switch (composition.background) {
    case "surface-2":
      return theme.surface2;
    case "shell":
      return theme.shell;
    case "accent":
      return theme.accent;
    default:
      return theme.surface;
  }
}

/* ── main ────────────────────────────────────────────────────────── */

async function main(): Promise<void> {
  const opts = parseArgs(process.argv.slice(2));

  const deckPath = path.join(ROOT, "deck.json");
  const deck = JSON.parse(fs.readFileSync(deckPath, "utf8")) as Deck;
  const theme = loadTheme(deck);
  const padding: Padding = { x: theme.padX, y: theme.padY };

  const pres = new PptxGenJS();
  pres.defineLayout(PPTX_LAYOUT);
  pres.layout = PPTX_LAYOUT.name;
  pres.title = deck.meta.title;
  if (deck.meta.owner) pres.author = deck.meta.owner;

  let pageCount = 0;
  for (const slide of deck.slides) {
    const variants =
      opts.mode === "comparison"
        ? slide.variants
        : slide.variants.filter((v) => v.id === slide.selectedVariant);

    for (const variant of variants.length ? variants : slide.variants.slice(0, 1)) {
      const composition = compileVariant(variant, slide.content, {
        lang: deck.meta.lang,
      });
      const pptxSlide = pres.addSlide();
      pptxSlide.background = { color: hex(backgroundColor(theme, composition)) };

      const ctx: Ctx = {
        pres,
        slide: pptxSlide,
        theme,
        padding,
        fonts: fontSet(theme.pptxFonts, deck.meta.lang),
      };
      for (const el of composition.elements) {
        writeElement(ctx, el);
      }
      pageCount += 1;
    }
  }

  const outPath = path.isAbsolute(opts.out)
    ? opts.out
    : path.join(ROOT, opts.out);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  await pres.writeFile({ fileName: outPath });

  console.log(
    `✓ ${outPath}\n  ${pageCount} pages · theme ${theme.id} · mode ${opts.mode}` +
      `\n  stage ${PPTX_LAYOUT.width}in × ${PPTX_LAYOUT.height}in · padding ${padding.x}×${padding.y}px`,
  );
}

main().catch((error) => {
  console.error(`✗ export failed: ${error?.message ?? error}`);
  process.exit(1);
});
