#!/usr/bin/env bash
# deferred_work_schema_lib — sourceable shared schema validation primitives.
#
# Single source of truth for the regexes + per-line validators used by:
#   - git-hooks/pre-commit gate ② (scans only ADDED lines from staged diff)
#   - scripts/lint_deferred_work.sh (scans the entire file)
#
# Before v0.1.27 these two scanners each carried their own copies of the 4
# regexes (HEAD_FULL_RE / TARGET_VALID_RE / STATUS_VALID_RE / LEGACY_INLINE_RE)
# — drift between them was a documented codex-review concern. This lib makes
# them one set; the two scanners differ only in what subset of lines they
# feed in.
#
# Schema authoritative reference: .claude/harness/conventions/deferred-work-schema.md
#
# Usage:
#   source $SCRIPT_DIR/deferred_work_schema_lib.sh
#   _dwsl_target_valid "$value" && echo ok || echo BAD
#
# This file is `source`d, so it MUST NOT use `set -e` / set -u (would force
# the caller's behavior). It only defines functions + constants.

# Regex constants (POSIX ERE, used with `grep -E`).
# Exported so calling scripts can also use them directly if needed.
DWSL_HEAD_FULL_RE='^- \*\*FU-[A-Za-z0-9._\-]+\*\* `\[status:[a-z\-]+\]` `\[bucket:[a-zA-Z0-9.+\-]+\]` `\[target:[^]`]*\]` `\[source:[^]`]*\]`'
DWSL_TARGET_VALID_RE='^(Story [0-9]+\.[0-9]+([.-][A-Za-z0-9]+)?|Epic [0-9]+( [A-Za-z][A-Za-z0-9 -]*)?|v[0-9]+\.[0-9]+\+ [A-Za-z][A-Za-z0-9-]+|customer-feedback|N/A)$'
DWSL_STATUS_VALID_RE='^(pending|in-progress|partial|resolved|deferred|needs-review|superseded)$'
DWSL_LEGACY_INLINE_RE='— (\*\*)?(Resolved|Partial resolution) by Story [0-9.]+(\*\*)? \([0-9]{4}-'
DWSL_FU_HEAD_PREFIX_RE='^- \*\*FU-'
DWSL_FU_RETRO_PREFIX_RE='^- \*\*FU-RETRO-'

# _dwsl_is_fu_head_line <line>
# Returns 0 if line starts with `- **FU-`, else 1.
_dwsl_is_fu_head_line() {
    printf '%s' "$1" | grep -qE "$DWSL_FU_HEAD_PREFIX_RE"
}

# _dwsl_is_fu_retro_line <line>
# Returns 0 if line is in the FU-RETRO-* namespace (forbidden).
_dwsl_is_fu_retro_line() {
    printf '%s' "$1" | grep -qE "$DWSL_FU_RETRO_PREFIX_RE"
}

# _dwsl_has_4tag_head <line>
# Returns 0 if line carries the full schema v1 4-tag block.
_dwsl_has_4tag_head() {
    printf '%s' "$1" | grep -qE "$DWSL_HEAD_FULL_RE"
}

# _dwsl_extract_target <line>
# Echoes the [target:...] value (without brackets/backticks). Empty on miss.
_dwsl_extract_target() {
    printf '%s' "$1" | sed -nE 's/.*`\[target:([^]`]*)\]`.*/\1/p'
}

# _dwsl_extract_status <line>
# Echoes the [status:...] value.
_dwsl_extract_status() {
    printf '%s' "$1" | sed -nE 's/.*`\[status:([^]`]*)\]`.*/\1/p'
}

# _dwsl_target_valid <value>
# Returns 0 if value matches schema §3.3 enumeration.
_dwsl_target_valid() {
    printf '%s' "$1" | grep -qE "$DWSL_TARGET_VALID_RE"
}

# _dwsl_status_valid <value>
# Returns 0 if value matches schema §3.1 enumeration.
_dwsl_status_valid() {
    printf '%s' "$1" | grep -qE "$DWSL_STATUS_VALID_RE"
}

# _dwsl_has_legacy_inline <line>
# Returns 0 if line contains the deprecated inline "Resolved by Story X.Y" suffix.
_dwsl_has_legacy_inline() {
    printf '%s' "$1" | grep -qE "$DWSL_LEGACY_INLINE_RE"
}
