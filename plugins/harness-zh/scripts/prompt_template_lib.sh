#!/usr/bin/env bash
# prompt_template_lib — sourceable shared prompt-template rendering helper.
#
# Single source of truth for the `${project_display_name}` placeholder
# substitution used by:
#   - scripts/process_retro_residue.sh   (stage 6.5 residue processor)
#   - scripts/backfill_resolved_markers.sh (legacy C12 backfill)
# Both consumers carry an inline fallback copy of render_prompt_template
# (guarded `declare -F`, for partial-deployment skew — same convention as
# lint_deferred_work.sh's DWSL_* inline fallback). Changing the function here
# REQUIRES updating both inline copies.
#
# Before review 2026-06-10 #50 the two scripts each carried a copied
# `sed "s/.../${VAL//\//\\/}/g"` that only escaped `/` — a display name
# containing `&` rendered the literal matched text back (`Foo & Bar` →
# `Foo ${project_display_name} Bar`), and `\1`-style backslash sequences
# crashed sed entirely (set -e → whole prompt generation aborted).
#
# Implementation note: awk index()/substr() splicing — *literal* string
# replacement, no regex / sed-replacement metacharacter interpretation.
# The value is passed via ENVIRON (not `awk -v`) because -v applies escape
# processing to backslashes; ENVIRON delivers bytes verbatim.
#
# This file is `source`d, so it MUST NOT use `set -e` / `set -u` (would
# force the caller's behavior). It only defines functions.

# render_prompt_template <template-path> <display-name>
# Streams <template-path> to stdout with every literal occurrence of
# `${project_display_name}` replaced by <display-name> (verbatim — safe for
# `&`, `\`, `/`, quotes, CJK). Returns awk's exit code (non-zero if the
# template file is unreadable — caller's set -e handles it).
render_prompt_template() {
    local _ptl_template="$1"
    local _ptl_name="${2:-}"
    HZH_PTL_DISPLAY_NAME="$_ptl_name" awk '
        BEGIN {
            repl = ENVIRON["HZH_PTL_DISPLAY_NAME"]
            ph = "${project_display_name}"
            plen = length(ph)
        }
        {
            line = $0
            out = ""
            while ((i = index(line, ph)) > 0) {
                out = out substr(line, 1, i - 1) repl
                line = substr(line, i + plen)
            }
            print out line
        }
    ' "$_ptl_template"
}
