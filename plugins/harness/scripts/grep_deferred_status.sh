#!/usr/bin/env bash
# Grep deferred-work coverage from a story's perspective (schema v1).
#
# Reads schema-tagged FU bullets and emits four sections for a given story key:
#   ① 待消化 (open):       status ∈ {pending, in-progress, partial, needs-review}
#                          AND target = "Story X.Y"
#   ② 已消化 (closed):     status ∈ {resolved, skipped, superseded}
#                          AND target = "Story X.Y"
#                          (matched via target field — schema-canonical;
#                          legacy "Resolved by Story X.Y" inline strings are
#                          captured in 历史 audit log within the FU bullet.)
#   ③ 同 epic 孤儿:        FU-EPIC.* prefix, status open, but target ≠ this story
#                          (informational — what other Story X.* items in epic)
#
# Used by:
#   - solo-dev manual query: `just deferred-status STORY=2-5`
#   - run-sprint stage 5 echo extension
#
# Usage:
#   grep_deferred_status.sh <story-key> [path/to/deferred-work.md]
#
# Exit code: 0 ok / 1 bad arg / 2 source missing

set -euo pipefail

usage() {
    echo "usage: $0 <story-key> [path/to/deferred-work.md]" >&2
    exit 1
}

[ $# -ge 1 ] || usage
RAW_KEY="$1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh"
DEFAULT_DW="$HARNESS_DEFERRED_WORK_PATH"
DW="${2:-$DEFAULT_DW}"

if [ ! -f "$DW" ]; then
    echo "ERROR: deferred-work.md not found at $DW" >&2
    exit 2
fi

NORMALIZED=$(echo "$RAW_KEY" | sed -E 's/[._]/-/g')
EPIC=$(echo "$NORMALIZED" | awk -F- '{print $1}')
SEQ=$(echo "$NORMALIZED" | awk -F- '{print $2}')

if ! [[ "$EPIC" =~ ^[0-9]+$ ]] || ! [[ "$SEQ" =~ ^[0-9]+$ ]]; then
    echo "ERROR: cannot derive (EPIC, SEQ) from '$RAW_KEY' — expect form 4-1-... / 4-1 / 4.1" >&2
    exit 1
fi

exec python3 - "$DW" "$EPIC" "$SEQ" "$RAW_KEY" <<'PYEOF'
"""Schema v1 story-perspective deferred-work status."""
from __future__ import annotations

import re
import sys
from pathlib import Path

DW = Path(sys.argv[1])
EPIC = sys.argv[2]
SEQ = sys.argv[3]
RAW_KEY = sys.argv[4]
SHORT = f"{EPIC}.{SEQ}"

FU_HEAD_RE = re.compile(
    r'^- \*\*(?P<id>FU-[A-Za-z0-9._\-]+)\*\*'
    r'\s+`\[status:(?P<status>[a-z\-]+)\]`'
    r'\s+`\[bucket:(?P<bucket>[a-zA-Z0-9.+\-]+)\]`'
    r'\s+`\[target:(?P<target>[^\]`]*)\]`'
    r'\s+`\[source:(?P<source>[^\]`]*)\]`'
    r'\s*—\s*(?P<desc>.*)$'
)

OPEN_STATUSES = {'pending', 'in-progress', 'partial', 'needs-review'}
CLOSED_STATUSES = {'resolved', 'skipped', 'superseded'}

target_match = f"Story {SHORT}"
fu_id_prefix = f"FU-{SHORT}."

text = DW.read_text(encoding='utf-8')
pending, closed, orphan = [], [], []

for i, line in enumerate(text.split('\n'), start=1):
    m = FU_HEAD_RE.match(line)
    if not m:
        continue
    fu = {
        'id': m.group('id'),
        'status': m.group('status'),
        'target': m.group('target').strip(),
        'desc': m.group('desc')[:80],
        'line': i,
    }
    targets_this_story = (fu['target'] == target_match)
    is_same_epic = fu['id'].startswith(fu_id_prefix) or re.match(rf'^FU-{re.escape(SHORT)}-', fu['id'])

    if targets_this_story:
        if fu['status'] in OPEN_STATUSES:
            pending.append(fu)
        else:
            closed.append(fu)
    elif is_same_epic and fu['status'] in OPEN_STATUSES:
        orphan.append(fu)


def render(items, label):
    print(f'--- {label} ---  count={len(items)}')
    if not items:
        print('  (无)')
        return
    for it in items:
        print(f'  - {it["id"]:35s} status={it["status"]:13s} line {it["line"]:5d}  {it["desc"]}')

print(f'=== Deferred-work status for Story {SHORT} (key={RAW_KEY}) ===')
print(f'Source: {DW}')
print()
render(pending, '① 待消化（target=Story ' + SHORT + ', status open）')
print()
render(closed, '② 已消化（target=Story ' + SHORT + ', status closed）')
print()
render(orphan, '③ 同 epic（FU-' + SHORT + '.*）但 target 非本 story 的 open 条目')
print()
print('--- summary ---')
print(f'Story {SHORT}: 待消化 {len(pending)} / 已消化 {len(closed)} / 同 epic 孤儿 {len(orphan)}')
PYEOF
