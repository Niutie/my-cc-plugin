#!/usr/bin/env bash
# Grep open deferred-work items targeting a single story (schema v1).
#
# Reads schema-tagged FU bullets and emits open items whose `[target:...]`
# field is exactly `Story X.Y` AND whose status is open
# (pending / in-progress / partial / needs-review).
#
# Used by:
#   - run-sprint stage 1 prompt injection (.claude/commands/run.md)
#     surfaces "candidate FU items the new spec should evaluate / merge"
#
# Usage:
#   grep_pending_deferred_for_story.sh <story-key> [path/to/deferred-work.md]
#   grep_pending_deferred_for_story.sh <epic> <story-int> [path/to/deferred-work.md]
#
# story-key forms accepted:
#   - full key:  4-1-detection-rule-engine-core
#   - short:     4-1
#   - dotted:    4.1
#
# Output format (stdout, machine + human readable):
#   FU-X.Y.Z | status: pending | excerpt: <≤80 字>
# >15 hits truncates and appends:
#   ... 完整 N=<count> 条 → bash .claude/harness/scripts/grep_pending_deferred_for_story.sh <key>
#
# Exit code:
#   0 — printed (zero or more matches)
#   1 — bad arg
#   2 — source missing

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

# 2-arg compat (epic-2 retro B5): `<epic> <story>` (e.g. `3 5`) → "3-5".
if [ $# -ge 2 ] && [[ "$RAW_KEY" =~ ^[0-9]+$ ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
    RAW_KEY="${RAW_KEY}-${2}"
    DW="${3:-$DEFAULT_DW}"
else
    DW="${2:-$DEFAULT_DW}"
fi

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
"""Schema v1 — emit open FU items targeting Story X.Y."""
from __future__ import annotations

import re
import sys
from pathlib import Path

DW = Path(sys.argv[1])
EPIC = sys.argv[2]
SEQ = sys.argv[3]
RAW_KEY = sys.argv[4]
SHORT = f"{EPIC}.{SEQ}"
LIMIT = 15

FU_HEAD_RE = re.compile(
    r'^- \*\*(?P<id>FU-[A-Za-z0-9._\-]+)\*\*'
    r'\s+`\[status:(?P<status>[a-z\-]+)\]`'
    r'\s+`\[bucket:(?P<bucket>[a-zA-Z0-9.+\-]+)\]`'
    r'\s+`\[target:(?P<target>[^\]`]*)\]`'
    r'\s+`\[source:(?P<source>[^\]`]*)\]`'
    r'\s*—\s*(?P<desc>.*)$'
)

OPEN_STATUSES = {'pending', 'in-progress', 'partial', 'needs-review'}
target_match = f"Story {SHORT}"

text = DW.read_text(encoding='utf-8')
hits = []
for line in text.split('\n'):
    m = FU_HEAD_RE.match(line)
    if not m:
        continue
    if m.group('status') not in OPEN_STATUSES:
        continue
    if m.group('target').strip() != target_match:
        continue
    desc = m.group('desc').strip()
    if len(desc) > 80:
        desc = desc[:77] + '...'
    hits.append({
        'id': m.group('id'),
        'status': m.group('status'),
        'desc': desc,
    })

if not hits:
    print(f'No open deferred items targeting {RAW_KEY}')
    sys.exit(0)

for h in hits[:LIMIT]:
    print(f'{h["id"]} | status: {h["status"]} | excerpt: "{h["desc"]}"')

if len(hits) > LIMIT:
    print(f'... 完整 N={len(hits)} 条 → bash .claude/harness/scripts/grep_pending_deferred_for_story.sh {RAW_KEY}')
PYEOF
