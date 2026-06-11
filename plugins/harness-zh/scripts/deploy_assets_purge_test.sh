#!/usr/bin/env bash
# Self-test for deploy_assets.sh manifest-based purge (review 2026-06-10 #46).
#
# Covers the DEPLOY_PURGE=1 behavior matrix + path validation:
#   T1 — fresh deploy: manifest written, counts correct
#   T2 — idempotent rerun: unchanged=N, manifest byte-identical
#   T2b— PURGE=1 with no prior manifest → purge skipped with notice
#   T3 — source shrinks + DEPLOY_PURGE=1 → stale file backed up (.bak.<TS>)
#        then removed, dropped from manifest; user-owned files untouched
#   T4 — purge failure (chmod 555 dir): candidate kept in manifest for retry
#        (purge_failed=1, exit 0); retry after chmod 755 purges it
#   T5 — tampered manifest entries (absolute / `..` traversal / out-of-scope /
#        symlink) are ALL refused with WARN, never deleted, and NOT written
#        back to the new manifest
#   T6 — FAILED>0: exit 2, purge skipped, manifest NOT updated
#
# Sandbox: fake PLUGIN_ROOT + DEST project under mktemp; nothing touches the
# real plugin or repo. Exit code = FAIL count.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/deploy_assets.sh"

if [ ! -f "$DEPLOY" ]; then
    echo "ERROR: deploy_assets.sh not found at $DEPLOY" >&2
    exit 2
fi

PASS=0
FAIL=0
WORKDIR="$(mktemp -d -t deploy-purge.XXXXXX)"
# T4 leaves a chmod 555 dir if an assertion dies mid-way — restore perms first
# so the trap's rm -rf can always clean up.
trap 'chmod -R u+w "$WORKDIR" 2>/dev/null; rm -rf "$WORKDIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

PLUGIN="$WORKDIR/fake-plugin"
DEST="$WORKDIR/project"
MANIFEST="$DEST/.claude/harness/.deploy-manifest.txt"

mkdir -p "$PLUGIN/scripts" "$PLUGIN/conventions" "$PLUGIN/commands" "$DEST"
printf 'arch v1\n'       > "$PLUGIN/architecture.md"
printf 'policy v1\n'     > "$PLUGIN/answer-policy.md"
printf 'changelog v1\n'  > "$PLUGIN/changelog.md"
printf 'triggers: {}\n'  > "$PLUGIN/test-stage-triggers.yaml"
printf 'tool a\n'        > "$PLUGIN/scripts/tool_a.sh"
printf 'old tool\n'      > "$PLUGIN/scripts/old_tool.sh"
printf 'conv\n'          > "$PLUGIN/conventions/conv.md"
printf 'cmd\n'           > "$PLUGIN/commands/foo.md"
# 8 deployable files total (4 top + 2 scripts + 1 conventions + 1 commands)

# run_deploy <purge:0|1> <dest> → fills $OUT (stdout) / $ERR (stderr) / $RC
run_deploy() {
    local purge="$1" dest="$2"
    local out_f="$WORKDIR/out.$$" err_f="$WORKDIR/err.$$"
    RC=0
    if [ "$purge" = "1" ]; then
        DEPLOY_PURGE=1 bash "$DEPLOY" "$PLUGIN" "$dest" >"$out_f" 2>"$err_f" || RC=$?
    else
        bash "$DEPLOY" "$PLUGIN" "$dest" >"$out_f" 2>"$err_f" || RC=$?
    fi
    OUT="$(cat "$out_f")"
    ERR="$(cat "$err_f")"
    rm -f "$out_f" "$err_f"
}

# ============================================================================
# T1 — fresh deploy
# ============================================================================
run_deploy 0 "$DEST"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | \
       grep -qx "deploy: installed=8 unchanged=0 updated=0 purged=0"; then
    ok "T1 fresh deploy: rc=0, installed=8"
else
    bad "T1 fresh deploy: rc=$RC out='$OUT' err='$ERR'"
fi
if [ -f "$MANIFEST" ] \
   && grep -qx ".claude/harness/scripts/old_tool.sh" "$MANIFEST" \
   && grep -qx ".claude/harness/architecture.md" "$MANIFEST" \
   && grep -qx ".claude/commands/foo.md" "$MANIFEST" \
   && [ "$(grep -c . "$MANIFEST")" = 8 ]; then
    ok "T1 manifest written with all 8 deployed paths"
else
    bad "T1 manifest wrong: $(cat "$MANIFEST" 2>/dev/null)"
fi

# ============================================================================
# T2 — idempotent rerun
# ============================================================================
cp "$MANIFEST" "$WORKDIR/manifest.t1"
run_deploy 0 "$DEST"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | \
       grep -qx "deploy: installed=0 unchanged=8 updated=0 purged=0"; then
    ok "T2 idempotent rerun: unchanged=8, nothing reinstalled"
else
    bad "T2 rerun: rc=$RC out='$OUT'"
fi
if cmp -s "$MANIFEST" "$WORKDIR/manifest.t1"; then
    ok "T2 manifest byte-identical after rerun"
else
    bad "T2 manifest drifted on idempotent rerun"
fi

# ============================================================================
# T2b — PURGE=1 but no prior manifest → skip with notice
# ============================================================================
DEST2="$WORKDIR/project2"
mkdir -p "$DEST2"
run_deploy 1 "$DEST2"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q "purged=0" \
   && printf '%s\n' "$ERR" | grep -q "purge: SKIPPED (no prior manifest"; then
    ok "T2b no-prior-manifest: purge skipped with notice, manifest seeded"
else
    bad "T2b: rc=$RC out='$OUT' err='$ERR'"
fi

# ============================================================================
# T3 — source shrinks → purge with backup; user-owned files untouched
# ============================================================================
printf 'user-authored\n' > "$DEST/.claude/commands/user-own.md"   # never in manifest
rm "$PLUGIN/scripts/old_tool.sh"
run_deploy 1 "$DEST"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | \
       grep -qx "deploy: installed=0 unchanged=7 updated=0 purged=1"; then
    ok "T3 purge run: purged=1"
else
    bad "T3 purge run: rc=$RC out='$OUT' err='$ERR'"
fi
if [ ! -f "$DEST/.claude/harness/scripts/old_tool.sh" ]; then
    ok "T3 stale file removed from dest"
else
    bad "T3 stale file still present"
fi
bak_file=""
for f in "$DEST/.claude/harness/scripts/old_tool.sh.bak."*; do
    [ -f "$f" ] && bak_file="$f"
done
if [ -n "$bak_file" ] && grep -qx "old tool" "$bak_file"; then
    ok "T3 backup written before rm ($(basename "$bak_file"))"
else
    bad "T3 backup missing or content wrong"
fi
if ! grep -qx ".claude/harness/scripts/old_tool.sh" "$MANIFEST" \
   && grep -qx ".claude/harness/scripts/tool_a.sh" "$MANIFEST"; then
    ok "T3 manifest shrank to surviving files"
else
    bad "T3 manifest still lists purged file: $(cat "$MANIFEST")"
fi
if [ -f "$DEST/.claude/commands/user-own.md" ] && [ -f "$DEST/.claude/harness/scripts/tool_a.sh" ]; then
    ok "T3 user-owned + surviving plugin files untouched"
else
    bad "T3 purge overreached into non-candidate files"
fi

# ============================================================================
# T4 — purge failure (chmod 555): candidate kept in manifest for retry
# ============================================================================
printf 'temp tool\n' > "$PLUGIN/scripts/temp_tool.sh"
run_deploy 0 "$DEST"     # install it + record in manifest
rm "$PLUGIN/scripts/temp_tool.sh"
chmod 555 "$DEST/.claude/harness/scripts"
run_deploy 1 "$DEST"
chmod 755 "$DEST/.claude/harness/scripts"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q "purged=0 purge_failed=1" \
   && printf '%s\n' "$ERR" | grep -q "failed to back up .claude/harness/scripts/temp_tool.sh"; then
    ok "T4 read-only dir: purge fails soft (purge_failed=1, exit 0)"
else
    bad "T4 failing purge: rc=$RC out='$OUT' err='$ERR'"
fi
if [ -f "$DEST/.claude/harness/scripts/temp_tool.sh" ] \
   && grep -qx ".claude/harness/scripts/temp_tool.sh" "$MANIFEST"; then
    ok "T4 candidate survives + written back to manifest for retry"
else
    bad "T4 candidate lost from manifest (forever-skip orphan): $(cat "$MANIFEST")"
fi
run_deploy 1 "$DEST"     # retry now that the dir is writable again
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q "purged=1" \
   && [ ! -f "$DEST/.claude/harness/scripts/temp_tool.sh" ] \
   && ! grep -qx ".claude/harness/scripts/temp_tool.sh" "$MANIFEST"; then
    ok "T4 retry succeeds: purged + dropped from manifest"
else
    bad "T4 retry: rc=$RC out='$OUT' manifest=$(cat "$MANIFEST")"
fi

# ============================================================================
# T5 — tampered manifest entries are refused (absolute / .. / scope / symlink)
# ============================================================================
printf 'victim\n' > "$WORKDIR/victim.txt"
printf 'outside\n' > "$DEST/outside-file.txt"
ln -s "$WORKDIR/victim.txt" "$DEST/.claude/harness/evil-link.md"
{
    echo "/etc/passwd"
    echo ".claude/harness/../outside-file.txt"
    echo "outside-file.txt"
    echo ".claude/harness/evil-link.md"
} >> "$MANIFEST"
run_deploy 1 "$DEST"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q "purged=0 purge_failed=4"; then
    ok "T5 all 4 tampered entries refused (purged=0 purge_failed=4)"
else
    bad "T5: rc=$RC out='$OUT' err='$ERR'"
fi
for want in \
    "refusing absolute path in manifest (skipped): /etc/passwd" \
    "refusing path with '..' traversal (skipped): .claude/harness/../outside-file.txt" \
    "refusing out-of-scope path (skipped): outside-file.txt" \
    "refusing symlink (skipped): .claude/harness/evil-link.md"
do
    if printf '%s\n' "$ERR" | grep -qF -- "$want"; then
        ok "T5 WARN: $want"
    else
        bad "T5 missing WARN '$want' in: $ERR"
    fi
done
if [ -f "$WORKDIR/victim.txt" ] && [ -L "$DEST/.claude/harness/evil-link.md" ] \
   && [ -f "$DEST/outside-file.txt" ]; then
    ok "T5 symlink target + out-of-scope file untouched"
else
    bad "T5 something was deleted that must not be"
fi
# Rejected entries are suspected tampering — must NOT be written back (unlike
# T4's transient-failure retry path). Paired positive: legit entry still there.
if ! grep -q "passwd\|outside-file\|evil-link" "$MANIFEST" \
   && grep -qx ".claude/harness/architecture.md" "$MANIFEST"; then
    ok "T5 tampered entries not written back to manifest"
else
    bad "T5 manifest retains tampered entries: $(cat "$MANIFEST")"
fi
rm -f "$DEST/.claude/harness/evil-link.md" "$DEST/outside-file.txt"

# ============================================================================
# T6 — FAILED>0: exit 2, purge skipped, manifest preserved
# ============================================================================
cp "$MANIFEST" "$WORKDIR/manifest.t6"
rm "$PLUGIN/architecture.md"          # required top file → FAILED=1
rm "$PLUGIN/conventions/conv.md"      # would-be purge candidate
run_deploy 1 "$DEST"
if [ "$RC" = 2 ] && printf '%s\n' "$OUT" | grep -q "FAILED=1" \
   && printf '%s\n' "$ERR" | grep -q "purge: SKIPPED (deploy had failures"; then
    ok "T6 FAILED>0: exit 2 + purge skipped"
else
    bad "T6: rc=$RC out='$OUT' err='$ERR'"
fi
if cmp -s "$MANIFEST" "$WORKDIR/manifest.t6" \
   && [ -f "$DEST/.claude/harness/conventions/conv.md" ]; then
    ok "T6 manifest preserved + no purge happened on broken deploy"
else
    bad "T6 manifest/file mutated during failed deploy"
fi

echo ""
echo "============================================================================"
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
