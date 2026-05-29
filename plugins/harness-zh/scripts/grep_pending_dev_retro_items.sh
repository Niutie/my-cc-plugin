#!/bin/bash
# Pending DEV retro action items enumerator (machine-readable)
#
# 扫 sprint-status.yaml 的 retro_action_items 块，列出**所有** category: dev 且
# status ∈ {pending, in-progress} 的 action item —— 也就是 pre-commit gate ①
# （check_retro_action_items.sh）会阻 epic 4-6 新 story spec 创建的那一类。每项
# 附带 epic / code / status / chore_spec（stage 6.5 落地的实现 spec 路径，缺失则
# 空），供 `/harness-zh:run` §0.A.0 启动前置 gate 逐项自动兑现用。
#
# 与 check_retro_action_items.sh 的分工：
#   - check_retro_action_items.sh —— 计 exit code 的 **gate**（pre-commit hook 用）；
#     stderr 人读，stdout 无机器契约。
#   - 本脚本 —— 纯 **enumerator**；stdout 机器可读（TAB 分隔），不计 pending 数进
#     exit code（exit 0 = 正常输出，含 0 项；exit 2 = 文件缺失 / 参数错）。
#
# 复用 check_retro_action_items.sh 的 awk 状态机（同一 NON-STANDARD YAML 形状 —
# `<CODE>: <status>` 后跟过度缩进的 `category:` / `chore_spec:` 子字段；标准 YAML
# parser 解析不了，故沿用 awk）。本脚本在其基础上额外捕获 chore_spec 子字段。
#
# 用法：
#   bash .claude/harness/scripts/grep_pending_dev_retro_items.sh [path-to-sprint-status.yaml]
#
# stdout 契约：
#   每个待兑现 dev 项一行（TAB 分隔，5 列）：
#     ITEM<TAB><epic-N-retro><TAB><CODE><TAB><status><TAB><chore_spec|->
#   末尾三行汇总：
#     _PENDING_DEV_:<N>          # 待兑现 dev 项总数（= gate ① 计数口径）
#     _WITH_SPEC_:<M>            # 其中含 chore_spec 字段的（可自动兑现）
#     _NO_SPEC_:<K>             # 其中缺 chore_spec 的（需先补 chore spec / 手工处理）
#
# 退出码：
#   0   正常输出（含「0 项」边界 + 「块缺失」边界，后者 stderr 提示但不计错）
#   2   sprint-status.yaml 路径不存在 / 参数非法

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh"
SPRINT_STATUS="${1:-$HARNESS_SPRINT_STATUS_PATH}"

if [ ! -f "$SPRINT_STATUS" ]; then
    echo "ERROR: sprint-status.yaml not found at $SPRINT_STATUS" >&2
    exit 2
fi

# 块缺失 / 重复 header → 不是 enumerator 的硬错（gate 自会拦）；stderr 提示 + 输出 0 项。
header_count="$(grep -cE "^retro_action_items:" "$SPRINT_STATUS" || true)"
if [ "$header_count" -gt 1 ]; then
    echo "WARN: multiple retro_action_items: top-level keys ($header_count) — ambiguous yaml; emitting 0 items" >&2
    printf '_PENDING_DEV_:0\n_WITH_SPEC_:0\n_NO_SPEC_:0\n'
    exit 0
fi
if ! grep -qE "^retro_action_items:" "$SPRINT_STATUS"; then
    echo "WARN: retro_action_items block missing in $SPRINT_STATUS — emitting 0 items" >&2
    printf '_PENDING_DEV_:0\n_WITH_SPEC_:0\n_NO_SPEC_:0\n'
    exit 0
fi

# awk 状态机：与 check_retro_action_items.sh 同源，新增 current_chore_spec 捕获。
# 每遇新 action item header / epic header / 块结束时 flush 上一项；仅 dev +
# pending/in-progress 的项发 ITEM 行（其它 category / 终态静默跳过 —— 本脚本只
# 关心 gate ① 阻塞类）。E1 CRLF strip 沿用。
awk '
  function flush_item() {
    if (current_code != "") {
      if ((current_status == "pending" || current_status == "in-progress") \
          && current_category == "dev") {
        spec = (current_chore_spec == "" ? "-" : current_chore_spec)
        printf "ITEM\t%s\t%s\t%s\t%s\n", current_epic, current_code, current_status, spec
        pending_dev++
        if (current_chore_spec == "") { no_spec++ } else { with_spec++ }
      }
    }
    current_code=""; current_status=""; current_category=""; current_chore_spec=""
  }

  /^retro_action_items:/ { in_block=1; next }
  in_block && /^[^[:space:]#]/ { flush_item(); in_block=0 }

  in_block && /^[[:space:]]+[a-z0-9-]+-retro:[[:space:]]*$/ {
    flush_item()
    match($0, /[a-z0-9-]+-retro/)
    current_epic = substr($0, RSTART, RLENGTH)
    next
  }

  in_block && /^[[:space:]]+[A-Z][A-Za-z0-9-]*:[[:space:]]/ {
    flush_item()
    code = $1
    sub(":$", "", code)
    current_code = code
    current_status = $2
    sub(/\r$/, "", current_status)
    gsub(/["'"'"']/, "", current_status)
    next
  }

  in_block && /^[[:space:]]+category:[[:space:]]/ {
    cat = $2
    sub(/\r$/, "", cat)
    gsub(/["'"'"']/, "", cat)
    current_category = cat
    next
  }

  in_block && /^[[:space:]]+chore_spec:[[:space:]]/ {
    # value 可能含空格（罕见）；取第一个 token 后去引号即可 —— chore spec 文件名
    # 是 kebab-case 无空格，单 token 足够。
    spec = $2
    sub(/\r$/, "", spec)
    gsub(/["'"'"']/, "", spec)
    current_chore_spec = spec
    next
  }

  END {
    flush_item()
    printf "_PENDING_DEV_:%d\n", pending_dev+0
    printf "_WITH_SPEC_:%d\n", with_spec+0
    printf "_NO_SPEC_:%d\n", no_spec+0
  }
' "$SPRINT_STATUS"

exit 0
