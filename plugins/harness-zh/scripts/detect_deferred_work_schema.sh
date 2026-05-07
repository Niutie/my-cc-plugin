#!/usr/bin/env bash
# Detect schema-v1 conformance of the project's deferred-work.md.
#
# Used at /harness-zh:init §A.3.c (mid-project install detection) and
# /harness-zh:upgrade-deferred-work (post-init upgrade entry) to decide whether
# the existing deferred-work.md needs upgrade / archive / advisory-coexistence.
#
# Output (stdout, single-line JSON):
#   {"file_present": bool, "path": "...", "fu_total": N, "fu_v1": M,
#    "fu_legacy_head": K, "fu_legacy_inline_resolved": L,
#    "fu_retro_namespace": P, "v1_pct": 0.0..1.0,
#    "classification": "pristine"|"v1_clean"|"mixed"|"legacy"}
#
# Classification rules:
#   pristine — file present but no FU bullets (just-bootstrapped template state)
#   v1_clean — fu_total > 0 AND v1_pct >= 0.95
#   legacy   — fu_total > 0 AND v1_pct == 0
#   mixed    — fu_total > 0 AND 0 < v1_pct < 0.95
#
# Exit code:
#   0 — file present, classification emitted
#   2 — file missing (init §A.3.b should have bootstrapped; investigate)
#
# Usage:
#   bash .claude/harness/scripts/detect_deferred_work_schema.sh
#   bash .claude/harness/scripts/detect_deferred_work_schema.sh path/to/deferred-work.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh"

DW_PATH="${1:-$HARNESS_DEFERRED_WORK_PATH}"

if [ ! -f "$DW_PATH" ]; then
    printf '{"file_present": false, "path": "%s"}\n' "$DW_PATH"
    exit 2
fi

exec python3 - "$DW_PATH" <<'PYEOF'
"""Schema v1 conformance detector for deferred-work.md."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# FU bullet head — any line starting with `- **FU-...**`
fu_head_re = re.compile(r"^- \*\*FU-[A-Za-z0-9._\-]+\*\*", re.MULTILINE)
# Schema v1 4-tag head — must match pre-commit hook gate ② regex exactly
v1_head_re = re.compile(
    r"^- \*\*FU-[A-Za-z0-9._\-]+\*\* "
    r"`\[status:[a-z\-]+\]` "
    r"`\[bucket:[a-zA-Z0-9.+\-]+\]` "
    r"`\[target:[^]`]*\]` "
    r"`\[source:[^]`]*\]`",
    re.MULTILINE,
)
# Legacy inline status suffix — pre-schema-v1 pattern
legacy_inline_re = re.compile(
    r"— (\*\*)?(Resolved|Partial resolution) by Story [0-9.]+",
)
# FU-RETRO-* namespace (schema v1 §3.2 forbids in deferred-work.md)
retro_ns_re = re.compile(r"^- \*\*FU-RETRO-", re.MULTILINE)

fu_total = len(fu_head_re.findall(text))
fu_v1 = len(v1_head_re.findall(text))
fu_legacy_head = fu_total - fu_v1
fu_legacy_inline_resolved = len(legacy_inline_re.findall(text))
fu_retro_namespace = len(retro_ns_re.findall(text))

if fu_total == 0:
    classification = "pristine"
    v1_pct = 1.0
else:
    v1_pct = fu_v1 / fu_total
    if v1_pct >= 0.95:
        classification = "v1_clean"
    elif v1_pct == 0.0:
        classification = "legacy"
    else:
        classification = "mixed"

result = {
    "file_present": True,
    "path": str(path),
    "fu_total": fu_total,
    "fu_v1": fu_v1,
    "fu_legacy_head": fu_legacy_head,
    "fu_legacy_inline_resolved": fu_legacy_inline_resolved,
    "fu_retro_namespace": fu_retro_namespace,
    "v1_pct": round(v1_pct, 4),
    "classification": classification,
}
print(json.dumps(result, ensure_ascii=False))
PYEOF
