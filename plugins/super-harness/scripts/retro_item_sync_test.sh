#!/usr/bin/env bash
# retro_item_sync_test.sh — sprint-status.py retro-item-done / action-sync（issue #23）
#
# harness 的 retro_action_items 和 BMad 6.12 原生 action_items 是两本账。以前只有
# pipeline.md 兑现循环会同时翻两边，手工兑现和 harness 类行动项只翻了 harness 账。
# 这里验证：retro-item-done 两本账一起翻（嵌套写法、旧标量写法都认）；action-sync
# 列出不一致、--fix 补齐；上游脚本不可用时退回只改那一行 status。
#
# 用法：bash retro_item_sync_test.sh

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q .
mkdir -p .claude/harness/scripts _bmad-output/implementation-artifacts
cp "$HERE"/*.py .claude/harness/scripts/
printf "artifacts_root: '_bmad-output/implementation-artifacts'\n" > .claude/harness/harness-project-config.yaml
SS="_bmad-output/implementation-artifacts/sprint-status.yaml"
cat > "$SS" <<'EOF'
development_status:
  1-1-a: done
  epic-1-retrospective: done
retro_action_items:
  epic-1-retro:
    B1:
      status: done   # 单独提交 mark done，原生账没跟着翻
      category: harness
    B2:
      status: pending
      category: dev
      chore_spec: 'chore-retro-c1-b2-x.md'
  epic-2-retro:
    A1: done   # 旧标量写法
    A2:
      status: pending
      category: harness
action_items:
  - id: epic-1-retro-B1
    action: "b1"
    status: open
  - id: epic-1-retro-B2
    action: "b2"
    status: open
  - id: epic-2-retro-A1
    action: "a1"
    status: "open"
  - id: epic-2-retro-A2
    action: "a2"
    status: done
EOF
S="python3 .claude/harness/scripts/sprint-status.py"
export HARNESS_NO_UPSTREAM=1   # no uv / BMad skill here: exercise the one-line fallback

echo "== action-sync (check)"
OUT="$($S action-sync)"; RC=$?
[ $RC -eq 3 ] && echo "$OUT" | grep -qx 'MISMATCH=epic-1-retro-B1 harness=done native=open' \
    && echo "$OUT" | grep -qx 'MISMATCH=epic-2-retro-A1 harness=done native=open' \
    && echo "$OUT" | grep -qx 'MISMATCH_COUNT=2' && echo "$OUT" | grep -qx 'NATIVE_AHEAD=epic-2-retro-A2' \
    && ok "R1 lists harness-done / native-open items, both item forms; native-ahead reported only" || { bad "R1 rc=$RC"; echo "$OUT"; }

echo "== retro-item-done"
OUT="$($S retro-item-done 1 B2)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qx 'NATIVE_VIA=fallback' && echo "$OUT" | grep -qx 'NATIVE=done' \
    && echo "$OUT" | grep -qx 'HARNESS=pending->done' \
    && grep -A1 '    B2:' "$SS" | grep -q 'status: done' \
    && grep -A2 'id: epic-1-retro-B2' "$SS" | grep -q 'status: done' \
    && grep -q "chore_spec: 'chore-retro-c1-b2-x.md'" "$SS" \
    && ok "R2 flips both ledgers, leaves the other fields alone" || { bad "R2 rc=$RC"; echo "$OUT"; cat "$SS"; }
OUT="$($S retro-item-done 1 B2)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qx 'NATIVE=already-done' && echo "$OUT" | grep -qx 'HARNESS=done->done' \
    && ok "R3 idempotent" || { bad "R3 rc=$RC"; echo "$OUT"; }
OUT="$($S retro-item-done 1 Z9 2>&1)"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -q 'epic-1-retro.Z9' && ok "R4 unknown item → exit 1" || { bad "R4 rc=$RC"; echo "$OUT"; }

echo "== action-sync --fix"
OUT="$($S action-sync --fix)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qx 'FIXED=epic-1-retro-B1 via=fallback' && echo "$OUT" | grep -qx 'FIXED=epic-2-retro-A1 via=fallback' \
    && grep -A2 'id: epic-2-retro-A1' "$SS" | grep -q 'status: "done"' \
    && ok "R5 --fix flips the native items (quoting kept)" || { bad "R5 rc=$RC"; echo "$OUT"; cat "$SS"; }
OUT="$($S action-sync)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qx 'MISMATCH_COUNT=0' && ok "R6 ledgers agree afterwards" || { bad "R6 rc=$RC"; echo "$OUT"; }
grep -q '      status: done   # 单独提交 mark done，原生账没跟着翻' "$SS" && grep -q '    A1: done   # 旧标量写法' "$SS" \
    && ok "R7 comments and the scalar form are kept" || { bad "R7"; cat "$SS"; }

echo "== upstream failure leaves the harness ledger alone"
mkdir -p .claude/skills/bmad-retrospective/scripts bin
printf '#!/bin/sh\necho "{\\"ok\\": false, \\"error\\": \\"refused\\"}"\nexit 1\n' > bin/uv
chmod +x bin/uv
touch .claude/skills/bmad-retrospective/scripts/sprint_status.py
python3 - "$SS" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = t.replace("    A2:\n      status: pending", "    A2:\n      status: pending\n    A3:\n      status: pending", 1)
t += "  - id: epic-2-retro-A3\n    action: \"a3\"\n    status: open\n"
open(p, "w", encoding="utf-8").write(t)
PY
OUT="$(env -u HARNESS_NO_UPSTREAM PATH="$TMP/bin:$PATH" $S retro-item-done 2 A3 2>&1)"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -qx 'NATIVE_VIA=upstream' && echo "$OUT" | grep -qx 'NATIVE=failed' \
    && grep -A1 '    A3:' "$SS" | grep -q 'status: pending' \
    && ok "R8 upstream refusal → exit 1, harness ledger untouched" || { bad "R8 rc=$RC"; echo "$OUT"; }

echo
echo "retro_item_sync_test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
