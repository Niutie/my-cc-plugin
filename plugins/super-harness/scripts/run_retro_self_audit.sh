#!/usr/bin/env bash
# Retro self-audit（通用骨架，检查项由项目自己配置）
#
# retro 进入 Phase 2 Analyze 之前跑一次，机械核对「上几个 epic 的 retro
# action item 在代码库里有没有兑现证据」，输出 markdown 表格 4 列
# （id / 描述 / 自动判定 status / evidence）给 retro §2 cross-reference
# 当草稿。只读，不改 sprint-status.yaml。
#
# 检查项来自项目侧配置文件（plugin 不再内置任何项目的检查）：
#
#   .claude/harness/retro-self-audit.tsv
#
# 该文件不在 deploy manifest 里，init / update 不会创建、覆盖或 purge 它。
# 不存在或没有有效行时，脚本只打印一段带标签的空结果（见下）并 exit 0，
# 不输出表格——retro agent 照常手工填 §2。
# 测试或临时指定别的路径：环境变量 RETRO_SELF_AUDIT_CONFIG=<path>。
#
# 配置格式：每行一项，字段用 TAB 分隔；`#` 开头的行和空行忽略。
#
#   <min_prev_epic> <TAB> <id> <TAB> <描述> <TAB> <kind> <TAB> <arg1> [<TAB> <arg2>]
#
#   min_prev_epic  prev_epic_num ≥ 它时才检查（通常填该 action item 所属的 epic 号）
#   kind / 参数（路径相对仓库根；路径可写 `a|b|c`，取第一个存在的，
#                用于 sharded / 单文件两种 BMad 文档布局）：
#     file   <path>          文件存在 → done；否则 pending
#     exec   <path>          文件存在且可执行 → done；否则 pending
#     dir    <path>          目录存在 → done；否则 pending
#     grep   <path> <ERE>    文件含匹配行 → done；不含 → pending；文件缺失 → unknown
#     nogrep <path> <ERE>    文件不含匹配行 → done；含 → pending（报命中行数）；缺失 → unknown
#     cmd    <shell 命令>    在仓库根 `bash -c` 执行，退出码 0 → done；否则 pending
#     manual <evidence 文本> 无法机械判定 → unknown，evidence 原样输出
#
# 示例：.claude/harness/templates/retro-self-audit.tsv.example
#
# 输出：
#   有检查项：表头 2 行 + 每项 1 行，最后一行 `_CHECKS_:<N>`
#   无检查项：
#     RETRO_SELF_AUDIT: no-config
#     NOTE: ...（说明不要把本输出贴进 retro 文档）
#     _CHECKS_:0
#   配置行格式错误：该行跳过，stderr 打 WARN（不影响其它行和退出码）
#
# 用法：
#   bash .claude/harness/scripts/run_retro_self_audit.sh <prev_epic_num>
#
# 退出码：
#   0   正常（含无配置）
#   1   sprint-status.yaml 不存在
#   2   参数缺失 / 非法

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <prev_epic_num>" >&2
    exit 2
fi

PREV_EPIC="$1"
if ! [[ "$PREV_EPIC" =~ ^[0-9]+$ ]]; then
    echo "ERROR: prev_epic_num must be numeric, got: $PREV_EPIC" >&2
    exit 2
fi

ROOT="$(pwd)"
SPRINT_STATUS="${ROOT}/_bmad-output/implementation-artifacts/sprint-status.yaml"

if [ ! -f "$SPRINT_STATUS" ]; then
    echo "ERROR: sprint-status.yaml not found at $SPRINT_STATUS" >&2
    exit 1
fi

CONFIG="${RETRO_SELF_AUDIT_CONFIG:-${ROOT}/.claude/harness/retro-self-audit.tsv}"

# 表格单元格里不能有 `|` 和换行
cell() {
    printf '%s' "$1" | tr '\n|' ' /'
}

# `a|b|c` → 第一个存在的路径（相对 ROOT）；都不存在 → 空串
resolve_path() {
    local spec="$1" want="$2" cand
    local IFS='|'
    for cand in $spec; do
        [ -n "$cand" ] || continue
        case "$want" in
            dir) [ -d "${ROOT}/${cand}" ] && { echo "$cand"; return; } ;;
            *)   [ -e "${ROOT}/${cand}" ] && { echo "$cand"; return; } ;;
        esac
    done
    echo ""
}

row() {  # id desc status evidence
    echo "| $(cell "$1") | $(cell "$2") | $3 | $(cell "$4") |"
}

run_check() {  # id desc kind arg1 arg2
    local id="$1" desc="$2" kind="$3" a1="$4" a2="$5" p n
    case "$kind" in
        file|exec)
            p="$(resolve_path "$a1" file)"
            if [ -n "$p" ] && { [ "$kind" = file ] || [ -x "${ROOT}/${p}" ]; }; then
                row "$id" "$desc" done "$p"
            else
                row "$id" "$desc" pending "$a1 missing$([ "$kind" = exec ] && echo ' or not executable')"
            fi ;;
        dir)
            p="$(resolve_path "$a1" dir)"
            if [ -n "$p" ]; then row "$id" "$desc" done "$p/"; else row "$id" "$desc" pending "$a1 missing"; fi ;;
        grep|nogrep)
            p="$(resolve_path "$a1" file)"
            if [ -z "$p" ] || [ ! -f "${ROOT}/${p}" ]; then
                row "$id" "$desc" unknown "$a1 missing"; return
            fi
            n="$(grep -cE -- "$a2" "${ROOT}/${p}" 2>/dev/null || true)"
            n="${n:-0}"
            if [ "$kind" = grep ]; then
                if [ "$n" -gt 0 ]; then row "$id" "$desc" done "$p 命中 /$a2/"
                else row "$id" "$desc" pending "$p 无 /$a2/"; fi
            else
                if [ "$n" -eq 0 ]; then row "$id" "$desc" done "$p 无 /$a2/"
                else row "$id" "$desc" pending "$p 仍有 $n 行匹配 /$a2/"; fi
            fi ;;
        cmd)
            if (cd "$ROOT" && bash -c "$a1") >/dev/null 2>&1; then
                row "$id" "$desc" done "命令退出 0：$a1"
            else
                row "$id" "$desc" pending "命令非 0：$a1"
            fi ;;
        manual)
            row "$id" "$desc" unknown "${a1:-需人工判定}" ;;
        *)
            return 1 ;;
    esac
}

ROWS=()
if [ -f "$CONFIG" ]; then
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        case "$line" in ''|'#'*) continue ;; esac
        IFS=$'\t' read -r min id desc kind a1 a2 <<<"$line" || true
        if ! [[ "${min:-}" =~ ^[0-9]+$ ]] || [ -z "${id:-}" ] || [ -z "${kind:-}" ]; then
            echo "WARN: $CONFIG:$lineno 格式不对（需要 min_prev_epic<TAB>id<TAB>描述<TAB>kind<TAB>参数），已跳过" >&2
            continue
        fi
        [ "$PREV_EPIC" -ge "$min" ] || continue
        if ! out="$(run_check "$id" "${desc:-}" "$kind" "${a1:-}" "${a2:-}")"; then
            echo "WARN: $CONFIG:$lineno 未知 kind '$kind'，已跳过" >&2
            continue
        fi
        ROWS+=("$out")
    done < "$CONFIG"
fi

if [ "${#ROWS[@]}" -eq 0 ]; then
    echo "RETRO_SELF_AUDIT: no-config"
    if [ -f "$CONFIG" ]; then
        echo "NOTE: $CONFIG 里没有适用于 prev_epic=$PREV_EPIC 的检查项。"
    else
        echo "NOTE: 项目没有配置 retro self-audit 检查项（$CONFIG 不存在）。"
    fi
    echo "NOTE: 不要把本输出贴进 retro 文档。§2 cross-reference 表按 sprint-status.yaml 的 retro_action_items / action_items 和上一份 retro 文档手工填。"
    echo "_CHECKS_:0"
    exit 0
fi

echo "| id | 描述 | status | evidence |"
echo "|----|------|--------|----------|"
printf '%s\n' "${ROWS[@]}"
echo "_CHECKS_:${#ROWS[@]}"
exit 0
