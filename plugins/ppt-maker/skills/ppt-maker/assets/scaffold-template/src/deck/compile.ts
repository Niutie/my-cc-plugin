/* ─────────────────────────────────────────────────────────────────────
 * deck/compile.ts — variant → Composition.
 *
 * THE key architectural move: an archetype is not a React component, it
 * is a function that emits the same `Composition` a bespoke variant
 * writes by hand. So there is exactly ONE thing to render, and the PPTX
 * exporter never has to reverse-engineer a rendered DOM.
 *
 *     archetype(props, content) ─┐
 *                                ├─→ Composition ─→ react | pptx | pdf
 *     bespoke.composition ───────┘
 *
 * `contentMap` runs last, over either kind, so canonical content can be
 * re-projected onto a composition without touching its geometry.
 * ───────────────────────────────────────────────────────────────────── */

import { ARCHETYPES } from "../archetypes";
import type {
  Composition,
  Element,
  ListItem,
  SlideContent,
  Variant,
} from "./types";

export interface CompileContext {
  lang: "zh" | "en";
}

export function compileVariant(
  variant: Variant,
  content: SlideContent,
  ctx: CompileContext,
): Composition {
  const base =
    variant.kind === "archetype"
      ? compileArchetype(variant.archetype, variant.props ?? {}, content, ctx)
      : cloneComposition(variant.composition);

  return variant.contentMap
    ? applyContentMap(base, variant.contentMap, content)
    : base;
}

function compileArchetype(
  id: string,
  props: Record<string, unknown>,
  content: SlideContent,
  ctx: CompileContext,
): Composition {
  const archetype = ARCHETYPES[id];
  if (!archetype) {
    throw new Error(
      `unknown archetype "${id}" — known: ${Object.keys(ARCHETYPES).join(", ")}`,
    );
  }
  return archetype.build(props, content, ctx);
}

function cloneComposition(c: Composition): Composition {
  return JSON.parse(JSON.stringify(c)) as Composition;
}

/* ── contentMap ──────────────────────────────────────────────────── */

/**
 * Project canonical content onto compiled elements.
 *
 *   { "elements[2].text":  "presentation.title",
 *     "elements[4].items": "presentation.items" }
 *
 * Arrays coming from `presentation.items` are coerced to the shape the
 * target element wants, so a list can consume items without the deck
 * author restating every field.
 */
export function applyContentMap(
  composition: Composition,
  map: Record<string, string>,
  content: SlideContent,
): Composition {
  const out = cloneComposition(composition);
  for (const [target, source] of Object.entries(map)) {
    const value = readContentPath(content, source);
    if (value === undefined) continue;
    writeElementPath(out, target, value);
  }
  return out;
}

function readContentPath(content: SlideContent, path: string): unknown {
  return path.split(".").reduce<unknown>((node, key) => {
    if (node === null || node === undefined) return undefined;
    return (node as Record<string, unknown>)[key];
  }, content as unknown);
}

const ELEMENT_PATH = /^elements\[(\d+)\]\.(.+)$/;

function writeElementPath(
  composition: Composition,
  path: string,
  value: unknown,
): void {
  const m = path.match(ELEMENT_PATH);
  if (!m) throw new Error(`contentMap target must be elements[n].field: ${path}`);
  const el = composition.elements[Number(m[1])];
  if (!el) return;
  const field = m[2];

  if (field === "items") {
    (el as Extract<Element, { type: "list" }>).items = toListItems(value);
    return;
  }
  (el as unknown as Record<string, unknown>)[field] = value;
}

function toListItems(value: unknown): ListItem[] {
  if (!Array.isArray(value)) return [];
  return value.map((raw, i) => {
    const item = raw as Record<string, unknown>;
    return {
      id: typeof item.id === "string" ? item.id : `i${i}`,
      label: String(item.label ?? item.displayValue ?? ""),
      detail:
        typeof item.detail === "string"
          ? item.detail
          : typeof item.displayValue === "string"
            ? item.displayValue
            : undefined,
    };
  });
}
