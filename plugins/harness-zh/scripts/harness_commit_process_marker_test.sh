#!/bin/bash
# Self-test for harness-commit.py process-marker auto-prune (issue #8 /
# issue #9 finding 3, v0.1.39):
#
#   M1 — untracked `<KEY>.maven-skipped.json` is auto-pruned (STATUS=ok +
#        AUTO_FIXED=process-marker + file gone from worktree) instead of
#        UNEXPECTED_ARTIFACT halt.
#   M2 — untracked `<KEY>.sandbox-skipped.json` likewise.
#   M3 — an UNKNOWN marker tag (`<KEY>.gradle-skipped.json`) still halts —
#        the whitelist is an explicit enumeration, never `*-skipped.json`.
#   M4 — `<KEY>.codex-skipped.json` is a SCHEMA artifact (stage 2/4/5
#        story_json) and is staged, never swallowed by the marker prune.
#   M5 — a TRACKED `<KEY>.maven-skipped.json` (modified) is never
#        auto-deleted → halts UNEXPECTED_ARTIFACT (modified files never
#        auto-delete invariant).
#   M6 — --dry-run predicts the real-run outcome: STATUS=ok +
#        AUTO_FIXED=process-marker (action=planned-unstage+rm-dry-run), the
#        marker stays on disk, no UNEXPECTED_ARTIFACT halt.
#   M7 — worktree containing ONLY a marker: real run prunes it, then halts
#        "nothing left to commit" (stage 4 requires non-empty output) instead
#        of emitting a STATUS=ok that would suggest committing nothing.
#
# The mutating prune only runs on real (non --dry-run) invocations, so most
# fixtures here invoke harness-commit.py WITHOUT --dry-run inside throwaway
# tmp repos (stage 4 — project_code allowed, no dev-result gate).
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
    dir="$(mktemp -d -t hc_marker.XXXXXX)"
    (
        cd "$dir"
        git init -q
        git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
        mkdir -p _bmad-output/implementation-artifacts
        mkdir -p src
        touch _bmad-output/implementation-artifacts/.gitkeep
        touch src/.gitkeep
        printf '# story 9-9\nStatus: review\n' \
            > _bmad-output/implementation-artifacts/9-9-story.md
        printf 'development_status:\n  9-9-story: backlog\n' \
            > _bmad-output/implementation-artifacts/sprint-status.yaml
        printf '# deferred\n' \
            > _bmad-output/implementation-artifacts/deferred-work.md
        git add -A; git commit -q -m seed
    )
    echo "$dir"
}

# ============================================================================
# M1 — untracked maven-skipped marker auto-pruned, commit proceeds
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf 'code\n' > src/app.txt
    printf '{"reason":"no mvn in sandbox"}\n' \
        > _bmad-output/implementation-artifacts/9-9-story.maven-skipped.json
)
out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story 2>&1)"
marker_gone=0
[ ! -e "$dir/_bmad-output/implementation-artifacts/9-9-story.maven-skipped.json" ] && marker_gone=1
rm -rf "$dir"
if printf '%s' "$out" | grep -qE "^STATUS=ok$" \
   && printf '%s' "$out" | grep -qE "^AUTO_FIXED=process-marker _bmad-output/implementation-artifacts/9-9-story.maven-skipped.json action=unstaged\+rm tag=maven-skipped$" \
   && ! printf '%s' "$out" | grep -qE "^UNEXPECTED_ARTIFACT=" \
   && [ "$marker_gone" = 1 ]; then
    echo "PASS [M1-maven-skipped auto-pruned]"
else
    echo "FAIL [M1-maven-skipped]: marker_gone=$marker_gone out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# M2 — untracked sandbox-skipped marker auto-pruned
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf 'code\n' > src/app.txt
    printf '{"reason":"sandbox-bound"}\n' \
        > _bmad-output/implementation-artifacts/9-9-story.sandbox-skipped.json
)
out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story 2>&1)"
rm -rf "$dir"
if printf '%s' "$out" | grep -qE "^STATUS=ok$" \
   && printf '%s' "$out" | grep -qE "^AUTO_FIXED=process-marker .*tag=sandbox-skipped$"; then
    echo "PASS [M2-sandbox-skipped auto-pruned]"
else
    echo "FAIL [M2-sandbox-skipped]: out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# M3 — unknown marker tag still halts (explicit whitelist, no generalization)
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf '{"reason":"no gradle"}\n' \
        > _bmad-output/implementation-artifacts/9-9-story.gradle-skipped.json
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" != 0 ] \
   && printf '%s' "$out" | grep -qE "^STATUS=halt$" \
   && printf '%s' "$out" | grep -qE "^UNEXPECTED_ARTIFACT=_bmad-output/implementation-artifacts/9-9-story.gradle-skipped.json$" \
   && ! printf '%s' "$out" | grep -qE "^AUTO_FIXED=process-marker"; then
    echo "PASS [M3-unknown marker tag still halts]"
else
    echo "FAIL [M3-unknown-tag]: exit=$ex out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# M4 — codex-skipped.json is schema artifact: staged, never marker-pruned
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf '{"skipped":"codex-in-cc unavailable"}\n' \
        > _bmad-output/implementation-artifacts/9-9-story.codex-skipped.json
)
out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story 2>&1)"
codex_kept=0
[ -e "$dir/_bmad-output/implementation-artifacts/9-9-story.codex-skipped.json" ] && codex_kept=1
rm -rf "$dir"
if printf '%s' "$out" | grep -qE "^STATUS=ok$" \
   && printf '%s' "$out" | grep -qE "^STAGED=_bmad-output/implementation-artifacts/9-9-story.codex-skipped.json$" \
   && ! printf '%s' "$out" | grep -qE "^AUTO_FIXED=process-marker" \
   && [ "$codex_kept" = 1 ]; then
    echo "PASS [M4-codex-skipped schema artifact untouched]"
else
    echo "FAIL [M4-codex-skipped]: codex_kept=$codex_kept out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# M5 — tracked (modified) maven-skipped marker never auto-deleted → halt
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf '{"v":1}\n' \
        > _bmad-output/implementation-artifacts/9-9-story.maven-skipped.json
    git add -A; git commit -q -m track-marker
    printf '{"v":2}\n' \
        > _bmad-output/implementation-artifacts/9-9-story.maven-skipped.json
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story 2>&1)" || ex=$?
marker_kept=0
[ -e "$dir/_bmad-output/implementation-artifacts/9-9-story.maven-skipped.json" ] && marker_kept=1
rm -rf "$dir"
if [ "$ex" != 0 ] \
   && printf '%s' "$out" | grep -qE "^STATUS=halt$" \
   && printf '%s' "$out" | grep -qE "^UNEXPECTED_ARTIFACT=_bmad-output/implementation-artifacts/9-9-story.maven-skipped.json$" \
   && [ "$marker_kept" = 1 ]; then
    echo "PASS [M5-tracked marker never auto-deleted]"
else
    echo "FAIL [M5-tracked-marker]: exit=$ex marker_kept=$marker_kept out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# M6 — dry-run predicts the real-run outcome (marker excluded read-only)
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf 'code\n' > src/app.txt
    printf '{"reason":"no mvn in sandbox"}\n' \
        > _bmad-output/implementation-artifacts/9-9-story.maven-skipped.json
)
out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1)"
marker_kept=0
[ -e "$dir/_bmad-output/implementation-artifacts/9-9-story.maven-skipped.json" ] && marker_kept=1
rm -rf "$dir"
if printf '%s' "$out" | grep -qE "^STATUS=ok$" \
   && printf '%s' "$out" | grep -qE "^AUTO_FIXED=process-marker .*action=planned-unstage\+rm-dry-run tag=maven-skipped$" \
   && ! printf '%s' "$out" | grep -qE "^UNEXPECTED_ARTIFACT=" \
   && [ "$marker_kept" = 1 ]; then
    echo "PASS [M6-dry-run predicts auto-prune, file untouched]"
else
    echo "FAIL [M6-dry-run]: marker_kept=$marker_kept out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# M7 — marker-only worktree: pruned, then "nothing left to commit" halt
#      (stage 4 has skip_if_empty=False)
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf '{"reason":"no mvn in sandbox"}\n' \
        > _bmad-output/implementation-artifacts/9-9-story.maven-skipped.json
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story 2>&1)" || ex=$?
marker_gone=0
[ ! -e "$dir/_bmad-output/implementation-artifacts/9-9-story.maven-skipped.json" ] && marker_gone=1
rm -rf "$dir"
if [ "$ex" = 1 ] \
   && printf '%s' "$out" | grep -qE "^STATUS=halt$" \
   && printf '%s' "$out" | grep -qE "^REASON=worktree contained only auto-pruned files" \
   && printf '%s' "$out" | grep -qE "^AUTO_FIXED=process-marker .*tag=maven-skipped$" \
   && [ "$marker_gone" = 1 ]; then
    echo "PASS [M7-marker-only worktree pruned then clear halt]"
else
    echo "FAIL [M7-marker-only]: exit=$ex marker_gone=$marker_gone out=$out" >&2; failed=$((failed+1))
fi

echo "-------------------------------------------------------------------"
if [ "$failed" = 0 ]; then echo "ALL PASS"; else echo "$failed test(s) FAILED"; fi
exit "$failed"
