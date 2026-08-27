/* ─────────────────────────────────────────────────────────────────────
 * console/useDeck.ts — deck state, edits, and saving back to disk.
 *
 * Every mutation produces a new Deck object and marks the state dirty.
 * Saving POSTs the WHOLE deck to the dev server, which rewrites
 * deck.json — so the next `npm run export:pptx` picks the edit up. A
 * console that only changed pixels would be a demo; the point is that
 * what you fix on screen is what your colleague opens in PowerPoint.
 * ───────────────────────────────────────────────────────────────────── */

import { useCallback, useMemo, useState } from "react";
import type { Deck, SlideContent, Variant } from "../deck/types";
import {
  findContentPath,
  writeContentPath,
  describePath,
  type ContentPath,
} from "./contentPaths";

export interface EditResult {
  ok: boolean;
  message: string;
}

export type SaveState = "clean" | "dirty" | "saving" | "saved" | "error";

export function useDeck(initial: Deck) {
  const [deck, setDeck] = useState<Deck>(initial);
  const [index, setIndex] = useState(0);
  const [save, setSave] = useState<SaveState>("clean");
  const [lastEdit, setLastEdit] = useState<string | null>(null);

  const slide = deck.slides[Math.min(index, deck.slides.length - 1)];
  const variant = useMemo(
    () =>
      slide?.variants.find((v) => v.id === slide.selectedVariant) ??
      slide?.variants[0],
    [slide],
  );

  const mutate = useCallback((next: Deck) => {
    setDeck(next);
    setSave("dirty");
  }, []);

  const patchSlide = useCallback(
    (slideId: string, patch: (s: Deck["slides"][number]) => Deck["slides"][number]) => {
      mutate({
        ...deck,
        slides: deck.slides.map((s) => (s.id === slideId ? patch(s) : s)),
      });
    },
    [deck, mutate],
  );

  /** Switch which variant this page shows. */
  const selectVariant = useCallback(
    (variantId: string) => {
      if (!slide) return;
      patchSlide(slide.id, (s) => ({ ...s, selectedVariant: variantId }));
    },
    [slide, patchSlide],
  );

  /** Turn one of the archetype's typed controls. */
  const setProp = useCallback(
    (key: string, value: unknown) => {
      if (!slide || !variant || variant.kind !== "archetype") return;
      patchSlide(slide.id, (s) => ({
        ...s,
        variants: s.variants.map((v): Variant =>
          v.id === variant.id && v.kind === "archetype"
            ? { ...v, props: { ...(v.props ?? {}), [key]: value } }
            : v,
        ),
      }));
    },
    [slide, variant, patchSlide],
  );

  /**
   * Commit an in-place text edit. Resolves which canonical field the old
   * string came from and writes THERE — see console/contentPaths.ts for
   * why the composition is never edited directly.
   */
  const editText = useCallback(
    (before: string, after: string): EditResult => {
      if (!slide) return { ok: false, message: "no slide" };
      if (before.trim() === after.trim()) return { ok: true, message: "" };

      const target: ContentPath | null = findContentPath(slide.content, before);
      if (!target) {
        return {
          ok: false,
          message:
            "这段文字来自版式骨架（框架标题 / 编号 / 轴标签），不是你的内容，改不了",
        };
      }
      const content: SlideContent = writeContentPath(slide.content, target, after);
      patchSlide(slide.id, (s) => ({ ...s, content }));
      setLastEdit(describePath(target));
      return { ok: true, message: `已写入 ${describePath(target)}` };
    },
    [slide, patchSlide],
  );

  const persist = useCallback(async () => {
    setSave("saving");
    try {
      const response = await fetch("/__deck", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(deck),
      });
      if (!response.ok) throw new Error(await response.text());
      setSave("saved");
      // Back to a neutral label after a beat; "saved" forever reads as
      // though nothing since has been touched.
      setTimeout(() => setSave((s) => (s === "saved" ? "clean" : s)), 1600);
    } catch {
      setSave("error");
    }
  }, [deck]);

  return {
    deck,
    slide,
    variant,
    index,
    setIndex,
    selectVariant,
    setProp,
    editText,
    persist,
    save,
    lastEdit,
  };
}
