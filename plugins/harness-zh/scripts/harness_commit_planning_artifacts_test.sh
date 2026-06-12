#!/bin/bash
# Self-test for harness-commit.py `planning_artifacts:` frontmatter whitelist
# (issue #9 finding 1, v0.1.39):
#
#   P1 — story spec declaring `planning_artifacts:` lets a modified
#        `_bmad-output/planning-artifacts/epics.md` pass (STATUS=ok +
#        PLANNING_ARTIFACT= line + staged), instead of OUT_OF_SCOPE_BMAD halt.
#   P2 — UNdeclared planning-artifacts writeback still halts (issue #5 guard
#        regression check) and the GUIDANCE line now mentions the
#        `planning_artifacts:` mechanism.
#   P3 — invalid entries are silently dropped: non-.md (`epics.yaml`) and
#        wrong subtree (`brainstorming/`) both still halt with their paths in
#        OUT_OF_SCOPE_BMAD (load-bearing assertions — each kills the
#        validation-deletion mutant). The `..`-traversal rule cannot be
#        pinned at this integration level (git porcelain paths are always
#        normalized, so a `..` entry can never string-match a changed path);
#        P3b pins it at the parser level instead.
#   P3b — parser-level probe: `..` traversal entry yields an empty allowlist.
#   P4 — retro-fulfill stage: chore spec `chore-retro-c<epic>-<code>-*.md`
#        declaring the field passes (glob-fallback spec resolution — the
#        exact epic-6-run E11 scenario from issue #9).
#   P5 — retro-fulfill without declaration still halts.
#   P6 — declared on a project_code=False stage (stage 1) → whitelist does
#        NOT take effect; halts OUT_OF_SCOPE_BMAD (not the opaque FORBIDDEN)
#        and GUIDANCE says the mechanism doesn't apply on this stage.
#   P7 — retro-fulfill spec resolution prefers the sprint-status.yaml
#        `chore_spec:` field: two prefix-sharing lowercase-kebab codes
#        (E-flyway / E-flyway-extra) make the glob ambiguous, but the yaml
#        field resolves the right spec and the declared writeback passes.
#
# Runs against the PLUGIN SOURCE harness-commit.py directly (no deployed
# .claude/harness/ needed) via tmp git repos + --dry-run, like
# harness_commit_issue5_test.sh.
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

# Pre-track parent dirs + a baseline epics.md so the test modifies a tracked
# planning doc (the real issue #9 scenario: forward-only remediation edits an
# existing epics.md).
seed_repo() {
    local dir
    dir="$(mktemp -d -t hc_planning.XXXXXX)"
    (
        cd "$dir"
        git init -q
        git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
        mkdir -p _bmad-output/implementation-artifacts
        mkdir -p _bmad-output/planning-artifacts
        mkdir -p _bmad-output/brainstorming
        touch _bmad-output/implementation-artifacts/.gitkeep
        touch _bmad-output/brainstorming/.gitkeep
        printf '# epics\n\n## Story 5.3\n' > _bmad-output/planning-artifacts/epics.md
        printf 'development_status:\n  9-9-story: backlog\n' \
            > _bmad-output/implementation-artifacts/sprint-status.yaml
        printf '# deferred\n' \
            > _bmad-output/implementation-artifacts/deferred-work.md
        git add -A; git commit -q -m seed
    )
    echo "$dir"
}

# ============================================================================
# P1 — story spec declares planning_artifacts → epics.md writeback passes
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf -- '---\nstatus: ready-for-dev\nplanning_artifacts:\n  - _bmad-output/planning-artifacts/epics.md\n---\n# story 9-9\nStatus: review\n' \
        > _bmad-output/implementation-artifacts/9-9-story.md
    git add -A; git commit -q -m spec
    printf '\n## Story 5.3 (amended AC)\n' >> _bmad-output/planning-artifacts/epics.md
)
out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1)"
rm -rf "$dir"
if printf '%s' "$out" | grep -qE "^STATUS=ok$" \
   && ! printf '%s' "$out" | grep -qE "^OUT_OF_SCOPE_BMAD=" \
   && printf '%s' "$out" | grep -qE "^PLANNING_ARTIFACT=_bmad-output/planning-artifacts/epics.md$" \
   && printf '%s' "$out" | grep -qE "^STAGED=_bmad-output/planning-artifacts/epics.md$"; then
    echo "PASS [P1-declared planning writeback passes]"
else
    echo "FAIL [P1-declared]: out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# P2 — undeclared planning writeback still halts + GUIDANCE mentions mechanism
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf '# story 9-9\nStatus: review\n' \
        > _bmad-output/implementation-artifacts/9-9-story.md
    git add -A; git commit -q -m spec
    printf '\n## drift\n' >> _bmad-output/planning-artifacts/epics.md
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" != 0 ] \
   && printf '%s' "$out" | grep -qE "^STATUS=halt$" \
   && printf '%s' "$out" | grep -qE "^OUT_OF_SCOPE_BMAD=_bmad-output/planning-artifacts/epics.md$" \
   && printf '%s' "$out" | grep -qE "^GUIDANCE=.*planning_artifacts" ; then
    echo "PASS [P2-undeclared still halts + guidance updated]"
else
    echo "FAIL [P2-undeclared]: exit=$ex out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# P3 — invalid entries dropped (non-.md / wrong subtree), each load-bearing:
#      the declared epics.yaml and brainstorming/notes.md are BOTH modified
#      in the worktree and must BOTH appear in OUT_OF_SCOPE_BMAD.
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf -- '---\nplanning_artifacts:\n  - _bmad-output/planning-artifacts/../secrets.md\n  - _bmad-output/planning-artifacts/epics.yaml\n  - _bmad-output/brainstorming/notes.md\n---\n# story 9-9\nStatus: review\n' \
        > _bmad-output/implementation-artifacts/9-9-story.md
    git add -A; git commit -q -m spec
    printf '# notes\n' > _bmad-output/brainstorming/notes.md
    printf 'epics: {}\n' > _bmad-output/planning-artifacts/epics.yaml
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" != 0 ] \
   && printf '%s' "$out" | grep -qE "^STATUS=halt$" \
   && printf '%s' "$out" | grep -qE "^OUT_OF_SCOPE_BMAD=_bmad-output/brainstorming/notes.md$" \
   && printf '%s' "$out" | grep -qE "^OUT_OF_SCOPE_BMAD=_bmad-output/planning-artifacts/epics.yaml$"; then
    echo "PASS [P3-invalid entries dropped (non-.md + wrong subtree) still halt]"
else
    echo "FAIL [P3-invalid-entries]: exit=$ex out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# P3b — parser-level probe: `..` traversal entry never enters the allowlist
#       (unpinnable via porcelain paths — git normalizes them — so probe the
#       parser directly, same importlib pattern as issue5 test I1).
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf -- '---\nplanning_artifacts:\n  - _bmad-output/planning-artifacts/../secrets.md\n  - _bmad-output/planning-artifacts/ok.md\n---\n# story 9-9\n' \
        > _bmad-output/implementation-artifacts/9-9-story.md
)
p3b_out="$(cd "$dir" && python3 - "$HARNESS_PY" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
allowed = m.read_planning_artifacts_allowlist("9-9-story", None, "4")
want = {"_bmad-output/planning-artifacts/ok.md"}
print("OK" if allowed == want else "BAD " + repr(allowed))
PY
)"
rm -rf "$dir"
if [ "$p3b_out" = "OK" ]; then
    echo "PASS [P3b-parser drops .. traversal entry]"
else
    echo "FAIL [P3b-traversal]: $p3b_out" >&2; failed=$((failed+1))
fi

# ============================================================================
# P4 — retro-fulfill: chore spec declares planning_artifacts → passes
#      (the epic-6-run E11 forward-only remediation scenario)
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf -- '---\ntitle: '\''Chore E11 — flyway forward-only remediation'\''\ntype: '\''chore'\''\nplanning_artifacts:\n  - _bmad-output/planning-artifacts/epics.md\n---\n## Intent\nwrite back epics.md\n## Tasks & Acceptance\n- [ ] update epics.md\n' \
        > _bmad-output/implementation-artifacts/chore-retro-c5-E11-flyway-forward-only.md
    git add -A; git commit -q -m chore-spec
    printf '\n## Story 5.3 AC (remediated)\n' >> _bmad-output/planning-artifacts/epics.md
)
out="$(cd "$dir" && python3 "$HARNESS_PY" retro-fulfill E11 --epic 5 --dry-run 2>&1)"
rm -rf "$dir"
if printf '%s' "$out" | grep -qE "^STATUS=ok$" \
   && ! printf '%s' "$out" | grep -qE "^OUT_OF_SCOPE_BMAD=" \
   && printf '%s' "$out" | grep -qE "^PLANNING_ARTIFACT=_bmad-output/planning-artifacts/epics.md$"; then
    echo "PASS [P4-retro-fulfill declared writeback passes]"
else
    echo "FAIL [P4-retro-fulfill]: out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# P5 — retro-fulfill without declaration still halts
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf -- '---\ntitle: '\''Chore E12 — no planning writeback declared'\''\ntype: '\''chore'\''\n---\n## Tasks & Acceptance\n- [ ] something\n' \
        > _bmad-output/implementation-artifacts/chore-retro-c5-E12-no-writeback.md
    git add -A; git commit -q -m chore-spec
    printf '\n## sneaky edit\n' >> _bmad-output/planning-artifacts/epics.md
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" retro-fulfill E12 --epic 5 --dry-run 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" != 0 ] \
   && printf '%s' "$out" | grep -qE "^STATUS=halt$" \
   && printf '%s' "$out" | grep -qE "^OUT_OF_SCOPE_BMAD=_bmad-output/planning-artifacts/epics.md$"; then
    echo "PASS [P5-retro-fulfill undeclared still halts]"
else
    echo "FAIL [P5-retro-fulfill-undeclared]: exit=$ex out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# P6 — declared on a project_code=False stage (stage 1): whitelist gated off,
#      still the clear OUT_OF_SCOPE_BMAD halt (not FORBIDDEN), GUIDANCE says
#      the mechanism doesn't apply on this stage.
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf -- '---\nstatus: ready-for-dev\nplanning_artifacts:\n  - _bmad-output/planning-artifacts/epics.md\n---\n# story 9-9\nStatus: draft\n' \
        > _bmad-output/implementation-artifacts/9-9-story.md
    printf '\n## sneaky planning edit at stage 1\n' >> _bmad-output/planning-artifacts/epics.md
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 1 9-9-story --dry-run 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" != 0 ] \
   && printf '%s' "$out" | grep -qE "^STATUS=halt$" \
   && printf '%s' "$out" | grep -qE "^OUT_OF_SCOPE_BMAD=_bmad-output/planning-artifacts/epics.md$" \
   && ! printf '%s' "$out" | grep -qE "^FORBIDDEN=" \
   && printf '%s' "$out" | grep -qE "^GUIDANCE=.*does not apply on stage 1"; then
    echo "PASS [P6-project_code=False stage gated off with clear diagnosis]"
else
    echo "FAIL [P6-stage1]: exit=$ex out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# P7 — retro-fulfill resolution prefers yaml chore_spec over ambiguous glob:
#      codes E-flyway / E-flyway-extra share a prefix (glob alone would find
#      2 candidates for E-flyway → WARN + whitelist ignored), but the
#      sprint-status.yaml chore_spec field pins the right spec.
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    printf 'development_status:\n  9-9-story: backlog\n\nretro_action_items:\n  epic-5-retro:\n    E-flyway: pending\n      chore_spec: '\''chore-retro-c5-E-flyway-remediation.md'\''\n    E-flyway-extra: pending\n' \
        > _bmad-output/implementation-artifacts/sprint-status.yaml
    printf -- '---\ntitle: '\''Chore E-flyway'\''\ntype: '\''chore'\''\nplanning_artifacts:\n  - _bmad-output/planning-artifacts/epics.md\n---\n## Tasks & Acceptance\n- [ ] write back epics.md\n' \
        > _bmad-output/implementation-artifacts/chore-retro-c5-E-flyway-remediation.md
    printf -- '---\ntitle: '\''Chore E-flyway-extra'\''\ntype: '\''chore'\''\n---\n## Tasks & Acceptance\n- [ ] unrelated\n' \
        > _bmad-output/implementation-artifacts/chore-retro-c5-E-flyway-extra-cleanup.md
    git add -A; git commit -q -m chore-specs
    printf '\n## remediated by E-flyway\n' >> _bmad-output/planning-artifacts/epics.md
)
out="$(cd "$dir" && python3 "$HARNESS_PY" retro-fulfill E-flyway --epic 5 --dry-run 2>&1)"
rm -rf "$dir"
if printf '%s' "$out" | grep -qE "^STATUS=ok$" \
   && printf '%s' "$out" | grep -qE "^PLANNING_ARTIFACT=_bmad-output/planning-artifacts/epics.md$" \
   && ! printf '%s' "$out" | grep -q "WARN \[_resolve_spec_md_path\]"; then
    echo "PASS [P7-yaml chore_spec beats ambiguous glob]"
else
    echo "FAIL [P7-yaml-first]: out=$out" >&2; failed=$((failed+1))
fi

echo "-------------------------------------------------------------------"
if [ "$failed" = 0 ]; then echo "ALL PASS"; else echo "$failed test(s) FAILED"; fi
exit "$failed"
