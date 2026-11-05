#!/usr/bin/env bash
# Chore C10 — process_retro_residue.sh self-test
#
# fixture：
#   (a) 首次：6 项 pending → exit 0；stdout 只有 5 行摘要（PROMPT_FILE /
#       PENDING_COUNT / PENDING_CODES / ARTIFACT_DIR）；PROMPT_FILE 在 TMPDIR 下，
#       内容含 prompt 模板 + 6 项待 process 列表
#   (b) 幂等：上一轮已写 chore_spec 字段全 → no residue + exit 2，不留临时文件
#   (c) 增量：5 项已 process / 1 项新增 pending → prompt 文件仅列 1 项 + exit 0
#   (d) alphanumeric-dash code
#   (e) --stdout：整段 prompt 直出 stdout，不建临时文件
#
# 用 mktemp 临时 yaml + retro md fixture；TMPDIR 指到 fixture 目录内，prompt
# 临时文件随 fixture 一起清理。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTRY="${SCRIPT_DIR}/process_retro_residue.sh"

if [[ ! -x "$ENTRY" ]]; then
    echo "ERROR: $ENTRY not executable" >&2
    exit 1
fi

# 颜色
GREEN=$'\033[32m'
RED=$'\033[31m'
RESET=$'\033[0m'

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# 工具：mktemp 一对 yaml + retro md fixture
# ---------------------------------------------------------------------------
make_fixture() {
    local fixture_dir
    fixture_dir=$(mktemp -d)
    echo "$fixture_dir"
}

cleanup() {
    local d="$1"
    if [[ -n "$d" && -d "$d" ]]; then
        rm -rf "$d"
    fi
}

# 从摘要 stdout 取某个 KEY=value 的 value
summary_field() {  # $1 = summary text, $2 = key
    sed -n "s/^$2=//p" <<< "$1" | head -n 1
}

# 摘要里 PROMPT_FILE 指向的文件内容（不存在时输出空）
prompt_of() {  # $1 = summary text
    local pf
    pf="$(summary_field "$1" PROMPT_FILE)"
    if [[ -n "$pf" && -f "$pf" ]]; then
        cat "$pf"
    fi
}

# ---------------------------------------------------------------------------
# Fixture (a) — 首次：6 项 pending
# ---------------------------------------------------------------------------
echo ""
echo "=== Fixture (a) — 首次：epic-7-retro 6 项 pending（无 chore_spec 字段） ==="
FX_A=$(make_fixture)
mkdir -p "${FX_A}/_bmad-output/implementation-artifacts"
ART_A="${FX_A}/_bmad-output/implementation-artifacts"

cat > "${ART_A}/sprint-status.yaml" <<'YAML'
development_status:
  epic-7: backlog

retro_action_items:
  epic-7-retro:
    Z1: pending
    Z2: partial
    Z3: pending
    Z4: in-progress
    Z5: pending
    Z6: pending
    Z7: done
    Z8: deferred
YAML

cat > "${ART_A}/epic-7-retro-2026-05-03.md" <<'MD'
# Epic 7 Retrospective

## 6. Action Items

### Z1 — fake item 1
Action: do something
### Z2 — fake item 2
Action: partial work to upgrade
### Z3 — fake item 3
### Z4 — fake item 4
### Z5 — fake item 5
### Z6 — fake item 6
### Z7 — fake done item
### Z8 — fake deferred item
MD

mkdir -p "${FX_A}/tmp"
if sum_a=$(TMPDIR="${FX_A}/tmp" "$ENTRY" --epic 7 \
    --sprint-status "${ART_A}/sprint-status.yaml" \
    --retro-md "${ART_A}/epic-7-retro-2026-05-03.md" \
    --artifact-dir "$ART_A" 2>/dev/null); then
    rc_a=$?
else
    rc_a=$?
fi
out_a="$(prompt_of "$sum_a")"
pf_a="$(summary_field "$sum_a" PROMPT_FILE)"
art_abs_a="$(cd "$ART_A" && pwd)"

# 摘要契约：stdout 恰好 5 行、远小于 prompt；PROMPT_FILE 落在 TMPDIR 下（仓库外）
if [[ $rc_a -eq 0 ]] && \
   [[ "$(wc -l <<< "$sum_a" | tr -d ' ')" -eq 5 ]] && \
   [[ ${#sum_a} -lt 1024 ]] && \
   [[ "$pf_a" == "${FX_A}/tmp/retro-residue-epic7."* ]] && \
   [[ -s "$pf_a" ]] && \
   [[ "$(summary_field "$sum_a" PENDING_COUNT)" = 6 ]] && \
   [[ "$(summary_field "$sum_a" PENDING_CODES)" = "Z1 Z2 Z3 Z4 Z5 Z6" ]] && \
   [[ "$(summary_field "$sum_a" ARTIFACT_DIR)" = "$art_abs_a" ]] && \
   ! grep -q "=== FILE:" <<< "$out_a" && \
   ! grep -q "=== END FILE" <<< "$out_a" && \
   grep -qF "${art_abs_a}/chore-retro-c7-<code>-<slug>.md" <<< "$out_a"; then
    echo "${GREEN}PASS${RESET}: Fixture (a) — stdout 仅 5 行摘要 + PROMPT_FILE 在 TMPDIR + 字段正确"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: Fixture (a) summary — rc=$rc_a"
    echo "--- stdout ---"
    echo "$sum_a" | head -10
    echo "--------------"
    FAIL=$((FAIL + 1))
fi

# 期望：rc=0 + 列表 6 项 + 含 prompt 模板内容
expected_codes_a=("Z1" "Z2" "Z3" "Z4" "Z5" "Z6")
all_present=true
for code in "${expected_codes_a[@]}"; do
    if ! grep -qE "^- \`${code}\` \(status=" <<< "$out_a"; then
        all_present=false
        break
    fi
done

if [[ $rc_a -eq 0 ]] && \
   $all_present && \
   ! grep -qE "^- \`Z7\`" <<< "$out_a" && \
   ! grep -qE "^- \`Z8\`" <<< "$out_a" && \
   grep -q "RETRO RESIDUE PROCESSOR" <<< "$out_a"; then
    echo "${GREEN}PASS${RESET}: Fixture (a) — 6 待 process + Z7/Z8 跳过 + prompt 嵌入 (rc=$rc_a)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: Fixture (a) — rc=$rc_a; expected rc=0 + 6 codes Z1-Z6 + skip Z7/Z8"
    echo "--- partial output ---"
    grep -E "^- \`[A-Z][0-9]+\`|RETRO RESIDUE|待 process" <<< "$out_a" | head -10
    echo "----------------------"
    FAIL=$((FAIL + 1))
fi
cleanup "$FX_A"

# ---------------------------------------------------------------------------
# Fixture (b) — 幂等：所有 pending 项已写 chore_spec
# ---------------------------------------------------------------------------
echo ""
echo "=== Fixture (b) — 幂等：所有 pending/partial 项均已有 chore_spec ==="
FX_B=$(make_fixture)
mkdir -p "${FX_B}/_bmad-output/implementation-artifacts"
ART_B="${FX_B}/_bmad-output/implementation-artifacts"

cat > "${ART_B}/sprint-status.yaml" <<'YAML'
retro_action_items:
  epic-7-retro:
    Z1: pending
      chore_spec: 'chore-retro-c7-Z1-foo.md'
    Z2: partial
      chore_spec: 'chore-retro-c7-Z2-bar.md'
    Z3: done
    Z4: deferred
YAML

cat > "${ART_B}/epic-7-retro-2026-05-03.md" <<'MD'
# Epic 7 Retrospective

## 6. Action Items

### Z1 ### Z2 ### Z3 ### Z4
MD

mkdir -p "${FX_B}/tmp"
set +e
out_b=$(TMPDIR="${FX_B}/tmp" "$ENTRY" --epic 7 \
    --sprint-status "${ART_B}/sprint-status.yaml" \
    --retro-md "${ART_B}/epic-7-retro-2026-05-03.md" \
    --artifact-dir "$ART_B" 2>&1)
rc_b=$?
set -e

# exit 2 时不建 prompt 临时文件
if [[ $rc_b -eq 2 ]] && grep -q "no residue" <<< "$out_b" && \
   [[ -z "$(ls -A "${FX_B}/tmp")" ]] && ! grep -q "^PROMPT_FILE=" <<< "$out_b"; then
    echo "${GREEN}PASS${RESET}: Fixture (b) — exit 2 + 'no residue' (rc=$rc_b)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: Fixture (b) — expected rc=2 + 'no residue'; got rc=$rc_b"
    echo "--- output ---"
    echo "$out_b" | head -10
    echo "--------------"
    FAIL=$((FAIL + 1))
fi
cleanup "$FX_B"

# ---------------------------------------------------------------------------
# Fixture (c) — 增量：5 项已 process / 1 项新增 pending
# ---------------------------------------------------------------------------
echo ""
echo "=== Fixture (c) — 增量：5 项已 chore_spec / 1 项新 pending（Z6） ==="
FX_C=$(make_fixture)
mkdir -p "${FX_C}/_bmad-output/implementation-artifacts"
ART_C="${FX_C}/_bmad-output/implementation-artifacts"

cat > "${ART_C}/sprint-status.yaml" <<'YAML'
retro_action_items:
  epic-7-retro:
    Z1: pending
      chore_spec: 'chore-retro-c7-Z1-foo.md'
    Z2: partial
      chore_spec: 'chore-retro-c7-Z2-bar.md'
    Z3: pending
      chore_spec: 'chore-retro-c7-Z3-baz.md'
    Z4: pending
      chore_spec: 'chore-retro-c7-Z4-qux.md'
    Z5: pending
      chore_spec: 'chore-retro-c7-Z5-fiz.md'
    Z6: pending
    Z7: done
    Z8: deferred
YAML

cat > "${ART_C}/epic-7-retro-2026-05-03.md" <<'MD'
# Epic 7 Retrospective

## 6. Action Items

### Z6 — newly added action item
Action: do the new thing
MD

mkdir -p "${FX_C}/tmp"
set +e
sum_c=$(TMPDIR="${FX_C}/tmp" "$ENTRY" --epic 7 \
    --sprint-status "${ART_C}/sprint-status.yaml" \
    --retro-md "${ART_C}/epic-7-retro-2026-05-03.md" \
    --artifact-dir "$ART_C" 2>/dev/null)
rc_c=$?
set -e
out_c="$(prompt_of "$sum_c")"

# 期望：rc=0 + 仅 Z6 在待 process 列表 + Z1-Z5 在 chore_spec 已有清单
if [[ $rc_c -eq 0 ]] && \
   [[ "$(summary_field "$sum_c" PENDING_CODES)" = Z6 ]] && \
   grep -qE "^- \`Z6\` \(status=" <<< "$out_c" && \
   ! grep -qE "^- \`Z1\` \(status=" <<< "$out_c" && \
   grep -q "Z1=chore-retro-c7-Z1-foo.md" <<< "$out_c"; then
    echo "${GREEN}PASS${RESET}: Fixture (c) — 仅 Z6 待 process + Z1-Z5 在黑名单 (rc=$rc_c)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: Fixture (c) — rc=$rc_c; expected rc=0 + only Z6 + Z1-Z5 in existing list"
    echo "--- pending list ---"
    grep -E "^- \`Z[0-9]\`" <<< "$out_c" || true
    echo "--- existing list ---"
    grep -E "Z[0-9]=chore" <<< "$out_c" || true
    echo "--------------------"
    FAIL=$((FAIL + 1))
fi
cleanup "$FX_C"

# ---------------------------------------------------------------------------
# Fixture (d) — alphanumeric-dash code（C-bootstrap 类）— F1 codex review fix 回归
# ---------------------------------------------------------------------------
echo ""
echo "=== Fixture (d) — alphanumeric-dash code 兼容（C-bootstrap / C-foo-bar） ==="
FX_D=$(make_fixture)
mkdir -p "${FX_D}/_bmad-output/implementation-artifacts"
ART_D="${FX_D}/_bmad-output/implementation-artifacts"

cat > "${ART_D}/sprint-status.yaml" <<'YAML'
retro_action_items:
  epic-7-retro:
    Z1: pending
    C-bootstrap: pending
    C-foo-bar: pending
    Z2: done
YAML

cat > "${ART_D}/epic-7-retro-2026-05-03.md" <<'MD'
# Epic 7 Retrospective

## 6. Action Items

### Z1 — numeric code
### C-bootstrap — alphanumeric-dash code
### C-foo-bar — multi-dash slug
### Z2 — done
MD

mkdir -p "${FX_D}/tmp"
set +e
sum_d=$(TMPDIR="${FX_D}/tmp" "$ENTRY" --epic 7 \
    --sprint-status "${ART_D}/sprint-status.yaml" \
    --retro-md "${ART_D}/epic-7-retro-2026-05-03.md" \
    --artifact-dir "$ART_D" 2>/dev/null)
rc_d=$?
set -e
out_d="$(prompt_of "$sum_d")"

# 期望：rc=0 + 列表含 Z1 / C-bootstrap / C-foo-bar 三项 + skip Z2（done）
if [[ $rc_d -eq 0 ]] && \
   grep -qE "^- \`Z1\` \(status=" <<< "$out_d" && \
   grep -qE "^- \`C-bootstrap\` \(status=" <<< "$out_d" && \
   grep -qE "^- \`C-foo-bar\` \(status=" <<< "$out_d" && \
   ! grep -qE "^- \`Z2\` \(status=" <<< "$out_d"; then
    echo "${GREEN}PASS${RESET}: Fixture (d) — Z1 + C-bootstrap + C-foo-bar 全识别 + Z2 跳过 (rc=$rc_d)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: Fixture (d) — rc=$rc_d; alphanumeric-dash code 未识别"
    echo "--- pending list ---"
    grep -E "^- \`[A-Z][A-Za-z0-9-]*\`" <<< "$out_d" || true
    echo "--------------------"
    FAIL=$((FAIL + 1))
fi
cleanup "$FX_D"

# ---------------------------------------------------------------------------
# Fixture (e) — --stdout：整段 prompt 直出 stdout，不建临时文件
# ---------------------------------------------------------------------------
echo ""
echo "=== Fixture (e) — --stdout 调试模式 ==="
FX_E=$(make_fixture)
mkdir -p "${FX_E}/_bmad-output/implementation-artifacts" "${FX_E}/tmp"
ART_E="${FX_E}/_bmad-output/implementation-artifacts"
printf '%s\n' 'retro_action_items:' '  epic-7-retro:' '    Z1: pending' '    Z2: done' > "${ART_E}/sprint-status.yaml"
printf '%s\n' '# Epic 7 Retrospective' '' '### Z1 — item' '### Z2 — done' > "${ART_E}/epic-7-retro-2026-05-03.md"

set +e
out_e=$(TMPDIR="${FX_E}/tmp" "$ENTRY" --epic 7 --stdout \
    --sprint-status "${ART_E}/sprint-status.yaml" \
    --retro-md "${ART_E}/epic-7-retro-2026-05-03.md" \
    --artifact-dir "$ART_E" 2>/dev/null)
rc_e=$?
set -e

if [[ $rc_e -eq 0 ]] && \
   grep -q "RETRO RESIDUE PROCESSOR" <<< "$out_e" && \
   grep -qE "^- \`Z1\` \(status=" <<< "$out_e" && \
   grep -q "=== MANIFEST ===" <<< "$out_e" && \
   ! grep -q "^PROMPT_FILE=" <<< "$out_e" && \
   [[ -z "$(ls -A "${FX_E}/tmp")" ]]; then
    echo "${GREEN}PASS${RESET}: Fixture (e) — --stdout 直出 prompt，无临时文件 (rc=$rc_e)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: Fixture (e) — rc=$rc_e"
    echo "$out_e" | head -5
    FAIL=$((FAIL + 1))
fi
cleanup "$FX_E"

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
