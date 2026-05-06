#!/usr/bin/env bash
# Epic first-story inheritance block check
#
# bmad-create-story finalize sub-step + pre-commit hook（针对 [5-6]-1-*.md）；
# 扫 spec 文件名抽 epic / story id；若 X-1-* 且 X > 1 → grep
# `^## 继承自前序 Epic patterns$` 锚 + 5 行 sub-bullet 行 + 含
# `Epic {X-1} Story` 引用 + 至少一个 `sealed-patterns-epic-` 链接；缺失 → exit 1。
#
# 用法：
#   bash .claude/harness/scripts/check_inheritance_block.sh <spec-path>
#
# 退出码：
#   0   通过（X-1-* 触发 + 完整段；OR 不触发）
#   1   X-1-* 触发 + 段缺失 / sub-bullet 不全 / 缺 Epic {X-1} Story 引用 /
#       缺 sealed-patterns-epic- 文件链接
#   2   spec 文件不存在 / 参数缺失
#
# v1 → v2 (Epic 4 retro D5 2026-05-05)：加 sealed-patterns-epic- 链接检查
# （Epic 5+ 第一 story 必须引用至少一个 sealed-patterns-epic-{N-1}.md 文件，
# 让前序 epic 沉淀 patterns 跨 epic 显式继承）。Epic 1-3 retro §9.5 当前未抽
# sharded sealed-patterns 文件 — Epic 4 第一 story（4.1）已 done 不回退强制；
# 仅 Epic 5 / Epic 6 第一 story 触发本检查（hook trigger pattern 限定）。

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

# 从 spec 文件名抽 epic / story（如 4-1-rule-engine.md → epic=4 story=1）
basename="$(basename "$SPEC" .md)"
if [[ "$basename" =~ ^([0-9]+)-([0-9]+)- ]]; then
    epic="${BASH_REMATCH[1]}"
    story="${BASH_REMATCH[2]}"
else
    echo "PASS: $SPEC story id 不可解析（非业务 story 文件命名）；继承段约束不触发"
    exit 0
fi

# 触发条件：X-1-* 且 X > 1
if [ "$story" != "1" ]; then
    echo "PASS: Story $epic.$story 不是 epic 第一个 story；继承段约束不触发"
    exit 0
fi

if [ "$epic" -le 1 ]; then
    echo "PASS: Epic $epic Story $story 是 Epic 1 第一个 story；无前序 Epic 可继承；继承段约束不触发"
    exit 0
fi

prev_epic=$((epic - 1))

# 检查 H2 锚
if ! grep -qE '^## 继承自前序 Epic patterns[[:space:]]*$' "$SPEC"; then
    echo "FAIL: $SPEC 是 Epic $epic 第一个 story（X-1-* 触发），必须含 \`## 继承自前序 Epic patterns\` H2 段" >&2
    echo "      参考 chore-retro-c3-C7 spec + .claude/harness/prompt-suffixes/bmad-create-story-suffix.md 模板" >&2
    exit 1
fi

# 抽继承段（H2 行 → 下一 H2 行之前；用 in_block flag 避免 awk range pitfall）
block="$(awk '
    /^## 继承自前序 Epic patterns[[:space:]]*$/ { in_block = 1; print; next }
    in_block && /^## / { exit }
    in_block { print }
' "$SPEC")"

# 数 sub-bullet 行：所有 ^- 起始行（兼容 - (a) / - **(a)** / - **a)** 等格式）
sub_bullet_count="$(printf '%s\n' "$block" | grep -cE '^- ' || true)"

if [ "$sub_bullet_count" -lt 5 ]; then
    echo "FAIL: $SPEC 继承段 sub-bullet 行 = ${sub_bullet_count}（需 ≥ 5: self-review / mech-verify / DI / plugin-ready / retro 对齐）" >&2
    exit 1
fi

# 检查 Epic {prev_epic} Story 引用
if ! echo "$block" | grep -qE "Epic[[:space:]]*$prev_epic[[:space:]]*Story"; then
    echo "FAIL: $SPEC 继承段缺 \`Epic $prev_epic Story\` 引用（每 sub-bullet 必须 quote 至少 1 个具体先行 story 路径）" >&2
    exit 1
fi

# 检查 sealed-patterns-epic- 文件链接（Epic 4 retro D5 2026-05-05 加）
# Epic 5+ 第一 story 必须引用至少一个 sealed-patterns-epic-{N-1}.md sharded
# 文件 OR Epic (N-1) retro §9.5 锚点（D5 简化版兼容路径 — 后续如补 Epic 1-3
# sharded 文件再收紧）。Epic 4 第一 story（4.1）在 D5 立之前已 done — 仅向后
# enforce（epic >= 5）；不回退打 already-done spec。
if [ "$epic" -ge 5 ]; then
    if ! echo "$block" | grep -qE "sealed-patterns-epic-|epic-${prev_epic}-retro.*9\.5|epic-${prev_epic}-retro.*sealed"; then
        echo "FAIL: $SPEC 继承段缺 sealed-patterns 引用（必须含至少一个 \`sealed-patterns-epic-${prev_epic}.md\` 链接 OR Epic ${prev_epic} retro §9.5 锚点引用）" >&2
        echo "      参考 sealed-patterns-epic-4.md 模板（D5 简化版兑现）；Epic ${prev_epic} retro §9.5 / 同段 sealed patterns 列表是另一兼容路径。" >&2
        exit 1
    fi
    echo "PASS: $SPEC Epic $epic Story 1 继承段完整（H2 锚 + ${sub_bullet_count} sub-bullet + Epic ${prev_epic} Story 引用 + sealed-patterns 链接）"
else
    echo "PASS: $SPEC Epic $epic Story 1 继承段完整（H2 锚 + ${sub_bullet_count} sub-bullet + Epic ${prev_epic} Story 引用；epic <5 不强制 sealed-patterns 引用，向后兼容 D5 立前 already-done spec）"
fi
exit 0
