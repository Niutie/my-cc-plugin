import { useEffect, useState } from "react";
import { DEFAULT_PADDING, type Padding } from "../deck/layout";

/**
 * Read the active theme's stage padding out of the live CSS custom
 * properties.
 *
 * The theme's tokens.css stays the single source of truth for padding —
 * the browser reads it here, the PPTX exporter parses the same file. So
 * a roomy theme and a dense one differ identically on screen and in the
 * exported deck, with no second copy of the number to keep in sync.
 */
export function useThemePadding(): Padding {
  const [padding, setPadding] = useState<Padding>(DEFAULT_PADDING);

  useEffect(() => {
    const style = getComputedStyle(document.documentElement);
    const read = (name: string, fallback: number) => {
      const raw = style.getPropertyValue(name).trim();
      const n = Number.parseFloat(raw);
      return Number.isFinite(n) ? n : fallback;
    };
    setPadding({
      x: read("--stage-pad-x", DEFAULT_PADDING.x),
      y: read("--stage-pad-y", DEFAULT_PADDING.y),
    });
  }, []);

  return padding;
}
