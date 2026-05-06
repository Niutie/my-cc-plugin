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

# Q6 段锚（### Q6: 起 — Standard checklists 段也含此格式但不会被误命中
# 因为 standard checklists 含 7 行 sub-bullet 与 dev record 段格式相同）
if ! grep -qE '^### Q6:' "$SPEC"; then
    echo "FAIL: $SPEC 缺 \`### Q6:\` 段（Q6 全栈贯通 review）" >&2
    echo "      参考 .claude/harness/prompt-suffixes/bmad-dev-story-suffix.md Q6 7 sub-bullet 模板。" >&2
    exit 1
fi

# 数 (a)-(g) 7 行 sub-bullet
sub_count="$(grep -cE '^- \([a-g]\)' "$SPEC" || true)"
sub_count="${sub_count:-0}"

if [ "$sub_count" -lt 7 ]; then
    echo "FAIL: $SPEC Q6 sub-bullet 行数 = ${sub_count}（需 ≥ 7：(a)-(g) 全覆盖）" >&2
    exit 1
fi

echo "PASS: $SPEC Q6 段完整（### Q6: 锚 + ${sub_count} sub-bullet）"
exit 0
