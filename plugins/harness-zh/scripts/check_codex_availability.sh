#!/usr/bin/env bash
# check_codex_availability — probe whether codex-in-cc is usable.
#
# Cheap detection: only checks for codex-companion.mjs presence on disk.
# Does NOT invoke codex (would consume quota). Runtime auth/quota failures
# are detected in run.md stage 3 in-flight via stderr regex match — this
# script catches the static "plugin not installed" case so we can skip
# stage 3+4 *before* even spawning a subagent.
#
# Output: single JSON line on stdout. Always exit 0 (caller parses JSON).
#   {"available": bool,
#    "reason": "ok"|"not_installed",
#    "binary_path": "<path>"|null,
#    "remediation": "<install command>"|null}
#
# Used by:
#   - commands/run.md   stage 3 pre-flight (skip if unavailable)
#   - commands/codex-catchup.md (refuse catchup if still unavailable)

set -uo pipefail

# Find the highest-version codex-companion.mjs under ~/.claude/plugins/cache/openai-codex
FOUND=""
while IFS= read -r cand; do
    [ -f "$cand" ] || continue
    FOUND="$cand"
    break
done < <(find ~/.claude/plugins/cache/openai-codex -maxdepth 4 -name "codex-companion.mjs" 2>/dev/null | sort -V -r)

if [ -z "$FOUND" ]; then
    cat <<'EOF'
{"available": false, "reason": "not_installed", "binary_path": null, "remediation": "/plugin marketplace add openai/codex-plugin-cc && /plugin install codex@openai-codex"}
EOF
    exit 0
fi

# Path exists. We deliberately do NOT call `node "$FOUND" --version` or any
# auth probe — that consumes quota and would defeat the purpose of cheap
# pre-flight. Trust the path; downstream in-flight detection (run.md stage 3
# stderr regex) catches auth/quota at first invocation.
printf '{"available": true, "reason": "ok", "binary_path": "%s", "remediation": null}\n' "$FOUND"
