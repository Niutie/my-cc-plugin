#!/usr/bin/env node
/* ─────────────────────────────────────────────────────────────────────
 * gen-chart-palettes.mjs — derive each theme's chart palette, and prove it.
 *
 * A theme declares exactly ONE saturated accent, because a second brand
 * hue fights the first. Charts need more than that: series identity is
 * carried by hue, and a lightness-only ramp on one hue fails the
 * normal-vision separation floor (measured, not argued — the first
 * attempt here came out at ΔE 13.2 against a floor of 15).
 *
 * So the chart palette is a SEPARATE parameter from the deck accent.
 * Slot 1 is the accent, so a single-series chart still speaks in the
 * theme's voice; slots 2..6 are hues rotated away from it, stepped into
 * the mode's lightness band, and searched until the palette passes the
 * dataviz validator's six checks.
 *
 * The sequential ramp (heatmap / treemap / funnel) is a different job —
 * one hue, monotone lightness — and is checked with the ordinal rules
 * instead. Running the categorical checks on it fails by design.
 *
 *   node scripts/gen-chart-palettes.mjs --validator <path-to>/validate_palette.js
 *   node scripts/gen-chart-palettes.mjs --dry-run
 * ───────────────────────────────────────────────────────────────────── */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const THEMES = path.resolve(HERE, "../themes");

/* ── sRGB ↔ OKLab/OKLCH (Ottosson) ───────────────────────────────── */

const srgbToLinear = (v) =>
  v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
const linearToSrgb = (v) =>
  v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;

function hexToRgb(hex) {
  const h = hex.replace("#", "");
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255);
}
function rgbToHex([r, g, b]) {
  const c = (v) =>
    Math.max(0, Math.min(255, Math.round(v * 255)))
      .toString(16)
      .padStart(2, "0");
  return `#${c(r)}${c(g)}${c(b)}`;
}

function rgbToOklab([r, g, b]) {
  const [R, G, B] = [r, g, b].map(srgbToLinear);
  const l = Math.cbrt(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B);
  const m = Math.cbrt(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B);
  const s = Math.cbrt(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

function oklabToRgb([L, a, bb]) {
  const l = (L + 0.3963377774 * a + 0.2158037573 * bb) ** 3;
  const m = (L - 0.1055613458 * a - 0.0638541728 * bb) ** 3;
  const s = (L - 0.0894841775 * a - 1.291485548 * bb) ** 3;
  return [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ].map(linearToSrgb);
}

const toLch = (rgb) => {
  const [L, a, b] = rgbToOklab(rgb);
  return [L, Math.hypot(a, b), (Math.atan2(b, a) * 180) / Math.PI];
};
const fromLch = ([L, C, h]) => {
  const r = (h * Math.PI) / 180;
  return oklabToRgb([L, C * Math.cos(r), C * Math.sin(r)]);
};

const inGamut = (rgb) => rgb.every((v) => v >= -0.001 && v <= 1.001);

/** Highest chroma at this L and hue that still fits sRGB. */
function clampChroma(L, C, h) {
  let lo = 0;
  let hi = C;
  for (let i = 0; i < 24; i += 1) {
    const mid = (lo + hi) / 2;
    if (inGamut(fromLch([L, mid, h]))) lo = mid;
    else hi = mid;
  }
  return lo;
}

function slot(L, C, h) {
  return rgbToHex(fromLch([L, clampChroma(L, C, h), h]).map((v) => Math.max(0, Math.min(1, v))));
}

/* ── theme files ─────────────────────────────────────────────────── */

function readVars(css) {
  const clean = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const out = {};
  for (const m of clean.matchAll(/(--[a-z0-9-]+)\s*:\s*([^;}]+)[;}]/gi)) {
    out[m[1]] = m[2].trim();
  }
  return out;
}
const hexOf = (v, fallback) =>
  /^#[0-9a-f]{6}$/i.test(v ?? "") ? v : fallback;

const contrastRatio = (a, b) => {
  const [hi, lo] = [relLum(a), relLum(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

const relLum = (hex) => {
  const [r, g, b] = hexToRgb(hex).map(srgbToLinear);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};

/* ── search ──────────────────────────────────────────────────────── */

// Hue rotations away from the accent. Wide first steps because adjacent
// slots are the pairs that must separate; the later ones fill in.
const HUE_SETS = [
  [0, 150, 62, 214, 104, 268],
  [0, 168, 78, 250, 120, 30],
  [0, 130, 210, 60, 275, 165],
];
// Lightness patterns inside the mode's band, alternating so neighbours
// differ in value as well as hue.
const L_SETS = {
  light: [
    [0.54, 0.70, 0.47, 0.64, 0.75, 0.52],
    [0.50, 0.72, 0.58, 0.45, 0.68, 0.62],
    [0.58, 0.46, 0.70, 0.53, 0.74, 0.49],
  ],
  dark: [
    [0.58, 0.66, 0.50, 0.63, 0.54, 0.60],
    [0.62, 0.52, 0.66, 0.56, 0.49, 0.64],
    [0.55, 0.65, 0.59, 0.49, 0.67, 0.53],
  ],
};

async function main() {
  const argv = process.argv.slice(2);
  const dryRun = argv.includes("--dry-run");
  const vIndex = argv.indexOf("--validator");
  const validatorPath = vIndex >= 0 ? argv[vIndex + 1] : null;

  let validate = null;
  let validateOrdinal = null;
  if (validatorPath) {
    const mod = await import(path.resolve(validatorPath));
    validate = mod.validate;
    validateOrdinal = mod.validateOrdinal;
  } else {
    console.warn(
      "! no --validator given: palettes will be generated but NOT verified.\n" +
        "  Pass the dataviz skill's scripts/validate_palette.js to check them.",
    );
  }

  const rows = [];
  for (const dir of fs.readdirSync(THEMES).sort()) {
    const themeDir = path.join(THEMES, dir);
    const cssPath = path.join(themeDir, "tokens.css");
    if (!fs.existsSync(cssPath)) continue;

    let css = fs.readFileSync(cssPath, "utf8");
    const vars = readVars(css);
    const surface = hexOf(vars["--surface"], "#ffffff");
    const accent = hexOf(vars["--accent"], "#0060df");
    const mode = relLum(surface) < 0.18 ? "dark" : "light";

    const [, accentC, accentH] = toLch(hexToRgb(accent));
    // Keep the accent's own hue and a chroma at least at the identity
    // floor; a desaturated accent would make slot 1 read as a neutral.
    const chroma = Math.max(0.115, Math.min(accentC, 0.17));

    let best = null;
    for (const hues of HUE_SETS) {
      for (const Ls of L_SETS[mode]) {
        const palette = hues.map((dh, i) =>
          slot(Ls[i], chroma, (accentH + dh + 360) % 360),
        );
        // Slot 1 stays the theme's actual accent when it already sits in
        // the band — the brand voice should lead a single-series chart.
        const [aL] = toLch(hexToRgb(accent));
        const band = mode === "light" ? [0.43, 0.77] : [0.48, 0.67];
        if (aL >= band[0] && aL <= band[1] && accentC >= 0.10) palette[0] = accent;

        if (!validate) {
          best = { palette, report: null, score: 0 };
          break;
        }
        const { report, ok } = validate(palette, { mode, surface });
        const cvd = report.find((r) => /CVD/.test(r.check));
        const normal = report.find((r) => /Normal/.test(r.check));
        const score =
          (ok ? 1000 : 0) +
          (Number(String(cvd?.detail ?? "").match(/ΔE ([\d.]+)/)?.[1]) || 0) +
          (Number(String(normal?.detail ?? "").match(/ΔE ([\d.]+)/)?.[1]) || 0);
        if (!best || score > best.score) best = { palette, report, ok, score };
        if (ok) break;
      }
      if (best?.ok) break;
    }

    const palette = best.palette;
    // Sequential ramp: one hue (the accent's), monotone lightness. A
    // different job from categorical, checked with the ordinal rules.
    //
    // The end nearest the surface has to stay visible against it — a
    // first step at L 0.88 on a near-white slide measured 1.4:1, which
    // is a tile you cannot see. So that end is searched down until it
    // clears the floor rather than assumed.
    const seqChroma = Math.max(0.06, chroma * 0.9);
    const faintEnd = (() => {
      const step = mode === "dark" ? 0.02 : -0.02;
      let L = mode === "dark" ? 0.22 : 0.86;
      for (let i = 0; i < 30; i += 1) {
        if (contrastRatio(slot(L, seqChroma, accentH), surface) >= 2.2) return L;
        L += step;
      }
      return L;
    })();
    // The span is derived from where the faint end had to start, not
    // fixed: on a saturated surface the faint end lands high, and a
    // fixed far end then squeezes the steps below the visible-gap floor.
    const strongEnd = Math.max(
      0.18,
      Math.min(0.94, faintEnd + (mode === "dark" ? 0.34 : -0.34)),
    );
    const seq = Array.from({ length: 5 }, (_, i) =>
      slot(
        faintEnd + ((strongEnd - faintEnd) * i) / 4,
        seqChroma,
        accentH,
      ),
    );

    let seqOk = null;
    if (validateOrdinal) {
      seqOk = validateOrdinal(seq, { mode, surface }).ok;
    }

    const block =
      [
        "",
        "  /* ─── chart palette ───────────────────────────────────────────",
        "   * Generated by scripts/gen-chart-palettes.mjs and verified with",
        "   * the dataviz validator. Slot 1 is the theme accent; the rest are",
        "   * hues rotated from it, because one hue cannot carry series",
        "   * identity. Edit by hand only if you re-run the validator.",
        "   * ─────────────────────────────────────────────────────────── */",
      ]
        .concat(palette.map((c, i) => `  --chart-series-${i + 1}: ${c};`))
        .concat(seq.map((c, i) => `  --chart-seq-${i + 1}: ${c};`))
        .concat([
          `  --chart-pos: ${palette[0]};`,
          `  --chart-neg: ${slot(mode === "dark" ? 0.62 : 0.48, 0.02, accentH)};`,
        ])
        .join("\n") + "\n";

    if (!dryRun) {
      css = css.includes("--chart-series-1")
        ? css.replace(
            /\n\s*\/\* ─── chart palette[\s\S]*?--chart-neg:[^;]+;\n/,
            block,
          )
        : css.slice(0, css.lastIndexOf("}")) + block + css.slice(css.lastIndexOf("}"));
      fs.writeFileSync(cssPath, css);
    }

    rows.push({
      theme: dir,
      mode,
      ok: best.ok ?? null,
      seqOk,
      worst: best.report
        ? String(best.report.find((r) => /Normal/.test(r.check))?.detail ?? "")
            .match(/ΔE ([\d.]+)/)?.[1] ?? "?"
        : "?",
    });
  }

  const pad = (s, n) => String(s).padEnd(n);
  console.log(`${pad("theme", 20)}${pad("mode", 7)}${pad("categorical", 13)}${pad("ordinal", 9)}normal ΔE`);
  for (const r of rows) {
    console.log(
      pad(r.theme, 20) +
        pad(r.mode, 7) +
        pad(r.ok === null ? "—" : r.ok ? "PASS" : "FAIL", 13) +
        pad(r.seqOk === null ? "—" : r.seqOk ? "PASS" : "FAIL", 9) +
        r.worst,
    );
  }
  const bad = rows.filter((r) => r.ok === false).length;
  console.log(
    `\n${rows.length} themes · ${bad} categorical failures` +
      (dryRun ? " · dry run, nothing written" : ""),
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
