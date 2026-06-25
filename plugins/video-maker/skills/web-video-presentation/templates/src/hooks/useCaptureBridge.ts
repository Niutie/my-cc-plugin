import { useEffect, useRef, useState } from "react";
import type { ChapterDef } from "../registry/types";
import type { StepperState } from "./useStepper";

/** Read once at mount: was the page loaded with `?capture=1`? */
export function isCaptureMode(): boolean {
  if (typeof window === "undefined") return false;
  return new URLSearchParams(window.location.search).get("capture") === "1";
}

interface CaptureMeta {
  chapters: { id: string; title: string; steps: { text: string }[] }[];
}

interface Options {
  /** Only install the bridge when capture mode is active. */
  enabled: boolean;
  chapters: ChapterDef[];
  stepper: StepperState;
  /** Has playback been released? (set by start()) */
  started: boolean;
  /** Release playback — mounts the scene at the first step. */
  start: () => void;
}

/**
 * Headless-recording bridge for `?capture=1`.
 *
 * The `record-video.mjs` script (Playwright) drives the whole presentation
 * through `window.__capture` instead of audio-driven auto-advance:
 *
 *   __capture.ready            – truthy once the bridge is installed
 *   __capture.meta()           – full structure (chapters × steps + text),
 *                                INCLUDING silent steps, so the recorder can
 *                                build an exact per-step schedule offline
 *   __capture.start()          – release the black pre-roll, mount step 0
 *   __capture.advance()        – go to the next step (recorder's clock)
 *   __capture.goto(c, s)       – jump to chapter c / step s
 *   __capture.state()          – { chapter, step, started, atEnd }
 *
 * The browser plays NO audio in capture mode — the recorder reconstructs the
 * audio track from the per-step mp3 files with the same 200ms trailing pad
 * the runtime uses, so the rebuilt audio lines up with the recorded video by
 * construction (both are placed on one shared schedule). This keeps capture
 * deterministic and independent of headless audio-device quirks.
 *
 * No-op (installs nothing) when `enabled` is false, so normal manual / audio /
 * auto playback is completely untouched.
 */
export function useCaptureBridge({
  enabled,
  chapters,
  stepper,
  started,
  start,
}: Options): void {
  // Latest values, so the long-lived window functions never capture stale
  // closures across re-renders.
  const ref = useRef({ chapters, stepper, started, start });
  ref.current = { chapters, stepper, started, start };

  useEffect(() => {
    if (!enabled || typeof window === "undefined") return;

    const api = {
      ready: true as const,
      meta(): CaptureMeta {
        return {
          chapters: ref.current.chapters.map((c) => ({
            id: c.id,
            title: c.title,
            steps: c.narrations.map((text) => ({ text })),
          })),
        };
      },
      start() {
        ref.current.start();
      },
      advance() {
        ref.current.stepper.next();
      },
      goto(chapter: number, step = 0) {
        ref.current.stepper.jumpToChapter(chapter, step);
      },
      state() {
        const { stepper, chapters, started } = ref.current;
        const lastChapter = chapters.length - 1;
        const stepsInChapter =
          chapters[stepper.cursor.chapter]?.narrations.length ?? 1;
        return {
          chapter: stepper.cursor.chapter,
          step: stepper.cursor.step,
          started,
          atEnd:
            stepper.cursor.chapter === lastChapter &&
            stepper.cursor.step === stepsInChapter - 1,
        };
      },
    };

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (window as any).__capture = api;
    return () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      if ((window as any).__capture === api) delete (window as any).__capture;
    };
  }, [enabled]);
}
