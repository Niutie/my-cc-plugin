#!/usr/bin/env bash
# ensure_gitignore — bring the project's .gitignore in line with the super-harness
# git tracking policy (0.3.1+):
#
#   deployed assets under .claude/harness/ are IGNORED (they are plugin copies,
#   refreshed by every /super-harness:update); the two user-edited configs are
#   TRACKED:
#
#     /.claude/harness/*
#     !/.claude/harness/harness-project-config.yaml
#     !/.claude/harness/parallel.yaml
#
# super-harness deploys nothing else into the project tree (slash commands are
# served by the plugin, not copied into .claude/commands/ — see deploy_assets.sh),
# so these three lines cover every deployed file, the deploy manifest, and the
# update backups under .claude/harness/.backup/.
#
# Idempotent: appends only what is missing; creates .gitignore when absent.
#   - `/.claude/harness/*` missing → the whole block is appended (the negations
#     must come AFTER it to take effect, even if older copies exist above)
#   - only negations missing      → just those are appended
#   - a bare `/.claude/harness` or `/.claude/harness/` line (what super-harness
#     ≤ 0.3.0 `superh.py doctor` told users to add) ignores the directory itself,
#     and git cannot re-include files inside an ignored directory → that exact
#     line is removed and reported as GITIGNORE_REPLACED=
#
# Usage:
#   bash ensure_gitignore.sh [PROJECT_ROOT]          # default $PWD
#   bash ensure_gitignore.sh [PROJECT_ROOT] --check  # report only, write nothing
#
# Output (stdout, one KEY=value per line):
#   GITIGNORE_ADDED=<line>        each appended line
#   GITIGNORE_REPLACED=<line>     each removed legacy line
#   GITIGNORE_MISSING=<line>      (--check) each line that would be added
#   GITIGNORE_CONFLICT=<path> <- <source:line:pattern>
#                                 a config that is still ignored after the edit
#                                 (another rule, e.g. `.claude/`, global excludes)
#   GITIGNORE_TRACKED_ASSETS=<N>  deployed files already committed (ignore rules
#                                 do not apply to tracked files); followed by
#   GITIGNORE_UNTRACK_HINT=<cmd>  the command that stops tracking them
#   GITIGNORE_STATUS=added|unchanged|missing
#
# Exit codes: 0 ok (also --check with nothing missing); 1 bad args / write
# failure; 4 --check and something is missing.

set -uo pipefail

ROOT="$PWD"
CHECK=0
for a in "$@"; do
    case "$a" in
        --check) CHECK=1 ;;
        -h|--help) sed -nE 's/^# ?//p' "$0" | head -45; exit 0 ;;
        -*) echo "ERROR [ensure_gitignore]: unknown flag: $a" >&2; exit 1 ;;
        *) ROOT="$a" ;;
    esac
done
if [ ! -d "$ROOT" ]; then
    echo "ERROR [ensure_gitignore]: not a directory: $ROOT" >&2
    exit 1
fi

GI="$ROOT/.gitignore"
IGNORE_LINE='/.claude/harness/*'
CONFIGS=".claude/harness/harness-project-config.yaml .claude/harness/parallel.yaml"
LEGACY_LINES='/.claude/harness
/.claude/harness/'

has_line() {
    [ -f "$GI" ] || return 1
    # exact line match, tolerant of trailing whitespace / CRLF
    sed -e 's/[[:space:]]*$//' "$GI" | grep -qxF -- "$1"
}

TO_ADD=""
if ! has_line "$IGNORE_LINE"; then
    TO_ADD="$IGNORE_LINE"
    for c in $CONFIGS; do TO_ADD="$TO_ADD
!/$c"; done
else
    for c in $CONFIGS; do
        has_line "!/$c" || TO_ADD="${TO_ADD:+$TO_ADD
}!/$c"
    done
fi

LEGACY_HIT=""
if [ -f "$GI" ]; then
    while IFS= read -r l; do
        [ -n "$l" ] && has_line "$l" && LEGACY_HIT="${LEGACY_HIT:+$LEGACY_HIT
}$l"
    done <<EOF
$LEGACY_LINES
EOF
fi

if [ "$CHECK" = "1" ]; then
    if [ -z "$TO_ADD" ] && [ -z "$LEGACY_HIT" ]; then
        echo "GITIGNORE_STATUS=unchanged"
        exit 0
    fi
    [ -n "$TO_ADD" ] && printf '%s\n' "$TO_ADD" | sed 's/^/GITIGNORE_MISSING=/'
    [ -n "$LEGACY_HIT" ] && printf '%s\n' "$LEGACY_HIT" | sed 's/^/GITIGNORE_REPLACED=/'
    echo "GITIGNORE_STATUS=missing"
    exit 4
fi

STATUS="unchanged"
if [ -n "$LEGACY_HIT" ]; then
    TMP="$(mktemp "$GI.tmp.XXXXXX")" || exit 1
    # drop exactly the legacy lines (trailing whitespace / CR tolerated)
    awk '{ s = $0; sub(/[ \t\r]+$/, "", s) } s == "/.claude/harness" || s == "/.claude/harness/" { next } { print }' \
        "$GI" > "$TMP" && mv -f "$TMP" "$GI" || { rm -f "$TMP"; echo "ERROR [ensure_gitignore]: failed to rewrite $GI" >&2; exit 1; }
    printf '%s\n' "$LEGACY_HIT" | sed 's/^/GITIGNORE_REPLACED=/'
    STATUS="added"
    # the removed line may have been the only ignore rule → recompute
    if ! has_line "$IGNORE_LINE"; then
        TO_ADD="$IGNORE_LINE"
        for c in $CONFIGS; do TO_ADD="$TO_ADD
!/$c"; done
    fi
fi

if [ -n "$TO_ADD" ]; then
    {
        # keep the previous last line intact when the file lacks a final newline
        if [ -s "$GI" ] && [ -n "$(tail -c 1 "$GI")" ]; then
            echo ""
        fi
        echo "# super-harness: deployed assets are ignored, the two configs are tracked"
        printf '%s\n' "$TO_ADD"
    } >> "$GI" || { echo "ERROR [ensure_gitignore]: failed to write $GI" >&2; exit 1; }
    printf '%s\n' "$TO_ADD" | sed 's/^/GITIGNORE_ADDED=/'
    STATUS="added"
fi

# Post-checks need a git work tree rooted at ROOT.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    for c in $CONFIGS; do
        # --no-index: judge the path by the rules even if it is tracked already
        src="$(git -C "$ROOT" check-ignore --no-index -v -- "$c" 2>/dev/null || true)"
        case "$src" in
            ""|*":!"*) ;;   # not ignored, or the last matching rule is a negation
            *) echo "GITIGNORE_CONFLICT=$c <- ${src%%$'\t'*}" ;;
        esac
    done
    n_tracked="$(git -C "$ROOT" ls-files -- .claude/harness 2>/dev/null \
        | grep -vxF -e .claude/harness/harness-project-config.yaml -e .claude/harness/parallel.yaml \
        | grep -c . || true)"
    if [ "${n_tracked:-0}" -gt 0 ]; then
        echo "GITIGNORE_TRACKED_ASSETS=$n_tracked"
        echo "GITIGNORE_UNTRACK_HINT=git rm -r -q --cached .claude/harness && git add .gitignore .claude/harness/harness-project-config.yaml .claude/harness/parallel.yaml"
    fi
fi

echo "GITIGNORE_STATUS=$STATUS"
exit 0
