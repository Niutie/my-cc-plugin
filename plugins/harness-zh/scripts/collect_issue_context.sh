#!/usr/bin/env bash
# Collect plugin-level + project-state context for /harness-zh:report-issue.
# Renders a markdown body to stdout for `gh issue create --body-file`.
#
# Usage:
#   bash .claude/harness/scripts/collect_issue_context.sh \
#       --type bug|feature|halt|other \
#       --description "one-line summary" \
#       [--story <key>] [--epic <num>] \
#       [--halt-command run|run-test|init|update|upgrade-deferred-work|other] \
#       [--halt-stage <N>] [--halt-reason "现场一句话"] \
#       [--reproduction-file <path>]    # optional file with reproduction notes
#
# All flags optional except --type and --description; the script tolerates
# missing harness state (yaml absent / git not init / sprint-status missing).
#
# Exit code:
#   0  always (best-effort renderer; partial state is fine)
#   2  bad/missing required flag

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source read_harness_config.sh defensively — script must work even when
# harness-project-config.yaml is absent (e.g. /report-issue triggered on a
# project that hasn't run /harness-zh:init yet).
HARNESS_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd 2>/dev/null || pwd)"
if [ -f "$SCRIPT_DIR/read_harness_config.sh" ]; then
    # shellcheck source=read_harness_config.sh
    source "$SCRIPT_DIR/read_harness_config.sh" 2>/dev/null || true
fi

TYPE=""
DESC=""
STORY=""
EPIC=""
HALT_CMD=""
HALT_STAGE=""
HALT_REASON=""
REPRO_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --type)              TYPE="${2:-}"; shift 2;;
        --description)       DESC="${2:-}"; shift 2;;
        --story)             STORY="${2:-}"; shift 2;;
        --epic)              EPIC="${2:-}"; shift 2;;
        --halt-command)      HALT_CMD="${2:-}"; shift 2;;
        --halt-stage)        HALT_STAGE="${2:-}"; shift 2;;
        --halt-reason)       HALT_REASON="${2:-}"; shift 2;;
        --reproduction-file) REPRO_FILE="${2:-}"; shift 2;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

if [ -z "$TYPE" ] || [ -z "$DESC" ]; then
    echo "ERROR: --type and --description are required" >&2
    exit 2
fi

case "$TYPE" in
    bug|feature|halt|other) ;;
    *) echo "ERROR: --type must be one of: bug, feature, halt, other" >&2; exit 2;;
esac

# ── Plugin version ──────────────────────────────────────────────────────────
# Try project-side changelog first (deployed copy carries the version that
# generated these assets), then fall back to plugin.json probe.
PLUGIN_VERSION="unknown"
if [ -f "$HARNESS_REPO_ROOT/.claude/harness/changelog.md" ]; then
    v="$(grep -oE '^## [vV]?[0-9]+\.[0-9]+\.[0-9]+' "$HARNESS_REPO_ROOT/.claude/harness/changelog.md" 2>/dev/null \
        | head -1 | sed -E 's/^## [vV]?//')"
    [ -n "$v" ] && PLUGIN_VERSION="$v"
fi
if [ "$PLUGIN_VERSION" = "unknown" ]; then
    # Try ~/.claude/plugins/**/plugin.json (highest semver under cache/)
    # v0.1.30: use `command grep` inside the pipe-fed while loop — see
    # discover_plugin_root.sh comment for the grep-wrapper-subshell-exec hazard.
    pv="$(
        find "$HOME/.claude/plugins" -maxdepth 6 -name plugin.json 2>/dev/null | while IFS= read -r m; do
            command grep -q '"name":[[:space:]]*"harness-zh"' "$m" 2>/dev/null || continue
            command grep -oE '"version":[[:space:]]*"[^"]+"' "$m" | head -1 | sed -E 's/.*"([^"]+)"/\1/'
        done | sort -V -r | head -1
    )"
    [ -n "$pv" ] && PLUGIN_VERSION="$pv"
fi

# ── Environment ─────────────────────────────────────────────────────────────
OS_INFO="$(uname -srm 2>/dev/null || echo unknown)"
SHELL_INFO="${SHELL:-unknown}"
PLUGIN_ROOT_INJECTED="${CLAUDE_PLUGIN_ROOT:-(not injected)}"

# ── Git state (best effort) ─────────────────────────────────────────────────
GIT_BRANCH="(no git)"
GIT_HEAD="(no git)"
GIT_DIRTY="(no git)"
RECENT_HARNESS_COMMITS="(none / no git)"
RECENT_PROJECT_COMMITS="(none / no git)"
if git rev-parse --git-dir >/dev/null 2>&1; then
    GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    GIT_HEAD="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        GIT_DIRTY="dirty ($(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') changed)"
    else
        GIT_DIRTY="clean"
    fi
    rh="$(git log --oneline -10 -- .claude/harness/ .claude/commands/ 2>/dev/null)"
    [ -n "$rh" ] && RECENT_HARNESS_COMMITS="$rh"
    rp="$(git log --oneline -5 2>/dev/null)"
    [ -n "$rp" ] && RECENT_PROJECT_COMMITS="$rp"
fi

# ── Sprint state (tolerate missing) ─────────────────────────────────────────
SPRINT_COUNT="(sprint-status.yaml not present / harness not init)"
SPRINT_NEXT="(n/a)"
if [ -f "${HARNESS_SPRINT_STATUS_PATH:-}" ] && [ -x "$SCRIPT_DIR/sprint-status.py" ]; then
    SPRINT_COUNT="$(python3 "$SCRIPT_DIR/sprint-status.py" count 2>/dev/null || echo unknown)"
    SPRINT_NEXT="$(python3 "$SCRIPT_DIR/sprint-status.py" next 2>/dev/null || echo none)"
fi

# ── Epic context line (rendered unconditionally in "## Project state") ─────
# review 2026-06-10 #69：--epic 此前只在 halt block 内渲染 — 非 halt 类型
# （bug/feature/other）传 --epic 即被静默丢弃，与 report-issue.md §1 把它列为
# 通用上下文 flag 的契约不符。提升到 Project state 段无条件渲染。
EPIC_LINE=""
[ -n "$EPIC" ] && EPIC_LINE=$'\n'"- Epic context: $EPIC"

# ── Story state (only if --story passed) ────────────────────────────────────
STORY_BLOCK=""
if [ -n "$STORY" ] && [ -x "$SCRIPT_DIR/harness-state.py" ]; then
    sj="$(python3 "$SCRIPT_DIR/harness-state.py" "$STORY" 2>/dev/null || true)"
    if [ -n "$sj" ]; then
        STORY_BLOCK=$'\n\n## Story state — '"$STORY"$'\n\n```\n'"$sj"$'\n```'
    fi
fi

# ── Halt block (only if --halt-stage passed) ────────────────────────────────
HALT_BLOCK=""
if [ -n "$HALT_STAGE" ] || [ -n "$HALT_REASON" ] || [ -n "$HALT_CMD" ]; then
    HALT_BLOCK=$'\n\n## Halt context\n\n'
    [ -n "$HALT_CMD" ]    && HALT_BLOCK+="- Command: \`/harness-zh:$HALT_CMD\`"$'\n'
    [ -n "$HALT_STAGE" ]  && HALT_BLOCK+="- Stage: $HALT_STAGE"$'\n'
    [ -n "$STORY" ]       && HALT_BLOCK+="- Story: \`$STORY\`"$'\n'
    [ -n "$EPIC" ]        && HALT_BLOCK+="- Epic: $EPIC"$'\n'
    if [ -n "$HALT_REASON" ]; then
        HALT_BLOCK+=$'- Halt reason / 现场摘要：\n\n  > '"$HALT_REASON"$'\n'
    fi
fi

# ── Reproduction (optional file) ────────────────────────────────────────────
REPRO_BLOCK=""
if [ -n "$REPRO_FILE" ] && [ -f "$REPRO_FILE" ]; then
    REPRO_BLOCK=$'\n\n## Reproduction / steps tried\n\n'
    REPRO_BLOCK+="$(cat "$REPRO_FILE")"
fi

# ── harness-project-config.yaml fingerprint (privacy-conscious) ────────────
# Show only neutral fields: project_name (could be sensitive — user can edit),
# project_language, deferred_work_mode. Skip path-y / org fields.
CONFIG_FP="(not loaded)"
if [ -f "${HARNESS_CONFIG_PATH:-}" ]; then
    pname="$(grep -E '^project_name:' "$HARNESS_CONFIG_PATH" 2>/dev/null | head -1 | sed -E "s/^project_name:[[:space:]]+//;s/^['\"]//;s/['\"]$//")"
    plang="$(grep -E '^project_language:' "$HARNESS_CONFIG_PATH" 2>/dev/null | head -1 | sed -E "s/^project_language:[[:space:]]+//;s/^['\"]//;s/['\"]$//")"
    dwmode="$(grep -E '^deferred_work_mode:' "$HARNESS_CONFIG_PATH" 2>/dev/null | head -1 | sed -E "s/^deferred_work_mode:[[:space:]]+//;s/^['\"]//;s/['\"]$//")"
    CONFIG_FP=""
    [ -n "$pname" ]  && CONFIG_FP+="  - project_name: \`$pname\`"$'\n'
    [ -n "$plang" ]  && CONFIG_FP+="  - project_language: \`$plang\`"$'\n'
    [ -n "$dwmode" ] && CONFIG_FP+="  - deferred_work_mode: \`$dwmode\`"$'\n'
    [ -z "$CONFIG_FP" ] && CONFIG_FP="(yaml present but no recognized fields)"
fi

# ── Render markdown ─────────────────────────────────────────────────────────
cat <<MD
## Summary

$DESC

**Type**: \`$TYPE\`

## Plugin & environment

- harness-zh version: \`$PLUGIN_VERSION\`
- CLAUDE_PLUGIN_ROOT: \`$PLUGIN_ROOT_INJECTED\`
- OS: \`$OS_INFO\`
- Shell: \`$SHELL_INFO\`

## Project state

- Git branch: \`$GIT_BRANCH\` @ \`$GIT_HEAD\` ($GIT_DIRTY)
- Sprint position: $SPRINT_COUNT
- Next backlog story: \`$SPRINT_NEXT\`$EPIC_LINE

### harness-project-config.yaml fingerprint

$CONFIG_FP

### Recent harness-asset commits (\`.claude/harness/\` + \`.claude/commands/\`)

\`\`\`
$RECENT_HARNESS_COMMITS
\`\`\`

### Recent project commits (last 5)

\`\`\`
$RECENT_PROJECT_COMMITS
\`\`\`$STORY_BLOCK$HALT_BLOCK$REPRO_BLOCK

---

_Auto-collected by \`/harness-zh:report-issue\` (harness-zh \`$PLUGIN_VERSION\`)._
MD
