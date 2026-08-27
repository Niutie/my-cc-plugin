/* ─────────────────────────────────────────────────────────────────────
 * console/contentPaths.ts — where an on-screen edit actually goes.
 *
 * THE rule of the console: an edit lands in the canonical content, never
 * in a compiled element. If you could edit the composition directly,
 * switching variants would silently throw the edit away, and the .pptx
 * would ship whichever copy of the text happened to win.
 *
 * So editing works by provenance: find which canonical field produced
 * the string on screen, and write there. Text with no canonical source
 * — a framework heading like "S · 优势", a step number — is NOT
 * editable, and the console says so rather than pretending.
 * ───────────────────────────────────────────────────────────────────── */

import type { SlideContent } from "../deck/types";

export type ContentPath =
  | { kind: "presentation"; field: PresentationField }
  | { kind: "item"; index: number; field: ItemField }
  | { kind: "meta"; key: string };

type PresentationField =
  | "title"
  | "titleShort"
  | "summary"
  | "summaryShort"
  | "takeaway";

type ItemField = "label" | "displayValue" | "detail";

const PRESENTATION_FIELDS: PresentationField[] = [
  "title",
  "titleShort",
  "summary",
  "summaryShort",
  "takeaway",
];

const ITEM_FIELDS: ItemField[] = ["label", "displayValue", "detail"];

/**
 * Which canonical field produced this exact string.
 *
 * Matched by value rather than tracked through compilation: an
 * archetype's build() would otherwise have to thread provenance through
 * every element it emits, and any layout that forgot would produce text
 * that silently isn't editable. Value matching has one failure mode —
 * two fields holding the identical string — and it resolves in a fixed
 * order so the behaviour is at least predictable.
 */
export function findContentPath(
  content: SlideContent,
  text: string,
): ContentPath | null {
  const trimmed = text.trim();
  if (!trimmed) return null;

  for (const field of PRESENTATION_FIELDS) {
    if (content.presentation[field]?.trim() === trimmed) {
      return { kind: "presentation", field };
    }
  }

  const items = content.presentation.items ?? [];
  for (let index = 0; index < items.length; index += 1) {
    for (const field of ITEM_FIELDS) {
      if (items[index][field]?.trim() === trimmed) {
        return { kind: "item", index, field };
      }
    }
  }

  for (const [key, value] of Object.entries(content.meta ?? {})) {
    if (value?.trim() === trimmed) return { kind: "meta", key };
  }

  return null;
}

/** Apply an edit, returning a new content object. */
export function writeContentPath(
  content: SlideContent,
  target: ContentPath,
  value: string,
): SlideContent {
  const next: SlideContent = JSON.parse(JSON.stringify(content));

  if (target.kind === "presentation") {
    next.presentation[target.field] = value;
    return next;
  }
  if (target.kind === "item") {
    const items = next.presentation.items ?? [];
    if (items[target.index]) items[target.index][target.field] = value;
    return next;
  }
  next.meta = { ...(next.meta ?? {}), [target.key]: value };
  return next;
}

/** Human-readable, for the console's "you edited X" line. */
export function describePath(target: ContentPath): string {
  if (target.kind === "presentation") return `presentation.${target.field}`;
  if (target.kind === "item") {
    return `items[${target.index}].${target.field}`;
  }
  return `meta.${target.key}`;
}
