#!/usr/bin/env bash
# check_inheritance_block.sh self-test (Epic 4 retro D5 2026-05-05)
#
# 6 fixture：
#   (a) happy        — 5-1-* 含 H2 + ≥5 sub-bullet + Epic 4 Story 引用 + sealed-patterns-epic-4.md 链接 → exit 0
#   (b) no-h2        — 5-1-* 缺 H2 段 → exit 1
#   (c) few-bullets  — 5-1-* 含 H2 + 仅 3 sub-bullet → exit 1
#   (d) no-sealed    — 5-1-* 含 H2 + 5 sub-bullet + Epic 4 Story 引用，但缺
#                      sealed-patterns-epic- 链接 / epic-4-retro §9.5 锚 → exit 1
#   (e) retro-file-anchor — 无 sealed-patterns 链接，但同行 `epic-4-retro-….md §9.5`
#                      锚点引用（suffix 推荐字面形式）→ exit 0
#   (f) retro-uppercase — 无 sealed-patterns 链接，但同行 `Epic 4 retro §9.5`
#                      大写空格形式（v0.1.38 F7 放宽分支）→ exit 0
#
# 退出码：
#   0   全部 fixture 行为符合期望
#   1   任一 fixture 行为异常
#
# 不依赖 git / 真 spec 文件 — 全部 fixture 现场写到 mktemp 目录。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$SCRIPT_DIR/check_inheritance_block.sh"

if [ ! -x "$CHECKER" ]; then
    echo "FAIL: checker not executable at $CHECKER" >&2
    exit 1
fi

WORK="$(mktemp -d -t inherit-block-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

run_fixture() {
    local name="$1" file="$2" expected_exit="$3"
    local actual_exit
    set +e
    bash "$CHECKER" "$file" >/dev/null 2>&1
    actual_exit=$?
    set -e
    if [ "$actual_exit" -eq "$expected_exit" ]; then
        echo "PASS: fixture $name (exit=$actual_exit)"
        pass=$((pass + 1))
    else
        echo "FAIL: fixture $name (expected exit=$expected_exit, got $actual_exit)" >&2
        fail=$((fail + 1))
    fi
}

# ---------------------------------------------------------------------
# Fixture (a): happy — 5-1-* 完整继承段
# ---------------------------------------------------------------------
cat >"$WORK/5-1-happy.md" <<'EOF'
# Story 5.1 Happy Fixture

## 继承自前序 Epic patterns

- (a) **跨 story Resolved 锚机制** — 沿用 Epic 4 Story 4.3 / 4.5 FU-X.Y → Resolved 路径（详 [sealed-patterns-epic-4.md](../../planning-artifacts/architecture/sealed-patterns-epic-4.md) P-4.1）。
- (b) **structured_matcher kind dispatch** — 沿用 Epic 4 Story 4.3 / 4.4 pattern（详 sealed-patterns-epic-4.md P-4.2）。
- (c) **schemaState 状态机** — 沿用 Epic 4 Story 4.5 schemaState 3 子值（详 sealed-patterns-epic-4.md P-4.3）。
- (d) **Policy plugin Registry** — 沿用 Epic 4 Story 4.6 Registry singleton + Apply / ApplyMutating 双方法（详 sealed-patterns-epic-4.md P-4.5）。
- (e) **canonical pin 不破回归** — 沿用 Epic 4 Story 4.7 / 4.6 / 4.5 / 4.1 pre-flight pin（详 sealed-patterns-epic-4.md P-4.10）。

## Story
EOF
run_fixture "(a) happy" "$WORK/5-1-happy.md" 0

# ---------------------------------------------------------------------
# Fixture (b): no-h2 — 5-1-* 缺继承段 H2
# ---------------------------------------------------------------------
cat >"$WORK/5-1-no-h2.md" <<'EOF'
# Story 5.1 No-H2 Fixture

## Story
不含继承段。
EOF
run_fixture "(b) no-h2" "$WORK/5-1-no-h2.md" 1

# ---------------------------------------------------------------------
# Fixture (c): few-bullets — 5-1-* 含 H2 但仅 3 sub-bullet
# ---------------------------------------------------------------------
cat >"$WORK/5-1-few-bullets.md" <<'EOF'
# Story 5.1 Few-Bullets Fixture

## 继承自前序 Epic patterns

- (a) 沿用 Epic 4 Story 4.3 sealed-patterns-epic-4.md P-4.2。
- (b) 沿用 Epic 4 Story 4.5 sealed-patterns-epic-4.md P-4.3。
- (c) 沿用 Epic 4 Story 4.6 sealed-patterns-epic-4.md P-4.5。

## Story
EOF
run_fixture "(c) few-bullets" "$WORK/5-1-few-bullets.md" 1

# ---------------------------------------------------------------------
# Fixture (d): no-sealed — 5-1-* 含 H2 + 5 sub-bullet + Epic 4 Story 引用，
#                          但缺 sealed-patterns-epic- 链接 / retro §9.5 锚
# ---------------------------------------------------------------------
cat >"$WORK/5-1-no-sealed.md" <<'EOF'
# Story 5.1 No-Sealed Fixture

## 继承自前序 Epic patterns

- (a) 沿用 Epic 4 Story 4.3 structured_matcher pattern。
- (b) 沿用 Epic 4 Story 4.5 schemaState pattern。
- (c) 沿用 Epic 4 Story 4.6 Registry pattern。
- (d) 沿用 Epic 4 Story 4.7 SEVERITY_RANK 跨栈 grep 守门。
- (e) 沿用 Epic 4 Story 4.1 canonical pin pre-flight 路径。

## Story
EOF
run_fixture "(d) no-sealed" "$WORK/5-1-no-sealed.md" 1

# ---------------------------------------------------------------------
# Fixture (e): retro-file-anchor — 无 sealed-patterns 链接，但同行
#              `epic-4-retro-….md §9.5` 锚点引用（suffix 推荐字面形式）
# ---------------------------------------------------------------------
cat >"$WORK/5-1-retro-file-anchor.md" <<'EOF'
# Story 5.1 Retro-File-Anchor Fixture

## 继承自前序 Epic patterns

- (a) 沿用 Epic 4 Story 4.3 structured_matcher pattern。
- (b) 沿用 Epic 4 Story 4.5 schemaState pattern。
- (c) 沿用 Epic 4 Story 4.6 Registry pattern。
- (d) 沿用 Epic 4 沉淀 patterns（详 epic-4-retro-2026-05-05.md §9.5 锚点）。
- (e) 沿用 Epic 4 Story 4.1 canonical pin pre-flight 路径。

## Story
EOF
run_fixture "(e) retro-file-anchor" "$WORK/5-1-retro-file-anchor.md" 0

# ---------------------------------------------------------------------
# Fixture (f): retro-uppercase — 无 sealed-patterns 链接，但同行
#              `Epic 4 retro §9.5` 大写空格形式（v0.1.38 F7 放宽分支）
# ---------------------------------------------------------------------
cat >"$WORK/5-1-retro-uppercase.md" <<'EOF'
# Story 5.1 Retro-Uppercase Fixture

## 继承自前序 Epic patterns

- (a) 沿用 Epic 4 Story 4.3 structured_matcher pattern。
- (b) 沿用 Epic 4 Story 4.5 schemaState pattern。
- (c) 沿用 Epic 4 Story 4.6 Registry pattern。
- (d) 沿用 Epic 4 沉淀 patterns（详 Epic 4 retro §9.5 锚点）。
- (e) 沿用 Epic 4 Story 4.1 canonical pin pre-flight 路径。

## Story
EOF
run_fixture "(f) retro-uppercase" "$WORK/5-1-retro-uppercase.md" 0

# ---------------------------------------------------------------------
echo ""
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
