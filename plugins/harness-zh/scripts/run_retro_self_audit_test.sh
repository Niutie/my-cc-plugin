#!/usr/bin/env bash
# run_retro_self_audit self-test
#
# review 2026-06-10 #10/#95：此前 `cd ../../..` 后直接跑宿主树的
# .claude/harness/scripts/run_retro_self_audit.sh — 源树没有部署副本，永远
# 跑不了；且旧 check_A4 的 aegis 硬编码路径会刷 stderr 噪音。现改为自举
# mktemp 沙箱 fixture：从同源树拷 scripts/ + prompt-suffixes/（源树布局
# plugins/harness-zh/{scripts,prompt-suffixes} 与部署布局
# .claude/harness/{scripts,prompt-suffixes} 相对结构一致，两边通跑），种子
# sprint-status.yaml + deferred-work.md 后在 fixture 内实测：
#   - 表头 / 行数 / A1 status enum / C9 自报 done（既有断言保留）
#   - Phase A #95 新行为：check_A4 输出 unknown 行（aegis 死引用已删）
#   - prev_epic=3 全程 stderr 干净（无 'No such file or directory' 噪音）
#   - prev_epic=1 仅 A 系列 8 行
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUFFIX_DIR="$SCRIPT_DIR/../prompt-suffixes"

if [ ! -f "$SCRIPT_DIR/run_retro_self_audit.sh" ]; then
    echo "ERROR: run_retro_self_audit.sh not found next to test" >&2
    exit 1
fi
if [ ! -f "$SUFFIX_DIR/bmad-dev-story-suffix.md" ]; then
    echo "ERROR: prompt-suffixes/bmad-dev-story-suffix.md not found at $SUFFIX_DIR" >&2
    exit 1
fi

# ---- self-bootstrapped sandbox fixture (EXIT trap cleanup) ----
WORKDIR="$(mktemp -d -t run_retro_self_audit_test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

FIXTURE="$WORKDIR/proj"
mkdir -p "$FIXTURE/.claude/harness/scripts" \
         "$FIXTURE/.claude/harness/prompt-suffixes" \
         "$FIXTURE/_bmad-output/implementation-artifacts"
cp "$SCRIPT_DIR"/*.sh "$FIXTURE/.claude/harness/scripts/"
cp "$SCRIPT_DIR"/*.py "$FIXTURE/.claude/harness/scripts/" 2>/dev/null || true
chmod +x "$FIXTURE/.claude/harness/scripts/"*.sh
cp "$SUFFIX_DIR"/*.md "$FIXTURE/.claude/harness/prompt-suffixes/"

cat > "$FIXTURE/_bmad-output/implementation-artifacts/sprint-status.yaml" <<'YAML'
development_status:
  epic-1: done
  epic-2: done
  epic-3: done
retro_action_items: {}
YAML
cat > "$FIXTURE/_bmad-output/implementation-artifacts/deferred-work.md" <<'YAML'
# Deferred Work

## 1. 总账

（fixture — A6 §1 物化检查用）
YAML

cd "$FIXTURE"

STDERR_E3="$WORKDIR/stderr-e3.log"
OUT="$(bash .claude/harness/scripts/run_retro_self_audit.sh 3 2>"$STDERR_E3")"

# 检查表头
if ! echo "$OUT" | head -1 | grep -qE '^\| id \| 描述 \| status \| evidence \|$'; then
    echo "FAIL: 表头格式不正确" >&2
    echo "$OUT" | head -3 >&2
    exit 1
fi

# 检查行数 ≥ 26（A1-A8 + B1-B9 + C1-C9）+ 2 表头
total_rows="$(echo "$OUT" | grep -c '^|' || true)"
if [ "$total_rows" -lt 28 ]; then
    echo "FAIL: 表格行数 $total_rows < 28（期望 ≥ 28：表头 1 + 表头分隔 1 + 26 数据行）" >&2
    exit 1
fi

# 检查 A1 出现且 status 字段是 done/pending/partial/unknown 之一
a1_row="$(echo "$OUT" | grep '^| A1 ' || true)"
if [ -z "$a1_row" ]; then
    echo "FAIL: A1 行缺失" >&2
    exit 1
fi
if ! echo "$a1_row" | grep -qE '\| (done|pending|partial|unknown) \|'; then
    echo "FAIL: A1 status 字段不在 4 类 enum 内" >&2
    echo "  row: $a1_row" >&2
    exit 1
fi

# Phase A review #95：check_A4 不再 grep aegis 专属路径 — 输出 unknown 行
# 并指引 clone 后按 PROJECT-SPECIFIC 声明重写
a4_row="$(echo "$OUT" | grep '^| A4 ' || true)"
if [ -z "$a4_row" ]; then
    echo "FAIL: A4 行缺失" >&2
    exit 1
fi
if ! echo "$a4_row" | grep -q '| unknown |'; then
    echo "FAIL: A4 应输出 unknown（aegis 死引用已删，project-specific 待重写）；实际：$a4_row" >&2
    exit 1
fi
if ! echo "$a4_row" | grep -q 'PROJECT-SPECIFIC'; then
    echo "FAIL: A4 evidence 应指引 PROJECT-SPECIFIC 重写；实际：$a4_row" >&2
    exit 1
fi

# Phase A review #95 连带：prev_epic=3 全程 stderr 必须干净（旧 check_A4 的
# `wc -l < <aegis path>` not-found 报错刷屏已根除）
if [ -s "$STDERR_E3" ]; then
    echo "FAIL: prev_epic=3 stderr 应为空；实际：" >&2
    head -5 "$STDERR_E3" >&2
    exit 1
fi

# 检查 C9 行（脚本自身落地后应自报 done）
c9_row="$(echo "$OUT" | grep '^| C9 ' || true)"
if [ -z "$c9_row" ]; then
    echo "FAIL: C9 行缺失" >&2
    exit 1
fi
if ! echo "$c9_row" | grep -q '| done |'; then
    echo "FAIL: C9 应自报 done（脚本已落地）；实际：$c9_row" >&2
    exit 1
fi

# 跑 prev_epic=1 仅扫 A* 系列
OUT_E1="$(bash .claude/harness/scripts/run_retro_self_audit.sh 1)"
e1_rows="$(echo "$OUT_E1" | grep -cE '^\| [ABC][0-9]' || true)"
if [ "$e1_rows" -ne 8 ]; then
    echo "FAIL: prev_epic=1 期望 8 行（A1-A8）；实际 $e1_rows" >&2
    exit 1
fi

echo "PASS: run_retro_self_audit_test.sh ($total_rows total rows for prev_epic=3, $e1_rows for prev_epic=1; A4=unknown; stderr clean)"
exit 0
