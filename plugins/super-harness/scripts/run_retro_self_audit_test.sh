#!/usr/bin/env bash
# run_retro_self_audit self-test
#
# review 2026-06-10 #10/#95：此前 `cd ../../..` 后直接跑宿主树的
# .claude/harness/scripts/run_retro_self_audit.sh — 源树没有部署副本，永远
# 跑不了；且旧 check_A4 的 aegis 硬编码路径会刷 stderr 噪音。现改为自举
# mktemp 沙箱 fixture：从同源树拷 scripts/ + prompt-suffixes/（源树布局
# plugins/super-harness/{scripts,prompt-suffixes} 与部署布局
# .claude/harness/{scripts,prompt-suffixes} 相对结构一致，两边通跑），种子
# sprint-status.yaml + deferred-work.md 后在 fixture 内实测：
#   - 无配置（新项目）：输出 RETRO_SELF_AUDIT: no-config + _CHECKS_:0，无表格行，
#     不含任何原项目（Aegis）字样，exit 0，stderr 干净
#   - 有配置：每种 kind 的 done / pending / unknown 判定、min_prev_epic 过滤、
#     `a|b` 路径回退、格式错误行 WARN 跳过
#   - templates/retro-self-audit.tsv.example 每行都能被解析（无 WARN）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUFFIX_DIR="$SCRIPT_DIR/../prompt-suffixes"

if [ ! -f "$SCRIPT_DIR/run_retro_self_audit.sh" ]; then
    echo "ERROR: run_retro_self_audit.sh not found next to test" >&2
    exit 1
fi
if [ ! -d "$SUFFIX_DIR" ]; then
    echo "ERROR: prompt-suffixes/ not found at $SUFFIX_DIR" >&2
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
AUDIT=".claude/harness/scripts/run_retro_self_audit.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- 1. 无配置 ----
ERR="$WORKDIR/err.log"
OUT="$(bash "$AUDIT" 3 2>"$ERR")" || fail "无配置时退出码非 0"
echo "$OUT" | head -1 | grep -qx 'RETRO_SELF_AUDIT: no-config' || fail "无配置首行应为 RETRO_SELF_AUDIT: no-config；实际：$(echo "$OUT" | head -1)"
echo "$OUT" | tail -1 | grep -qx '_CHECKS_:0' || fail "无配置末行应为 _CHECKS_:0"
echo "$OUT" | grep -q '^|' && fail "无配置不应输出表格行"
echo "$OUT" | grep -qE 'sink_mode|NFR52|admin_init|console-web|pending' && fail "无配置输出含原项目检查项：$OUT"
[ -s "$ERR" ] && fail "无配置 stderr 应为空：$(head -3 "$ERR")"

# ---- 2. 有配置 ----
mkdir -p docs bin
printf 'all good\n' > docs/report.md
printf 'TBD here\nTBD again\n' > docs/todo.md
printf '#!/bin/sh\n' > bin/tool.sh; chmod +x bin/tool.sh
printf 'x\n' > bin/plain.sh
CFG="$WORKDIR/audit.tsv"
{
    printf '# comment line\n\n'
    printf '1\tX1\tfile ok\tfile\tdocs/report.md\n'
    printf '1\tX2\tfile missing\tfile\tdocs/nope.md\n'
    printf '1\tX3\texec ok\texec\tbin/tool.sh\n'
    printf '1\tX4\texec not x\texec\tbin/plain.sh\n'
    printf '1\tX5\tdir ok\tdir\tdocs\n'
    printf '1\tX6\tgrep hit\tgrep\tdocs/report.md\tgood\n'
    printf '1\tX7\tgrep miss\tgrep\tdocs/report.md\tbad\n'
    printf '1\tX8\tgrep file missing\tgrep\tdocs/nope.md\tx\n'
    printf '1\tX9\tnogrep clean\tnogrep\tdocs/report.md\tTBD\n'
    printf '1\tX10\tnogrep dirty\tnogrep\tdocs/todo.md\tTBD\n'
    printf '1\tX11\tcmd ok\tcmd\ttest -d docs\n'
    printf '1\tX12\tcmd fail\tcmd\tfalse\n'
    printf '1\tX13\tmanual\tmanual\twaiting for customer\n'
    printf '1\tX14\talt path\tfile\tdocs/nope.md|docs/report.md\n'
    printf '5\tX15\tfuture epic\tfile\tdocs/report.md\n'
    printf 'oops\tbad line\n'
    printf '1\tX16\tbad kind\twhatever\tx\n'
} > "$CFG"
OUT="$(RETRO_SELF_AUDIT_CONFIG="$CFG" bash "$AUDIT" 3 2>"$ERR")" || fail "有配置退出码非 0"
echo "$OUT" | head -1 | grep -qE '^\| id \| 描述 \| status \| evidence \|$' || fail "表头格式不对：$(echo "$OUT" | head -1)"
expect() {  # id status
    local r; r="$(echo "$OUT" | grep "^| $1 |" || true)"
    [ -n "$r" ] || fail "$1 行缺失"
    echo "$r" | grep -q "| $2 |" || fail "$1 期望 $2；实际：$r"
}
expect X1 done; expect X2 pending; expect X3 done; expect X4 pending; expect X5 done
expect X6 done; expect X7 pending; expect X8 unknown; expect X9 done; expect X10 pending
expect X11 done; expect X12 pending; expect X13 unknown; expect X14 done
echo "$OUT" | grep -q '^| X15 |' && fail "X15 min_prev_epic=5 > 3，不应出现"
echo "$OUT" | grep -q '^| X16 |' && fail "X16 未知 kind 应跳过"
echo "$OUT" | tail -1 | grep -qx '_CHECKS_:14' || fail "末行应为 _CHECKS_:14；实际：$(echo "$OUT" | tail -1)"
[ "$(grep -c '^WARN:' "$ERR" || true)" -eq 2 ] || fail "应有 2 行 WARN（格式错误 + 未知 kind）；实际：$(cat "$ERR")"

# prev_epic=4 时 X15 仍不出现，=5 时出现
OUT5="$(RETRO_SELF_AUDIT_CONFIG="$CFG" bash "$AUDIT" 5 2>/dev/null)"
echo "$OUT5" | grep -q '^| X15 | future epic | done |' || fail "prev_epic=5 时 X15 应出现且 done"

# ---- 3. 示例文件可解析 ----
EXAMPLE="$SCRIPT_DIR/../templates/retro-self-audit.tsv.example"
[ -f "$EXAMPLE" ] || fail "示例文件缺失：$EXAMPLE"
OUTX="$(RETRO_SELF_AUDIT_CONFIG="$EXAMPLE" bash "$AUDIT" 3 2>"$ERR")" || fail "示例配置退出码非 0"
[ -s "$ERR" ] && fail "示例配置不应有 WARN：$(head -3 "$ERR")"
nx="$(grep -cvE '^(#|$)' "$EXAMPLE")"
echo "$OUTX" | tail -1 | grep -qx "_CHECKS_:$nx" || fail "示例配置应输出 $nx 项；实际：$(echo "$OUTX" | tail -1)"

echo "PASS: run_retro_self_audit_test.sh (no-config empty result; 14 configured checks across all kinds; example parses $nx rows)"
exit 0
