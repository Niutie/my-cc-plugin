/* ─────────────────────────────────────────────────────────────────────
 * deck/types.ts — the Deck DSL.
 *
 * This file is the contract that makes dual-rendering possible. EVERY
 * visual thing in a deck must be expressible here, because three
 * renderers consume it:
 *
 *   composition ──┬─→ render/react   → HTML deck (screen / console)
 *                 ├─→ export/pptx    → editable .pptx
 *                 └─→ Playwright     → PDF (prints the HTML)
 *
 * RED LINE: no renderer may accept free-form HTML/JSX/CSS from the deck
 * data. If a visual idea can't be said in this DSL, extend the DSL —
 * don't escape it. The moment a slide carries raw markup, PPTX export
 * degrades to a DOM-walker and the whole architecture collapses (that
 * is exactly the trap the closed-source prior art fell into).
 * ───────────────────────────────────────────────────────────────────── */

/* ── 1. Deck ─────────────────────────────────────────────────────── */

export interface Deck {
  schemaVersion: 1;
  meta: DeckMeta;
  slides: Slide[];
}

export interface DeckMeta {
  title: string;
  /** What this deck is for — steers variant selection and acceptance. */
  goal?: string;
  audience?: string;
  owner?: string;
  /** Deck language. Drives every string; never mix defaults from a theme. */
  lang: "zh" | "en";
  /** Theme id — matches a directory under the skill's themes/. */
  theme: string;
  /** Reproducibility: same seed + same content → same variant picks. */
  seed?: string;
  /** One id per user-facing generation task; retries reuse it. */
  runId?: string;
}

/* ── 2. Slide + canonical content ────────────────────────────────── */

/**
 * Page roles. Used ONLY as a soft ordering hint when picking archetype
 * candidates — real eligibility is decided by capacity (how much text /
 * how many items / whether media is needed), never by the role name.
 */
export type SlideRole =
  | "cover"
  | "agenda"
  | "statement"
  | "metrics"
  | "trend"
  | "comparison"
  | "distribution"
  | "process"
  | "relationship"
  | "matrix"
  | "case"
  | "risks"
  | "actions"
  | "result"
  | "closing";

export interface Slide {
  id: string;
  role: SlideRole;
  /** Which facet of the content matters most on this page. */
  priority?: "title" | "metrics" | "items" | "media" | "narrative";
  /** THE single source of truth for this page. All variants project it. */
  content: SlideContent;
  /** Exactly 3 archetype variants + 1 bespoke, once the deck is deliverable. */
  variants: Variant[];
  /** id of the variant shown in the deck and in `selected-only` exports. */
  selectedVariant: string;
}

export interface SlideContent {
  presentation: Presentation;
  media?: MediaRef[];
  /** Deck furniture: brand, section label, page kicker. */
  meta?: Record<string, string>;
}

/**
 * The canonical content package. Every variant of a page renders THIS —
 * they choose length, ordering, grouping and visual hierarchy, they do
 * NOT invent three different stories. `*Short` fields exist so a dense
 * archetype can pick a shorter string without rewriting the fact.
 */
export interface Presentation {
  title: string;
  titleShort?: string;
  summary?: string;
  summaryShort?: string;
  /** The one sentence the audience should leave with. */
  takeaway?: string;
  items?: Item[];
}

export interface Item {
  /** Stable across variants — contentMap and the console address it. */
  id: string;
  label: string;
  /** Raw number for charts. `displayValue` is what humans read. */
  value?: number;
  displayValue?: string;
  detail?: string;
  unit?: string;
  /** Required facts survive into EVERY variant, however dense. */
  required?: boolean;
  priority?: number;
}

export interface MediaRef {
  id: string;
  /** Deck-relative path only. Never absolute, file://, or remote. */
  src: string;
  kind: "image" | "video";
  alt?: string;
}

/* ── 3. Variants ─────────────────────────────────────────────────── */

export type Variant = ArchetypeVariant | BespokeVariant;

interface VariantBase {
  id: string;
  /**
   * Projects canonical content onto the compiled composition.
   * Keys are element paths (`elements[2].text`, `elements[3].items`),
   * values are content paths (`presentation.title`, `presentation.items`).
   */
  contentMap?: Record<string, string>;
}

export interface ArchetypeVariant extends VariantBase {
  kind: "archetype";
  /** Key into the archetype registry. */
  archetype: string;
  /** Archetype knobs — the typed controls the console exposes. */
  props?: Record<string, unknown>;
}

export interface BespokeVariant extends VariantBase {
  kind: "bespoke";
  designIntent: DesignIntent;
  composition: Composition;
}

/**
 * Why this page looks the way it does. Written BEFORE the composition,
 * and checked against the composition at review time — a page whose
 * geometry doesn't visibly implement its `compositionFamily` fails.
 */
export interface DesignIntent {
  objective: string;
  audience: string;
  narrativeRole: string;
  emphasis: string;
  rationale: string;
  compositionFamily: CompositionFamily;
}

/**
 * The anti-card-wall constraint. A deck may not run the same family on
 * consecutive pages, and `card-grid` shapes may not exceed one third of
 * the body pages — otherwise every AI deck degenerates into the same
 * three-boxes-in-a-row layout.
 */
export type CompositionFamily =
  | "hero"
  | "split"
  | "metric-spotlight"
  | "chart-led"
  | "timeline"
  | "matrix"
  | "editorial"
  | "comparison"
  | "process"
  /** Forces acting on each other, or a loop that feeds itself — Porter,
   *  flywheels, ecosystem maps. Distinct from `process`, which is a
   *  sequence with a start and an end. */
  | "relationship";

/* ── 4. Composition — what both renderers actually walk ──────────── */

export interface Composition {
  background?: BackgroundRole;
  elements: Element[];
}

export type BackgroundRole = "surface" | "surface-2" | "shell" | "accent";

export type Element = TextEl | MetricEl | ListEl | ChartEl | ShapeEl;

interface ElementBase {
  id: string;
  /** 1-indexed placement on the 12×8 grid. */
  grid: GridRect;
  /** Ignore the stage padding and place against the full 1920×1080 frame. */
  bleed?: boolean;
  /**
   * Fix the element's px size inside its grid cell. The grid stays the
   * placement system; this is for marks smaller than a cell — a 12px
   * timeline dot has no business being 122px wide just because that is
   * what one column measures.
   */
  size?: { w?: number; h?: number };
  /** Where a `size`-constrained element sits in its cell. Default centre. */
  anchor?: Anchor;
}

export type Anchor =
  | "top-left"
  | "top"
  | "top-right"
  | "left"
  | "center"
  | "right"
  | "bottom-left"
  | "bottom"
  | "bottom-right";

export interface GridRect {
  column: number;
  row: number;
  width: number;
  height: number;
}

export type TextRole =
  | "title"
  | "subtitle"
  | "body"
  | "kicker"
  | "caption"
  | "quote";

export interface TextEl extends ElementBase {
  type: "text";
  role: TextRole;
  text: string;
  align?: "left" | "center" | "right";
  /** Vertical anchoring inside the element box. */
  valign?: "top" | "middle" | "bottom";
  /** Paints the text in the accent colour. One per page, at most. */
  accent?: boolean;
}

export interface MetricEl extends ElementBase {
  type: "metric";
  /** Pre-formatted for display — "1,240" / "38%" / "3.2×". */
  value: string;
  label?: string;
  unit?: string;
  detail?: string;
  align?: "left" | "center" | "right";
  accent?: boolean;
}

export interface ListEl extends ElementBase {
  type: "list";
  style: "bullet" | "numbered" | "card" | "rule";
  items: ListItem[];
  /** Lay the items out in N columns inside the element box. */
  columns?: number;
}

export interface ListItem {
  id?: string;
  label: string;
  detail?: string;
}

export interface ShapeEl extends ElementBase {
  type: "shape";
  /**
   * All of these map to a PowerPoint preset geometry of the same name,
   * so an analysis model exports as editable shapes rather than a
   * picture. Anything not in this list belongs in a chart's vector
   * layer, not here.
   */
  shape: "rect" | "line" | "ellipse" | "diamond" | "triangle" | "chevron";
  fill?: BackgroundRole | "accent-soft" | "none";
  stroke?: "rule" | "accent" | "none";
  /**
   * Which edge of the box a `line` is drawn on. Explicit rather than
   * inferred from the grid rect: a 1×4 cell is ambiguous, and guessing
   * wrong puts a column divider across the page.
   */
  orient?: "horizontal" | "vertical";
}

export interface ChartEl extends ElementBase {
  type: "chart";
  chart: ChartSpec;
  /** Optional caption rendered under the plot area, inside the box. */
  caption?: string;
}

/* ── 5. Charts ───────────────────────────────────────────────────── */

/**
 * P0 ships `column` only. The kind union is the roadmap: every kind
 * listed here must be implementable by BOTH renderers before it ships —
 * natively where PowerPoint has an equivalent, as vector shapes where
 * it doesn't. See references/CHARTS.md.
 */
export type ChartKind =
  | "column"
  | "bar"
  | "line"
  | "area"
  | "pie"
  | "donut"
  | "scatter"
  | "bubble"
  | "radar"
  | "waterfall"
  | "funnel"
  | "heatmap"
  | "treemap"
  | "sankey"
  | "gantt"
  | "slope"
  | "dumbbell"
  | "marimekko";

export interface ChartSpec {
  kind: ChartKind;
  /** X axis / slice labels. */
  categories: string[];
  series: ChartSeries[];
  /** Suffix appended to every value label ("%", "亿"). */
  unit?: string;
  /** Draw the value on top of each mark. */
  showValues?: boolean;
  /** Force the value axis to start somewhere other than the data min. */
  baseline?: number;
  /** Show the series legend. Single-series charts should leave this off. */
  legend?: boolean;
  /**
   * How this chart leaves the building.
   *
   *   native  (default where PowerPoint has an equivalent) — a real
   *           PowerPoint chart with an editable data sheet; PowerPoint
   *           draws the marks, so styling is approximated.
   *   vector  real PowerPoint shapes, pixel-identical to the browser,
   *           but the numbers are baked in.
   */
  render?: "native" | "vector";
}

export interface ChartSeries {
  name: string;
  /** Aligned with `categories`; `null` is a genuine gap, not a zero. */
  data: (number | null)[];
}
