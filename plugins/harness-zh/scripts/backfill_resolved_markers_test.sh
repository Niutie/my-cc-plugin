#!/usr/bin/env bash
# Chore C12 — self-test for backfill_resolved_markers + diff_guardrail
#
# 3 fixture：
#   (a) 漏标追加 → diff_guardrail PASS
#   (b) 已标跳过（new == old） → diff_guardrail PASS（0 changes）
#   (c) fresh agent 跑偏（删除 FU 行 / 改 trigger） → diff_guardrail FAIL exit 1
#
# 第 4 fixture 顺手测：误用其它 marker 文字 → FAIL（确保 marker regex 严）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAIL="${SCRIPT_DIR}/diff_guardrail.sh"

if [[ ! -x "$GUARDRAIL" ]]; then
    chmod +x "$GUARDRAIL" 2>/dev/null || true
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

run_fixture() {
    local name="$1"
    local expected_exit="$2"
    local old_file="$3"
    local new_file="$4"

    set +e
    output=$(bash "$GUARDRAIL" "$old_file" "$new_file" 2>&1)
    actual_exit=$?
    set -e

    if [[ "$actual_exit" -eq "$expected_exit" ]]; then
        echo "  ✓ $name (exit=$actual_exit as expected)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name (expected exit=$expected_exit, got $actual_exit)"
        echo "    output: $output"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================================
# Fixture A — 漏标追加（PASS）
# ============================================================================
echo "Fixture A: 漏标追加（PASS expected）"

cat > "$TMPDIR/a.old.md" <<'EOF'
# Deferred Work

## §2 Story 1.x

### Story 1.4

- **FU-1.4.G** — bucket 命名混淆扩展易引混淆
  - **来源**：codex-review naming-confusion
  - **回头处理时机**：Epic 1 retrospective 复盘时

- **FU-1.4.H** — 留待 Epic 6 production lockdown
  - **回头处理时机**：Epic 6 production lockdown
EOF

cat > "$TMPDIR/a.new.md" <<'EOF'
# Deferred Work

## §2 Story 1.x

### Story 1.4

- **FU-1.4.G** — bucket 命名混淆扩展易引混淆 — Resolved by Story epic-1-retrospective (2026-05-02): ADR 0007 + bucket_names.go 注释充分，命名混淆未升级
  - **来源**：codex-review naming-confusion
  - **回头处理时机**：Epic 1 retrospective 复盘时

- **FU-1.4.H** — 留待 Epic 6 production lockdown
  - **回头处理时机**：Epic 6 production lockdown
EOF

run_fixture "A 漏标追加" 0 "$TMPDIR/a.old.md" "$TMPDIR/a.new.md"

# ============================================================================
# Fixture B — needs-review 追加（PASS）
# ============================================================================
echo "Fixture B: needs-review 追加（PASS expected）"

cat > "$TMPDIR/b.old.md" <<'EOF'
- **FU-1.5.J** — golangci-lint 规则集后续业务代码增多时再扩展
  - **回头处理时机**：Story 1.6 / Epic 6 业务代码增多时
EOF

cat > "$TMPDIR/b.new.md" <<'EOF'
- **FU-1.5.J** — golangci-lint 规则集后续业务代码增多时再扩展 — Story 1.6 done but no resolution evidence — needs solo-dev review
  - **回头处理时机**：Story 1.6 / Epic 6 业务代码增多时
EOF

run_fixture "B needs-review 追加" 0 "$TMPDIR/b.old.md" "$TMPDIR/b.new.md"

# ============================================================================
# Fixture C — 删除行（FAIL）
# ============================================================================
echo "Fixture C: 删除 FU 描述行（FAIL expected）"

cat > "$TMPDIR/c.old.md" <<'EOF'
- **FU-1.4.G** — 命名混淆
  - **来源**：codex-review
  - **回头处理时机**：Epic 1 retro
EOF

cat > "$TMPDIR/c.new.md" <<'EOF'
- **FU-1.4.G** — 命名混淆
  - **回头处理时机**：Epic 1 retro
EOF

run_fixture "C 删除 sublist 行" 1 "$TMPDIR/c.old.md" "$TMPDIR/c.new.md"

# ============================================================================
# Fixture D — 改 trigger 描述（FAIL — NOT_PREFIX）
# ============================================================================
echo "Fixture D: 改 trigger 描述（FAIL expected）"

cat > "$TMPDIR/d.old.md" <<'EOF'
- **FU-1.4.G** — 命名混淆
  - **回头处理时机**：Epic 1 retrospective 复盘时
EOF

cat > "$TMPDIR/d.new.md" <<'EOF'
- **FU-1.4.G** — 命名混淆
  - **回头处理时机**：Story 1.11 实施时
EOF

run_fixture "D 改 trigger 描述" 1 "$TMPDIR/d.old.md" "$TMPDIR/d.new.md"

# ============================================================================
# Fixture E — 错误 marker 格式（FAIL — BAD_MARKER）
# ============================================================================
echo "Fixture E: 错误 marker 格式（FAIL expected）"

cat > "$TMPDIR/e.old.md" <<'EOF'
- **FU-1.4.G** — 命名混淆
EOF

cat > "$TMPDIR/e.new.md" <<'EOF'
- **FU-1.4.G** — 命名混淆 — fixed by some random commit
EOF

run_fixture "E 错误 marker 格式" 1 "$TMPDIR/e.old.md" "$TMPDIR/e.new.md"

# ============================================================================
# Fixture F — 加新行（FAIL — line count）
# ============================================================================
echo "Fixture F: fresh agent 加新行（FAIL expected）"

cat > "$TMPDIR/f.old.md" <<'EOF'
- **FU-1.4.G** — 命名混淆
EOF

cat > "$TMPDIR/f.new.md" <<'EOF'
- **FU-1.4.G** — 命名混淆
- **FU-1.4.H** — 新加项（fresh agent 不该加）
EOF

run_fixture "F 增加新行" 1 "$TMPDIR/f.old.md" "$TMPDIR/f.new.md"

# ============================================================================
# Fixture G — 完全无修改（PASS）
# ============================================================================
echo "Fixture G: 无修改（PASS expected）"

cat > "$TMPDIR/g.old.md" <<'EOF'
- **FU-1.4.G** — 命名混淆
- **FU-1.4.H** — Epic 6 production lockdown
EOF
cp "$TMPDIR/g.old.md" "$TMPDIR/g.new.md"

run_fixture "G 无修改" 0 "$TMPDIR/g.old.md" "$TMPDIR/g.new.md"

# ============================================================================
echo ""
echo "==============================="
echo "results: PASS=$PASS  FAIL=$FAIL"
echo "==============================="

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
exit 0
