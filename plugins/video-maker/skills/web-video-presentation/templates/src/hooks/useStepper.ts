import { useCallback, useEffect, useMemo, useState } from "react";
import type { ChapterDef } from "../registry/types";

/**
 * Bump this when chapter step counts / structure change so old persisted
 * cursors don't land mid-removed-step.
 */
const STORAGE_KEY = "presentation-cursor-v4";

export type Cursor = { chapter: number; step: number };

export interface StepperState {
  cursor: Cursor;
  totalChapters: number;
  chapterTotalSteps: number;
  globalIndex: number;
  totalGlobal: number;
  next(): void;
  prev(): void;
  jumpToChapter(idx: number, step?: number): void;
  jumpToGlobal(globalIdx: number): void;
}

const clamp = (n: number, lo: number, hi: number) =>
  Math.max(lo, Math.min(hi, n));

/**
 * Clamp a (possibly stale) cursor to the current chapter list. Persisted
 * cursors can outlive structural changes — fewer chapters, fewer steps,
 * a different scaffolded project sharing the same dev-server origin — so
 * we always re-validate before handing one to React.
 */
function sanitize(cursor: Cursor, chapters: ChapterDef[]): Cursor {
  if (chapters.length === 0) return { chapter: 0, step: 0 };
  const chapter = clamp(cursor.chapter | 0, 0, chapters.length - 1);
  const stepCount = chapters[chapter]!.narrations.length;
  const step = clamp(cursor.step | 0, 0, Math.max(0, stepCount - 1));
  return { chapter, step };
}

export function useStepper(
  chapters: ChapterDef[],
  navBlocked = false,
): StepperState {
  // Captured ONCE at mount: was the page loaded with `?auto=1`? An auto-play
  // load is an ephemeral recording session — it always starts from the top
  // and never persists, so every refresh replays from the beginning and the
  // manual (dev) cursor in localStorage is left untouched. Switching to auto
  // later via the `M` key does NOT reset — only a fresh `?auto=1` load does.
  // (Corollary: a session that LOADED in auto and is then switched to manual
  // via `M` also won't persist for the rest of that session — intentional, so
  // a recording session never overwrites the dev cursor.)
  const [autoLoad] = useState(() => {
    if (typeof window === "undefined") return false;
    return new URLSearchParams(window.location.search).get("auto") === "1";
  });

  const [cursor, setCursor] = useState<Cursor>(() => {
    const fallback = { chapter: 0, step: 0 };
    if (typeof window === "undefined") return fallback;
    if (autoLoad) return fallback; // auto-play always starts from the beginning
    try {
      const raw = window.localStorage.getItem(STORAGE_KEY);
      if (raw) return sanitize(JSON.parse(raw), chapters);
    } catch {
      /* ignore */
    }
    return fallback;
  });

  // Re-sanitize if the chapter list shape changes after mount (e.g. HMR
  // updates `chapters.ts`) — keeps a stale persisted cursor from leaking
  // into a render where it's now out of range.
  useEffect(() => {
    setCursor((cur) => {
      const next = sanitize(cur, chapters);
      return next.chapter === cur.chapter && next.step === cur.step
        ? cur
        : next;
    });
  }, [chapters]);

  useEffect(() => {
    if (autoLoad) return; // ephemeral auto-play session — don't clobber the manual cursor
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(cursor));
    } catch {
      /* ignore */
    }
  }, [cursor, autoLoad]);

  const offsets = useMemo(() => {
    const arr: number[] = [];
    let acc = 0;
    for (const c of chapters) {
      arr.push(acc);
      acc += c.narrations.length;
    }
    return arr;
  }, [chapters]);
  const totalGlobal = useMemo(
    () => chapters.reduce((s, c) => s + c.narrations.length, 0),
    [chapters],
  );
  const globalIndex = (offsets[cursor.chapter] ?? 0) + cursor.step;

  const next = useCallback(() => {
    setCursor((cur) => {
      const c = chapters[cur.chapter]!;
      if (cur.step < c.narrations.length - 1)
        return { ...cur, step: cur.step + 1 };
      if (cur.chapter < chapters.length - 1)
        return { chapter: cur.chapter + 1, step: 0 };
      return cur;
    });
  }, [chapters]);

  const prev = useCallback(() => {
    setCursor((cur) => {
      if (cur.step > 0) return { ...cur, step: cur.step - 1 };
      if (cur.chapter > 0) {
        const p = chapters[cur.chapter - 1]!;
        return { chapter: cur.chapter - 1, step: p.narrations.length - 1 };
      }
      return cur;
    });
  }, [chapters]);

  const jumpToChapter = useCallback(
    (idx: number, step = 0) => {
      const ch = clamp(idx, 0, chapters.length - 1);
      const c = chapters[ch]!;
      setCursor({
        chapter: ch,
        step: clamp(step, 0, c.narrations.length - 1),
      });
    },
    [chapters],
  );

  const jumpToGlobal = useCallback(
    (g: number) => {
      const target = clamp(g, 0, totalGlobal - 1);
      let acc = 0;
      for (let i = 0; i < chapters.length; i++) {
        const t = chapters[i]!.narrations.length;
        if (target < acc + t) {
          setCursor({ chapter: i, step: target - acc });
          return;
        }
        acc += t;
      }
    },
    [chapters, totalGlobal],
  );

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement) return;
      // A modal start gate (AutoStartGate) is up — swallow nav keys so the
      // same Space that releases auto-play doesn't also advance past page 1.
      if (navBlocked) return;
      if (e.key === "ArrowRight" || e.key === " ") {
        e.preventDefault();
        next();
      } else if (e.key === "ArrowLeft" || e.key === "Backspace") {
        e.preventDefault();
        prev();
      } else if (e.key === "Home") {
        jumpToChapter(0, 0);
      } else if (e.key === "End") {
        const last = chapters.length - 1;
        jumpToChapter(last, chapters[last]!.narrations.length - 1);
      } else if (e.key >= "1" && e.key <= "9") {
        const n = Number(e.key) - 1;
        if (n < chapters.length) jumpToChapter(n, 0);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [next, prev, jumpToChapter, chapters, navBlocked]);

  const ch = chapters[cursor.chapter]!;
  return {
    cursor,
    totalChapters: chapters.length,
    chapterTotalSteps: ch.narrations.length,
    globalIndex,
    totalGlobal,
    next,
    prev,
    jumpToChapter,
    jumpToGlobal,
  };
}
