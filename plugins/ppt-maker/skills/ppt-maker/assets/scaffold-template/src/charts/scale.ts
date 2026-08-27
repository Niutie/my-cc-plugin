/* ─────────────────────────────────────────────────────────────────────
 * charts/scale.ts — the numeric side of charting.
 *
 * Tick selection and value formatting only. Where things go is
 * frame.ts; what they look like is the kinds/. Kept separate because
 * these two functions are the ones every chart needs and none should
 * reimplement.
 * ───────────────────────────────────────────────────────────────────── */

/**
 * "Nice" round tick values — the 1 / 2 / 2.5 / 5 / 10 progression every
 * charting library converges on, because those are the intervals people
 * read without doing arithmetic.
 */
export function niceTicks(
  rawMin: number,
  rawMax: number,
  target = 5,
): { min: number; max: number; step: number; values: number[] } {
  if (!Number.isFinite(rawMin) || !Number.isFinite(rawMax) || rawMin === rawMax) {
    const base = Number.isFinite(rawMax) ? rawMax : 1;
    const span = Math.abs(base) || 1;
    rawMin = Math.min(0, base - span);
    rawMax = Math.max(0, base + span);
  }

  const span = rawMax - rawMin;
  const rough = span / Math.max(1, target);
  const magnitude = Math.pow(10, Math.floor(Math.log10(rough)));
  const normalised = rough / magnitude;
  const stepFactor =
    normalised <= 1 ? 1 : normalised <= 2 ? 2 : normalised <= 2.5 ? 2.5 : normalised <= 5 ? 5 : 10;
  const step = stepFactor * magnitude;

  const min = Math.floor(rawMin / step) * step;
  const max = Math.ceil(rawMax / step) * step;

  const values: number[] = [];
  // Accumulate with an index rather than repeated addition so floating
  // point drift can't push a tick to 2.9999999999999996.
  const count = Math.round((max - min) / step);
  for (let i = 0; i <= count; i += 1) {
    values.push(round(min + i * step));
  }
  return { min, max, step, values };
}

function round(n: number): number {
  return Math.abs(n) < 1e-9 ? 0 : Number(n.toPrecision(12));
}

export function formatValue(value: number, unit?: string): string {
  // "0亿" reads as a quantity of nothing; a bare 0 reads as the origin.
  if (value === 0) return "0";
  const abs = Math.abs(value);
  const body =
    abs >= 1000
      ? value.toLocaleString("en-US")
      : Number.isInteger(value)
        ? String(value)
        : String(round(value));
  return unit ? `${body}${unit}` : body;
}
