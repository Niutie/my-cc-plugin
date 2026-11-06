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
#   (g) 同 epic 遗留段（0.3.3）：[target:Epic 4] 出现在 [epic-backlog] 段；
#       本 story 自己 defer 的（source *-of-4.1）、别的 epic、Epic 4 retro 不出现
#   (h) 只有 epic 遗留、没有 Story 命中 → 不输出 No open，只输出遗留段
#   (i) epic 遗留 12 条 → 截断 10 + 摘要（指向 --epic）
#   (j) --epic N：列 Epic 1..N 的 open 项（带 target/source），不含 N+1、closed、Story 目标
#   (k) --epic 无命中 / 非数字参数
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

# ---------- Fixture (g): 同 epic 遗留段 ----------
echo "[fixture g] [target:Epic 4] 进 [epic-backlog] 段；自身 defer / 他 epic / Epic 4 retro 不进"
TMP_G="$WORKDIR/fixture-g.md"
cat > "$TMP_G" <<'EOF2'
# Deferred Work — fixture g

- **FU-4.1.A** `[status:pending]` `[bucket:cross-story]` `[target:Story 4.1]` `[source:dev-of-3.2]` — story 命中
- **FU-4.0.B1** `[status:pending]` `[bucket:other]` `[target:Epic 4]` `[source:build-auto-of-4.0]` — 同 epic 遗留 alpha
- **FU-4.1.B1** `[status:pending]` `[bucket:other]` `[target:Epic 4]` `[source:build-auto-of-4.1]` — 本 story 自己 defer 的
- **FU-4.10.B1** `[status:pending]` `[bucket:other]` `[target:Epic 4]` `[source:build-auto-of-4.10]` — Story 4.10 defer，不是本 story
- **FU-3.2.B1** `[status:pending]` `[bucket:other]` `[target:Epic 3]` `[source:build-auto-of-3.2]` — 别的 epic
- **FU-4.0.B2** `[status:pending]` `[bucket:other]` `[target:Epic 4 retro]` `[source:build-auto-of-4.0]` — Epic 4 retro 不算
- **FU-4.0.B3** `[status:resolved]` `[bucket:other]` `[target:Epic 4]` `[source:build-auto-of-4.0]` — 已关闭
EOF2

OUT_G=$(run_fixture 4-1-slug "$TMP_G")
assert_contains "g.1 story 命中 FU-4.1.A" "$OUT_G" "FU-4.1.A"
assert_contains "g.2 遗留段标题" "$OUT_G" "[epic-backlog] Epic 4 遗留"
assert_contains "g.3 遗留段含 FU-4.0.B1" "$OUT_G" "FU-4.0.B1"
assert_contains "g.4 Story 4.10 的 defer 不被当成自身来源" "$OUT_G" "FU-4.10.B1"
assert_line_count "g.5 共 4 行（1 story + 标题 + 2 遗留）" "$OUT_G" "4"
assert_not_contains "g.6 本 story 自己 defer 的不回灌" "$OUT_G" "FU-4.1.B1"
assert_not_contains "g.7 别的 epic 不进" "$OUT_G" "FU-3.2.B1"
assert_not_contains "g.8 Epic 4 retro 不进" "$OUT_G" "FU-4.0.B2"
assert_not_contains "g.9 closed 不进" "$OUT_G" "FU-4.0.B3"
G_FIRST=$(echo "$OUT_G" | head -1)
assert_contains "g.10 story 命中排在遗留段之前" "$G_FIRST" "FU-4.1.A"

# ---------- Fixture (h): 只有 epic 遗留 ----------
echo "[fixture h] 只有 epic 遗留时不输出 No open"
TMP_H="$WORKDIR/fixture-h.md"
cat > "$TMP_H" <<'EOF2'
# Deferred Work — fixture h

- **FU-4.0.B1** `[status:needs-review]` `[bucket:other]` `[target:Epic 4]` `[source:build-auto-of-4.0]` — 只有遗留
EOF2

OUT_H=$(run_fixture 4-2 "$TMP_H")
assert_contains "h.1 遗留段标题" "$OUT_H" "[epic-backlog] Epic 4 遗留"
assert_contains "h.2 遗留项" "$OUT_H" "FU-4.0.B1 | status: needs-review"
assert_not_contains "h.3 不输出 No open" "$OUT_H" "No open deferred items"

# ---------- Fixture (i): epic 遗留截断 ----------
echo "[fixture i] epic 遗留 12 条 → 截断 10 + 摘要"
TMP_I="$WORKDIR/fixture-i.md"
{
    echo "# Deferred Work — fixture i"
    echo ""
    for i in $(seq 1 12); do
        printf -- '- **FU-4.0.B%s** `[status:pending]` `[bucket:other]` `[target:Epic 4]` `[source:build-auto-of-4.0]` — 遗留 %s\n' "$i" "$i"
    done
} > "$TMP_I"

OUT_I=$(run_fixture 4-3 "$TMP_I")
assert_line_count "i.1 共 12 行（标题 + 10 + 摘要）" "$OUT_I" "12"
assert_contains "i.2 摘要行指向 --epic" "$OUT_I" "Epic 4 遗留共 N=12 条 → bash .claude/harness/scripts/grep_pending_deferred_for_story.sh --epic 4"
assert_contains "i.3 第 10 条仍输出" "$OUT_I" "FU-4.0.B10 |"
assert_not_contains "i.4 第 11 条被截断" "$OUT_I" "FU-4.0.B11 |"

# ---------- Fixture (j): --epic 模式 ----------
echo "[fixture j] --epic 4 列 Epic 1..4 的 open 项"
OUT_J=$("$GREP_SH" --epic 4 "$TMP_G")
assert_contains "j.1 含 Epic 4 遗留" "$OUT_J" "FU-4.0.B1 | status: pending | target: Epic 4 | source: build-auto-of-4.0"
assert_contains "j.2 含本 story 自身 defer（retro 要分诊）" "$OUT_J" "FU-4.1.B1"
assert_contains "j.3 含更早 epic 的遗留" "$OUT_J" "FU-3.2.B1 | status: pending | target: Epic 3"
assert_line_count "j.4 共 4 行" "$OUT_J" "4"
assert_not_contains "j.5 Story 目标不进" "$OUT_J" "FU-4.1.A"
assert_not_contains "j.6 Epic 4 retro 不进" "$OUT_J" "FU-4.0.B2"
assert_not_contains "j.7 closed 不进" "$OUT_J" "FU-4.0.B3"
OUT_J3=$("$GREP_SH" --epic 3 "$TMP_G")
assert_contains "j.8 --epic 3 含 Epic 3" "$OUT_J3" "FU-3.2.B1"
assert_not_contains "j.9 --epic 3 不含 Epic 4" "$OUT_J3" "FU-4.0.B1"

# ---------- Fixture (k): --epic 无命中 / 坏参数 ----------
echo "[fixture k] --epic 无命中 / 非数字"
OUT_K=$("$GREP_SH" --epic 2 "$TMP_G")
assert_contains "k.1 无命中文案" "$OUT_K" "No open deferred items targeting Epic 1..2"
assert_line_count "k.2 单行" "$OUT_K" "1"
set +e
"$GREP_SH" --epic abc "$TMP_G" >/dev/null 2>&1
RC_K=$?
"$GREP_SH" --epic >/dev/null 2>&1
RC_K2=$?
set -e
assert_contains "k.3 非数字 exit 1" "rc=$RC_K" "rc=1"
assert_contains "k.4 缺参数 exit 1" "rc=$RC_K2" "rc=1"

# ---------- summary ----------
echo ""
echo "==============================="
echo "TEST SUMMARY: PASS=$PASS  FAIL=$FAIL"
echo "==============================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
