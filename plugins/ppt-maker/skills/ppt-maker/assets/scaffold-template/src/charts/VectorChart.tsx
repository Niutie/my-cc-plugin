/* ─────────────────────────────────────────────────────────────────────
 * charts/VectorChart.tsx — SVG renderer for the primitive layer.
 *
 * One component draws all 18 chart kinds, because by the time anything
 * gets here a chart is just a list of primitives. Adding a chart never
 * means touching this file.
 * ───────────────────────────────────────────────────────────────────── */

import type { Rect } from "../deck/layout";
import type { ChartSpec } from "../deck/types";
import { paintCss, pathToSvg, type Primitive } from "./primitives";
import { chartDef } from "./registry";

const FAMILY = {
  display: "var(--font-display-cn), var(--font-display-en)",
  body: "var(--font-body)",
  mono: "var(--font-mono)",
} as const;

export function VectorChart({ spec, rect }: { spec: ChartSpec; rect: Rect }) {
  const { primitives } = chartDef(spec.kind).build(spec, rect);

  return (
    <svg
      width={rect.w}
      height={rect.h}
      viewBox={`0 0 ${rect.w} ${rect.h}`}
      style={{ overflow: "visible" }}
      role="img"
      aria-label={spec.series.map((s) => s.name).join("、")}
    >
      {/* Primitives are absolute stage px; shift once into element space
          instead of making every builder aware of where it was placed. */}
      <g transform={`translate(${-rect.x} ${-rect.y})`}>
        {primitives.map((p, i) => (
          <Prim key={i} p={p} />
        ))}
      </g>
    </svg>
  );
}

function Prim({ p }: { p: Primitive }) {
  switch (p.kind) {
    case "rect":
      return (
        <rect
          x={p.x}
          y={p.y}
          width={Math.max(0, p.w)}
          height={Math.max(0, p.h)}
          rx={p.radius}
          fill={p.fill ? paintCss(p.fill) : "none"}
          fillOpacity={p.opacity}
          stroke={p.stroke ? paintCss(p.stroke) : undefined}
          strokeWidth={p.strokeW}
        />
      );

    case "ellipse":
      return (
        <ellipse
          cx={p.x + p.w / 2}
          cy={p.y + p.h / 2}
          rx={p.w / 2}
          ry={p.h / 2}
          fill={p.fill ? paintCss(p.fill) : "none"}
          fillOpacity={p.opacity}
          stroke={p.stroke ? paintCss(p.stroke) : undefined}
          strokeWidth={p.strokeW}
        />
      );

    case "line":
      return (
        <line
          x1={p.x1}
          y1={p.y1}
          x2={p.x2}
          y2={p.y2}
          stroke={paintCss(p.stroke)}
          strokeWidth={p.strokeW ?? 1}
          strokeDasharray={p.dash ? "4 4" : undefined}
        />
      );

    case "path":
      return (
        <path
          d={pathToSvg(p)}
          fill={p.fill ? paintCss(p.fill) : "none"}
          fillOpacity={p.opacity}
          stroke={p.stroke ? paintCss(p.stroke) : undefined}
          strokeWidth={p.strokeW}
          strokeLinejoin="round"
          strokeLinecap="round"
        />
      );

    case "text": {
      const anchor =
        p.align === "center" ? "middle" : p.align === "right" ? "end" : "start";
      const x =
        p.align === "center" ? p.x + p.w / 2 : p.align === "right" ? p.x + p.w : p.x;
      const y =
        p.valign === "top"
          ? p.y + p.sizePx * 0.9
          : p.valign === "bottom"
            ? p.y + p.h
            : p.y + p.h / 2;
      return (
        <text
          x={x}
          y={y}
          textAnchor={anchor}
          dominantBaseline={p.valign === "middle" ? "middle" : "auto"}
          fill={paintCss(p.color)}
          fontFamily={FAMILY[p.family ?? "body"]}
          fontSize={p.sizePx}
          fontWeight={p.weight}
          transform={p.rotate ? `rotate(${p.rotate} ${x} ${y})` : undefined}
        >
          {p.text}
        </text>
      );
    }
  }
}
