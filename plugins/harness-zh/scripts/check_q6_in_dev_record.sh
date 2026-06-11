#!/usr/bin/env bash
# Q6 full-stack review section format check
#
# 扫指定 story spec 的 Dev Agent Record 段是否含 `### Q6:` + 7 行
# sub-bullet `- (a)` ... `- (g)`；缺失或行数不全 → exit 1。
# Epic 4 retro 启动时 solo-dev 跑此脚本统计 Q6 兑现率。
#
# 用法：
#   bash .claude/harness/scripts/check_q6_in_dev_record.sh <spec-path>
#
# 退出码：
#   0   通过（含 ### Q6: 段 + 7 行 (a)-(g)）
#   1   段缺失 / 行数不全
#   2   spec 文件不存在 / 参数缺失

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <spec-path>" >&2
    exit 2
fi

SPEC="$1"

if [ ! -f "$SPEC" ]; then
    echo "ERROR: spec file not found: $SPEC" >&2
    exit 2
fi

# Q6 段锚（### Q6: 起）
if ! grep -qE '^### Q6:' "$SPEC"; then
    echo "FAIL: $SPEC 缺 \`### Q6:\` 段（Q6 全栈贯通 review）" >&2
    echo "      参考 .claude/harness/prompt-suffixes/bmad-dev-story-suffix.md Q6 7 sub-bullet 模板。" >&2
    exit 1
fi

# 数 (a)-(g) 7 行 sub-bullet — 仅在 Q6 段内（`### Q6:` 起到下一个 `#` 标题止）。
# review 2026-06-10 #52：旧实现 grep 全文件，spec 内其它段落（如继承段 /
# Standard checklists）的 `- (a)` 行会凑数 false-PASS；改 awk in_block 抽块
# （参照 check_inheritance_block.sh）后块内计数。
# regression R3 2026-06-10：终止条件 `f && /^#/` 把 Q6 段内 fenced code block
# （```bash ...```）里行首的 shell 注释 `#` 当成下一个标题提前截断 → 段被腰斩
# false-FAIL。加 fence 状态机（``` 行翻转 fence），终止仅认 fence 外的真标题
# `#+ `（# 后必须带空格，shell 注释 `# comment` 在 fence 内本就不会到达判定）。
q6_block="$(awk '
    /^```/ { fence = !fence }
    !fence && /^### Q6:/ { f = 1; next }
    f && !fence && /^#+ / { exit }
    f { print }
' "$SPEC")"
sub_count="$(printf '%s\n' "$q6_block" | grep -cE '^- \([a-g]\)' || true)"
sub_count="${sub_count:-0}"

if [ "$sub_count" -lt 7 ]; then
    echo "FAIL: $SPEC Q6 sub-bullet 行数 = ${sub_count}（需 ≥ 7：(a)-(g) 全覆盖）" >&2
    exit 1
fi

echo "PASS: $SPEC Q6 段完整（### Q6: 锚 + ${sub_count} sub-bullet）"
exit 0
