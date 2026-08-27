/* ─────────────────────────────────────────────────────────────────────
 * render/SlideView.tsx — the HTML renderer.
 *
 * Walks a compiled Composition and paints it with absolute positions
 * taken from deck/layout.ts. It does not compute geometry and it does
 * not read the deck's raw variants — by the time anything gets here it
 * is already a flat element list, exactly what the PPTX exporter sees.
 *
 * Every colour is a theme token (`var(--…)`); nothing hard-codes a hex.
 * That is what lets a deck change theme by swapping one CSS file.
 * ───────────────────────────────────────────────────────────────────── */

import { createContext, useContext, type CSSProperties, type ReactNode } from "react";
import { VectorChart } from "../charts/VectorChart";
import { listRows, metricBlocks } from "../deck/blocks";
import { elementRect, type Padding, type Rect } from "../deck/layout";
import { LIST, METRIC, TYPE } from "../deck/typography";
import type {
  ChartEl,
  Composition,
  Element,
  ListEl,
  MetricEl,
  ShapeEl,
  TextEl,
} from "../deck/types";

const FONT: Record<"display" | "body" | "mono", string> = {
  display: "var(--font-display-cn), var(--font-display-en)",
  body: "var(--font-body)",
  mono: "var(--font-mono)",
};

/**
 * Set by the console. When present, every string that came from the
 * deck's canonical content becomes editable in place — see
 * console/contentPaths.ts for where the edit actually lands.
 */
export type EditFn = (before: string, after: string) => void;
const EditContext = createContext<EditFn | null>(null);
export const EditProvider = EditContext.Provider;

/**
 * A run of text that may be edited in place. `contentEditable` holds the
 * DOM copy while the user types; on blur the value goes to the canonical
 * content and React re-renders from there, so the DOM is never the
 * source of truth even for a moment longer than a keystroke.
 */
function T({ children }: { children: ReactNode }) {
  const edit = useContext(EditContext);
  if (!edit || typeof children !== "string" || !children) return <>{children}</>;
  return (
    <span
      contentEditable
      suppressContentEditableWarning
      data-no-advance
      spellCheck={false}
      style={{ outline: "none", cursor: "text" }}
      onBlur={(e) => edit(children, e.currentTarget.textContent ?? "")}
      onKeyDown={(e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          e.currentTarget.blur();
        }
        e.stopPropagation();
      }}
    >
      {children}
    </span>
  );
}

const SURFACE: Record<string, string> = {
  surface: "var(--surface)",
  "surface-2": "var(--surface-2)",
  shell: "var(--shell)",
  accent: "var(--accent)",
  "accent-soft": "var(--accent-soft)",
};

export function SlideView({
  composition,
  padding,
}: {
  composition: Composition;
  padding: Padding;
}) {
  // A plain `surface` page paints NOTHING: .stage-frame is already
  // var(--surface) and carries the theme's decoration layer (hairline
  // grid, paper grain, scanlines). Painting an opaque surface here would
  // bury the one thing that makes a theme recognisable. Only a page that
  // genuinely departs from the default background fills.
  const fill =
    composition.background && composition.background !== "surface"
      ? SURFACE[composition.background]
      : undefined;

  return (
    <div className="slide" style={{ background: fill }}>
      {composition.elements.map((el) => (
        <ElementView key={el.id} el={el} padding={padding} />
      ))}
    </div>
  );
}

function ElementView({ el, padding }: { el: Element; padding: Padding }) {
  const rect = elementRect(el, padding);
  const base: CSSProperties = {
    position: "absolute",
    left: rect.x,
    top: rect.y,
    width: rect.w,
    height: rect.h,
  };

  switch (el.type) {
    case "text":
      return <TextView el={el} style={base} />;
    case "metric":
      return (
        <div style={base}>
          <MetricView el={el} rect={rect} />
        </div>
      );
    case "list":
      return (
        <div style={base}>
          <ListView el={el} rect={rect} />
        </div>
      );
    case "shape":
      return <ShapeView el={el} style={base} />;
    case "chart":
      return <ChartView el={el} style={base} rect={rect} />;
    default:
      return null;
  }
}

/* ── text ────────────────────────────────────────────────────────── */

function TextView({ el, style }: { el: TextEl; style: CSSProperties }) {
  const spec = TYPE[el.role];
  const justify =
    el.valign === "middle"
      ? "center"
      : el.valign === "bottom"
        ? "flex-end"
        : "flex-start";

  return (
    <div style={{ ...style, display: "flex", flexDirection: "column", justifyContent: justify }}>
      <span
        style={{
          fontFamily: FONT[spec.family],
          fontSize: spec.sizePx,
          // Display roles follow the theme's weight knob when it sets one
          // (swiss-ikb goes 200 — "the bigger it gets, the thinner it is").
          fontWeight:
            el.role === "title" || el.role === "quote"
              ? (`var(--title-weight, ${spec.weight})` as CSSProperties["fontWeight"])
              : spec.weight,
          lineHeight: spec.lineHeight,
          letterSpacing: `${spec.tracking}em`,
          color: el.accent ? "var(--accent)" : `var(--${spec.color})`,
          textAlign: el.align ?? "left",
          textTransform: spec.uppercase ? "uppercase" : undefined,
          whiteSpace: "pre-wrap",
        }}
      >
        <T>{el.text}</T>
      </span>
    </div>
  );
}

/* ── metric ──────────────────────────────────────────────────────── */

function MetricView({
  el,
  rect,
}: {
  el: MetricEl;
  rect: Rect;
}) {
  const align = el.align ?? "left";
  const blocks = metricBlocks(el, rect);
  // Sub-rects are absolute stage px; the element wrapper is at rect.x/y,
  // so shift them into element-local space.
  const local = (r: Rect): CSSProperties => ({
    position: "absolute",
    left: r.x - rect.x,
    top: r.y - rect.y,
    width: r.w,
    height: r.h,
    textAlign: align,
  });

  return (
    <>
      {blocks.label && el.label && (
        <span
          style={{
            ...local(blocks.label),
            fontFamily: FONT.mono,
            fontSize: METRIC.label.sizePx,
            letterSpacing: `${METRIC.label.tracking}em`,
            textTransform: "uppercase",
            color: "var(--text-mute)",
          }}
        >
          <T>{el.label}</T>
        </span>
      )}
      <span
        style={{
          ...local(blocks.value),
          fontFamily: "var(--hero-num-font, var(--font-display-en))",
          fontStyle: "var(--hero-num-style, normal)" as CSSProperties["fontStyle"],
          fontWeight:
            `var(--hero-num-weight, ${METRIC.value.weight})` as CSSProperties["fontWeight"],
          fontSize: blocks.valueSize,
          lineHeight: `${blocks.value.h}px`,
          letterSpacing: `${METRIC.value.tracking}em`,
          color: el.accent ? "var(--accent)" : "var(--text)",
          fontVariantNumeric: "tabular-nums",
          whiteSpace: "nowrap",
        }}
      >
        <T>{el.value}</T>
        {el.unit && (
          <span style={{ fontSize: blocks.unitSize, fontWeight: 400 }}>
            {el.unit}
          </span>
        )}
      </span>
      {blocks.detail && el.detail && (
        <span
          style={{
            ...local(blocks.detail),
            fontFamily: FONT.body,
            fontSize: METRIC.detail.sizePx,
            lineHeight: METRIC.detail.lineHeight,
            color: "var(--text-mute)",
          }}
        >
          <T>{el.detail}</T>
        </span>
      )}
    </>
  );
}

/* ── list ────────────────────────────────────────────────────────── */

function ListView({ el, rect }: { el: ListEl; rect: Rect }) {
  const rows = listRows(el, rect);
  const local = (r: Rect): CSSProperties => ({
    position: "absolute",
    left: r.x - rect.x,
    top: r.y - rect.y,
    width: r.w,
    height: r.h,
  });

  return (
    <>
      {rows.map((row) => {
        const item = el.items[row.index];
        return (
          <div key={item.id ?? row.index}>
            {el.style === "card" && (
              <div
                style={{
                  ...local(row.box),
                  background: "var(--surface-2)",
                  borderRadius: "var(--r-card)",
                }}
              />
            )}
            {el.style === "rule" && (
              <div
                style={{
                  ...local({ ...row.box, h: 0 }),
                  borderTop:
                    "var(--rule-w, 1px) var(--rule-style, solid) var(--rule)",
                }}
              />
            )}
            {row.marker && (
              <span
                style={{
                  ...local(row.marker),
                  fontFamily: FONT.mono,
                  fontSize: LIST.label.sizePx,
                  lineHeight: `${row.marker.h}px`,
                  color: "var(--accent)",
                }}
              >
                {el.style === "numbered"
                  ? String(row.index + 1).padStart(2, "0")
                  : "•"}
              </span>
            )}
            <span
              style={{
                ...local(row.label),
                fontFamily: FONT.display,
                fontSize: LIST.label.sizePx,
                fontWeight: LIST.label.weight,
                lineHeight: `${row.label.h}px`,
                color: "var(--text)",
              }}
            >
              <T>{item.label}</T>
            </span>
            {row.detail && item.detail && (
              <span
                style={{
                  ...local(row.detail),
                  fontFamily: FONT.body,
                  fontSize: LIST.detail.sizePx,
                  lineHeight: `${row.detail.h}px`,
                  color: "var(--text-mute)",
                }}
              >
                <T>{item.detail}</T>
              </span>
            )}
          </div>
        );
      })}
    </>
  );
}

/* ── shape ───────────────────────────────────────────────────────── */

function ShapeView({ el, style }: { el: ShapeEl; style: CSSProperties }) {
  if (el.shape === "line") {
    const colour = el.stroke === "accent" ? "var(--accent)" : "var(--rule)";
    const edge = `var(--rule-w, 1px) var(--rule-style, solid) ${colour}`;
    const vertical = el.orient === "vertical";
    return (
      <div
        style={{
          ...style,
          ...(vertical
            ? { width: 0, left: (style.left as number) + (style.width as number) / 2, borderLeft: edge }
            : { height: 0, borderTop: edge }),
        }}
      />
    );
  }
  // clip-path mirrors PowerPoint's preset geometry of the same name, so
  // the two renderings agree on the silhouette as well as the box.
  const CLIP: Partial<Record<typeof el.shape, string>> = {
    diamond: "polygon(50% 0%, 100% 50%, 50% 100%, 0% 50%)",
    triangle: "polygon(50% 0%, 100% 100%, 0% 100%)",
    chevron: "polygon(0% 0%, 82% 0%, 100% 50%, 82% 100%, 0% 100%, 18% 50%)",
  };
  const clip = CLIP[el.shape];

  return (
    <div
      style={{
        ...style,
        background: el.fill && el.fill !== "none" ? SURFACE[el.fill] : "transparent",
        border:
          !clip && el.stroke && el.stroke !== "none"
            ? `var(--rule-w, 1px) solid ${
                el.stroke === "accent" ? "var(--accent)" : "var(--rule)"
              }`
            : undefined,
        borderRadius:
          el.shape === "ellipse" ? "50%" : clip ? 0 : "var(--r-card)",
        clipPath: clip,
      }}
    />
  );
}

/* ── chart ───────────────────────────────────────────────────────── */

function ChartView({
  el,
  style,
  rect,
}: {
  el: ChartEl;
  style: CSSProperties;
  rect: Rect;
}) {
  return (
    <div style={style}>
      <VectorChart spec={el.chart} rect={rect} />
      {el.caption && (
        <div
          style={{
            position: "absolute",
            left: 0,
            bottom: -4,
            fontFamily: FONT.body,
            fontSize: 15,
            color: "var(--text-mute)",
          }}
        >
          {el.caption}
        </div>
      )}
    </div>
  );
}
