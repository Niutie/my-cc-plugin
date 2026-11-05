#!/usr/bin/env bash
# Self-test for run_codex_review.sh (pipeline.md §1 B2.2). A fake `node` on
# PATH stands in for codex-companion: it prints the fixture stdout / stderr
# named by env vars and exits with FAKE_EXIT, so no codex or node is needed.
#
#   C1 findings → ok, CODEX_FINDINGS=2, report = frontmatter + codex stdout byte for byte
#   C2 "No material findings." → ok, CODEX_FINDINGS=0
#   C3 story text full of "rate limit / quota / unauthorized / reset" in a
#      successful review → still ok (no keyword false positive)
#   C4 codex usage-limit error → quota, exit 2, no report file left behind
#   C5 401 error → auth, exit 2
#   C6 failed turn whose raw model message mentions quota, parse error does
#      not → error, exit 1 (raw message is never scanned)
#   C7 exit 0 but no Verdict line (unparseable output) → error
#   C8 companion missing → unavailable / not_installed
#   C9 --timeout exceeded → timeout (skipped when no timeout binary)
#   C10 --cwd + --window-degraded → head is HEAD of --cwd, window: degraded line
#
# 退出码 = 失败用例数。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RCR="$SCRIPT_DIR/run_codex_review.sh"

failed=0
pass() { echo "PASS [$1]"; }
fail() { echo "FAIL [$1]: $2" >&2; failed=$((failed+1)); }

T="$(mktemp -d -t rcr_test.XXXXXX)" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo" "$T/fx"
cat > "$T/bin/node" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"
[ -n "${FAKE_OUT:-}" ] && cat "$FAKE_OUT"
[ -n "${FAKE_ERR:-}" ] && cat "$FAKE_ERR" >&2
printf '%s\n' "$@" > "${FAKE_ARGS:-/dev/null}"
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$T/bin/node"
touch "$T/companion.mjs"
(
    cd "$T/repo" || exit 1
    git init -q; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
    echo a > a; git add a; git commit -q -m seed
)
BASE="$(git -C "$T/repo" rev-parse HEAD)"

cat > "$T/fx/findings.md" <<'EOF'
# Codex Adversarial Review

Target: branch diff against abc123
Verdict: needs-attention

Two problems.

Findings:
- [high] Token bucket never refills (src/limit.py:10-20)
  The refill path is dead code.
  Recommendation: call refill() on each request.
- [low] Naming (src/limit.py:3)
  x
EOF
cat > "$T/fx/clean.md" <<'EOF'
# Codex Adversarial Review

Target: branch diff against abc123
Verdict: approve

Looks fine.

No material findings.
EOF
cat > "$T/fx/keywords.md" <<'EOF'
# Codex Adversarial Review

Target: branch diff against abc123
Verdict: needs-attention

The rate limit and quota handling for unauthorized users looks off; password reset hits your limit check.

Findings:
- [medium] 401 Unauthorized path skips the rate limit (src/auth.py:5)
  usage limit reached is reported as 429 Too Many Requests.
EOF
printf '[codex] Starting Codex review thread.\n[codex] Codex error: You'"'"'ve hit your usage limit. Try again in 2 hours.\n' > "$T/fx/quota.err"
printf 'Error: unexpected status 401 Unauthorized\n' > "$T/fx/auth.err"
cat > "$T/fx/parsefail.md" <<'EOF'
# Codex Adversarial Review

Codex did not return valid structured JSON.

- Parse error: Unexpected token R in JSON at position 0

Raw final message:

```text
Review: the quota check and rate limit are wrong; 401 Unauthorized; hit your limit.
```
EOF
printf '[codex] reasoning: thinking about rate limit and quota\n' > "$T/fx/progress.err"

run() {  # env assignments come from the caller; echoes stdout, sets RC
    OUT_TXT="$(cd "$T/repo" && TMPDIR="$T" PATH="$T/bin:$PATH" bash "$RCR" --key 9-1-foo --base "$BASE" \
        --spec _bmad-output/implementation-artifacts/spec-9-1-foo.md --companion "$T/companion.mjs" \
        --out "$T/repo/report.md" "$@")"
    RC=$?
}
first() { printf '%s\n' "$OUT_TXT" | head -1; }
val() { printf '%s\n' "$OUT_TXT" | sed -n "s/^$1=//p" | head -1; }

# C1
rm -f "$T/repo/report.md"
FAKE_OUT="$T/fx/findings.md" FAKE_ERR="$T/fx/progress.err" FAKE_EXIT=0 FAKE_ARGS="$T/args" run
body="$(awk 'n>=2 && !skip {print; next} n>=2 && skip {skip=0; next} /^---$/ {n++; if (n==2) skip=1}' "$T/repo/report.md")"
if [ "$RC" = 0 ] && [ "$(first)" = "CODEX_STATUS: ok" ] && [ "$(val CODEX_FINDINGS)" = 2 ] \
   && [ "$body" = "$(cat "$T/fx/findings.md")" ] && grep -q "^base: $BASE$" "$T/repo/report.md" \
   && grep -q '^--wait$' "$T/args" && grep -q "^$BASE$" "$T/args"; then
    pass C1
else
    fail C1 "rc=$RC out=$OUT_TXT"
fi

# C2
rm -f "$T/repo/report.md"
FAKE_OUT="$T/fx/clean.md" FAKE_EXIT=0 run
if [ "$RC" = 0 ] && [ "$(first)" = "CODEX_STATUS: ok" ] && [ "$(val CODEX_FINDINGS)" = 0 ] \
   && grep -q '^No material findings\.$' "$T/repo/report.md" && grep -q '^findings: 0$' "$T/repo/report.md"; then
    pass C2
else
    fail C2 "rc=$RC out=$OUT_TXT"
fi

# C3
rm -f "$T/repo/report.md"
FAKE_OUT="$T/fx/keywords.md" FAKE_ERR="$T/fx/progress.err" FAKE_EXIT=0 run
if [ "$RC" = 0 ] && [ "$(first)" = "CODEX_STATUS: ok" ] && [ "$(val CODEX_FINDINGS)" = 1 ]; then
    pass C3
else
    fail C3 "rc=$RC out=$OUT_TXT"
fi

# C4
rm -f "$T/repo/report.md"
FAKE_OUT=/dev/null FAKE_ERR="$T/fx/quota.err" FAKE_EXIT=1 run
if [ "$RC" = 2 ] && [ "$(first)" = "CODEX_STATUS: quota" ] && [ "$(val CODEX_REASON)" = quota_exhausted ] \
   && [ ! -e "$T/repo/report.md" ]; then
    pass C4
else
    fail C4 "rc=$RC out=$OUT_TXT"
fi

# C5
FAKE_OUT=/dev/null FAKE_ERR="$T/fx/auth.err" FAKE_EXIT=1 run
if [ "$RC" = 2 ] && [ "$(first)" = "CODEX_STATUS: auth" ] && [ "$(val CODEX_REASON)" = auth_failed ]; then
    pass C5
else
    fail C5 "rc=$RC out=$OUT_TXT"
fi

# C6
FAKE_OUT="$T/fx/parsefail.md" FAKE_ERR="$T/fx/progress.err" FAKE_EXIT=1 run
if [ "$RC" = 1 ] && [ "$(first)" = "CODEX_STATUS: error" ] && [ ! -e "$T/repo/report.md" ]; then
    pass C6
else
    fail C6 "rc=$RC out=$OUT_TXT"
fi

# C7
FAKE_OUT="$T/fx/parsefail.md" FAKE_EXIT=0 run
if [ "$RC" = 1 ] && [ "$(first)" = "CODEX_STATUS: error" ] && [ ! -e "$T/repo/report.md" ]; then
    pass C7
else
    fail C7 "rc=$RC out=$OUT_TXT"
fi

# C8
OUT_TXT="$(cd "$T/repo" && TMPDIR="$T" CLAUDE_PLUGIN_ROOT='' HOME="$T/nohome" PATH="$T/bin:$PATH" bash "$RCR" --key 9-1-foo --base "$BASE" --spec s.md --out "$T/repo/report.md")"; RC=$?
if [ "$RC" = 2 ] && [ "$(first)" = "CODEX_STATUS: unavailable" ] && [ "$(val CODEX_REASON)" = not_installed ]; then
    pass C8
else
    fail C8 "rc=$RC out=$OUT_TXT"
fi

# C9
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    FAKE_SLEEP=5 FAKE_OUT="$T/fx/clean.md" FAKE_EXIT=0 run --timeout 1
    if [ "$RC" = 2 ] && [ "$(first)" = "CODEX_STATUS: timeout" ] && [ "$(val CODEX_REASON)" = timeout ] \
       && [ ! -e "$T/repo/report.md" ]; then
        pass C9
    else
        fail C9 "rc=$RC out=$OUT_TXT"
    fi
else
    echo "SKIP [C9]: no timeout binary"
fi

# C10
(
    cd "$T/repo" || exit 1
    git worktree add -q --detach "$T/wt" HEAD >/dev/null 2>&1
    cd "$T/wt" && echo b > b && git add b && git commit -q -m other
)
WT_HEAD="$(git -C "$T/wt" rev-parse HEAD)"
FAKE_OUT="$T/fx/clean.md" FAKE_EXIT=0 FAKE_ARGS="$T/args" run --cwd "$T/wt" --window-degraded
if [ "$RC" = 0 ] && grep -q "^head: $WT_HEAD$" "$T/repo/report.md" && grep -q '^window: degraded$' "$T/repo/report.md" \
   && grep -q '^--cwd$' "$T/args"; then
    pass C10
else
    fail C10 "rc=$RC out=$OUT_TXT"
fi
git -C "$T/repo" worktree remove --force "$T/wt" >/dev/null 2>&1 || true

echo ""
echo "run_codex_review_test: failed=$failed"
exit "$failed"
