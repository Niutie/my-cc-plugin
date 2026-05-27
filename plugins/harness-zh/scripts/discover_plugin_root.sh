#!/usr/bin/env bash
# discover_plugin_root — locate harness-zh plugin install dir.
#
# Single source of truth for the discovery logic that init.md / update.md /
# upgrade-deferred-work.md previously duplicated (~50 lines × 3). Each command
# still keeps a minimal inline bootstrap (~12 lines) for the very first
# discovery (chicken-and-egg: can't source the helper before knowing where it
# lives). After PLUGIN_ROOT is found once, anything else can just call this
# script.
#
# Usage:
#   bash $PLUGIN_ROOT/scripts/discover_plugin_root.sh   # prints PLUGIN_ROOT to stdout
#   PLUGIN_ROOT="$(bash .claude/harness/scripts/discover_plugin_root.sh)" || exit 1
#
# Discovery order (each step short-circuits on hit):
#   1. ${CLAUDE_PLUGIN_ROOT} env (Claude Code injects in hooks ctx; sometimes
#      in commands ctx). Only used if dir actually exists.
#   2. ~/.claude/plugins/**/plugin.json scan, filter by name=="harness-zh",
#      keep only `*/cache/*` paths (canonical install location), skip orphaned
#      copies (those have a .orphaned_at marker), pick highest semver via
#      `sort -V -r`.
#   3. Fallback to any non-orphaned hit (e.g. marketplaces/ side).
#
# Exit codes:
#   0 — PLUGIN_ROOT printed to stdout (single line, no trailing newline noise)
#   1 — could not locate plugin

set -uo pipefail

# 1) env var path
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -n "$PLUGIN_ROOT" ] && [ -d "$PLUGIN_ROOT" ]; then
    printf '%s\n' "$PLUGIN_ROOT"
    exit 0
fi
PLUGIN_ROOT=""

# 2) cache scan with semver-ordered selection
# Use `command grep` inside the pipe-fed while loop (v0.1.30): on some dev envs
# `grep` is a shell function wrapper that does `exec -a ugrep ...` when it
# detects it's already in a subshell. The right side of `find | while` IS a
# subshell, so the wrapper replaces the entire while-loop subshell with the
# grep process — the loop dies after one iteration. `command` bypasses
# function lookup. Step 3 below uses process-substitution so the while runs
# in the main shell where the wrapper takes its safe `( exec )` branch — but
# we still defensively use `command grep` there too for consistency.
PLUGIN_ROOT="$(
    find ~/.claude/plugins -maxdepth 6 -name plugin.json 2>/dev/null | while IFS= read -r manifest; do
        command grep -q '"name":[[:space:]]*"harness-zh"' "$manifest" 2>/dev/null || continue
        cand="$(dirname "$(dirname "$manifest")")"
        [ -f "$cand/.orphaned_at" ] && continue
        # bash 3.2 (macOS default) has case+glob quirk inside $(...); use [[ == ]]
        [[ "$cand" == */cache/* ]] || continue
        printf '%s\t%s\n' "$(basename "$cand")" "$cand"
    done | sort -V -r -k1,1 | head -n 1 | cut -f2-
)"

# 3) fallback to any non-orphaned hit (covers marketplaces/<...>/plugins/<plugin>/)
if [ -z "$PLUGIN_ROOT" ]; then
    while IFS= read -r manifest; do
        if command grep -q '"name":[[:space:]]*"harness-zh"' "$manifest" 2>/dev/null; then
            cand="$(dirname "$(dirname "$manifest")")"
            [ -f "$cand/.orphaned_at" ] && continue
            PLUGIN_ROOT="$cand"
            break
        fi
    done < <(find ~/.claude/plugins -maxdepth 6 -name plugin.json 2>/dev/null)
fi

if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    cat >&2 <<'EOF'
ERROR [discover_plugin_root]: could not locate harness-zh plugin install dir
  Tried:
    1. ${CLAUDE_PLUGIN_ROOT} env var
    2. cache scan: ~/.claude/plugins/**/plugin.json with name=="harness-zh"
    3. non-cache fallback
  Verify the plugin is installed:
    /plugin marketplace add Niutie/my-cc-plugin
    /plugin install harness-zh@my-cc-plugin
EOF
    exit 1
fi

printf '%s\n' "$PLUGIN_ROOT"
