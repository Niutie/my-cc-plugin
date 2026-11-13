#!/usr/bin/env bash
# ledger_merge_test.sh — issue #30：合流 rebase 时 deferred-work.md 按 FU 合并，
# rebase 之后逐条比对 FU。
#
# 回放 issue 里 8.5 / 8.7 的形状：
#   台账末尾一条 FU-A（FU-8.4.B7）；
#   分支 X（先合入）在末尾追加一节 FU-B（FU-8.7.B3）；
#   分支 Y 给 FU-A 加一条历史行、翻 resolved；
#   Y rebase 到 X 上。
# 覆盖：
#   M1-M3  冲突按 FU 消解：历史行留在 FU-A，FU-B 不变，FU 以外的行都在
#   M4     0.5.2 的行级 union 结果会被逐条比对查出来（FU-A、FU-B）
#   M5     两边都改同一条 FU：合并结果两边的行都在，比对通过
#   M6     账本里有重复的 FU id：退回整份 union
#   H1-H4  _check_ledger：对不上就 held（hold_kind=ledger，列出 FU），
#          lane 有新提交后重跑不再比对；对得上则放行
set -u
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q -b sprint repo
cd repo
git config user.email t@example.com
git config user.name Tester
git config commit.gpgsign false
ART=_bmad-output/implementation-artifacts
mkdir -p "$ART"
DW="$ART/deferred-work.md"
cat > "$DW" <<'EOF'
# Deferred Work — Fixture

---

## Deferred from: build-auto review of 8.4 (2026-11-01)

- **FU-8.4.B6** `[status:pending]` `[bucket:other]` `[target:Epic 8]` `[source:build-auto-of-8.4]` — six
  - **关联**：spec-8-4.md

- **FU-8.4.B7** `[status:pending]` `[bucket:other]` `[target:Epic 8]` `[source:build-auto-of-8.4]` — seven
  - **关联**：spec-8-4.md
EOF
git add -A; git commit -qm base
BASE="$(git rev-parse HEAD)"

git checkout -qb story/8-5
python3 - "$DW" <<'PY'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t = t.replace("**FU-8.4.B7** `[status:pending]`", "**FU-8.4.B7** `[status:resolved]`")
t += "  - **历史**：\n    - 2026-11-05 `pending → resolved` by Story 8.5 — spool flush covers it\n"
open(p, "w", encoding="utf-8").write(t)
PY
git commit -qam "feat(8-5): implement"
LANE="$(git rev-parse HEAD)"

git checkout -q sprint
cat >> "$DW" <<'EOF'

---

## Deferred from: build-auto review of 8.7 (2026-11-06)

- **FU-8.7.B3** `[status:pending]` `[bucket:other]` `[target:Epic 8]` `[source:build-auto-of-8.7]` — b3
  - **关联**：spec-8-7.md
EOF
git commit -qam "feat(8-7): implement"
SPRINT="$(git rev-parse HEAD)"

# helpers: import superh from the plugin source tree
PY() { python3 - "$SCRIPTS" "$@"; }

echo "== M: per-FU conflict resolution"
git checkout -q story/8-5
git -c core.hooksPath=/dev/null rebase "$SPRINT" >/dev/null 2>&1
PY "$TMP/repo" "$ART" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import superh
from pathlib import Path
resolved, remaining = superh._auto_resolve(None, Path(sys.argv[2]), sys.argv[3])
print("RESOLVED=" + "|".join(resolved)); print("REMAINING=" + "|".join(remaining))
PY
GIT_EDITOR=true git -c core.hooksPath=/dev/null rebase --continue >/dev/null 2>&1
RES="$(git rev-parse HEAD)"
blk() {  # blk <file> <FU id> — that FU's block
    python3 - "$SCRIPTS" "$1" "$2" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import superh
b, _ = superh._fu_blocks(open(sys.argv[2], encoding="utf-8").read())
print("\n".join(b.get(sys.argv[3], ())))
PY
}
blk "$DW" FU-8.4.B7 | grep -q 'by Story 8.5' && blk "$DW" FU-8.4.B7 | grep -q 'status:resolved' \
    && ok "M1 history line stays under FU-8.4.B7" || { bad "M1"; cat "$DW"; }
[ "$(blk "$DW" FU-8.7.B3)" = "$(git show "$SPRINT:$DW" > "$TMP/s.md"; blk "$TMP/s.md" FU-8.7.B3)" ] \
    && ok "M2 FU-8.7.B3 unchanged" || { bad "M2"; cat "$DW"; }
grep -q '^## Deferred from: build-auto review of 8.7' "$DW" && [ "$(grep -c '^- \*\*FU-' "$DW")" = 3 ] \
    && [ "$(grep -c 'by Story 8.5' "$DW")" = 1 ] && ok "M3 sections and FU heads all kept, nothing doubled" || { bad "M3"; cat "$DW"; }

mm() {  # mm <base> <lane> <sprint> <result-file-or-rev> — mismatched FU ids
    python3 - "$SCRIPTS" "$@" <<'PY'
import sys, subprocess
sys.path.insert(0, sys.argv[1])
import superh
def blob(x):
    if x.startswith("@"):
        return open(x[1:], "rb").read()
    r = subprocess.run(["git", "show", x], capture_output=True)
    return r.stdout
print(" ".join(superh._ledger_mismatches(*(blob(x) for x in sys.argv[2:6]))))
PY
}
[ -z "$(mm "$BASE:$DW" "$LANE:$DW" "$SPRINT:$DW" "$RES:$DW")" ] && ok "M3b per-FU check passes on the merged ledger" \
    || bad "M3b $(mm "$BASE:$DW" "$LANE:$DW" "$SPRINT:$DW" "$RES:$DW")"

# what 0.5.2 produced: a plain line union of the conflicting hunk
git show "$BASE:$DW" > "$TMP/b"; git show "$SPRINT:$DW" > "$TMP/o"; git show "$LANE:$DW" > "$TMP/t"
git merge-file -p --union "$TMP/o" "$TMP/b" "$TMP/t" > "$TMP/old-union.md"
[ "$(mm "$BASE:$DW" "$LANE:$DW" "$SPRINT:$DW" "@$TMP/old-union.md")" = "FU-8.4.B7 FU-8.7.B3" ] \
    && ok "M4 per-FU check catches the line-union misplacement" || { bad "M4 $(mm "$BASE:$DW" "$LANE:$DW" "$SPRINT:$DW" "@$TMP/old-union.md")"; cat "$TMP/old-union.md"; }

# both sides add a history line to the same FU
python3 - "$TMP/b" "$TMP/o2" "$TMP/t2" <<'PY'
import sys
b = open(sys.argv[1], encoding="utf-8").read()
o = b + "  - **历史**：\n    - 2026-11-06 `target: Epic 8 → Story 8.9` by epic-8-retro — moved\n"
t = b.replace("**FU-8.4.B7** `[status:pending]`", "**FU-8.4.B7** `[status:resolved]`") \
    + "  - **历史**：\n    - 2026-11-05 `pending → resolved` by Story 8.5 — done\n"
open(sys.argv[2], "w", encoding="utf-8").write(o); open(sys.argv[3], "w", encoding="utf-8").write(t)
PY
python3 - "$SCRIPTS" "$TMP/b" "$TMP/o2" "$TMP/t2" "$TMP/m2" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import superh
b, o, t = (open(p, "rb").read() for p in sys.argv[2:5])
m, how = superh._merge_ledger(b, o, t)
open(sys.argv[5], "wb").write(m)
print(how)
PY
blk "$TMP/m2" FU-8.4.B7 | grep -q 'by Story 8.5' && blk "$TMP/m2" FU-8.4.B7 | grep -q 'by epic-8-retro' \
    && [ -z "$(mm "@$TMP/b" "@$TMP/t2" "@$TMP/o2" "@$TMP/m2")" ] \
    && ok "M5 both sides changed one FU: both lines kept, check passes" || { bad "M5"; cat "$TMP/m2"; }

printf -- '- **FU-8.4.B6** `[status:pending]` `[bucket:other]` `[target:Epic 8]` `[source:x]` — dup\n' >> "$TMP/b"
cp "$TMP/b" "$TMP/o3"; printf -- '- **FU-9.1.B1** `[status:pending]` `[bucket:other]` `[target:Epic 9]` `[source:y]` — o\n' >> "$TMP/o3"
cp "$TMP/b" "$TMP/t3"; printf -- '- **FU-9.2.B1** `[status:pending]` `[bucket:other]` `[target:Epic 9]` `[source:z]` — t\n' >> "$TMP/t3"
HOW="$(python3 - "$SCRIPTS" "$TMP/b" "$TMP/o3" "$TMP/t3" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import superh
m, how = superh._merge_ledger(*(open(p, "rb").read() for p in sys.argv[2:5]))
print(how, b"FU-9.1.B1" in m and b"FU-9.2.B1" in m)
PY
)"
[ "$HOW" = "union True" ] && ok "M6 duplicate FU ids fall back to a plain union" || bad "M6 $HOW"

echo "== H: _check_ledger after the rebase"
# a lane whose rebased head carries the misplaced (0.5.2) ledger
git checkout -q -b story/bad "$SPRINT"
cp "$TMP/old-union.md" "$DW"; git commit -qam "feat(8-5): implement (rebased by 0.5.2)"
BADHEAD="$(git rev-parse HEAD)"
git checkout -q sprint
chk() {  # chk <branch> <lane json in/out>
    python3 - "$SCRIPTS" "$TMP/repo" "$ART" "$1" "$2" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1])
import superh
from pathlib import Path
root, art, branch, lf = Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
class Ctx:
    def __init__(self): self.root = root
    def artifacts_rel(self): return art
    def save_lane(self, lane): json.dump(lane, open(lf, "w"))
lane = json.load(open(lf))
lane["branch"] = branch
try:
    superh._check_ledger(Ctx(), lane, root)
    print("PASSED")
except SystemExit as e:
    print(f"EXIT={e.code}")
json.dump(lane, open(lf, "w"))
PY
}
printf '{"key":"8-5","rebased":true,"rebase_from":"%s","onto":"%s"}' "$LANE" "$SPRINT" > "$TMP/lane.json"
OUT="$(chk story/bad "$TMP/lane.json")"
echo "$OUT" | grep -qx 'HOLD_KIND=ledger' && echo "$OUT" | grep -qx 'LEDGER_FU=FU-8.4.B7' \
    && echo "$OUT" | grep -qx 'LEDGER_FU=FU-8.7.B3' && echo "$OUT" | grep -qx 'EXIT=1' \
    && [ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["phase"], d["hold_kind"], d["ledger_hold_head"])' "$TMP/lane.json")" = "held ledger $BADHEAD" ] \
    && ok "H1 misplaced history → held (ledger), FU ids listed" || { bad "H1"; echo "$OUT"; cat "$TMP/lane.json"; }
OUT="$(chk story/bad "$TMP/lane.json")"
echo "$OUT" | grep -qx 'HOLD_KIND=ledger' && ok "H2 re-run with nothing changed holds again" || { bad "H2"; echo "$OUT"; }
git checkout -q story/bad; git show "$RES:$DW" > "$DW"; git commit -qam "fix(8-5): move history back"; git checkout -q sprint
OUT="$(chk story/bad "$TMP/lane.json")"
echo "$OUT" | grep -qx 'PASSED' && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "ledger_hold_head" not in d; assert any("ledger check skipped" in n for n in d["notes"])' "$TMP/lane.json" \
    && ok "H3 after the person's fix commit the check is skipped" || { bad "H3"; echo "$OUT"; cat "$TMP/lane.json"; }
printf '{"key":"8-5","rebased":true,"rebase_from":"%s","onto":"%s"}' "$LANE" "$SPRINT" > "$TMP/lane.json"
OUT="$(chk story/8-5 "$TMP/lane.json")"
echo "$OUT" | grep -qx 'PASSED' && ok "H4 correctly merged lane passes" || { bad "H4"; echo "$OUT"; }

echo
echo "ledger_merge_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
