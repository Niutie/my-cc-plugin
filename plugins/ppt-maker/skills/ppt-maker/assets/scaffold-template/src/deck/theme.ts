/* ─────────────────────────────────────────────────────────────────────
 * deck/theme.ts — theme tokens, resolved for both renderers.
 *
 * `tokens.css` stays the SINGLE source of truth for a theme's look. The
 * browser consumes it as CSS custom properties; the PPTX exporter parses
 * the same file here. Nothing is duplicated into a parallel JSON, so a
 * theme can never drift between screen and export.
 *
 * PowerPoint does not embed fonts. A theme therefore also declares
 * `pptxFonts` in its theme.json — the family the exporter writes into
 * the .pptx, chosen from what a normal Office install actually has.
 * ───────────────────────────────────────────────────────────────────── */

export interface ChartTokens {
  /** Categorical series colours, in use order. At least 4. */
  series: string[];
  grid: string;
  axis: string;
  label: string;
  /** Waterfall / delta semantics. */
  pos: string;
  neg: string;
  /** Sequential ramp for heatmap / treemap, light → dark. */
  seq: string[];
}

export interface ThemeTokens {
  id: string;
  shell: string;
  surface: string;
  surface2: string;
  surface3: string;
  text: string;
  text2: string;
  textMute: string;
  textFaint: string;
  rule: string;
  accent: string;
  /** Flattened over `surface` — PowerPoint shape fills want a solid hex. */
  accentSoft: string;
  padX: number;
  padY: number;
  radiusCard: number;
  ruleWidth: number;
  /**
   * Personality knobs a theme may override. Undefined means "use the
   * type scale's own weight" — the default lives in typography.ts and
   * nowhere else, so the two renderers can't disagree about it.
   *
   * PowerPoint text runs only carry b="1"/b="0", so any weight maps to
   * bold at >= 600 on export. A 200-weight theme reads extra-light in
   * the browser and regular in the .pptx; that is PowerPoint's floor,
   * not a bug in the mapping.
   */
  titleWeight?: number;
  heroNumWeight?: number;
  chart: ChartTokens;
  /** Font families the exporter writes into the .pptx. */
  pptxFonts: PptxFonts;
}

export interface FontSet {
  display: string;
  body: string;
  mono: string;
}

/**
 * PowerPoint substitutes silently when a font is missing, so a theme
 * declares what it actually expects to find on a normal Office install.
 * `zh` is a separate set rather than a magic fallback: the Latin face
 * that carries a theme's character is rarely the right CJK face, and
 * guessing produces decks that look fine locally and wrong everywhere.
 */
export interface PptxFonts extends FontSet {
  zh?: FontSet;
}

export const DEFAULT_PPTX_FONTS: PptxFonts = {
  display: "Arial",
  body: "Arial",
  mono: "Consolas",
  zh: { display: "Microsoft YaHei", body: "Microsoft YaHei", mono: "Consolas" },
};

export function fontSet(fonts: PptxFonts, lang: "zh" | "en"): FontSet {
  return lang === "zh" && fonts.zh ? fonts.zh : fonts;
}

/* ── colour utilities ────────────────────────────────────────────── */

export interface Rgba {
  r: number;
  g: number;
  b: number;
  a: number;
}

export function parseColor(input: string): Rgba | null {
  const value = input.trim();

  const hex = value.match(/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i);
  if (hex) {
    let h = hex[1];
    if (h.length === 3) {
      h = h
        .split("")
        .map((c) => c + c)
        .join("");
    }
    const r = parseInt(h.slice(0, 2), 16);
    const g = parseInt(h.slice(2, 4), 16);
    const b = parseInt(h.slice(4, 6), 16);
    const a = h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1;
    return { r, g, b, a };
  }

  const fn = value.match(/^rgba?\(([^)]+)\)$/i);
  if (fn) {
    const parts = fn[1].split(/[,/]/).map((p) => p.trim());
    if (parts.length < 3) return null;
    const [r, g, b] = parts.slice(0, 3).map((p) => Number.parseFloat(p));
    const a = parts.length > 3 ? Number.parseFloat(parts[3]) : 1;
    if ([r, g, b, a].some((n) => Number.isNaN(n))) return null;
    return { r, g, b, a };
  }

  return null;
}

/** "#RRGGBB" — pptxgenjs wants six hex digits, no leading hash. */
export function toHex(c: Rgba): string {
  const h = (n: number) =>
    Math.max(0, Math.min(255, Math.round(n)))
      .toString(16)
      .padStart(2, "0");
  return `#${h(c.r)}${h(c.g)}${h(c.b)}`;
}

/** Flatten a translucent colour over an opaque one. */
export function flatten(fg: Rgba, bg: Rgba): Rgba {
  return {
    r: fg.r * fg.a + bg.r * (1 - fg.a),
    g: fg.g * fg.a + bg.g * (1 - fg.a),
    b: fg.b * fg.a + bg.b * (1 - fg.a),
    a: 1,
  };
}

export function mix(a: Rgba, b: Rgba, t: number): Rgba {
  return {
    r: a.r + (b.r - a.r) * t,
    g: a.g + (b.g - a.g) * t,
    b: a.b + (b.b - a.b) * t,
    a: 1,
  };
}

/** WCAG relative luminance — used to decide light vs dark derivations. */
export function luminance(c: Rgba): number {
  const ch = (v: number) => {
    const s = v / 255;
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

export function contrastRatio(a: Rgba, b: Rgba): number {
  const la = luminance(a);
  const lb = luminance(b);
  const [hi, lo] = la > lb ? [la, lb] : [lb, la];
  return (hi + 0.05) / (lo + 0.05);
}

/* ── tokens.css → ThemeTokens ────────────────────────────────────── */

/** Pull every `--name: value;` out of a stylesheet's :root blocks. */
export function readCssVars(css: string): Record<string, string> {
  const stripped = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const out: Record<string, string> = {};
  const re = /(--[a-z0-9-]+)\s*:\s*([^;}]+)[;}]/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(stripped))) {
    out[m[1]] = m[2].trim();
  }
  return out;
}

/** Resolve `var(--a, fallback)` chains against the same map. */
export function resolveVar(
  vars: Record<string, string>,
  name: string,
  depth = 0,
): string | undefined {
  if (depth > 8) return undefined;
  const raw = vars[name];
  if (raw === undefined) return undefined;
  const ref = raw.match(/^var\(\s*(--[a-z0-9-]+)\s*(?:,\s*([^)]+))?\)$/i);
  if (!ref) return raw;
  const resolved = resolveVar(vars, ref[1], depth + 1);
  return resolved ?? ref[2]?.trim();
}

function num(value: string | undefined, fallback: number): number {
  if (!value) return fallback;
  const m = value.match(/(-?[\d.]+)/);
  return m ? Number.parseFloat(m[1]) : fallback;
}

function optNum(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const m = value.match(/(-?[\d.]+)/);
  return m ? Number.parseFloat(m[1]) : undefined;
}

function color(
  vars: Record<string, string>,
  name: string,
  fallback: string,
): Rgba {
  const raw = resolveVar(vars, name);
  return (raw && parseColor(raw)) || parseColor(fallback)!;
}

/**
 * Derive the chart palette when a theme doesn't declare one.
 *
 * The theme contract allows exactly ONE saturated accent — a second hue
 * fights the first. Charts still need distinguishable series, so the
 * ramp is built from the accent's own lightness steps plus neutral
 * steps walked away from the surface. Hue stays constant; separation
 * comes from value, which also survives greyscale printing.
 *
 * A theme that needs something better declares --chart-series-N itself.
 */
function deriveChartTokens(
  vars: Record<string, string>,
  base: {
    accent: Rgba;
    surface: Rgba;
    text: Rgba;
    textMute: Rgba;
    rule: Rgba;
  },
): ChartTokens {
  const declared: string[] = [];
  for (let i = 1; i <= 8; i += 1) {
    const raw = resolveVar(vars, `--chart-series-${i}`);
    const parsed = raw ? parseColor(raw) : null;
    if (parsed) declared.push(toHex(parsed));
  }

  // Two poles, always the same way round: `surface` is the theme's
  // background and `text` its ink, so mixing toward either gives real
  // separation on a light theme AND on a dark one. Resist the urge to
  // swap them by luminance — these formulas are mirrored as color-mix()
  // fallbacks in base.css, which has no way to branch, and the exporter
  // must land on the same colours the browser shows.
  const toward = base.text;
  const away = base.surface;
  const derived = [
    toHex(base.accent),
    toHex(mix(base.accent, away, 0.45)),
    toHex(mix(base.accent, toward, 0.4)),
    toHex(mix(base.textMute, away, 0.15)),
    toHex(mix(base.accent, away, 0.7)),
    toHex(mix(base.textMute, toward, 0.35)),
    toHex(mix(base.accent, toward, 0.65)),
    toHex(mix(base.textMute, away, 0.5)),
  ];

  const series = declared.length >= 4 ? declared : derived;

  const seqRaw: string[] = [];
  for (let i = 1; i <= 5; i += 1) {
    const raw = resolveVar(vars, `--chart-seq-${i}`);
    const parsed = raw ? parseColor(raw) : null;
    if (parsed) seqRaw.push(toHex(parsed));
  }
  // Accent fractions over the surface — mirrors --chart-seq-N in base.css.
  const seq =
    seqRaw.length >= 3
      ? seqRaw
      : [0.12, 0.29, 0.46, 0.66, 1].map((t) =>
          toHex(mix(away, base.accent, t)),
        );

  const posRaw = resolveVar(vars, "--chart-pos");
  const negRaw = resolveVar(vars, "--chart-neg");

  return {
    series,
    grid: toHex(color(vars, "--chart-grid", toHex(base.rule))),
    axis: toHex(color(vars, "--chart-axis", toHex(base.textMute))),
    label: toHex(color(vars, "--chart-label", toHex(base.textMute))),
    pos: toHex((posRaw && parseColor(posRaw)) || base.accent),
    // Mirrors --chart-neg in base.css. A loss should read heavier than a
    // gain without going to near-black, which on a light theme swallows
    // the bar entirely.
    neg: toHex(
      (negRaw && parseColor(negRaw)) || mix(base.textMute, base.text, 0.3),
    ),
    seq,
  };
}

export function parseThemeTokens(
  id: string,
  css: string,
  pptxFonts: PptxFonts = DEFAULT_PPTX_FONTS,
): ThemeTokens {
  const vars = readCssVars(css);

  const surface = color(vars, "--surface", "#ffffff");
  const accent = color(vars, "--accent", "#002fa7");
  const text = color(vars, "--text", "#0a0a0a");
  const textMute = color(vars, "--text-mute", "#737373");
  const rule = color(vars, "--rule", "#e0e0e0");
  const accentSoftRaw = color(vars, "--accent-soft", "rgba(0,0,0,0.08)");

  return {
    id,
    shell: toHex(color(vars, "--shell", "#e8e8e6")),
    surface: toHex(surface),
    surface2: toHex(color(vars, "--surface-2", "#f0f0ee")),
    surface3: toHex(color(vars, "--surface-3", "#d4d4d2")),
    text: toHex(text),
    text2: toHex(color(vars, "--text-2", "#2a2a2a")),
    textMute: toHex(textMute),
    textFaint: toHex(color(vars, "--text-faint", "#a8a8a8")),
    rule: toHex(rule),
    accent: toHex(accent),
    accentSoft: toHex(flatten(accentSoftRaw, surface)),
    padX: num(resolveVar(vars, "--stage-pad-x"), 96),
    padY: num(resolveVar(vars, "--stage-pad-y"), 72),
    radiusCard: num(resolveVar(vars, "--r-card"), 0),
    ruleWidth: num(resolveVar(vars, "--rule-w"), 1),
    titleWeight: optNum(resolveVar(vars, "--title-weight")),
    heroNumWeight: optNum(resolveVar(vars, "--hero-num-weight")),
    chart: deriveChartTokens(vars, {
      accent,
      surface,
      text,
      textMute,
      rule,
    }),
    pptxFonts,
  };
}
