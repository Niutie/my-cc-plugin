#!/usr/bin/env bash
# Migrate category:harness entries from sprint-status.yaml.retro_action_items
# to .claude/harness/upstream-feedback.md.
#
# Detects "harness" 类的 retro action items（plugin 维护方的债，不是项目侧的），
# 把它们搬到 upstream-feedback.md（plugin 用户用来汇总后提 GitHub issue），
# sprint-status.yaml 里被迁的条目 status 翻成 'migrated-upstream' 留 audit 痕迹（**不**删行；
# 用户后续可手工清掉 commented block）。
#
# Two modes:
#   --dry-run   (default) Print preview JSON + human-readable plan; no file writes
#   --apply     Actually do migration: append to upstream-feedback.md, mutate sprint-status.yaml
#
# Safety:
#   --apply 写动作前会备份 sprint-status.yaml → sprint-status.yaml.bak.<timestamp>
#   upstream-feedback.md 不存在时自动 bootstrap 自 plugin templates/（fallback 内嵌 minimal header）
#   migration 幂等：已 status=migrated-upstream 的条目本工具不会重复迁
#
# Exit code:
#   0  — success（dry-run 或 apply 都返 0）
#   2  — sprint-status.yaml 缺
#   3  — retro_action_items 块缺
#   4  — --apply 时 plugin templates/ 不可达且 fallback 写失败（罕见）
#
# Usage:
#   bash .claude/harness/scripts/extract_harness_feedback.sh                # dry-run
#   bash .claude/harness/scripts/extract_harness_feedback.sh --dry-run      # explicit
#   bash .claude/harness/scripts/extract_harness_feedback.sh --apply        # actually migrate

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh"

MODE="dry-run"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  MODE="dry-run"; shift;;
        --apply)    MODE="apply"; shift;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg: $1" >&2
            echo "Usage: $0 [--dry-run | --apply]" >&2
            exit 2
            ;;
    esac
done

SS_PATH="$HARNESS_SPRINT_STATUS_PATH"
UF_PATH="$HARNESS_REPO_ROOT/.claude/harness/upstream-feedback.md"

# Detector preflight
DETECT_JSON="$(bash "$SCRIPT_DIR/detect_harness_residue.sh" "$SS_PATH" 2>/dev/null || true)"
DETECT_EXIT=$?

if [ "$DETECT_EXIT" = "2" ]; then
    echo "ERROR: sprint-status.yaml missing at $SS_PATH" >&2
    exit 2
fi
if [ "$DETECT_EXIT" = "3" ]; then
    echo "ERROR: retro_action_items block missing in $SS_PATH" >&2
    exit 3
fi

COUNT="$(printf '%s' "$DETECT_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("count",0))')"

if [ "$COUNT" = "0" ]; then
    echo "✅ 无 unmigrated category:harness 条目（count=0）"
    echo "   sprint-status.yaml 已干净；upstream-feedback.md 无需变动"
    exit 0
fi

echo "⚠️  发现 ${COUNT} 条 unmigrated category:harness 条目（来自 sprint-status.yaml.retro_action_items）"
echo

# Pretty-print preview from JSON
DETECT_JSON_ENV="$DETECT_JSON" python3 <<'PYEOF'
import json
import os

data = json.loads(os.environ["DETECT_JSON_ENV"])
by_epic: dict[str, list] = {}
for item in data["items"]:
    by_epic.setdefault(item["epic"], []).append(item)
for epic, items in by_epic.items():
    print(f"## {epic}")
    for it in items:
        desc = it["description"] or "(无 inline description)"
        print(f"  - {it['code']} `[status:{it['status']}]` — {desc}")
        if it["chore_spec"]:
            print(f"     · chore_spec: {it['chore_spec']}")
    print()
PYEOF

if [ "$MODE" = "dry-run" ]; then
    echo "─────────────────────────────────────────────────────"
    echo "DRY RUN — 上述条目 **不会** 被实际迁移。"
    echo "执行迁移：bash $0 --apply"
    echo
    echo "迁移行为："
    echo "  1. 追加到 .claude/harness/upstream-feedback.md（不存在则 bootstrap）"
    echo "  2. sprint-status.yaml 里被迁条目 status 翻 'migrated-upstream'（保留行 + audit）"
    echo "  3. sprint-status.yaml 备份到 .bak.<timestamp>"
    exit 0
fi

# ─── apply mode ───────────────────────────────────────────

# Bootstrap upstream-feedback.md if missing
if [ ! -f "$UF_PATH" ]; then
    PLUGIN_TPL=""
    # Try to locate plugin templates/ — first env var, then standard locations
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/templates/upstream-feedback.md.template" ]; then
        PLUGIN_TPL="$CLAUDE_PLUGIN_ROOT/templates/upstream-feedback.md.template"
    else
        # Scan plugin install dirs (mirror init/update logic, kept minimal here)
        while IFS= read -r manifest; do
            if grep -q '"name":[[:space:]]*"harness-zh"' "$manifest" 2>/dev/null; then
                cand="$(dirname "$(dirname "$manifest")")/templates/upstream-feedback.md.template"
                if [ -f "$cand" ]; then
                    PLUGIN_TPL="$cand"
                    break
                fi
            fi
        done < <(find ~/.claude/plugins -maxdepth 6 -name plugin.json 2>/dev/null)
    fi

    mkdir -p "$(dirname "$UF_PATH")"
    if [ -n "$PLUGIN_TPL" ] && [ -f "$PLUGIN_TPL" ]; then
        cp "$PLUGIN_TPL" "$UF_PATH"
    else
        # Inline minimal fallback
        cat > "$UF_PATH" <<'TPL'
# Harness/Plugin Upstream Feedback

> 给 harness-zh plugin 维护方的改进建议汇总（migration tool fallback header；
> 完整模板见 plugin templates/upstream-feedback.md.template）。

---

TPL
        if [ ! -f "$UF_PATH" ]; then
            echo "ERROR: 写 $UF_PATH 失败（fallback 也写不出）" >&2
            exit 4
        fi
    fi
    echo "✅ Bootstrapped: $UF_PATH"
fi

# Backup sprint-status.yaml
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_PATH="${SS_PATH}.bak.${TS}"
cp "$SS_PATH" "$BACKUP_PATH"
echo "✅ Backup: $BACKUP_PATH"

# Apply: append to UF + mutate SS in-place via python
export DETECT_JSON UF_PATH SS_PATH

python3 <<'PYEOF'
"""Apply harness-feedback migration:
   1. Append items to upstream-feedback.md grouped by epic (preserving any existing sections).
   2. Mutate sprint-status.yaml: change <CODE>: <status> line to <CODE>: migrated-upstream
      for each migrated entry.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
from pathlib import Path

detect = json.loads(os.environ["DETECT_JSON"])
items = detect["items"]
uf_path = Path(os.environ["UF_PATH"])
ss_path = Path(os.environ["SS_PATH"])

# 1) Append to upstream-feedback.md
by_epic: dict[str, list] = {}
for it in items:
    by_epic.setdefault(it["epic"], []).append(it)

today = dt.date.today().isoformat()
existing = uf_path.read_text(encoding="utf-8")
section_re = re.compile(r"^## From: (\S+)", re.MULTILINE)
existing_sections = {m.group(1) for m in section_re.finditer(existing)}

append_blocks: list[str] = []
for epic in sorted(by_epic.keys()):
    block_lines = []
    if epic in existing_sections:
        # Append to existing section by adding a sub-heading marker per migration date
        block_lines.append(f"### Migrated on {today}")
    else:
        block_lines.append(f"## From: {epic} (migrated {today})")
    block_lines.append("")
    for it in by_epic[epic]:
        desc = it["description"] or "(无 inline description — retro 文档原文待补)"
        block_lines.append(f"- **{it['code']}** `[status:pending]` — {desc}")
        block_lines.append(
            f"  - 上下文：自 sprint-status.yaml.retro_action_items.{epic}.{it['code']} 迁入"
            f"（原 status: {it['status']}）"
        )
        if it["chore_spec"]:
            block_lines.append(
                f"  - 关联：plugin repo chore-spec 建议 `{it['chore_spec']}`"
            )
    block_lines.append("")
    append_blocks.append("\n".join(block_lines))

new_uf = existing.rstrip() + "\n\n---\n\n" + "\n---\n\n".join(append_blocks).rstrip() + "\n"
uf_path.write_text(new_uf, encoding="utf-8")
print(f"✅ Appended {len(items)} item(s) to {uf_path}")

# 2) Mutate sprint-status.yaml: rewrite each migrated <CODE>: <status> line
ss_text = ss_path.read_text(encoding="utf-8")
ss_lines = ss_text.splitlines(keepends=True)

# Build a fast lookup: (epic, code) → True for items to migrate
to_migrate = {(it["epic"], it["code"]) for it in items}

# Walk the retro_action_items block, replace matching code lines
top_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*:")
epic_re = re.compile(r"^  ([A-Za-z][A-Za-z0-9_-]+):\s*(?:#.*)?$")
code_re = re.compile(r"^(    )([A-Za-z][A-Za-z0-9-]*)(:\s*)([A-Za-z][A-Za-z0-9-]*)(\s*(?:#.*)?)$")

in_block = False
current_epic: str | None = None
mutations = 0

for i, line in enumerate(ss_lines):
    if line.startswith("retro_action_items:"):
        in_block = True
        continue
    if in_block:
        # next top-level key ends the block
        stripped_line = line.rstrip("\n")
        if stripped_line and top_re.match(stripped_line):
            in_block = False
            continue
        m_epic = epic_re.match(stripped_line)
        if m_epic:
            current_epic = m_epic.group(1)
            continue
        m_code = code_re.match(stripped_line)
        if m_code and current_epic:
            code = m_code.group(2)
            if (current_epic, code) in to_migrate:
                # Preserve indent + code: + comment; rewrite status only
                new_line = (
                    m_code.group(1)  # leading 4 spaces
                    + m_code.group(2)  # code
                    + m_code.group(3)  # ': '
                    + "migrated-upstream"  # new status
                    + m_code.group(5)  # trailing comment
                    + "\n"
                )
                ss_lines[i] = new_line
                mutations += 1

ss_path.write_text("".join(ss_lines), encoding="utf-8")
print(f"✅ Mutated {mutations} status field(s) in {ss_path}")
PYEOF

echo
echo "迁移完成。下一步建议："
echo "  1. 看 diff: git diff ${SS_PATH} ${UF_PATH}"
echo "  2. review upstream-feedback.md，按需 merge / 删噪音"
echo "  3. 准备好后到 https://github.com/Niutie/my-cc-plugin/issues 提 issue"
echo "  4. 备份在 ${BACKUP_PATH}（确认无误后可删）"
