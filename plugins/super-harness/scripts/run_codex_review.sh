#!/usr/bin/env bash
# run_codex_review — run the codex adversarial review for one story and turn
# the result into a structured status (pipeline.md §1 B2.2, codex-catchup §4.3).
#
# Why a script: the main agent used to hand this to a subagent that ran
# codex-companion in a 2-minute default Bash timeout, judged success by file
# size, retyped codex stdout into the report, and decided quota/auth by
# scanning the subagent's prose for words like "quota" / "unauthorized"
# (a story about rate limiting tripped it). Here every decision comes from
# codex's exit code and its own output format:
#   ok           exit 0 AND a `Verdict: <word>` line (render.mjs
#                renderReviewResult) AND either finding bullets
#                `- [critical|high|medium|low] ...` or `No material findings.`
#   quota / auth exit != 0 (or no Verdict) AND a codex runtime error message
#                matches; only error lines are matched — stderr lines that are
#                not `[codex]` progress, `[codex] Codex error:` lines, and the
#                `- Parse error:` line. Codex's review prose is never scanned.
#   unavailable  companion script missing, or "Codex CLI is not installed"
#   timeout      the review ran past --timeout (default 570 s, under the
#                600000 ms Bash tool cap the pipeline asks for)
#   error        anything else (bad base ref, unparseable output, ...)
#
# The report file is assembled by shell (frontmatter + codex stdout, byte for
# byte) and only moved into place when the status is ok — a failed run never
# leaves `<KEY>.codex-review.md` in the worktree.
#
# Usage:
#   bash .claude/harness/scripts/run_codex_review.sh --key <KEY> --base <SHA> --spec <spec path>
#        [--cwd <dir>]            review a different worktree (codex-catchup window anchor);
#                                 frontmatter head = HEAD of that dir
#        [--window-degraded]      add `window: degraded` to the frontmatter (codex-catchup)
#        [--companion <path>]     codex-companion.mjs (default: $CLAUDE_PLUGIN_ROOT, then
#                                 the newest ~/.claude/plugins/cache/openai-codex/codex/*/)
#        [--out <file>]           report path (default <artifacts>/<KEY>.codex-review.md)
#        [--timeout <secs>]       default $CODEX_REVIEW_TIMEOUT or 570; 0 = no limit
#
# stdout, first line always:
#   CODEX_STATUS: ok|quota|auth|unavailable|timeout|error
# then KEY=VALUE lines: CODEX_EXIT=, CODEX_REASON= (non-ok: the marker reason
# quota_exhausted / auth_failed / not_installed / timeout / unknown),
# CODEX_FINDINGS= and REPORT_FILE= (ok), RAW_DIR= (raw stdout/stderr kept for
# inspection), and on non-ok a short tail of codex's error output.
#
# Exit: 0 = ok; 2 = quota / auth / unavailable / timeout (pipeline §B2.1 skip);
#       1 = error (halt) or bad arguments.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

KEY=""; BASE=""; SPEC=""; CWD=""; DEGRADED=0; COMPANION=""; OUT=""
TIMEOUT_S="${CODEX_REVIEW_TIMEOUT:-570}"

usage() { sed -n '2,46p' "$0" >&2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --key) KEY="${2:-}"; shift 2 ;;
        --base) BASE="${2:-}"; shift 2 ;;
        --spec) SPEC="${2:-}"; shift 2 ;;
        --cwd) CWD="${2:-}"; shift 2 ;;
        --window-degraded) DEGRADED=1; shift ;;
        --companion) COMPANION="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT_S="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "CODEX_STATUS: error"; echo "CODEX_REASON=unknown"; echo "ERROR=unknown argument: $1"; exit 1 ;;
    esac
done

if [ -z "$KEY" ] || [ -z "$BASE" ] || [ -z "$SPEC" ]; then
    echo "CODEX_STATUS: error"
    echo "CODEX_REASON=unknown"
    echo "ERROR=--key, --base and --spec are required"
    exit 1
fi

if [ -z "$OUT" ]; then
    ART="_bmad-output/implementation-artifacts"
    if [ -f "$SCRIPT_DIR/read_harness_config.sh" ]; then
        # shellcheck source=read_harness_config.sh
        ART="$(source "$SCRIPT_DIR/read_harness_config.sh" 2>/dev/null && printf '%s' "${HARNESS_ARTIFACTS_ROOT:-$ART}")" || ART="_bmad-output/implementation-artifacts"
    fi
    OUT="${ART%/}/${KEY}.codex-review.md"
fi

if [ -z "$COMPANION" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs" ]; then
    COMPANION="${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs"
fi
if [ -z "$COMPANION" ]; then
    COMPANION="$(ls "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)"
fi
if [ -z "$COMPANION" ] || [ ! -f "$COMPANION" ] || ! command -v node >/dev/null 2>&1; then
    echo "CODEX_STATUS: unavailable"
    echo "CODEX_REASON=not_installed"
    echo "CODEX_EXIT=-"
    echo "DETAIL=codex-companion.mjs or node not found"
    exit 2
fi

RAW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-${KEY}.XXXXXX")" || {
    echo "CODEX_STATUS: error"; echo "CODEX_REASON=unknown"; echo "ERROR=mktemp failed"; exit 1; }
RAW_OUT="$RAW_DIR/stdout.md"
RAW_ERR="$RAW_DIR/stderr.log"

FOCUS="review focus: story ${KEY} 的代码实现（spec 在 ${SPEC}，作为验收标准上下文，review 对象是代码 diff）"
CMD=(node "$COMPANION" adversarial-review --wait --base "$BASE")
[ -n "$CWD" ] && CMD+=(--cwd "$CWD")
CMD+=("$FOCUS")

TO_BIN=""
if [ "${TIMEOUT_S:-0}" != "0" ]; then
    if command -v timeout >/dev/null 2>&1; then TO_BIN="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then TO_BIN="gtimeout"
    fi
fi
if [ -n "$TO_BIN" ]; then
    "$TO_BIN" "$TIMEOUT_S" "${CMD[@]}" >"$RAW_OUT" 2>"$RAW_ERR"
else
    "${CMD[@]}" >"$RAW_OUT" 2>"$RAW_ERR"
fi
EXIT=$?

# error lines only: stderr minus `[codex] ` progress (but keep `[codex] Codex
# error:`), plus the `- Parse error:` line codex renders on a failed turn.
error_lines() {
    { grep -v '^\[codex\] ' "$RAW_ERR" 2>/dev/null
      grep '^\[codex\] Codex error:' "$RAW_ERR" 2>/dev/null
      grep '^- Parse error:' "$RAW_OUT" 2>/dev/null
    } || true
}

finish_fail() {  # $1 status  $2 reason  $3 exit code
    echo "CODEX_STATUS: $1"
    echo "CODEX_REASON=$2"
    echo "CODEX_EXIT=$EXIT"
    echo "RAW_DIR=$RAW_DIR"
    echo "--- codex error output (tail) ---"
    { error_lines; tail -n 5 "$RAW_OUT" 2>/dev/null; } | tail -n 15
    exit "$3"
}

HAS_VERDICT=0
grep -Eq '^Verdict: [A-Za-z-]+[[:space:]]*$' "$RAW_OUT" && HAS_VERDICT=1

if [ "$EXIT" -eq 0 ] && [ "$HAS_VERDICT" = 1 ]; then
    N="$(grep -Ec '^- \[(critical|high|medium|low)\] ' "$RAW_OUT")"
    if [ "$N" -eq 0 ] && ! grep -Eq '^No material findings\.[[:space:]]*$' "$RAW_OUT"; then
        finish_fail error unknown 1
    fi
    if [ -n "$CWD" ]; then HEAD_SHA="$(git -C "$CWD" rev-parse HEAD 2>/dev/null)"; else HEAD_SHA="$(git rev-parse HEAD 2>/dev/null)"; fi
    mkdir -p "$(dirname "$OUT")"
    TMP_REPORT="$RAW_DIR/report.md"
    {
        printf -- '---\nstory: %s\nbase: %s\nhead: %s\nreviewer: codex-adversarial\nfindings: %s\n' "$KEY" "$BASE" "$HEAD_SHA" "$N"
        [ "$DEGRADED" = 1 ] && printf 'window: degraded\n'
        printf -- '---\n\n'
        cat "$RAW_OUT"
    } >"$TMP_REPORT" && mv "$TMP_REPORT" "$OUT" || {
        echo "CODEX_STATUS: error"; echo "CODEX_REASON=unknown"; echo "CODEX_EXIT=$EXIT"; echo "ERROR=cannot write $OUT"; exit 1; }
    echo "CODEX_STATUS: ok"
    echo "CODEX_EXIT=0"
    echo "CODEX_FINDINGS=$N"
    echo "REPORT_FILE=$OUT"
    echo "RAW_DIR=$RAW_DIR"
    exit 0
fi

if [ "$EXIT" -eq 124 ] && [ -n "$TO_BIN" ]; then
    finish_fail timeout timeout 2
fi

ERRS="$(error_lines)"
if printf '%s\n' "$ERRS" | grep -Eiq "hit your (usage )?limit|usage limit (reached|exceeded)|insufficient_quota|quota exceeded|429 Too Many Requests|status 429|rate_limit_exceeded"; then
    finish_fail quota quota_exhausted 2
fi
if printf '%s\n' "$ERRS" | grep -Eiq "401 Unauthorized|status 401|not logged in|codex login|not authenticated|token could not be refreshed|invalid_api_key|Incorrect API key"; then
    finish_fail auth auth_failed 2
fi
if printf '%s\n' "$ERRS" | grep -q "Codex CLI is not installed"; then
    finish_fail unavailable not_installed 2
fi
finish_fail error unknown 1
