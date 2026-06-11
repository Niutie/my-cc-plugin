#!/usr/bin/env bash
# Self-test for sprint-status.py dual-format parser (review 2026-06-10 #39/#45;
# issue Niutie/my-cc-plugin#4 regression net).
#
# Three fixture projects, each a sandboxed deployed layout
# (<proj>/.claude/harness/scripts/ + <proj>/_bmad-output/implementation-artifacts/):
#   F1 — 纯单行格式      `  key: status  # comment`
#   F2 — 纯 BMad 多行块   `  key:\n    status: ...\n    depends_on: [...]`
#   F3 — 混合 + CJK key + epic-* 单行
#
# Covered commands: next / count / status / set / epic-all-done / next-in-epic
# / epic-of / find-by-status. Asserts the Phase A new behaviors:
#   - cmd_status accepts epic-* keys (finding #77 — read/write symmetric)
#   - cmd_set rewrites the nested `status:` line of a block entry (NOT the key
#     line), preserves trailing inline comments + depends_on, and touches
#     exactly 2 lines (target + last_updated) — asserted via diff.
#   - CJK story keys parse in both layouts.
#
# Source-tree-direct (no deployed fixture needed). Exit code = FAIL count.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hermetic: a caller-exported config override must not leak into the sandbox.
unset HARNESS_CONFIG_PATH 2>/dev/null || true

for f in sprint-status.py harness_config.py; do
    if [ ! -f "$SCRIPT_DIR/$f" ]; then
        echo "ERROR: $f not found at $SCRIPT_DIR/$f" >&2
        exit 2
    fi
done

PASS=0
FAIL=0
WORKDIR="$(mktemp -d -t sprint-status-fmt.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

TODAY="$(date +%Y-%m-%d)"

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# make_project <name> → deployed layout; yaml content comes from stdin.
# Sets $PROJ / $SS (script path) / $YAML for the caller.
make_project() {
    local name="$1"
    PROJ="$WORKDIR/$name"
    mkdir -p "$PROJ/.claude/harness/scripts" \
             "$PROJ/_bmad-output/implementation-artifacts"
    cp "$SCRIPT_DIR/sprint-status.py" "$PROJ/.claude/harness/scripts/"
    cp "$SCRIPT_DIR/harness_config.py" "$PROJ/.claude/harness/scripts/"
    printf "artifacts_root: '_bmad-output/implementation-artifacts'\n" \
        > "$PROJ/.claude/harness/harness-project-config.yaml"
    SS="$PROJ/.claude/harness/scripts/sprint-status.py"
    YAML="$PROJ/_bmad-output/implementation-artifacts/sprint-status.yaml"
    cat > "$YAML"
}

# assert_cmd <label> <expected_rc> <expected_stdout> <cmd...>
# expected_stdout="" means "don't check stdout content".
assert_cmd() {
    local label="$1" want_rc="$2" want_out="$3"
    shift 3
    local rc=0 out
    out="$(python3 "$SS" "$@" 2>/dev/null)" || rc=$?
    if [ "$rc" != "$want_rc" ]; then
        bad "$label: rc=$rc (want $want_rc), out='$out'"
        return
    fi
    if [ -n "$want_out" ] && [ "$out" != "$want_out" ]; then
        bad "$label: out='$out' (want '$want_out')"
        return
    fi
    ok "$label"
}

# assert_set_diff <label> <key> <new_status> <expected_new_target_line>
# Runs `set` and asserts (via diff) that ONLY the line carrying the status
# value changed, plus last_updated (which is rewritten only when it isn't
# already today's date). Positive assertions only.
assert_set_diff() {
    local label="$1" key="$2" new_status="$3" want_line="$4"
    cp "$YAML" "$YAML.before"
    # last_updated already == today (earlier set in the same fixture) → set
    # rewrites it to the identical value → diff shows 1 new line, not 2.
    local want_n=2
    grep -qxF "last_updated: $TODAY" "$YAML.before" && want_n=1
    local rc=0
    python3 "$SS" set "$key" "$new_status" >/dev/null 2>&1 || rc=$?
    if [ "$rc" != 0 ]; then
        bad "$label: set rc=$rc"
        rm -f "$YAML.before"
        return
    fi
    local new_lines n
    new_lines="$(diff "$YAML.before" "$YAML" | grep '^>' | sed 's/^> //')"
    n="$(printf '%s\n' "$new_lines" | grep -c .)"
    if [ "$n" != "$want_n" ]; then
        bad "$label: diff introduced $n new lines (want exactly $want_n): $new_lines"
        rm -f "$YAML.before"
        return
    fi
    if ! printf '%s\n' "$new_lines" | grep -qxF -- "$want_line"; then
        bad "$label: rewritten line missing; want '$want_line', got: $new_lines"
        rm -f "$YAML.before"
        return
    fi
    if [ "$want_n" = 2 ] && \
       ! printf '%s\n' "$new_lines" | grep -qxF -- "last_updated: $TODAY"; then
        bad "$label: last_updated not refreshed to $TODAY: $new_lines"
        rm -f "$YAML.before"
        return
    fi
    if ! grep -qxF "last_updated: $TODAY" "$YAML"; then
        bad "$label: file's last_updated is not $TODAY after set"
        rm -f "$YAML.before"
        return
    fi
    ok "$label"
    rm -f "$YAML.before"
}

# ============================================================================
# F1 — 纯单行格式
# ============================================================================
echo "=== F1: single-line format ==="
make_project "f1-single" <<'EOF'
project: demo
last_updated: 2026-06-01
development_status:
  1-1-后端工程脚手架: done
  1-2-api-endpoints: done  # 行尾注释保留
  epic-1-retrospective: done
  epic-1: done
  2-1-前端面板: backlog
  2-2-cli-tooling: backlog
EOF

assert_cmd "F1 next → first backlog (CJK key)"        0 "2-1-前端面板"  next
assert_cmd "F1 count excludes epic-* keys"            0 "2/4"           count
assert_cmd "F1 status of CJK story key"               0 "done"          status "1-1-后端工程脚手架"
assert_cmd "F1 status of epic-N-retrospective (#77)"  0 "done"          status "epic-1-retrospective"
assert_cmd "F1 status of bare epic-N key (#77)"       0 "done"          status "epic-1"
assert_cmd "F1 status of unknown key → rc 1"          1 ""              status "9-9-no-such-story"
assert_cmd "F1 epic-of CJK key"                       0 "2"             epic-of "2-1-前端面板"
assert_cmd "F1 epic-all-done 1 → all done"            0 ""              epic-all-done 1
assert_cmd "F1 epic-all-done 2 → pending remain"      1 ""              epic-all-done 2
assert_cmd "F1 next-in-epic 2"                        0 "2-1-前端面板"  next-in-epic 2
assert_cmd "F1 find-by-status done → last done story" 0 "1-2-api-endpoints" find-by-status done

assert_set_diff "F1 set CJK key → only target+last_updated change" \
    "2-1-前端面板" "done" "  2-1-前端面板: done"
assert_cmd "F1 next advances after set"               0 "2-2-cli-tooling" next
assert_set_diff "F1 set preserves trailing inline comment" \
    "1-2-api-endpoints" "review" "  1-2-api-endpoints: review  # 行尾注释保留"
assert_cmd "F1 status reflects set value"             0 "review"        status "1-2-api-endpoints"

# ============================================================================
# F2 — 纯 BMad 多行块格式（key: 换行 status:/depends_on:）
# ============================================================================
echo "=== F2: BMad multi-line block format ==="
make_project "f2-block" <<'EOF'
project: demo
last_updated: 2026-06-01
development_status:
  1-1-后端工程脚手架:
    status: done
    depends_on: []
  1-2-api-endpoints:
    status: done  # 行尾注释保留
    depends_on:
      - 1-1-后端工程脚手架
  epic-1-retrospective:
    status: done
  2-1-前端面板:
    status: backlog
    depends_on:
      - 1-2-api-endpoints
  2-2-cli-tooling:
    depends_on: []
    status: backlog
EOF

assert_cmd "F2 next → first backlog (not the pseudo-key 'status')" \
                                                      0 "2-1-前端面板"  next
assert_cmd "F2 count excludes epic-* keys"            0 "2/4"           count
assert_cmd "F2 status of CJK block key"               0 "done"          status "1-1-后端工程脚手架"
assert_cmd "F2 status of epic-N-retrospective block (#77)" \
                                                      0 "done"          status "epic-1-retrospective"
assert_cmd "F2 status of block w/ depends_on before status" \
                                                      0 "backlog"       status "2-2-cli-tooling"
assert_cmd "F2 epic-of"                               0 "1"             epic-of "1-2-api-endpoints"
assert_cmd "F2 epic-all-done 1 → all done"            0 ""              epic-all-done 1
assert_cmd "F2 epic-all-done 2 → pending remain"      1 ""              epic-all-done 2
assert_cmd "F2 next-in-epic 2"                        0 "2-1-前端面板"  next-in-epic 2

# set on a block entry must rewrite the NESTED status line, not the key line.
assert_set_diff "F2 set block entry → nested status line rewritten" \
    "2-1-前端面板" "done" "    status: done"
if grep -qxF '  2-1-前端面板:' "$YAML"; then
    ok "F2 block key line intact after set (no value appended)"
else
    bad "F2 block key line was modified by set"
fi
if grep -qxF '      - 1-2-api-endpoints' "$YAML"; then
    ok "F2 depends_on list intact after set"
else
    bad "F2 depends_on list corrupted by set"
fi
assert_cmd "F2 status reflects set value"             0 "done"          status "2-1-前端面板"
assert_cmd "F2 next advances after set"               0 "2-2-cli-tooling" next
assert_set_diff "F2 set preserves nested inline comment" \
    "1-2-api-endpoints" "review" "    status: review  # 行尾注释保留"

# ============================================================================
# F3 — 混合格式 + epic-* 单行 key
# ============================================================================
echo "=== F3: mixed format ==="
make_project "f3-mixed" <<'EOF'
project: demo
last_updated: 2026-06-01
development_status:
  1-1-后端工程脚手架: done
  1-2-api-endpoints:
    status: done
    depends_on: []
  epic-1-retrospective: done
  2-1-前端面板:
    status: backlog
    depends_on:
      - 1-2-api-endpoints
  2-2-cli-tooling: backlog
  epic-2: in-progress
EOF

assert_cmd "F3 next → block entry by file order"      0 "2-1-前端面板"  next
assert_cmd "F3 count excludes epic-* keys"            0 "2/4"           count
assert_cmd "F3 status of single-line entry"           0 "done"          status "1-1-后端工程脚手架"
assert_cmd "F3 status of block entry"                 0 "backlog"       status "2-1-前端面板"
assert_cmd "F3 status of single-line epic-* key (#77)" \
                                                      0 "in-progress"   status "epic-2"
assert_cmd "F3 epic-all-done 1 → all done"            0 ""              epic-all-done 1
assert_cmd "F3 epic-all-done 2 → pending remain"      1 ""              epic-all-done 2
assert_cmd "F3 next-in-epic 2 → block entry"          0 "2-1-前端面板"  next-in-epic 2
assert_cmd "F3 epic-of"                               0 "2"             epic-of "2-2-cli-tooling"

assert_set_diff "F3 set block entry in mixed file" \
    "2-1-前端面板" "done" "    status: done"
assert_cmd "F3 next-in-epic advances to single-line entry" \
                                                      0 "2-2-cli-tooling" next-in-epic 2
assert_set_diff "F3 set single-line entry in mixed file" \
    "2-2-cli-tooling" "review" "  2-2-cli-tooling: review"
assert_cmd "F3 find-by-status review"                 0 "2-2-cli-tooling" find-by-status review
assert_cmd "F3 epic-all-done 2 still pending (review ≠ done)" \
                                                      1 ""              epic-all-done 2

echo ""
echo "============================================================================"
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
