#!/bin/bash
# Self-test for harness-commit.py `retro-fulfill` stage (issue #3).
#
# Runs against the PLUGIN SOURCE harness-commit.py directly (no deployed
# .claude/harness/ needed) via tmp git repos + --dry-run, so it passes in the
# source tree (unlike harness_commit_isolation_test.sh which needs a deployed
# copy). Fixtures:
#   F1 happy path  — project code + sprint-status.yaml(status flip) + chore-retro
#                    spec all staged; commit_msg = chore(retro-cN-CODE): ...
#   F2 missing epic — stage requires --epic → halt
#   F3 cross-story  — foreign <other>.md in the commit → halt (isolation intact)
#
# 整脚本退出码 = 失败 fixture 数（0 = 全过）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_PY="$SCRIPT_DIR/harness-commit.py"

if [ ! -f "$HARNESS_PY" ]; then
    echo "ERROR: harness-commit.py not found at $HARNESS_PY" >&2
    exit 1
fi

failed=0

seed_repo() {
    local dir
    dir="$(mktemp -d -t rf_stage.XXXXXX)"
    (
        cd "$dir"
        git init -q
        git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
        mkdir -p _bmad-output/implementation-artifacts console-api/internal
        touch _bmad-output/implementation-artifacts/.gitkeep console-api/internal/.gitkeep
        printf 'retro_action_items:\n  epic-4-retro:\n    D7: pending\n' \
            > _bmad-output/implementation-artifacts/sprint-status.yaml
        printf '# chore D7\n' \
            > _bmad-output/implementation-artifacts/chore-retro-c4-D7-foo.md
        git add -A; git commit -q -m seed
    )
    echo "$dir"
}

# --- F1 happy path ---
dir="$(seed_repo)"
(
    cd "$dir"
    printf 'package x\n' > console-api/internal/foo.go
    printf 'retro_action_items:\n  epic-4-retro:\n    D7: done\n' \
        > _bmad-output/implementation-artifacts/sprint-status.yaml
    printf '# chore D7\n- [x] done\n' \
        > _bmad-output/implementation-artifacts/chore-retro-c4-D7-foo.md
)
out="$(cd "$dir" && python3 "$HARNESS_PY" retro-fulfill D7 --epic 4 --dry-run 2>&1)"
rm -rf "$dir"
if printf '%s' "$out" | grep -qE "^STATUS=ok$" \
   && printf '%s' "$out" | grep -qE "SUGGEST_COMMIT_MSG=chore\(retro-c4-D7\): fulfill retro dev item" \
   && printf '%s' "$out" | grep -qE "STAGED=console-api/internal/foo.go" \
   && printf '%s' "$out" | grep -qE "STAGED=.*sprint-status.yaml" \
   && printf '%s' "$out" | grep -qE "STAGED=.*chore-retro-c4-D7-foo.md"; then
    echo "PASS [F1-happy]"
else
    echo "FAIL [F1-happy]: out=$out" >&2; failed=$((failed+1))
fi

# --- F2 missing epic ---
dir="$(seed_repo)"
(cd "$dir" && printf 'package x\n' > console-api/internal/foo.go)
ex2=0; out2="$(cd "$dir" && python3 "$HARNESS_PY" retro-fulfill D7 --dry-run 2>&1)" || ex2=$?
rm -rf "$dir"
if [ "$ex2" != 0 ] && printf '%s' "$out2" | grep -qE "requires --epic"; then
    echo "PASS [F2-missing-epic]"
else
    echo "FAIL [F2-missing-epic]: exit=$ex2 out=$out2" >&2; failed=$((failed+1))
fi

# --- F3 cross-story isolation ---
dir="$(seed_repo)"
(
    cd "$dir"
    printf 'package x\n' > console-api/internal/foo.go
    printf '# other\n' > _bmad-output/implementation-artifacts/9-9-other-story.md
)
out3="$(cd "$dir" && python3 "$HARNESS_PY" retro-fulfill D7 --epic 4 --dry-run 2>&1)"
rm -rf "$dir"
if printf '%s' "$out3" | grep -qE "^STATUS=halt$" \
   && printf '%s' "$out3" | grep -qE "CROSS_STORY=.*9-9-other-story.md"; then
    echo "PASS [F3-cross-story]"
else
    echo "FAIL [F3-cross-story]: out=$out3" >&2; failed=$((failed+1))
fi

echo "-------------------------------------------------------------------"
if [ "$failed" = 0 ]; then echo "ALL PASS"; else echo "$failed test(s) FAILED"; fi
exit "$failed"
