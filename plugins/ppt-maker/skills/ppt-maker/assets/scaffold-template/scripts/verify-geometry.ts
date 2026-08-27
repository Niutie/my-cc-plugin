#!/usr/bin/env tsx
/* ─────────────────────────────────────────────────────────────────────
 * verify-geometry.ts — proves the two renderers agree.
 *
 * The whole architecture rests on one claim: the HTML deck and the
 * exported .pptx place every box in the same spot. This script tests
 * that claim mechanically instead of trusting it.
 *
 * It re-derives, INDEPENDENTLY of the exporter, where each element and
 * sub-element must land — using the same shared geometry the browser
 * uses — converts to EMU, then unzips the .pptx and checks each
 * expected box actually exists in the slide XML. An independent oracle
 * catches "the exporter used the wrong rect", which a shared helper
 * called from both sides would happily agree about.
 *
 *   npm run export:pptx && npm run verify:geometry
 * ───────────────────────────────────────────────────────────────────── */

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { pathBounds, type Primitive } from "../src/charts/primitives";
import { chartDef, exportsNative } from "../src/charts/registry";
import { listRows, metricBlocks } from "../src/deck/blocks";
import { compileVariant } from "../src/deck/compile";
import {
  EMU_PER_INCH,
  FRAME,
  PPTX_LAYOUT,
  elementRect,
  toEmu,
  type Padding,
  type Rect,
} from "../src/deck/layout";
import { parseThemeTokens } from "../src/deck/theme";
import type { Composition, Deck } from "../src/deck/types";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");

/** EMU slack. 2 EMU is 1/457200 inch — far below any rounding that matters. */
const TOLERANCE = 2;

interface Expected {
  label: string;
  rect: Rect;
}

/* ── independent re-derivation of what must be on the slide ──────── */

function expectedBoxes(composition: Composition, padding: Padding): Expected[] {
  const out: Expected[] = [];

  for (const el of composition.elements) {
    const rect = elementRect(el, padding);

    switch (el.type) {
      case "text":
        if (el.text) out.push({ label: `${el.id}:text`, rect });
        break;

      case "shape":
        out.push({
          label: `${el.id}:shape`,
          rect:
            el.shape !== "line"
              ? rect
              : el.orient === "vertical"
                ? { x: rect.x + rect.w / 2, y: rect.y, w: 0, h: rect.h }
                : { ...rect, h: 0 },
        });
        break;

      case "chart":
        if (exportsNative(el.chart)) {
          // One graphicFrame at the element's box; PowerPoint draws the
          // insides, so the frame is all there is to check.
          out.push({ label: `${el.id}:chart`, rect });
        } else {
          // A vector chart is dozens of real shapes. Check every one —
          // this is the path with no native safety net, so it is the one
          // that most needs proving.
          const build = chartDef(el.chart.kind).build(el.chart, rect);
          build.primitives.forEach((prim, i) => {
            const b = primitiveBox(prim);
            if (b) out.push({ label: `${el.id}:${prim.kind}${i}`, rect: b });
          });
        }
        break;

      case "metric": {
        const blocks = metricBlocks(el, rect);
        if (blocks.label && el.label) {
          out.push({ label: `${el.id}:metric.label`, rect: blocks.label });
        }
        out.push({ label: `${el.id}:metric.value`, rect: blocks.value });
        if (blocks.detail && el.detail) {
          out.push({ label: `${el.id}:metric.detail`, rect: blocks.detail });
        }
        break;
      }

      case "list": {
        for (const row of listRows(el, rect)) {
          const item = el.items[row.index];
          if (el.style === "card") {
            out.push({ label: `${el.id}:card${row.index}`, rect: row.box });
          }
          if (el.style === "rule") {
            out.push({
              label: `${el.id}:rule${row.index}`,
              rect: { ...row.box, h: 0 },
            });
          }
          if (row.marker) {
            out.push({ label: `${el.id}:marker${row.index}`, rect: row.marker });
          }
          out.push({ label: `${el.id}:label${row.index}`, rect: row.label });
          if (row.detail && item.detail) {
            out.push({
              label: `${el.id}:detail${row.index}`,
              rect: row.detail,
            });
          }
        }
        break;
      }
    }
  }

  return out;
}

/** Where a chart primitive must land, mirroring the exporter's mapping. */
function primitiveBox(prim: Primitive): Rect | null {
  switch (prim.kind) {
    case "rect":
    case "ellipse":
    case "text":
      return { x: prim.x, y: prim.y, w: prim.w, h: prim.h };
    case "line":
      return {
        x: Math.min(prim.x1, prim.x2),
        y: Math.min(prim.y1, prim.y2),
        w: Math.abs(prim.x2 - prim.x1),
        h: Math.abs(prim.y2 - prim.y1),
      };
    case "path": {
      const b = pathBounds(prim.pts);
      return { x: b.x, y: b.y, w: Math.max(b.w, 1), h: Math.max(b.h, 1) };
    }
  }
}

/* ── read the .pptx back ─────────────────────────────────────────── */

interface XmlBox {
  x: number;
  y: number;
  cx: number;
  cy: number;
}

function unzip(file: string, entry: string): string {
  return execFileSync("unzip", ["-p", file, entry], {
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  });
}

function listEntries(file: string): string[] {
  const out = execFileSync("unzip", ["-Z1", file], { encoding: "utf8" });
  return out.split("\n").filter(Boolean);
}

/** Every `<a:off …/><a:ext …/>` pair in the slide, in document order. */
function readBoxes(xml: string): XmlBox[] {
  // <p:grpSpPr> carries the shape tree's own 0×0 transform. It is not a
  // shape, and counting it makes every slide look like it has one more
  // box than it does.
  xml = xml.replace(/<p:grpSpPr>[\s\S]*?<\/p:grpSpPr>/g, "");
  const boxes: XmlBox[] = [];
  const re =
    /<a:off\s+x="(-?\d+)"\s+y="(-?\d+)"\s*\/>\s*<a:ext\s+cx="(\d+)"\s+cy="(\d+)"\s*\/>/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml))) {
    boxes.push({
      x: Number(m[1]),
      y: Number(m[2]),
      cx: Number(m[3]),
      cy: Number(m[4]),
    });
  }
  return boxes;
}

function near(a: number, b: number): boolean {
  return Math.abs(a - b) <= TOLERANCE;
}

function findBox(boxes: XmlBox[], rect: Rect): XmlBox | undefined {
  return boxes.find(
    (b) =>
      near(b.x, toEmu(rect.x)) &&
      near(b.y, toEmu(rect.y)) &&
      near(b.cx, toEmu(rect.w)) &&
      near(b.cy, toEmu(rect.h)),
  );
}

/* ── main ────────────────────────────────────────────────────────── */

function main(): void {
  const pptxPath = path.join(
    ROOT,
    process.argv[2] ?? "dist/deck.pptx",
  );
  if (!fs.existsSync(pptxPath)) {
    throw new Error(`${pptxPath} not found — run npm run export:pptx first`);
  }

  const deck = JSON.parse(
    fs.readFileSync(path.join(ROOT, "deck.json"), "utf8"),
  ) as Deck;
  const theme = parseThemeTokens(
    deck.meta.theme,
    fs.readFileSync(path.join(ROOT, "src/styles/tokens.css"), "utf8"),
  );
  const padding: Padding = { x: theme.padX, y: theme.padY };

  let failures = 0;
  let checked = 0;

  /* 1. slide size */
  const presXml = unzip(pptxPath, "ppt/presentation.xml");
  const size = presXml.match(/<p:sldSz\s+cx="(\d+)"\s+cy="(\d+)"/);
  const wantCx = Math.round(PPTX_LAYOUT.width * EMU_PER_INCH);
  const wantCy = Math.round(PPTX_LAYOUT.height * EMU_PER_INCH);
  if (!size) {
    console.error("✗ presentation.xml has no <p:sldSz>");
    failures += 1;
  } else if (!near(Number(size[1]), wantCx) || !near(Number(size[2]), wantCy)) {
    console.error(
      `✗ slide size ${size[1]}×${size[2]} EMU, expected ${wantCx}×${wantCy}`,
    );
    failures += 1;
  } else {
    console.log(
      `✓ slide size ${size[1]}×${size[2]} EMU  (${FRAME.w}×${FRAME.h} px @ 144 dpi)`,
    );
  }

  /* 2. per-slide element geometry */
  const entries = listEntries(pptxPath).filter((e) =>
    /^ppt\/slides\/slide\d+\.xml$/.test(e),
  );
  entries.sort(
    (a, b) => Number(a.match(/\d+/)![0]) - Number(b.match(/\d+/)![0]),
  );

  const selected = deck.slides.map((slide) => {
    const variant =
      slide.variants.find((v) => v.id === slide.selectedVariant) ??
      slide.variants[0];
    return { slide, variant };
  });

  if (entries.length !== selected.length) {
    console.error(
      `✗ ${entries.length} slides in the .pptx, ${selected.length} in deck.json`,
    );
    failures += 1;
  }

  selected.forEach(({ slide, variant }, i) => {
    const entry = entries[i];
    if (!entry) return;

    const composition = compileVariant(variant, slide.content, {
      lang: deck.meta.lang,
    });
    const expected = expectedBoxes(composition, padding);
    const boxes = readBoxes(unzip(pptxPath, entry));

    const missing = expected.filter((e) => !findBox(boxes, e.rect));
    checked += expected.length;

    if (missing.length === 0) {
      console.log(
        `✓ ${slide.id} (${variant.id}) — ${expected.length}/${expected.length} boxes matched, ${boxes.length} shapes on the slide`,
      );
    } else {
      failures += missing.length;
      console.error(`✗ ${slide.id} (${variant.id}) — ${missing.length} missing:`);
      for (const m of missing) {
        console.error(
          `    ${m.label}\n      want EMU x=${toEmu(m.rect.x)} y=${toEmu(m.rect.y)} cx=${toEmu(m.rect.w)} cy=${toEmu(m.rect.h)}` +
            `\n      (px  x=${round(m.rect.x)} y=${round(m.rect.y)} w=${round(m.rect.w)} h=${round(m.rect.h)})`,
        );
      }
    }
  });

  console.log(
    `\n${failures === 0 ? "✓ PASS" : "✗ FAIL"} — ${checked - failures}/${checked} boxes aligned between the HTML geometry and the .pptx`,
  );
  if (failures > 0) process.exit(1);
}

function round(n: number): number {
  return Math.round(n * 100) / 100;
}

try {
  main();
} catch (error) {
  console.error(`✗ verify failed: ${(error as Error)?.message ?? error}`);
  process.exit(1);
}
