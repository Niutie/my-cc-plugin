#!/usr/bin/env bash
# deploy.sh — 把 super-harness 资产投递到项目的 .claude/super-harness/。
#
# 用法：bash <PLUGIN_ROOT>/scripts/deploy.sh <PLUGIN_ROOT> [DEST_ROOT]
#
# 投递：
#   scripts/superh.py          → .claude/super-harness/scripts/superh.py
#   prompts/*.md               → .claude/super-harness/prompts/
#   templates/config.yaml      → .claude/super-harness/config.yaml（仅当不存在）
#
# 已存在且内容不同的文件先备份为 <file>.bak.<时间戳> 再覆盖；config.yaml 永不覆盖。
# 输出最后一行：deploy: installed=N updated=M unchanged=K
# 退出码：0 成功；1 参数错误；2 有文件投递失败。

set -euo pipefail

PLUGIN_ROOT="${1:-}"
DEST_ROOT="${2:-$PWD}"
if [ -z "$PLUGIN_ROOT" ] || [ ! -f "$PLUGIN_ROOT/scripts/superh.py" ]; then
    echo "ERROR [deploy]: PLUGIN_ROOT 无效：'$PLUGIN_ROOT'" >&2
    exit 1
fi
cd "$DEST_ROOT"

TS="$(date +%Y%m%d%H%M%S)"
INSTALLED=0
UPDATED=0
UNCHANGED=0
FAILED=0

deploy_one() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ]; then
        if cmp -s "$src" "$dst"; then
            UNCHANGED=$((UNCHANGED + 1))
            return
        fi
        cp -p "$dst" "$dst.bak.$TS" || { FAILED=$((FAILED + 1)); return; }
        cp "$src" "$dst" || { FAILED=$((FAILED + 1)); return; }
        echo "updated: $dst (备份 $dst.bak.$TS)" >&2
        UPDATED=$((UPDATED + 1))
    else
        cp "$src" "$dst" || { FAILED=$((FAILED + 1)); return; }
        echo "installed: $dst" >&2
        INSTALLED=$((INSTALLED + 1))
    fi
}

deploy_one "$PLUGIN_ROOT/scripts/superh.py" ".claude/super-harness/scripts/superh.py"
for f in "$PLUGIN_ROOT"/prompts/*.md; do
    [ -f "$f" ] && deploy_one "$f" ".claude/super-harness/prompts/$(basename "$f")"
done
if [ ! -f .claude/super-harness/config.yaml ]; then
    cp "$PLUGIN_ROOT/templates/config.yaml" .claude/super-harness/config.yaml && {
        echo "installed: .claude/super-harness/config.yaml（模板）" >&2
        INSTALLED=$((INSTALLED + 1))
    } || FAILED=$((FAILED + 1))
fi
printf '%s\n' "$(cat "$PLUGIN_ROOT/.claude-plugin/plugin.json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')" \
    > .claude/super-harness/.version

if [ "$FAILED" -gt 0 ]; then
    echo "deploy: installed=$INSTALLED updated=$UPDATED unchanged=$UNCHANGED FAILED=$FAILED"
    exit 2
fi
echo "deploy: installed=$INSTALLED updated=$UPDATED unchanged=$UNCHANGED"
