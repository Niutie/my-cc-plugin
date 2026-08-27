/* ─────────────────────────────────────────────────────────────────────
 * archetypes/index.ts — the registry.
 *
 * Fifteen skeletons across the composition families. They are starting
 * shapes, not a template library: anything they can't hold goes to a
 * bespoke composition. Keeping the set small is deliberate — a big
 * layout library is an asset one person cannot maintain, and it pushes
 * the agent toward "pick a pretty page" instead of "look at the
 * content, then pick".
 *
 * Coverage is checked by family, not by count. Every family in
 * CompositionFamily must have at least one archetype, or a deck told to
 * vary its families has nowhere to go.
 * ───────────────────────────────────────────────────────────────────── */

import { chartFull, chartLed, comparisonSplit, metricWall } from "./data";
import { metricSpotlight } from "./metric-spotlight";
import { MODEL_ARCHETYPES } from "./models";
import {
  agendaNumbered,
  closing,
  coverHero,
  coverSplit,
  statement,
} from "./openers";
import {
  caseDetail,
  listCards,
  matrix2x2,
  processFlow,
  timelineSteps,
} from "./structure";
import type { Archetype } from "./types";

export const ARCHETYPE_LIST: Archetype[] = [
  // openers
  coverHero,
  coverSplit,
  statement,
  agendaNumbered,
  closing,
  // data
  metricSpotlight,
  metricWall,
  chartLed,
  chartFull,
  comparisonSplit,
  // structure
  timelineSteps,
  processFlow,
  matrix2x2,
  listCards,
  caseDetail,
  // analysis frameworks — fixed skeletons, content fills the cells
  ...MODEL_ARCHETYPES,
];

/** Frameworks are addressed by name, so a deck can ask for "model-swot". */
export const ARCHETYPES: Record<string, Archetype> = Object.fromEntries(
  ARCHETYPE_LIST.map((a) => [a.id, a]),
);

/** Archetypes whose geometry implements a given composition family. */
export function byFamily(family: string): Archetype[] {
  return ARCHETYPE_LIST.filter((a) => a.family === family);
}

export type { Archetype } from "./types";
