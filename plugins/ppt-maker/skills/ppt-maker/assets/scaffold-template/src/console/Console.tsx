/* ─────────────────────────────────────────────────────────────────────
 * console/Console.tsx — the editing panel.
 *
 * Deliberately NOT themed: the console is chrome, not part of the deck.
 * It uses its own neutral palette so a dark theme's slide and a light
 * theme's slide get the same controls, and so nobody mistakes a console
 * colour for a deck colour in a screenshot.
 * ───────────────────────────────────────────────────────────────────── */

import type { CSSProperties } from "react";
import { ARCHETYPES } from "../archetypes";
import type { ArchetypeControl } from "../archetypes/types";
import type { Deck, Slide, Variant } from "../deck/types";
import type { ExportState, SaveState } from "./useDeck";

/** Shared with App so the stage can make room instead of hiding under it. */
export const CONSOLE_WIDTH = 340;

const PANEL: CSSProperties = {
  position: "fixed",
  top: 0,
  right: 0,
  bottom: 0,
  width: CONSOLE_WIDTH,
  zIndex: 50,
  background: "#16181c",
  color: "#e8eaed",
  fontFamily:
    "ui-sans-serif, -apple-system, 'Segoe UI', 'Noto Sans SC', sans-serif",
  fontSize: 13,
  lineHeight: 1.5,
  overflowY: "auto",
  padding: "18px 18px 40px",
  boxShadow: "-1px 0 0 rgba(255,255,255,0.08)",
};

const LABEL: CSSProperties = {
  fontSize: 11,
  letterSpacing: "0.09em",
  textTransform: "uppercase",
  color: "#8b929c",
  margin: "20px 0 8px",
};

export function Console({
  deck,
  slide,
  variant,
  index,
  onIndex,
  onSelectVariant,
  onProp,
  onSave,
  save,
  lastEdit,
  notice,
  onExport,
  exportState,
  exportNote,
}: {
  deck: Deck;
  slide: Slide;
  variant: Variant | undefined;
  index: number;
  onIndex(i: number): void;
  onSelectVariant(id: string): void;
  onProp(key: string, value: unknown): void;
  onSave(): void;
  save: SaveState;
  lastEdit: string | null;
  notice: string | null;
  onExport(): void;
  exportState: ExportState;
  exportNote: string | null;
}) {
  const archetype =
    variant?.kind === "archetype" ? ARCHETYPES[variant.archetype] : undefined;

  return (
    <div style={PANEL} data-no-advance>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
        <strong style={{ fontSize: 14 }}>{deck.meta.title}</strong>
        <span style={{ color: "#8b929c" }}>
          {index + 1} / {deck.slides.length}
        </span>
      </div>

      <div style={LABEL}>页面</div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
        {deck.slides.map((s, i) => (
          <button
            key={s.id}
            onClick={() => onIndex(i)}
            title={s.content.presentation.title}
            style={chip(i === index)}
          >
            {i + 1}
          </button>
        ))}
      </div>

      <div style={LABEL}>方案</div>
      <div style={{ display: "grid", gap: 6 }}>
        {slide.variants.map((v) => (
          <button
            key={v.id}
            onClick={() => onSelectVariant(v.id)}
            style={{
              ...chip(v.id === slide.selectedVariant),
              width: "100%",
              textAlign: "left",
              padding: "8px 10px",
            }}
          >
            <strong>{v.id}</strong>{" "}
            <span style={{ color: "#8b929c" }}>
              {v.kind === "archetype"
                ? (ARCHETYPES[v.archetype]?.name.zh ?? v.archetype)
                : `定制 · ${v.designIntent.compositionFamily}`}
            </span>
          </button>
        ))}
      </div>

      <div style={LABEL}>
        {archetype ? `控件 · ${archetype.name.zh}` : "控件"}
      </div>
      {archetype ? (
        <div style={{ display: "grid", gap: 14 }}>
          {archetype.controls.map((control) => (
            <Control
              key={control.key}
              control={control}
              value={
                variant?.kind === "archetype"
                  ? variant.props?.[control.key]
                  : undefined
              }
              onChange={(v) => onProp(control.key, v)}
            />
          ))}
        </div>
      ) : (
        <p style={{ color: "#8b929c", margin: 0 }}>
          定制方案没有控件 —— 它的构图由 Agent 逐页设计，改动请回到对话里说。
        </p>
      )}

      <div style={LABEL}>改文字</div>
      <p style={{ color: "#8b929c", margin: 0 }}>
        双击页面上的文字直接改。改动写回 <code>deck.json</code> 的内容层，
        换方案不会丢，导出 PPTX 会带上。
      </p>
      {notice && (
        <p style={{ margin: "8px 0 0", color: notice.startsWith("已写入") ? "#7fd18a" : "#f0a35e" }}>
          {notice}
        </p>
      )}
      {lastEdit && !notice && (
        <p style={{ margin: "8px 0 0", color: "#8b929c" }}>上次改了 {lastEdit}</p>
      )}

      <div style={LABEL}>保存</div>
      <button
        onClick={onSave}
        disabled={save === "saving"}
        style={{
          ...chip(save === "dirty"),
          width: "100%",
          padding: "10px 12px",
          cursor: save === "saving" ? "wait" : "pointer",
        }}
      >
        {
          {
            clean: "已是最新",
            dirty: "写回 deck.json",
            saving: "保存中…",
            saved: "已保存 ✓",
            error: "保存失败 —— dev server 在跑吗？",
          }[save]
        }
      </button>
      <p style={{ color: "#6d747e", margin: "10px 0 0", fontSize: 12 }}>
        保存后跑 <code>npm run check</code> 复核容量与坐标。
      </p>

      <div style={LABEL}>导出</div>
      <button
        onClick={onExport}
        disabled={exportState === "running"}
        style={{
          // Blue is "this button does something"; a failed or in-flight
          // export shouldn't wear the same coat as a ready one.
          ...chip(exportState === "idle" || exportState === "done"),
          width: "100%",
          padding: "10px 12px",
          cursor: exportState === "running" ? "wait" : "pointer",
        }}
      >
        {
          {
            idle: save === "dirty" ? "保存并导出 PPTX" : "导出 PPTX",
            running: "导出中…",
            done: "已下载 ✓",
            error: "导出失败",
          }[exportState]
        }
      </button>
      {exportNote && (
        <p
          style={{
            margin: "8px 0 0",
            color: "#f0a35e",
            fontSize: 12,
            whiteSpace: "pre-wrap",
            wordBreak: "break-word",
          }}
        >
          {exportNote}
        </p>
      )}
      {/* Spaces around inline <code> are explicit: JSX drops the
          whitespace that sits next to a line break. */}
      <p style={{ color: "#6d747e", margin: "10px 0 0", fontSize: 12 }}>
        跑的就是 <code>npm run export:pptx</code>，文件同时落在{" "}
        <code>dist/deck.pptx</code>。
      </p>
      <p style={{ color: "#6d747e", margin: "6px 0 0", fontSize: 12 }}>
        <strong style={{ color: "#8b929c" }}>不含几何校验</strong> —— 交付前仍要跑{" "}
        <code>npm run check</code>。同一条命令加 <code>-- --mode=comparison</code>{" "}
        可展开全部方案。
      </p>
    </div>
  );
}

function chip(active: boolean): CSSProperties {
  return {
    background: active ? "#2f6fed" : "#23262b",
    color: active ? "#fff" : "#c7ccd3",
    border: "1px solid " + (active ? "#2f6fed" : "#31353c"),
    borderRadius: 6,
    padding: "5px 9px",
    cursor: "pointer",
    font: "inherit",
  };
}

function Control({
  control,
  value,
  onChange,
}: {
  control: ArchetypeControl;
  value: unknown;
  onChange(value: unknown): void;
}) {
  const label = (
    <div style={{ display: "flex", justifyContent: "space-between", gap: 8 }}>
      <span>{control.label.zh}</span>
      {control.type === "range" && (
        <span style={{ color: "#8b929c" }}>
          {typeof value === "number" ? value : control.default}
        </span>
      )}
    </div>
  );

  if (control.type === "range") {
    return (
      <label style={{ display: "grid", gap: 6 }}>
        {label}
        <input
          type="range"
          min={control.min}
          max={control.max}
          step={control.step}
          value={typeof value === "number" ? value : control.default}
          onChange={(e) => onChange(Number(e.target.value))}
        />
        {control.hint && (
          <span style={{ color: "#6d747e", fontSize: 12 }}>{control.hint.zh}</span>
        )}
      </label>
    );
  }

  if (control.type === "toggle") {
    const on = typeof value === "boolean" ? value : control.default;
    return (
      <label style={{ display: "flex", gap: 9, alignItems: "center", cursor: "pointer" }}>
        <input type="checkbox" checked={on} onChange={(e) => onChange(e.target.checked)} />
        <span>{control.label.zh}</span>
      </label>
    );
  }

  return (
    <label style={{ display: "grid", gap: 6 }}>
      {label}
      <select
        value={typeof value === "string" ? value : control.default}
        onChange={(e) => onChange(e.target.value)}
        style={{
          background: "#23262b",
          color: "#e8eaed",
          border: "1px solid #31353c",
          borderRadius: 6,
          padding: "6px 8px",
          font: "inherit",
        }}
      >
        {control.options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label.zh}
          </option>
        ))}
      </select>
    </label>
  );
}
