#!/usr/bin/env bash
# check_bmad_runtime — /harness-zh:run §0 前置：BMad 6.11+ build pipeline 运行条件探测
#
# harness-zh 0.2.0 起每条 story 由 bmad-build-auto 跑完。它有三个硬依赖，缺任何一个
# 都会在 subagent 已经开跑之后才 HALT（token 白烧），所以在 dispatch 前先探：
#   1. uv 在 PATH 上 —— 6.12 所有 skill 启动都走 `uv run _bmad/scripts/render_skill.py`
#      （bmad-build / bmad-build-auto 明确写了 uv 不可用就 HALT，不兜底）
#   2. bmad-build-auto skill 已安装 + `_bmad/scripts/render_skill.py` 存在
#   3. 嵌套子 agent 没被关掉 —— harness dispatch 的 subagent 里再由 bmad-build-auto
#      起 reviewer / 实现子 agent，需要 ≥ 2 层（CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH）
# 另外报告（不判失败）：BMad 版本、bmad-build-auto 是否挂了 codex review layer。
#
# 用法：
#   bash .claude/harness/scripts/check_bmad_runtime.sh [--project-root <dir>]
#
# stdout（key=value，逐行）：
#   BMAD_VERSION=<x.y.z|unknown>
#   UV=ok|missing
#   BUILD_AUTO_SKILL=<path>|missing
#   RENDER_SCRIPT=ok|missing
#   SUBAGENT_DEPTH=<n|default>
#   CODEX_IN_BUILD=<layer ids,…|none>
#   LEGACY_SKILLS=present|absent        (bmad-create-story / bmad-dev-story shim)
#   STATUS=ok|fail
#   REMEDIATION=<一行修复指引>           (每个失败项一行)
#
# 退出码：0 全部满足；1 至少一项硬依赖缺失；2 参数错误。

set -uo pipefail

ROOT="$PWD"
while [ $# -gt 0 ]; do
    case "$1" in
        --project-root) ROOT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -d "$ROOT" ] || { echo "project root not a directory: $ROOT" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
REMEDIATIONS=()

# --- BMad version (informational) -------------------------------------------
BMAD_VERSION="unknown"
MANIFEST="$ROOT/_bmad/_config/manifest.yaml"
if [ -f "$MANIFEST" ]; then
    v="$(awk '/^installation:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^[ ]+version:/{print $2; exit}' "$MANIFEST" | tr -d '"'"'")"
    [ -n "$v" ] && BMAD_VERSION="$v"
fi
echo "BMAD_VERSION=$BMAD_VERSION"

# --- uv ------------------------------------------------------------------------
if command -v uv >/dev/null 2>&1; then
    echo "UV=ok"
else
    echo "UV=missing"
    FAIL=1
    REMEDIATIONS+=("安装 uv（BMad 6.12 skill 启动依赖）：curl -LsSf https://astral.sh/uv/install.sh | sh  或  pipx install uv，然后确认新 shell 里 command -v uv 有输出")
fi

# --- bmad-build-auto skill + render script ---------------------------------
SKILL=""
for cand in "$ROOT/.claude/skills/bmad-build-auto/SKILL.md" "$HOME/.claude/skills/bmad-build-auto/SKILL.md"; do
    if [ -f "$cand" ]; then SKILL="$cand"; break; fi
done
if [ -n "$SKILL" ]; then
    echo "BUILD_AUTO_SKILL=$SKILL"
else
    echo "BUILD_AUTO_SKILL=missing"
    FAIL=1
    REMEDIATIONS+=("bmad-build-auto 未安装（需要 BMad ≥ 6.11）：在项目根跑 npx bmad-method install 升级到最新版")
fi
if [ -f "$ROOT/_bmad/scripts/render_skill.py" ]; then
    echo "RENDER_SCRIPT=ok"
else
    echo "RENDER_SCRIPT=missing"
    FAIL=1
    REMEDIATIONS+=("_bmad/scripts/render_skill.py 缺失：BMad 安装不完整或低于 6.11，重跑 npx bmad-method install")
fi

# --- nested subagent depth ---------------------------------------------------
DEPTH="${CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH:-}"
if [ -z "$DEPTH" ]; then
    for f in "$ROOT/.claude/settings.local.json" "$ROOT/.claude/settings.json" "$HOME/.claude/settings.json"; do
        [ -f "$f" ] || continue
        d="$(python3 -c 'import json,sys
try:
    print((json.load(open(sys.argv[1])).get("env") or {}).get("CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH",""))
except Exception:
    print("")' "$f" 2>/dev/null)"
        if [ -n "$d" ]; then DEPTH="$d"; break; fi
    done
fi
if [ -z "$DEPTH" ]; then
    echo "SUBAGENT_DEPTH=default"
else
    echo "SUBAGENT_DEPTH=$DEPTH"
    case "$DEPTH" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$DEPTH" -lt 2 ]; then
                FAIL=1
                REMEDIATIONS+=("CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=$DEPTH 关掉了嵌套子 agent；harness dispatch 的 subagent 里 bmad-build-auto 还要再起子 agent，至少需要 2（删掉该设置即用默认 3）")
            fi
            ;;
    esac
fi

# --- codex layer mounted in bmad-build-auto (informational) -----------------
CODEX_IDS="$(PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" "$SCRIPT_DIR" <<'PYEOF' 2>/dev/null
import sys
sys.path.insert(0, sys.argv[2])
try:
    import harness_spec
    ids = harness_spec.build_auto_codex_layer_ids(sys.argv[1])
    print(",".join(ids) if ids else "none")
except Exception:
    print("none")
PYEOF
)"
echo "CODEX_IN_BUILD=${CODEX_IDS:-none}"

# --- legacy skills (informational) ------------------------------------------
if [ -f "$ROOT/.claude/skills/bmad-dev-story/SKILL.md" ] || [ -f "$ROOT/.claude/skills/bmad-create-story/SKILL.md" ]; then
    echo "LEGACY_SKILLS=present"
else
    echo "LEGACY_SKILLS=absent"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "STATUS=ok"
    exit 0
fi
echo "STATUS=fail"
for r in "${REMEDIATIONS[@]}"; do
    echo "REMEDIATION=$r"
done
exit 1
