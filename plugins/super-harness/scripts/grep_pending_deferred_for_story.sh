#!/usr/bin/env bash
# Grep open deferred-work items for a story or an epic (schema v1).
#
# Open = status ∈ {pending, in-progress, partial, needs-review}.
#
# Story mode (B0 injection, `pipeline.md`):
#   1. open items whose `[target:...]` is exactly `Story X.Y`
#   2. open items whose target is exactly `Epic X` (the story's own epic) —
#      build-sync imports spec `deferred:` items with `[target:Epic N]`, so
#      without this section nothing would ever surface them to a later story
#      (0.3.3). Items this story deferred itself (`[source:*-of-X.Y]`) are
#      left out: re-injecting them on a resume would just loop.
#
# Epic mode (stage ⑥ retro triage, `bmad-retrospective-suffix.md`):
#   open items whose target is `Epic M` with M ≤ N — the retro of epic N
#   re-targets what this epic left behind, plus any leftovers of earlier
#   epics whose retro ran before 0.3.3 introduced the triage step.
#
# Usage:
#   grep_pending_deferred_for_story.sh <story-key> [path/to/deferred-work.md]
#   grep_pending_deferred_for_story.sh <epic> <story-int> [path/to/deferred-work.md]
#   grep_pending_deferred_for_story.sh --epic <N> [path/to/deferred-work.md]
#
# story-key forms accepted:
#   - full key:  4-1-detection-rule-engine-core
#   - short:     4-1
#   - dotted:    4.1
#
# Output format, story mode (stdout, machine + human readable):
#   FU-X.Y.Z | status: pending | excerpt: <≤80 字>          (Story X.Y 命中，≤15 行)
#   ... 完整 N=<count> 条 → bash .claude/harness/scripts/grep_pending_deferred_for_story.sh <key>
#   [epic-backlog] Epic X 遗留 …：                          (有同 epic 遗留时才出现)
#   FU-X.W.B1 | status: pending | excerpt: <≤80 字>         (≤10 行)
#   ... Epic X 遗留共 N=<count> 条 → bash … --epic X
# Neither section has hits → single line `No open deferred items targeting <key>`.
#
# Output format, epic mode (no truncation):
#   FU-X.Y.Z | status: pending | target: Epic M | source: <O> | excerpt: <≤80 字>
# No hits → `No open deferred items targeting Epic 1..N`.
#
# Exit code:
#   0 — printed (zero or more matches)
#   1 — bad arg
#   2 — source missing

set -euo pipefail

usage() {
    echo "usage: $0 <story-key> [path/to/deferred-work.md]" >&2
    echo "       $0 --epic <N> [path/to/deferred-work.md]" >&2
    exit 1
}

[ $# -ge 1 ] || usage

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh"
DEFAULT_DW="$HARNESS_DEFERRED_WORK_PATH"

if [ "$1" = "--epic" ]; then
    [ $# -ge 2 ] || usage
    MODE="epic"
    EPIC="$2"
    SEQ=""
    RAW_KEY="Epic $2"
    DW="${3:-$DEFAULT_DW}"
    if ! [[ "$EPIC" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --epic expects a number, got '$EPIC'" >&2
        exit 1
    fi
else
    MODE="story"
    RAW_KEY="$1"
    # 2-arg compat (epic-2 retro B5): `<epic> <story>` (e.g. `3 5`) → "3-5".
    if [ $# -ge 2 ] && [[ "$RAW_KEY" =~ ^[0-9]+$ ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
        RAW_KEY="${RAW_KEY}-${2}"
        DW="${3:-$DEFAULT_DW}"
    else
        DW="${2:-$DEFAULT_DW}"
    fi
fi

if [ ! -f "$DW" ]; then
    echo "ERROR: deferred-work.md not found at $DW" >&2
    exit 2
fi

if [ "$MODE" = "story" ]; then
    NORMALIZED=$(echo "$RAW_KEY" | sed -E 's/[._]/-/g')
    EPIC=$(echo "$NORMALIZED" | awk -F- '{print $1}')
    SEQ=$(echo "$NORMALIZED" | awk -F- '{print $2}')

    if ! [[ "$EPIC" =~ ^[0-9]+$ ]] || ! [[ "$SEQ" =~ ^[0-9]+[a-z]?$ ]]; then   # 124-4b-…: BMad allows a letter suffix
        echo "ERROR: cannot derive (EPIC, SEQ) from '$RAW_KEY' — expect form 4-1-... / 4-1 / 4.1" >&2
        exit 1
    fi
fi

exec python3 - "$DW" "$MODE" "$EPIC" "$SEQ" "$RAW_KEY" <<'PYEOF'
"""Schema v1 — emit open FU items for Story X.Y (+ Epic X backlog) or Epic ≤N."""
from __future__ import annotations

import re
import sys
from pathlib import Path

DW = Path(sys.argv[1])
MODE = sys.argv[2]
EPIC = sys.argv[3]
SEQ = sys.argv[4]
RAW_KEY = sys.argv[5]
STORY_LIMIT = 15
EPIC_BACKLOG_LIMIT = 10
SCRIPT = 'bash .claude/harness/scripts/grep_pending_deferred_for_story.sh'

FU_HEAD_RE = re.compile(
    r'^- \*\*(?P<id>FU-[A-Za-z0-9._\-]+)\*\*'
    r'\s+`\[status:(?P<status>[a-z\-]+)\]`'
    r'\s+`\[bucket:(?P<bucket>[a-zA-Z0-9.+\-]+)\]`'
    r'\s+`\[target:(?P<target>[^\]`]*)\]`'
    r'\s+`\[source:(?P<source>[^\]`]*)\]`'
    r'\s*—\s*(?P<desc>.*)$'
)
EPIC_TARGET_RE = re.compile(r'^Epic (\d+)$')

OPEN_STATUSES = {'pending', 'in-progress', 'partial', 'needs-review'}


def excerpt(desc: str) -> str:
    desc = desc.strip()
    return desc[:77] + '...' if len(desc) > 80 else desc


items = []
for line in DW.read_text(encoding='utf-8').split('\n'):
    m = FU_HEAD_RE.match(line)
    if not m or m.group('status') not in OPEN_STATUSES:
        continue
    items.append({
        'id': m.group('id'),
        'status': m.group('status'),
        'target': m.group('target').strip(),
        'source': m.group('source').strip(),
        'desc': excerpt(m.group('desc')),
    })


def row(h):
    return f'{h["id"]} | status: {h["status"]} | excerpt: "{h["desc"]}"'


if MODE == 'epic':
    limit = int(EPIC)
    hits = []
    for h in items:
        em = EPIC_TARGET_RE.match(h['target'])
        if em and int(em.group(1)) <= limit:
            hits.append(h)
    if not hits:
        print(f'No open deferred items targeting Epic 1..{EPIC}')
        sys.exit(0)
    for h in hits:
        print(f'{h["id"]} | status: {h["status"]} | target: {h["target"]} | '
              f'source: {h["source"]} | excerpt: "{h["desc"]}"')
    sys.exit(0)

SHORT = f"{EPIC}.{SEQ}"
story_hits = [h for h in items if h['target'] == f'Story {SHORT}']
own_source = f'-of-{SHORT}'
epic_hits = [h for h in items
             if h['target'] == f'Epic {EPIC}' and not h['source'].endswith(own_source)]

if not story_hits and not epic_hits:
    print(f'No open deferred items targeting {RAW_KEY}')
    sys.exit(0)

for h in story_hits[:STORY_LIMIT]:
    print(row(h))
if len(story_hits) > STORY_LIMIT:
    print(f'... 完整 N={len(story_hits)} 条 → {SCRIPT} {RAW_KEY}')

if epic_hits:
    print(f'[epic-backlog] Epic {EPIC} 遗留（target:Epic {EPIC}，没指定 story；'
          f'只在本 story 自然范围内顺手处理，其余留给 epic retro 分诊）：')
    for h in epic_hits[:EPIC_BACKLOG_LIMIT]:
        print(row(h))
    if len(epic_hits) > EPIC_BACKLOG_LIMIT:
        print(f'... Epic {EPIC} 遗留共 N={len(epic_hits)} 条 → {SCRIPT} --epic {EPIC}')
PYEOF
