#!/usr/bin/env bash
# Self-test for grep_pending_deferred_for_story.sh.
#
# 6 fixtures (per Epic 3 retro chore C11 ## Tasks):
#   (a) 标准命中：mock 3 条 FU 含 "Story 4.1" → 全部命中
#   (b) 无命中：mock 0 条匹配 → "No pending deferred items targeting <key>"
#   (c) 短格式 4-1 命中：mock 用 "Story 4-1" 字面 → 命中
#   (d) 版本号歧义不命中：mock "v0.2+ / 4.1 模型" → 不命中
#   (e) Resolved 跳过：mock 含 "Resolved by Story" → 不进 pending 输出
#   (f) >15 条命中 → 截断 15 + 摘要行
#
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREP_SH="$SCRIPT_DIR/grep_pending_deferred_for_story.sh"

if [ ! -x "$GREP_SH" ]; then
    echo "ERROR: $GREP_SH not executable" >&2
    exit 1
fi

PASS=0
FAIL=0

assert_contains() {
    local name="$1" output="$2" expect="$3"
    if echo "$output" | grep -qF "$expect"; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name"
        echo "    expected substring: $expect"
        echo "    actual output:"
        echo "$output" | sed 's/^/      /'
    fi
}

assert_not_contains() {
    local name="$1" output="$2" forbidden="$3"
    if echo "$output" | grep -qF "$forbidden"; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name"
        echo "    forbidden substring present: $forbidden"
        echo "    actual output:"
        echo "$output" | sed 's/^/      /'
    else
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    fi
}

assert_line_count() {
    local name="$1" output="$2" expect="$3"
    local actual
    actual=$(echo "$output" | grep -c . || true)
    if [ "$actual" = "$expect" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $name (lines=$actual)"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name (expected $expect lines, got $actual)"
        echo "$output" | sed 's/^/      /'
    fi
}

run_fixture() {
    local key="$1" md="$2"
    "$GREP_SH" "$key" "$md"
}

# ---------- Fixture (a): 标准命中（3 条） ----------
echo "[fixture a] 标准命中：3 条 FU 含 Story 4.1"
TMP_A=$(mktemp)
cat > "$TMP_A" <<'EOF'
# Deferred Work — fixture a

- **FU-4.1.A — 测试条目 alpha** — 一些描述。**回头处理时机**：Story 4.1 dev-story 阶段。
- **FU-4.1.B — 测试条目 beta** — 一些描述。**回头处理时机**：Story 4.1 dev-story 阶段。
- **FU-9.9.Z — 不相关条目** — 描述。**回头处理时机**：Epic 9 production lockdown。
- **FU-4.1.C — 测试条目 gamma** — 描述含 Story 4.1。**回头处理时机**：Story 4.1 dev-story 阶段。
EOF

OUT_A=$(run_fixture 4-1 "$TMP_A")
assert_contains "a.1 命中 FU-4.1.A" "$OUT_A" "FU-4.1.A"
assert_contains "a.2 命中 FU-4.1.B" "$OUT_A" "FU-4.1.B"
assert_contains "a.3 命中 FU-4.1.C" "$OUT_A" "FU-4.1.C"
assert_not_contains "a.4 不命中无关 FU-9.9.Z" "$OUT_A" "FU-9.9.Z"
rm -f "$TMP_A"

# ---------- Fixture (b): 无命中 ----------
echo "[fixture b] 无命中"
TMP_B=$(mktemp)
cat > "$TMP_B" <<'EOF'
# Deferred Work — fixture b

- **FU-1.2.A — 完全不相关** — **回头处理时机**：Story 1.2 dev。
- **FU-9.9.Z — 不相关** — **回头处理时机**：Epic 9。
EOF

OUT_B=$(run_fixture 4-99-nonexistent "$TMP_B")
assert_contains "b.1 输出 No pending" "$OUT_B" "No pending deferred items targeting 4-99-nonexistent"
rm -f "$TMP_B"

# ---------- Fixture (c): 短格式 4-1 命中 ----------
echo "[fixture c] 短格式 4-1 字面命中"
TMP_C=$(mktemp)
cat > "$TMP_C" <<'EOF'
# Deferred Work — fixture c

- **FU-4.1.A — 短格式条目** — 描述提及 Story 4-1 的字面写法。**回头处理时机**：Story 4-1 dev-story。
- **FU-4.1.B — 全 key 条目** — 描述提及 4-1-detection-rule-engine-core 文件路径。**回头处理时机**：Story 4-1。
EOF

OUT_C=$(run_fixture 4-1 "$TMP_C")
assert_contains "c.1 命中 FU-4.1.A（Story 4-1 短格式）" "$OUT_C" "FU-4.1.A"
assert_contains "c.2 命中 FU-4.1.B（4-1-<slug> 形式）" "$OUT_C" "FU-4.1.B"
rm -f "$TMP_C"

# ---------- Fixture (d): 版本号歧义不命中 ----------
echo "[fixture d] 版本号歧义不命中"
TMP_D=$(mktemp)
cat > "$TMP_D" <<'EOF'
# Deferred Work — fixture d

- **FU-9.9.A — 版本号歧义条目** — 描述：v0.2+ / 4.1 模型升级；包含纯数字 4.1 但不应误命中。**回头处理时机**：v0.2+ sprint。
- **FU-9.9.B — 时间戳歧义** — 描述：在 4-10 期间一并验证；纯数字时间戳不应误命中。**回头处理时机**：v0.2+ sprint。
EOF

OUT_D=$(run_fixture 4-1 "$TMP_D")
assert_contains "d.1 输出 No pending（纯数字不误命中）" "$OUT_D" "No pending deferred items targeting 4-1"
assert_not_contains "d.2 不误命中 FU-9.9.A" "$OUT_D" "FU-9.9.A"
assert_not_contains "d.3 不误命中 FU-9.9.B" "$OUT_D" "FU-9.9.B"
rm -f "$TMP_D"

# ---------- Fixture (e): Resolved 跳过 ----------
echo "[fixture e] Resolved 跳过"
TMP_E=$(mktemp)
cat > "$TMP_E" <<'EOF'
# Deferred Work — fixture e

- **FU-4.1.A — 已 resolved 条目** — 描述。**回头处理时机**：Story 4.1 dev-story。 — **Resolved by Story 4.1** (2026-05-04): 改了 X / Y / Z。
- **FU-4.1.B — partial resolved 条目** — 描述。**回头处理时机**：Story 4.1 dev-story。 — **Partial resolution by Story 4.1** (2026-05-04): 改了 X，Y 仍 open。
- **FU-4.1.C — 未 resolved 条目** — 描述。**回头处理时机**：Story 4.1 dev-story。
EOF

OUT_E=$(run_fixture 4-1 "$TMP_E")
assert_not_contains "e.1 跳过 Resolved by FU-4.1.A" "$OUT_E" "FU-4.1.A"
assert_not_contains "e.2 跳过 Partial resolution by FU-4.1.B" "$OUT_E" "FU-4.1.B"
assert_contains "e.3 保留 pending FU-4.1.C" "$OUT_E" "FU-4.1.C"
rm -f "$TMP_E"

# ---------- Fixture (f): >15 条截断 ----------
echo "[fixture f] 17 条命中 → 截断 15 + 摘要"
TMP_F=$(mktemp)
{
    echo "# Deferred Work — fixture f"
    echo ""
    for i in $(seq 1 17); do
        echo "- **FU-4.1.${i} — 测试条目 ${i}** — 描述。**回头处理时机**：Story 4.1 dev-story。"
    done
} > "$TMP_F"

OUT_F=$(run_fixture 4-1 "$TMP_F")
# 期望：15 行 FU + 1 行摘要 = 16 行
assert_line_count "f.1 输出共 16 行（15 + 摘要）" "$OUT_F" "16"
assert_contains "f.2 摘要行含 完整 N=17" "$OUT_F" "完整 N=17 条"
assert_contains "f.3 摘要行含脚本路径提示" "$OUT_F" "bash .claude/harness/scripts/grep_pending_deferred_for_story.sh 4-1"
rm -f "$TMP_F"

# ---------- summary ----------
echo ""
echo "==============================="
echo "TEST SUMMARY: PASS=$PASS  FAIL=$FAIL"
echo "==============================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
