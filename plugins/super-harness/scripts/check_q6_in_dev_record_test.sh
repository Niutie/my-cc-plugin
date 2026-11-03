#!/usr/bin/env bash
# Self-test for check_q6_in_dev_record.sh Q6-block extraction:
#
#   1 — regression R3 (2026-06-10): a fenced code block (```bash) inside the
#       Q6 section contains shell comments at column 0; the old awk terminator
#       `f && /^#/` treated them as the next heading and truncated the block
#       → false-FAIL on a fully-compliant 7-bullet section. Must PASS now.
#   2 — review #52 regression guard: `- (a)`-shaped filler lines OUTSIDE the
#       Q6 section (after the next heading) must NOT count — a Q6 section with
#       only 3 real bullets stays FAIL even when the rest of the file carries
#       7+ lookalike lines.
#   3 — plain compliant section (7 bullets, no fences) still PASSes.
#   4 — missing `### Q6:` anchor still FAILs.
#
# Exit code = failed fixture count (0 = all pass).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SH="$SCRIPT_DIR/check_q6_in_dev_record.sh"

if [ ! -f "$CHECK_SH" ]; then
    echo "ERROR: check_q6_in_dev_record.sh not found at $CHECK_SH" >&2
    exit 2
fi

PASS=0
FAIL=0
WORKDIR="$(mktemp -d -t q6-check.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ============================================================================
# 1 — R3: fenced ```bash block with column-0 `#` comments inside Q6 → PASS
#     (bullets (e)-(g) live AFTER the fence; pre-fix the block was truncated
#     at the first in-fence comment, counting only 4 bullets → false-FAIL)
# ============================================================================
cat > "$WORKDIR/fence.md" <<'EOF'
# Story 9-9

## Dev Agent Record

### Q6: full-stack review

- (a) api layer checked
- (b) db layer checked
- (c) ui layer checked
- (d) auth layer checked

```bash
# verify the wiring end to end
# (these comments start at column 0 on purpose)
grep -r "handler" src/
```

- (e) infra layer checked
- (f) logging checked
- (g) docs updated

## Next Section
EOF
ex=0; out="$(bash "$CHECK_SH" "$WORKDIR/fence.md" 2>&1)" || ex=$?
if [ "$ex" = 0 ] && printf '%s\n' "$out" | grep -q "^PASS:"; then
    ok "1 fenced # comments inside Q6 don't truncate the block (7 bullets seen)"
else
    bad "1 expected PASS exit 0, got exit=$ex out=$out"
fi

# ============================================================================
# 2 — #52: filler `- (a)` lines after the next heading must NOT count
# ============================================================================
cat > "$WORKDIR/filler.md" <<'EOF'
# Story 9-9

### Q6: full-stack review

- (a) api layer checked
- (b) db layer checked
- (c) ui layer checked

## Standard checklists

- (a) lookalike filler
- (b) lookalike filler
- (c) lookalike filler
- (d) lookalike filler
- (e) lookalike filler
- (f) lookalike filler
- (g) lookalike filler
EOF
ex=0; out="$(bash "$CHECK_SH" "$WORKDIR/filler.md" 2>&1)" || ex=$?
if [ "$ex" = 1 ] && printf '%s\n' "$out" | grep -q "sub-bullet 行数 = 3"; then
    ok "2 out-of-section filler still FAILs (counted 3, not 10)"
else
    bad "2 expected FAIL exit 1 with count=3, got exit=$ex out=$out"
fi

# ============================================================================
# 3 — plain compliant section (no fences) still PASSes
# ============================================================================
cat > "$WORKDIR/plain.md" <<'EOF'
### Q6: full-stack review

- (a) one
- (b) two
- (c) three
- (d) four
- (e) five
- (f) six
- (g) seven

## After
EOF
ex=0; out="$(bash "$CHECK_SH" "$WORKDIR/plain.md" 2>&1)" || ex=$?
if [ "$ex" = 0 ] && printf '%s\n' "$out" | grep -q "^PASS:"; then
    ok "3 plain 7-bullet section PASSes"
else
    bad "3 expected PASS exit 0, got exit=$ex out=$out"
fi

# ============================================================================
# 4 — missing anchor still FAILs
# ============================================================================
cat > "$WORKDIR/noanchor.md" <<'EOF'
# Story 9-9

## Dev Agent Record

- (a) bullets without a Q6 heading
EOF
ex=0; out="$(bash "$CHECK_SH" "$WORKDIR/noanchor.md" 2>&1)" || ex=$?
if [ "$ex" = 1 ] && printf '%s\n' "$out" | grep -q "Q6"; then
    ok "4 missing ### Q6: anchor FAILs"
else
    bad "4 expected FAIL exit 1, got exit=$ex out=$out"
fi

echo ""
echo "============================================================================"
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
