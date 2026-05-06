#!/usr/bin/env bash
# Chore C12 — diff guardrail：deferred-work.md backfill 强校验
#
# 用法：
#   bash .claude/harness/scripts/diff_guardrail.sh <old-file> <new-file>
#
# 校验规则（fresh agent 输出 vs 原 deferred-work.md）：
#   1. ❌ 0 容忍 `-` 删除行（除非配对 `+` 行只是同位置追加 — 即原行被替换为"原行 + 追加文本"）
#   2. ✅ 允许 `+` 新增整行（极少 — 只在 § 1 总账自动重算之类场景；本 chore 不触发）
#   3. ✅ 允许"FU 行原内容 + ` — Resolved by Story...` / ` — Story X.Y done but no resolution evidence`"形式的行替换
#       即 diff 中 `-原行` / `+原行 — Resolved by Story ...` 配对，且 `+` 行 startswith `-` 行去掉前导 `-`/`+` 字符的内容
#   4. ✅ 允许 trailing whitespace 差异（容错）
#
# 异常 → exit 1 + stderr 列违例行号
# 一致 → exit 0 + stderr 输出"diff_guardrail PASS: N 行追加，0 删除/修改"

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <old-file> <new-file>" >&2
    exit 2
fi

OLD="$1"
NEW="$2"

if [[ ! -f "$OLD" ]]; then
    echo "ERROR: old file not found: $OLD" >&2
    exit 2
fi
if [[ ! -f "$NEW" ]]; then
    echo "ERROR: new file not found: $NEW" >&2
    exit 2
fi

# 用 python 做 line-by-line diff 校验（pure bash + diff 处理 hunk 边界复杂）
python3 - "$OLD" "$NEW" <<'PYEOF'
"""diff_guardrail: validate fresh agent only appended inline markers to FU lines."""
from __future__ import annotations

import re
import sys
from pathlib import Path

OLD = Path(sys.argv[1])
NEW = Path(sys.argv[2])

old_lines = OLD.read_text(encoding='utf-8').splitlines()
new_lines = NEW.read_text(encoding='utf-8').splitlines()

# 允许的追加 marker 模式
RESOLVED_RE = re.compile(r' — Resolved by Story \S+ \(\d{4}-\d{2}-\d{2}\): .{1,280}$')
NEEDS_REVIEW_RE = re.compile(r' — Story \S+ done but no resolution evidence — needs solo-dev review$')

violations = []
appended_resolved = 0
appended_needs_review = 0
unchanged = 0

# 简单的 line-by-line 校验：要求 old 与 new 行数相同（仅 inline 追加 = 0 行数变化）
# 若 fresh agent 加了新行（极罕见，本 chore 严格禁止），违例
if len(old_lines) != len(new_lines):
    print(
        f'VIOLATION: line count changed: old={len(old_lines)} new={len(new_lines)}; '
        'fresh agent must only inline-append (no new lines, no deletions).',
        file=sys.stderr,
    )
    sys.exit(1)

for i, (old_line, new_line) in enumerate(zip(old_lines, new_lines), start=1):
    if old_line == new_line:
        unchanged += 1
        continue

    # new 行必须以 old 行为前缀（仅追加 = 字符串前缀关系）
    if not new_line.startswith(old_line):
        violations.append(
            (i, 'NOT_PREFIX', old_line[:120], new_line[:120])
        )
        continue

    delta = new_line[len(old_line):]

    # delta 必须匹配允许的 marker 模式之一
    if RESOLVED_RE.fullmatch(delta):
        appended_resolved += 1
    elif NEEDS_REVIEW_RE.fullmatch(delta):
        appended_needs_review += 1
    else:
        violations.append(
            (i, 'BAD_MARKER', old_line[:120], delta[:200])
        )

if violations:
    print(f'diff_guardrail FAIL: {len(violations)} violation(s)', file=sys.stderr)
    for ln, kind, old_excerpt, info in violations[:20]:
        print(f'  L{ln} [{kind}]', file=sys.stderr)
        print(f'    OLD: {old_excerpt}', file=sys.stderr)
        if kind == 'NOT_PREFIX':
            print(f'    NEW: {info}', file=sys.stderr)
        else:
            print(f'    DELTA: {info}', file=sys.stderr)
    if len(violations) > 20:
        print(f'  ... and {len(violations) - 20} more', file=sys.stderr)
    sys.exit(1)

changed = appended_resolved + appended_needs_review
print(
    f'diff_guardrail PASS: {changed} line(s) appended '
    f'(Resolved={appended_resolved}, needs-review={appended_needs_review}); '
    f'{unchanged} line(s) unchanged.',
    file=sys.stderr,
)
sys.exit(0)
PYEOF
