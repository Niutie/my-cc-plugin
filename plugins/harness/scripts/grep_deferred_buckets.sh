#!/usr/bin/env bash
# Mechanically tally open FU bullets in deferred-work.md by bucket (schema v1).
#
# Reads schema-tagged bullets (`- **FU-X.Y.Z** [status:...] [bucket:...]
# [target:...] [source:...] — desc`) and aggregates open items per bucket.
#
# Buckets (schema v1 §3.2; mutually exclusive):
#   epic-6 / v0.2+ / v1.0+ / v2.0+ / sandbox / cross-story / test-harness / other
#
# Hard thresholds (per Epic 2 retro B6 + Epic 3 retro C5):
#   epic-6        30
#   v0.2+         40
#   v1.0+ + v2.0+ 30  (合并口径)
#   sandbox       25
# cross-story / test-harness / other 无 hard threshold (open 计入但不算债).
#
# Status semantics:
#   OPEN   = pending | in-progress | partial | needs-review
#   CLOSED = resolved | skipped | superseded
#
# Usage: grep_deferred_buckets.sh [--list] [--json] [--show-resolved] [--emit-section1] [path/to/deferred-work.md]
#
# Flags:
#   --list           print each open FU id + bucket + line in trailing section
#   --json           machine-readable output instead of human-readable text
#   --show-resolved  augment per-bucket display with pending/total/resolved/needs-review
#   --emit-section1  emit markdown bucket-table block suitable for replacing the
#                    AUTO-GENERATED-BUCKETS section in deferred-work.md §1
#
# Exit code:
#   0 — within all thresholds
#   1 — at least one threshold breached
#   2 — source file missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh"
DEFAULT_PATH="$HARNESS_DEFERRED_WORK_PATH"

exec python3 - "$DEFAULT_PATH" "$@" <<'PYEOF'
"""Schema v1 bucket tally for deferred-work.md."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

DEFAULT_PATH = sys.argv[1]
RAW_ARGS = sys.argv[2:]

# Schema v1 bullet head:
#   - **FU-X.Y.Z** `[status:...]` `[bucket:...]` `[target:...]` `[source:...]` — desc
FU_HEAD_RE = re.compile(
    r'^- \*\*(?P<id>FU-[A-Za-z0-9._\-]+)\*\*'
    r'\s+`\[status:(?P<status>[a-z\-]+)\]`'
    r'\s+`\[bucket:(?P<bucket>[a-zA-Z0-9.+\-]+)\]`'
    r'\s+`\[target:(?P<target>[^\]`]*)\]`'
    r'\s+`\[source:(?P<source>[^\]`]*)\]`'
)

# OPEN status values (count toward bucket totals)
OPEN_STATUSES = {'pending', 'in-progress', 'partial', 'needs-review'}
# CLOSED status values (excluded from open count)
CLOSED_STATUSES = {'resolved', 'skipped', 'superseded'}

# Buckets with hard thresholds (per Epic 2 retro B6 + Epic 3 retro C5)
THRESHOLDS = {
    'epic-6': 30,
    'v0.2+': 40,
    'v1.0+': 30,    # combined v1.0+ + v2.0+
    'sandbox': 25,
}

# Display order (v2.0+ is a real schema bucket; merged with v1.0+ for threshold)
BUCKET_ORDER = ['epic-6', 'v0.2+', 'v1.0+', 'v2.0+', 'sandbox', 'cross-story', 'test-harness', 'other']

LABELS = {
    'epic-6': 'Epic 6 production lockdown / hardening',
    'v0.2+': 'v0.2+ 真增量',
    'v1.0+': 'v1.0+ / FR68/69/70/77',
    'v2.0+': 'v2.0+ 真增量',
    'sandbox': 'sandbox-bound (docker-daemon-locked 操作员复跑)',
    'cross-story': 'cross-story (待下游 Story 自然消化)',
    'test-harness': 'test-harness (FU-Test-* 流水线产物)',
    'other': 'other (客户反馈触发 / stale-residual / 未分类)',
}


def parse_bullets(text):
    """Yield {id, status, bucket, target, source, line} per FU bullet."""
    bullets = []
    for i, line in enumerate(text.split('\n'), start=1):
        m = FU_HEAD_RE.match(line)
        if not m:
            continue
        bullets.append({
            'id': m.group('id'),
            'status': m.group('status'),
            'bucket': m.group('bucket'),
            'target': m.group('target').strip(),
            'source': m.group('source').strip(),
            'line': i,
        })
    return bullets


def main():
    want_list = '--list' in RAW_ARGS
    want_json = '--json' in RAW_ARGS
    show_resolved = '--show-resolved' in RAW_ARGS
    emit_section1 = '--emit-section1' in RAW_ARGS
    flags = {'--list', '--json', '--show-resolved', '--emit-section1'}
    positional = [a for a in RAW_ARGS if a not in flags]
    path = Path(positional[0]) if positional else Path(DEFAULT_PATH)

    if not path.exists():
        print(f'ERROR: {path} not found', file=sys.stderr)
        return 2

    text = path.read_text(encoding='utf-8')
    bullets = parse_bullets(text)

    # initialize counters
    open_counts = {b: 0 for b in BUCKET_ORDER}
    closed_counts = {b: 0 for b in BUCKET_ORDER}
    needs_review_counts = {b: 0 for b in BUCKET_ORDER}
    open_items = []
    unknown_status = []
    unknown_bucket = []

    for b in bullets:
        status, bucket = b['status'], b['bucket']
        if bucket not in open_counts:
            unknown_bucket.append(b)
            bucket = 'other'
        if status not in OPEN_STATUSES and status not in CLOSED_STATUSES:
            unknown_status.append(b)
            continue
        if status in OPEN_STATUSES:
            open_counts[bucket] += 1
            if status == 'needs-review':
                needs_review_counts[bucket] += 1
            open_items.append({**b, 'bucket': bucket})
        else:
            closed_counts[bucket] += 1

    # threshold check (v1.0+ and v2.0+ merged for threshold purposes)
    def threshold_count(k):
        if k == 'v1.0+':
            return open_counts['v1.0+'] + open_counts.get('v2.0+', 0)
        return open_counts[k]

    breaches = [k for k, t in THRESHOLDS.items() if threshold_count(k) > t]

    open_total = sum(open_counts.values())
    closed_total = sum(closed_counts.values())
    needs_review_total = sum(needs_review_counts.values())

    def total_for(k):
        return open_counts[k] + closed_counts[k]

    def resolved_pct_for(k):
        m = total_for(k)
        if m == 0:
            return 0.0
        return closed_counts[k] * 100.0 / m

    # --- emit-section1: markdown block for §1 AUTO-GENERATED-BUCKETS ---
    if emit_section1:
        lines = []
        lines.append('| 类别 | 当前 open 数 | hard threshold | 状态 |')
        lines.append('|---|---:|---:|---|')
        # threshold rows
        for k in ('epic-6', 'v0.2+', 'v1.0+', 'sandbox'):
            tc = threshold_count(k)
            t = THRESHOLDS[k]
            if tc > t:
                marker = f'🔴 BREACHED (超 {round((tc-t)*100/t)}%)'
                tc_disp = f'**{tc}**'
            else:
                marker = '🟢 within'
                tc_disp = str(tc)
            label = LABELS[k]
            if k == 'v1.0+':
                # show "v1.0+ + v2.0+" composition if v2.0+ has any
                v2 = open_counts.get('v2.0+', 0)
                if v2 > 0:
                    label += f'（{open_counts["v1.0+"]} v1.0+ + {v2} v2.0+）'
            lines.append(f'| {label} | {tc_disp} | {t} | {marker} |')
        # non-threshold rows (v2.0+ already counted under v1.0+ threshold; skip its row)
        for k in ('cross-story', 'test-harness', 'other'):
            lines.append(f'| {LABELS[k]} | {open_counts[k]} | — | — |')
        lines.append(f'| **open total** | **{open_total}** | — | — |')
        lines.append(f'| closed (resolved / skipped / superseded) | {closed_total} | — | — |')
        if needs_review_total > 0:
            lines.append(f'| needs-review (trigger story done + 0 evidence) | {needs_review_total} | — | included in open |')

        lines.append('')
        lines.append(f'**Reproduce**：`bash .claude/harness/scripts/grep_deferred_buckets.sh` (`exit 0` = 全 within；`exit 1` = 至少一类 breached；`exit 2` = source missing)。`--list` 输出每类下具体 FU IDs；`--json` 机器可读；`--emit-section1` 输出本表 markdown。')
        if breaches:
            lines.append('')
            lines.append(f'**当前 breach 类别**：{" / ".join(breaches)}（详 §1.1+ critical evaluation）。')
        for ln in lines:
            print(ln)
        return 1 if breaches else 0

    # --- json output ---
    if want_json:
        payload = {
            'path': str(path),
            'unique_bullets': len(bullets),
            'open_total': open_total,
            'closed_total': closed_total,
            'needs_review_total': needs_review_total,
            'open_counts': open_counts,
            'closed_counts': closed_counts,
            'needs_review_counts': needs_review_counts,
            'thresholds': THRESHOLDS,
            'breaches': breaches,
            'unknown_status': [b['id'] for b in unknown_status],
            'unknown_bucket': [b['id'] for b in unknown_bucket],
            'items': open_items if want_list else None,
        }
        if show_resolved:
            payload['totals'] = {k: total_for(k) for k in open_counts}
            payload['resolved_pct'] = {k: round(resolved_pct_for(k), 1) for k in open_counts}
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 1 if breaches else 0

    # --- human-readable text output ---
    print('=== Deferred Work Bucket Tally (schema v1) ===')
    print(f'Source: {path}')
    print(f'Total FU bullets parsed: {len(bullets)}')
    print(f'  open  (pending / in-progress / partial / needs-review): {open_total}')
    print(f'  closed (resolved / skipped / superseded):               {closed_total}')
    if unknown_status:
        print(f'  ⚠  unknown status (skipped): {len(unknown_status)} — {[b["id"] for b in unknown_status]}')
    if unknown_bucket:
        print(f'  ⚠  unknown bucket (treated as other): {len(unknown_bucket)} — {[b["id"] for b in unknown_bucket]}')
    print()
    print('--- Open by bucket ---')
    for k in BUCKET_ORDER:
        threshold_str = ''
        if k in THRESHOLDS:
            tc = threshold_count(k)
            threshold_str = f'  hard threshold = {THRESHOLDS[k]}'
        if show_resolved:
            line = (
                f'  {LABELS[k]:55s} pending={open_counts[k]:3d}/total={total_for(k):3d} '
                f'(resolved={closed_counts[k]:3d}, '
                f'needs-review={needs_review_counts[k]:3d}, '
                f'{resolved_pct_for(k):5.1f}%){threshold_str}'
            )
        else:
            line = f'  {LABELS[k]:55s} {open_counts[k]:4d}  {threshold_str}'
        print(line)
    if show_resolved:
        print()
        print(f'  needs-review total (trigger story done + 0 evidence — solo-dev decision pending): {needs_review_total}')
    print()
    print('--- Threshold breach status ---')
    for k in ('epic-6', 'v0.2+', 'v1.0+', 'sandbox'):
        tc = threshold_count(k)
        t = THRESHOLDS[k]
        breached = tc > t
        marker = f'BREACHED — critical evaluation required' if breached else 'within threshold'
        comp = ''
        if k == 'v1.0+' and open_counts.get('v2.0+', 0) > 0:
            comp = f' ({open_counts["v1.0+"]} v1.0+ + {open_counts["v2.0+"]} v2.0+)'
        print(f'  {LABELS[k]:55s} {tc:4d} / {t}{comp}  → {marker}')

    if want_list:
        print()
        print('--- Open items per bucket (id : line) ---')
        for bucket in BUCKET_ORDER:
            items = [it for it in open_items if it['bucket'] == bucket]
            if not items:
                continue
            print(f'\n[{bucket}] ({len(items)} items)')
            for it in items:
                print(f'  {it["id"]:35s} status={it["status"]:13s} target={it["target"]:35s} line {it["line"]}')

    return 1 if breaches else 0


sys.exit(main())
PYEOF
