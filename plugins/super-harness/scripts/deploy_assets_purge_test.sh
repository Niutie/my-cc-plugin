#!/usr/bin/env bash
# Self-test for deploy_assets.sh manifest-based purge (review 2026-06-10 #46).
#
# Covers the DEPLOY_PURGE=1 behavior matrix + path validation:
#   T1 — fresh deploy: manifest written, counts correct
#   T2 — idempotent rerun: unchanged=N, manifest byte-identical
#   T2b— PURGE=1 with no prior manifest → purge skipped with notice
#   T3 — source shrinks + DEPLOY_PURGE=1 → stale file backed up under
#        .claude/harness/.backup/<TS>/<path> (0.3.1+; no `.bak.<TS>` next to it)
#        then removed, dropped from manifest; user-owned files untouched
#   T4 — purge failure (chmod 555 dir → rm denied; read-only .backup/ → backup
#        denied): candidate kept in manifest for retry (purge_failed=1, exit 0);
#        retry after chmod 755 purges it
#   T5 — tampered manifest entries (absolute / `..` traversal / out-of-scope /
#        symlink) are ALL refused with WARN, never deleted, and NOT written
#        back to the new manifest
#   T6 — FAILED>0: exit 2, purge skipped, manifest NOT updated
#   T7 — harness-zh migration: plugin commands/ are NOT deployed; an old
#        harness-zh manifest's .claude/commands/*.md copies are purged (with
#        backup) on the first PURGE=1 run; parallel.yaml never manifest-owned
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

mkdir -p "$PLUGIN/scripts" "$PLUGIN/conventions" "$PLUGIN/commands" "$PLUGIN/templates" "$DEST"
printf 'pipeline v1\n'   > "$PLUGIN/pipeline.md"
printf 'arch v1\n'       > "$PLUGIN/architecture.md"
printf 'arch-par v1\n'   > "$PLUGIN/architecture-parallel.md"
printf 'policy v1\n'     > "$PLUGIN/answer-policy.md"
printf 'changelog v1\n'  > "$PLUGIN/changelog.md"
printf 'tool a\n'        > "$PLUGIN/scripts/tool_a.sh"
printf 'old tool\n'      > "$PLUGIN/scripts/old_tool.sh"
printf 'conv\n'          > "$PLUGIN/conventions/conv.md"
printf 'cmd\n'           > "$PLUGIN/commands/foo.md"     # must NOT be deployed
printf 'max_slots: 2\n'  > "$PLUGIN/templates/parallel.yaml"
# 9 manifest-owned files (5 top + 2 scripts + 1 conventions + 1 templates);
# a fresh deploy also installs .claude/harness/parallel.yaml (counted in
# installed=, but never in the manifest) → installed=10.

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
       grep -qx "deploy: installed=10 unchanged=0 updated=0 purged=0"; then
    ok "T1 fresh deploy: rc=0, installed=10 (9 manifest + parallel.yaml)"
else
    bad "T1 fresh deploy: rc=$RC out='$OUT' err='$ERR'"
fi
if [ -f "$MANIFEST" ] \
   && grep -qx ".claude/harness/scripts/old_tool.sh" "$MANIFEST" \
   && grep -qx ".claude/harness/architecture.md" "$MANIFEST" \
   && grep -qx ".claude/harness/pipeline.md" "$MANIFEST" \
   && ! grep -q "commands/" "$MANIFEST" \
   && ! grep -qx ".claude/harness/parallel.yaml" "$MANIFEST" \
   && [ "$(grep -c . "$MANIFEST")" = 9 ]; then
    ok "T1 manifest written with all 9 deployed paths (no commands, no parallel.yaml)"
else
    bad "T1 manifest wrong: $(cat "$MANIFEST" 2>/dev/null)"
fi

# ============================================================================
# T2 — idempotent rerun
# ============================================================================
cp "$MANIFEST" "$WORKDIR/manifest.t1"
run_deploy 0 "$DEST"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | \
       grep -qx "deploy: installed=0 unchanged=9 updated=0 purged=0"; then
    ok "T2 idempotent rerun: unchanged=9, nothing reinstalled"
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
mkdir -p "$DEST/.claude/commands"
printf 'user-authored\n' > "$DEST/.claude/commands/user-own.md"   # never in manifest
rm "$PLUGIN/scripts/old_tool.sh"
run_deploy 1 "$DEST"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | \
       grep -qx "deploy: installed=0 unchanged=8 updated=0 purged=1"; then
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
for f in "$DEST/.claude/harness/.backup/"*/.claude/harness/scripts/old_tool.sh; do
    [ -f "$f" ] && bak_file="$f"
done
if [ -n "$bak_file" ] && grep -qx "old tool" "$bak_file" \
   && ! ls "$DEST/.claude/harness/scripts/"*.bak.* >/dev/null 2>&1; then
    ok "T3 backup written before rm (${bak_file#"$DEST"/})"
else
    bad "T3 backup missing, content wrong, or a .bak.<TS> left next to the file"
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
   && printf '%s\n' "$ERR" | grep -q "failed to remove .claude/harness/scripts/temp_tool.sh"; then
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
# backup itself denied (read-only backup root) → skip rm, keep for retry
mkdir -p "$DEST/.claude/harness/.backup"
chmod -R a-w "$DEST/.claude/harness/.backup"   # incl. a same-second <TS>/ dir
run_deploy 1 "$DEST"
chmod -R u+w "$DEST/.claude/harness/.backup"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q "purged=0 purge_failed=1" \
   && printf '%s\n' "$ERR" | grep -q "failed to back up .claude/harness/scripts/temp_tool.sh" \
   && [ -f "$DEST/.claude/harness/scripts/temp_tool.sh" ]; then
    ok "T4 backup denied: file kept, purge fails soft"
else
    bad "T4 backup denied: rc=$RC out='$OUT' err='$ERR'"
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

# ============================================================================
# T7 — migrating a harness-zh project
# ============================================================================
printf 'arch v1\n'  > "$PLUGIN/architecture.md"
printf 'conv\n'     > "$PLUGIN/conventions/conv.md"
DEST3="$WORKDIR/project3"
mkdir -p "$DEST3/.claude/harness" "$DEST3/.claude/commands"
printf 'old harness-zh run\n'  > "$DEST3/.claude/commands/run.md"
printf 'old harness-zh init\n' > "$DEST3/.claude/commands/init.md"
printf 'my own command\n'      > "$DEST3/.claude/commands/mine.md"
# 0.3.0 upgrade: test-stage assets deployed by older versions are purged too
mkdir -p "$DEST3/.claude/harness/scripts"
printf 'triggers: {}\n'  > "$DEST3/.claude/harness/test-stage-triggers.yaml"
printf 'old probe\n'     > "$DEST3/.claude/harness/scripts/check_test_harness_env.sh"
printf '%s\n' .claude/commands/init.md .claude/commands/run.md .claude/harness/architecture.md \
    .claude/harness/test-stage-triggers.yaml .claude/harness/scripts/check_test_harness_env.sh \
    > "$DEST3/.claude/harness/.deploy-manifest.txt"
run_deploy 1 "$DEST3"
if [ "$RC" = 0 ] && [ ! -f "$DEST3/.claude/harness/test-stage-triggers.yaml" ] \
   && [ ! -f "$DEST3/.claude/harness/scripts/check_test_harness_env.sh" ]; then
    ok "T7b 0.3.0 upgrade purges retired test-stage assets"
else
    bad "T7b retired test-stage assets left behind: out='$OUT'"
fi
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q "purged=4" \
   && [ ! -f "$DEST3/.claude/commands/run.md" ] && [ ! -f "$DEST3/.claude/commands/init.md" ] \
   && ls "$DEST3/.claude/harness/.backup/"*/.claude/commands/run.md >/dev/null 2>&1 \
   && ! ls "$DEST3/.claude/commands/"*.bak.* >/dev/null 2>&1; then
    ok "T7 old harness-zh command copies purged with backup"
else
    bad "T7 purge of old command copies: rc=$RC out='$OUT' err='$ERR'"
fi
if [ -f "$DEST3/.claude/commands/mine.md" ] && [ ! -f "$DEST3/.claude/commands/foo.md" ] \
   && ! grep -q "commands/" "$DEST3/.claude/harness/.deploy-manifest.txt" \
   && [ -f "$DEST3/.claude/harness/parallel.yaml" ]; then
    ok "T7 user command kept, plugin commands not deployed, parallel.yaml installed"
else
    bad "T7 post-migration state wrong: $(ls "$DEST3/.claude/commands") / $(cat "$DEST3/.claude/harness/.deploy-manifest.txt")"
fi

echo ""
echo "============================================================================"
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
