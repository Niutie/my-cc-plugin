#!/usr/bin/env bash
# D-decisions extract proposal helper
#
# 扫 spec 文件中 D{N}.{M}.{a-z} 锚点（如 D3.6.b）；命中 ≥ 5 条时打印
# extract 提议 + sharded 文件路径模板 `architecture/decisions/d-{epic}-{story}.md`。
# 不直接改 spec —— solo-dev 确认后手工迁移；本脚本仅 visibility。
#
# 用法：
#   bash .claude/harness/scripts/extract_d_decisions.sh <spec-path>
#
# 退出码：
#   0  正常输出（< 5 静默通过；≥ 5 打印提议）
#   2  spec 文件不存在 / 参数缺失

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

# 抓 spec 中 D{N}.{M}.{a-z} 锚点（H3 标题格式 `### D3.6.b — ...`）
hits="$(grep -cE '^### D[0-9]+\.[0-9]+\.[a-z]' "$SPEC" || true)"

if [ "$hits" -lt 5 ]; then
    echo "PASS: $SPEC has $hits D-decisions (< 5 threshold; no extract proposed)"
    exit 0
fi

# 从 spec 文件名抽 epic / story（如 4-1-rule-engine-core.md → epic=4, story=1）
basename="$(basename "$SPEC" .md)"
if [[ "$basename" =~ ^([0-9]+)-([0-9]+)- ]]; then
    epic="${BASH_REMATCH[1]}"
    story="${BASH_REMATCH[2]}"
    sharded_path="_bmad-output/planning-artifacts/architecture/decisions/d-${epic}-${story}.md"
else
    epic="?"
    story="?"
    sharded_path="_bmad-output/planning-artifacts/architecture/decisions/d-<epic>-<story>.md"
fi

echo "PROPOSE EXTRACT: $SPEC has $hits D-decisions (≥ 5 threshold)"
echo ""
echo "  Suggested sharded file: $sharded_path"
echo ""
echo "  Workflow（solo-dev 手工执行）:"
echo "  1. 创建 $sharded_path（含完整 D{N}.{M}.{a-z} 段全文）"
echo "  2. 在主 spec 替换为：标题 + 一行摘要 + 链接到 sharded 文件"
echo "  3. 重跑 spec-length-check 确认行数下降"
echo ""
echo "  D-decisions 锚点列表："
grep -nE '^### D[0-9]+\.[0-9]+\.[a-z]' "$SPEC" | head -50

exit 0
