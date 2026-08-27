/* ─────────────────────────────────────────────────────────────────────
 * archetypes/types.ts — the archetype contract.
 *
 * Two ideas live here, and they are the reason a deck doesn't overflow
 * or degenerate:
 *
 *  1. CAPACITY. Every archetype declares, in machine-readable form, how
 *     much content it can actually hold. Selection is content-first:
 *     measure the page's canonical content, then ask which archetypes
 *     fit. Never "pick a nice layout, then squeeze the text in".
 *
 *  2. CONTROLS. Every knob a human may turn after generation is declared
 *     here as a typed control, with the array it caps where relevant.
 *     The console renders these; the exporter re-reads props and rebuilds
 *     the composition. So an edit made in the browser survives into the
 *     next .pptx — the console is not a cosmetic overlay.
 * ───────────────────────────────────────────────────────────────────── */

import type { CompileContext } from "../deck/compile";
import type { Composition, CompositionFamily, SlideContent } from "../deck/types";

export interface Bilingual {
  zh: string;
  en: string;
}

export type ArchetypeControl =
  | RangeControl
  | ToggleControl
  | SelectControl;

interface ControlBase {
  key: string;
  label: Bilingual;
  /** Shown under the control in the console. */
  hint?: Bilingual;
}

export interface RangeControl extends ControlBase {
  type: "range";
  default: number;
  min: number;
  max: number;
  step: number;
  /**
   * This control caps how many entries of a content array are visible.
   * The validator uses it to check the array can actually be consumed.
   */
  bindsArray?: "items";
}

export interface ToggleControl extends ControlBase {
  type: "toggle";
  default: boolean;
}

export interface SelectControl extends ControlBase {
  type: "select";
  default: string;
  options: Array<{ value: string; label: Bilingual }>;
}

/**
 * What the archetype can hold. Hard conditions (`items`, `needsValues`,
 * `media`) filter candidates out; character budgets rank them.
 */
export interface Capacity {
  /** Max characters before the title box overflows at its type size. */
  titleChars: number;
  summaryChars?: number;
  takeawayChars?: number;
  items: { min: number; max: number };
  /** Item labels only, per item. */
  itemLabelChars?: number;
  itemDetailChars?: number;
  /** Requires `item.value` to be a real number (charts, metric walls). */
  needsValues?: boolean;
  media?: { min: number; max: number };
}

export interface Archetype {
  id: string;
  name: Bilingual;
  family: CompositionFamily;
  /** Soft ordering hint only — capacity decides eligibility. */
  roles: string[];
  capacity: Capacity;
  controls: ArchetypeControl[];
  build(
    props: Record<string, unknown>,
    content: SlideContent,
    ctx: CompileContext,
  ): Composition;
}

/* ── prop reading helpers (props come from JSON, so nothing is typed) ── */

export function propNumber(
  props: Record<string, unknown>,
  key: string,
  fallback: number,
  min: number,
  max: number,
): number {
  const raw = props[key];
  const n = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.round(n)));
}

export function propBool(
  props: Record<string, unknown>,
  key: string,
  fallback: boolean,
): boolean {
  const raw = props[key];
  return typeof raw === "boolean" ? raw : fallback;
}

export function propEnum<T extends string>(
  props: Record<string, unknown>,
  key: string,
  fallback: T,
  allowed: readonly T[],
): T {
  const raw = props[key];
  return typeof raw === "string" && (allowed as readonly string[]).includes(raw)
    ? (raw as T)
    : fallback;
}

/** Measure canonical content against a capacity. Null = fits. */
export function capacityError(
  capacity: Capacity,
  content: SlideContent,
): string | null {
  const p = content.presentation;
  const items = p.items ?? [];

  if (items.length < capacity.items.min) {
    return `needs at least ${capacity.items.min} items, got ${items.length}`;
  }
  if (capacity.needsValues && items.some((i) => typeof i.value !== "number")) {
    return "needs a numeric `value` on every item";
  }
  const required = items.filter((i) => i.required).length;
  if (required > capacity.items.max) {
    return `${required} required items exceed the ${capacity.items.max} visible slots`;
  }
  const media = content.media?.length ?? 0;
  if (capacity.media && media < capacity.media.min) {
    return `needs ${capacity.media.min} media, got ${media}`;
  }
  if (!capacity.media && media > 0) {
    return "has media but this archetype exposes no media slot";
  }

  const title = p.titleShort ?? p.title;
  if (title.length > capacity.titleChars) {
    return `title is ${title.length} chars, budget is ${capacity.titleChars}`;
  }
  return null;
}
