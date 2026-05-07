#!/usr/bin/env bash
# Detect category:harness entries in sprint-status.yaml retro_action_items block
# that have NOT yet been migrated to .claude/harness/upstream-feedback.md.
#
# Used at /harness-zh:init §A.3.d (mid-project install detection) to decide
# whether to prompt user for migration. Also called as preview by
# extract_harness_feedback.sh --dry-run.
#
# Output (stdout, single-line JSON):
#   {"file_present": bool, "path": "...", "count": N,
#    "items": [{"epic": "epic-5-retro", "code": "E1", "status": "pending",
#                "category": "harness", "description": "...optional inline comment...",
#                "chore_spec": "..."}]}
#
# "Migrated" entries are detected by looking for the special status value
# "migrated-upstream" — the migration tool sets this. Items with that status
# are NOT included in the JSON (they've been processed already).
#
# Exit code:
#   0 — file present, JSON emitted (count may be 0)
#   2 — sprint-status.yaml missing
#   3 — retro_action_items block missing in sprint-status.yaml
#
# Usage:
#   bash .claude/harness/scripts/detect_harness_residue.sh
#   bash .claude/harness/scripts/detect_harness_residue.sh path/to/sprint-status.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh"

SS_PATH="${1:-$HARNESS_SPRINT_STATUS_PATH}"

if [ ! -f "$SS_PATH" ]; then
    printf '{"file_present": false, "path": "%s", "count": 0, "items": []}\n' "$SS_PATH"
    exit 2
fi

if ! grep -qE "^retro_action_items:" "$SS_PATH"; then
    printf '{"file_present": true, "path": "%s", "count": 0, "items": [], "note": "retro_action_items block missing"}\n' "$SS_PATH"
    exit 3
fi

exec python3 - "$SS_PATH" <<'PYEOF'
"""Scan retro_action_items block for unmigrated category:harness items."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# Yaml shape:
#   retro_action_items:
#     epic-N-retro:
#       <CODE>: <status>     # optional inline comment / description
#         category: <dev|harness>
#         chore_spec: '<filename>'   # optional
#
# Indents: 2-space "epic-...:", 4-space "<CODE>: <status>", 6-space sub-fields.
# Tolerant of inline comments and blank lines.

# Locate retro_action_items block (top-level; tolerate trailing top-level keys).
top_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*:")
in_block = False
block_lines: list[str] = []
for line in text.splitlines():
    if line.startswith("retro_action_items:"):
        in_block = True
        continue
    if in_block:
        if line and top_re.match(line):
            break  # next top-level key
        block_lines.append(line)

# Walk block lines; emit items.
items: list[dict] = []
current_epic: str | None = None
current_code: str | None = None
current_status: str | None = None
current_category: str | None = None
current_chore_spec: str | None = None
current_desc: str | None = None  # inline comment after "code: status"

epic_re = re.compile(r"^  ([A-Za-z][A-Za-z0-9_-]+):\s*(?:#.*)?$")
code_re = re.compile(r"^    ([A-Za-z][A-Za-z0-9-]*):\s*([A-Za-z][A-Za-z0-9-]*)\s*(?:#\s*(.*?))?\s*$")
field_re = re.compile(r"^      ([a-z_]+):\s*'?([^'#]*?)'?\s*(?:#.*)?$")


def flush() -> None:
    if (
        current_epic
        and current_code
        and current_category == "harness"
        and current_status != "migrated-upstream"
    ):
        items.append(
            {
                "epic": current_epic,
                "code": current_code,
                "status": current_status,
                "category": current_category,
                "description": current_desc or "",
                "chore_spec": current_chore_spec or "",
            }
        )


for line in block_lines:
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    m = epic_re.match(line)
    if m:
        flush()
        current_epic = m.group(1)
        current_code = None
        current_status = None
        current_category = None
        current_chore_spec = None
        current_desc = None
        continue
    m = code_re.match(line)
    if m and current_epic:
        flush()
        current_code = m.group(1)
        current_status = m.group(2)
        desc = (m.group(3) or "").strip()
        current_desc = desc
        current_category = None
        current_chore_spec = None
        continue
    m = field_re.match(line)
    if m and current_code:
        key, value = m.group(1), m.group(2).strip()
        if key == "category":
            current_category = value
        elif key == "chore_spec":
            current_chore_spec = value

# Final flush after loop.
flush()

result = {
    "file_present": True,
    "path": str(path),
    "count": len(items),
    "items": items,
}
print(json.dumps(result, ensure_ascii=False))
PYEOF
