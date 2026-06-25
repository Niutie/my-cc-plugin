import "./CaptureGate.css";

interface Props {
  visible: boolean;
}

/**
 * Solid-black pre-roll for `?capture=1` headless recording.
 *
 * Held up until `window.__capture.start()` fires. Two jobs:
 *   1. Give the recorder a uniform black lead-in that ffmpeg `blackdetect`
 *      can find — that's how the recorder learns exactly where on-screen
 *      content begins, to trim the head and align the rebuilt audio track.
 *   2. Keep the first scene unmounted until start, so step 0's entry
 *      animation plays from the top the instant recording begins (same
 *      trick as AutoStartGate).
 *
 * Intentionally has NO fade / animation — the lead-in must be a clean,
 * static black so the black→content transition is a single crisp edge.
 */
export function CaptureGate({ visible }: Props) {
  if (!visible) return null;
  return <div className="capture-gate" data-no-advance aria-hidden />;
}
