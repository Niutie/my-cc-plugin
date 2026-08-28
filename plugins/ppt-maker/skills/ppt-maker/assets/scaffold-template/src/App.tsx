/* ─────────────────────────────────────────────────────────────────────
 * App.tsx — the deck shell.
 *
 * Three modes, all off the same state:
 *   ?capture=1   naked 1920×1080 frame for screenshots and export
 *   default      the deck, keyboard-driven
 *   console (c)  the editing panel, plus in-place text editing
 *
 * The console is dev-only in practice: it saves and exports through
 * Vite middlewares that a built deck doesn't have. That is on purpose —
 * a deck you send someone is a finished artefact, not a shared editor.
 * ───────────────────────────────────────────────────────────────────── */

import { useCallback, useEffect, useMemo, useState } from "react";
import deckData from "../deck.json";
import { Stage } from "./components/Stage";
import { CONSOLE_WIDTH, Console } from "./console/Console";
import { useDeck } from "./console/useDeck";
import { compileVariant } from "./deck/compile";
import type { Deck } from "./deck/types";
import { type Padding } from "./deck/layout";
import { useThemePadding } from "./hooks/useThemePadding";
import { EditProvider, SlideView } from "./render/SlideView";

const initial = deckData as unknown as Deck;
const params = new URLSearchParams(window.location.search);
const capture = params.has("capture");
const printing = params.has("print");

/** `?slide=3` opens on page 3 — used by screenshot / capture tooling. */
function initialIndex(): number {
  const raw = Number(params.get("slide"));
  if (!Number.isFinite(raw)) return 0;
  return Math.max(0, Math.min(initial.slides.length - 1, Math.round(raw) - 1));
}

/**
 * Print mode stacks every slide at exactly one PDF page each.
 *
 * A PDF page of 13.333 x 7.5 in is 1280 x 720 CSS px at Chrome's 96
 * px/inch, so the 1920x1080 stage is scaled by exactly 2/3 — the same
 * frame, no reflow, no second layout to keep in sync.
 */
const PRINT_SCALE = 2 / 3;

function PrintView({ deck, padding }: { deck: Deck; padding: Padding }) {
  return (
    <div className="print-root">
      {deck.slides.map((slide) => {
        const variant =
          slide.variants.find((v) => v.id === slide.selectedVariant) ??
          slide.variants[0];
        let composition = null;
        try {
          composition = variant
            ? compileVariant(variant, slide.content, { lang: deck.meta.lang })
            : null;
        } catch (error) {
          console.error(slide.id, error);
        }
        return (
          <div className="print-page" key={slide.id}>
            <div
              className="stage-frame print-frame"
              style={{ transform: `scale(${PRINT_SCALE})` }}
            >
              {composition && (
                <SlideView composition={composition} padding={padding} />
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}

export default function App() {
  const deckState = useDeck(initial);
  const { deck, slide, variant, index, setIndex } = deckState;
  const [consoleOpen, setConsoleOpen] = useState(params.has("console"));
  const [notice, setNotice] = useState<string | null>(null);
  const padding = useThemePadding();

  useEffect(() => {
    setIndex(initialIndex());
  }, [setIndex]);

  const composition = useMemo(() => {
    if (!slide || !variant) return null;
    try {
      return compileVariant(variant, slide.content, { lang: deck.meta.lang });
    } catch (error) {
      console.error(`slide ${slide.id} / variant ${variant.id}:`, error);
      return null;
    }
  }, [slide, variant, deck.meta.lang]);

  const go = useCallback(
    (delta: number) => {
      setIndex(Math.max(0, Math.min(deck.slides.length - 1, index + delta)));
    },
    [index, deck.slides.length, setIndex],
  );

  const onEdit = useCallback(
    (before: string, after: string) => {
      const result = deckState.editText(before, after);
      setNotice(result.message || null);
      if (result.message) setTimeout(() => setNotice(null), 4000);
    },
    [deckState],
  );

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      // Never steal keys from a field the user is typing into.
      const target = e.target as HTMLElement | null;
      if (target?.isContentEditable || /INPUT|SELECT|TEXTAREA/.test(target?.tagName ?? "")) {
        return;
      }
      if (e.key === "ArrowRight" || e.key === "PageDown") go(1);
      else if (e.key === "ArrowLeft" || e.key === "PageUp") go(-1);
      else if (e.key === "c" && !capture) setConsoleOpen((v) => !v);
      else if (e.key === "s" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        void deckState.persist();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [go, deckState]);

  if (!slide) return null;
  if (printing) return <PrintView deck={deck} padding={padding} />;

  return (
    <>
      <Stage
        onAdvance={() => go(1)}
        capture={capture}
        reserveRight={consoleOpen ? CONSOLE_WIDTH : 0}
      >
        {composition ? (
          <EditProvider value={consoleOpen ? onEdit : null}>
            <SlideView composition={composition} padding={padding} />
          </EditProvider>
        ) : (
          <div style={{ padding: 96, fontFamily: "var(--font-mono)" }}>
            slide “{slide.id}” failed to compile — see the console.
          </div>
        )}
        {!capture && (
          <div className="deck-hud">
            {index + 1} / {deck.slides.length} · {variant?.id} ·{" "}
            {consoleOpen ? "C 关闭控制台" : "C 打开控制台"}
          </div>
        )}
      </Stage>

      {consoleOpen && !capture && (
        <Console
          deck={deck}
          slide={slide}
          variant={variant}
          index={index}
          onIndex={setIndex}
          onSelectVariant={deckState.selectVariant}
          onProp={deckState.setProp}
          onSave={() => void deckState.persist()}
          save={deckState.save}
          lastEdit={deckState.lastEdit}
          notice={notice}
          onExport={() => void deckState.exportPptx()}
          exportState={deckState.exportState}
          exportNote={deckState.exportNote}
        />
      )}
    </>
  );
}
