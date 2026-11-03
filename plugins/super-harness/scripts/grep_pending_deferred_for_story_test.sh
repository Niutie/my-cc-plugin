#!/usr/bin/env bash
# Self-test for grep_pending_deferred_for_story.sh (schema v1).
#
# review 2026-06-10 #11：被测脚本已重写为 schema v1 四标签解析
# （`- **FU-X.Y.Z** `[status:..]` `[bucket:..]` `[target:..]` `[source:..]` — desc`，
# 无命中输出 'No open deferred items targeting <key>'）。本测试 6 组 fixture
# 全部按 v1 格式重写；每个 assert_not_contains 均配套同 fixture 的正向断言
# （contains / line_count），杜绝空输出恒真。
#
# 6 fixtures：
#   (a) 标准命中：3 条 open FU `[target:Story 4.1]` → 全部命中（含 status 回显）
#   (b) 无命中 → "No open deferred items targeting <key>"
#   (c) key 形式归一：4-1 / 4.1 / 4-1-<slug> 三种入参均命中 [target:Story 4.1]
#   (d) 歧义不误命中：desc 含 "4.1" / target=Story 4.10 前缀重叠 → 0 命中
#   (e) closed status 跳过：resolved / skipped / superseded 不输出；open 保留
#   (f) 17 条命中 → 截断 15 + 摘要行（共 16 行）
#
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREP_SH="$SCRIPT_DIR/grep_pending_deferred_for_story.sh"

if [ ! -x "$GREP_SH" ]; then
    echo "ERROR: $GREP_SH not executable" >&2
    exit 1
fi

# All fixture files live in one mktemp sandbox, cleaned by EXIT trap
# (NOT RETURN trap — that never fires at top level; review #94 bug class).
WORKDIR="$(mktemp -d -t grep_pending_deferred_test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

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

# ---------- Fixture (a): 标准命中（3 条 open FU targeting Story 4.1） ----------
echo "[fixture a] 标准命中：3 条 open FU [target:Story 4.1]"
TMP_A="$WORKDIR/fixture-a.md"
cat > "$TMP_A" <<'EOF'
# Deferred Work — fixture a

- **FU-4.1.A** `[status:pending]` `[bucket:other]` `[target:Story 4.1]` `[source:dev-of-3.2]` — 测试条目 alpha
- **FU-4.1.B** `[status:in-progress]` `[bucket:test-coverage]` `[target:Story 4.1]` `[source:dev-of-3.3]` — 测试条目 beta
- **FU-9.9.Z** `[status:pending]` `[bucket:other]` `[target:Epic 9 production lockdown]` `[source:dev-of-3.4]` — 不相关条目
- **FU-4.1.C** `[status:needs-review]` `[bucket:cross-story]` `[target:Story 4.1]` `[source:review-of-3.5]` — 测试条目 gamma
EOF

OUT_A=$(run_fixture 4-1 "$TMP_A")
assert_contains "a.1 命中 FU-4.1.A" "$OUT_A" "FU-4.1.A"
assert_contains "a.2 命中 FU-4.1.B" "$OUT_A" "FU-4.1.B"
assert_contains "a.3 命中 FU-4.1.C" "$OUT_A" "FU-4.1.C"
assert_contains "a.4 status 字段回显（in-progress）" "$OUT_A" "status: in-progress"
assert_contains "a.5 excerpt 字段回显" "$OUT_A" "excerpt:"
assert_line_count "a.6 恰好 3 行输出" "$OUT_A" "3"
# a.7 反向断言（配套 a.1-a.6 正向断言 — 非恒真）
assert_not_contains "a.7 不命中无关 FU-9.9.Z" "$OUT_A" "FU-9.9.Z"

# ---------- Fixture (b): 无命中 ----------
echo "[fixture b] 无命中"
TMP_B="$WORKDIR/fixture-b.md"
cat > "$TMP_B" <<'EOF'
# Deferred Work — fixture b

- **FU-1.2.A** `[status:pending]` `[bucket:other]` `[target:Story 1.2]` `[source:dev-of-1.1]` — 完全不相关
- **FU-9.9.Z** `[status:pending]` `[bucket:other]` `[target:Epic 9]` `[source:dev-of-9.8]` — 不相关
EOF

OUT_B=$(run_fixture 4-99-nonexistent "$TMP_B")
assert_contains "b.1 输出 No open（schema v1 文案）" "$OUT_B" "No open deferred items targeting 4-99-nonexistent"
assert_line_count "b.2 无命中时单行输出" "$OUT_B" "1"

# ---------- Fixture (c): key 入参形式归一（4-1 / 4.1 / 全 slug） ----------
echo "[fixture c] key 形式归一：4-1 / 4.1 / 4-1-<slug> 均命中 [target:Story 4.1]"
TMP_C="$WORKDIR/fixture-c.md"
cat > "$TMP_C" <<'EOF'
# Deferred Work — fixture c

- **FU-4.1.A** `[status:pending]` `[bucket:other]` `[target:Story 4.1]` `[source:dev-of-3.9]` — 归一化测试条目
EOF

OUT_C1=$(run_fixture 4-1 "$TMP_C")
OUT_C2=$(run_fixture 4.1 "$TMP_C")
OUT_C3=$(run_fixture 4-1-detection-rule-engine-core "$TMP_C")
assert_contains "c.1 短 key 4-1 命中" "$OUT_C1" "FU-4.1.A"
assert_contains "c.2 dotted key 4.1 命中" "$OUT_C2" "FU-4.1.A"
assert_contains "c.3 全 slug key 命中" "$OUT_C3" "FU-4.1.A"

# ---------- Fixture (d): 歧义不误命中 ----------
echo "[fixture d] 歧义不误命中（desc 含 4.1 / target=Story 4.10 前缀重叠）"
TMP_D="$WORKDIR/fixture-d.md"
cat > "$TMP_D" <<'EOF'
# Deferred Work — fixture d

- **FU-9.9.A** `[status:pending]` `[bucket:other]` `[target:v0.2+ model-upgrade]` `[source:dev-of-9.9]` — v0.2+ / 4.1 模型升级；desc 含纯数字 4.1 不应误命中
- **FU-9.9.B** `[status:pending]` `[bucket:other]` `[target:Story 4.10]` `[source:dev-of-9.9]` — target=Story 4.10，前缀重叠不应命中 Story 4.1
EOF

OUT_D=$(run_fixture 4-1 "$TMP_D")
# d.1 正向断言（配套 d.2/d.3 反向断言 — 非恒真）
assert_contains "d.1 输出 No open（desc/前缀歧义不误命中）" "$OUT_D" "No open deferred items targeting 4-1"
assert_not_contains "d.2 不误命中 FU-9.9.A（desc 含 4.1）" "$OUT_D" "FU-9.9.A"
assert_not_contains "d.3 不误命中 FU-9.9.B（Story 4.10 前缀重叠）" "$OUT_D" "FU-9.9.B"

# ---------- Fixture (e): closed status 跳过 ----------
echo "[fixture e] closed status（resolved/skipped/superseded）跳过；open 保留"
TMP_E="$WORKDIR/fixture-e.md"
cat > "$TMP_E" <<'EOF'
# Deferred Work — fixture e

- **FU-4.1.A** `[status:resolved]` `[bucket:other]` `[target:Story 4.1]` `[source:dev-of-3.2]` — 已 resolved 条目
- **FU-4.1.B** `[status:skipped]` `[bucket:other]` `[target:Story 4.1]` `[source:dev-of-3.3]` — 决策性不做条目
- **FU-4.1.D** `[status:superseded]` `[bucket:other]` `[target:Story 4.1]` `[source:dev-of-3.4]` — 被取代条目
- **FU-4.1.C** `[status:partial]` `[bucket:cross-story]` `[target:Story 4.1]` `[source:dev-of-3.5]` — partial 仍 open 应保留
EOF

OUT_E=$(run_fixture 4-1 "$TMP_E")
# e.1 正向断言（配套 e.3-e.5 反向断言 — 非恒真）
assert_contains "e.1 保留 open FU-4.1.C（partial）" "$OUT_E" "FU-4.1.C"
assert_line_count "e.2 仅 1 行输出（3 条 closed 全过滤）" "$OUT_E" "1"
assert_not_contains "e.3 跳过 resolved FU-4.1.A" "$OUT_E" "FU-4.1.A"
assert_not_contains "e.4 跳过 skipped FU-4.1.B" "$OUT_E" "FU-4.1.B"
assert_not_contains "e.5 跳过 superseded FU-4.1.D" "$OUT_E" "FU-4.1.D"

# ---------- Fixture (f): 17 条命中 → 截断 15 + 摘要 ----------
echo "[fixture f] 17 条命中 → 截断 15 + 摘要行"
TMP_F="$WORKDIR/fixture-f.md"
{
    echo "# Deferred Work — fixture f"
    echo ""
    for i in $(seq 1 17); do
        printf -- '- **FU-4.1.%s** `[status:pending]` `[bucket:other]` `[target:Story 4.1]` `[source:dev-of-3.9]` — 测试条目 %s\n' "$i" "$i"
    done
} > "$TMP_F"

OUT_F=$(run_fixture 4-1 "$TMP_F")
# 期望：15 行 FU + 1 行摘要 = 16 行
assert_line_count "f.1 输出共 16 行（15 + 摘要）" "$OUT_F" "16"
assert_contains "f.2 摘要行含 完整 N=17" "$OUT_F" "完整 N=17 条"
assert_contains "f.3 摘要行含脚本路径提示" "$OUT_F" "bash .claude/harness/scripts/grep_pending_deferred_for_story.sh 4-1"
assert_contains "f.4 第 15 条仍输出" "$OUT_F" "FU-4.1.15"
# f.5 反向断言（配套 f.1/f.4 正向断言 — 非恒真）
assert_not_contains "f.5 第 16 条被截断" "$OUT_F" "FU-4.1.16"

# ---------- summary ----------
echo ""
echo "==============================="
echo "TEST SUMMARY: PASS=$PASS  FAIL=$FAIL"
echo "==============================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
