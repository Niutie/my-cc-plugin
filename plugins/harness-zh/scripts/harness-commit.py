#!/usr/bin/env python3
"""
harness-commit.py — sprint pipeline commit helper.

Implements §-1.d (commit protocol) + §0.5 (path expected-output table)
from .claude/commands/run.md, so the main agent doesn't have to
hand-walk the rules every commit.

Usage:
    python3 .claude/harness/scripts/harness-commit.py <stage> <key> [--epic <num>] [--dry-run]

stage ∈ {1, 2, 3, 4, 5, 5-5, 5-fallback, 6, 6-5, 6-done, T1, T3, T4}

Stage taxonomy:
    1..5 / 5-fallback / 6 / 6-5 / 6-done — run-sprint pipeline (story dev → epic retro)
    5-5                                  — run-sprint stage 5.5 test-harness invocation
                                            (atdd + e2e per-story; sandbox graceful skip)
    T1 / T3 / T4                         — run-test-sprint independent stages
                                            (epic test-design / atdd / e2e automate)

Behavior:
    1. List worktree changes (git status --porcelain -uall -z; -uall expands
       untracked directories into individual files so blacklist scanning
       sees every new file — review 2026-06-10 finding #1; -z yields raw
       NUL-delimited paths so quotes/newlines/` -> ` in filenames can't be
       mis-parsed — finding #79).
    1b. Drop junk-tier files (.DS_Store / *.tmp / *.swp / __pycache__ /
       *.pyc) that are NOT in HEAD from the working set: never staged, never
       a halt — one `NOTE: skipped junk file: <path>` line on stderr each.
       Tracked paths (in HEAD) are never junk-filtered (R1 regression fix).
    2. Run global blacklist scan (§-1.d step 2) — credential/secret files +
       protected harness/BMad infra paths. Any hit → halt.
    3. Run cross-story isolation scan on _bmad-output/implementation-artifacts/*
       (§-1.d step 3). Any miss → halt.
    4. Classify each changed path against the stage's expected-output spec
       (§0.5 table).
    5. git add -- <path> the union of (expected artifacts ∪ project code).
       Refuses to add paths that fail any rule.
    6. Sanity check: git diff --cached --stat + git status --porcelain -uall
       (must show no unstaged remainders; junk-tier files NOT in HEAD exempt).
    7. Print key=value lines on stdout:
         STATUS=ok|halt|skip
         REASON=<short>
         STAGED=<path>                              (one line per path that was staged)
         BLACKLIST=<path> (<pattern>)                (only on halt — global blacklist hit)
         CROSS_STORY=<path>                          (only on halt — wrong story key)
         OUT_OF_SCOPE_BMAD=<path>                     (only on halt — _bmad-output/ file outside implementation-artifacts/, issue #5)
         UNEXPECTED_ARTIFACT=<path>                  (only on halt — artifact outside spec)
         FORBIDDEN=<path>                            (only on halt — non-artifact in stage that bans them)
         UNSTAGED=<path>                             (only on halt — leftover after add)
         DEV_RESULT_MISSING=<msg>                    (stage 2 halt — dev-result.json missing)
         DEV_RESULT_FAIL_PARSE=<msg>                 (stage 2 halt — JSON parse error)
         DEV_RESULT_FAIL_CHECK=<key>=<status> ...     (stage 2 halt — check field is `fail` or unrecognized)
         DEV_RESULT_STATUS_MISMATCH=json=<x> md=<y>   (stage 2 halt — final_story_status ≠ md Status)
         DEV_RESULT_STATUS_MISSING=<msg>              (stage 2 halt — md missing Status line)
         REVIEW_FINDINGS_MISSING=<msg>                (stage 5 halt — review-findings.json missing)
         REVIEW_FINDINGS_FAIL_PARSE=<msg>             (stage 5 halt — JSON parse error)
         REVIEW_FINDINGS_UNRESOLVED=critical=<n> ...  (stage 5 halt — high/medium/critical unresolved)
         REVIEW_FINDINGS_STATUS_MISMATCH=json=<x> md=<y>  (stage 5 halt)
         REVIEW_FINDINGS_STATUS_MISSING=<msg>         (stage 5 halt — md missing Status line)
         SUGGEST_COMMIT_MSG=<message>                 (only on STATUS=ok — caller commits with this message)
         SUGGEST_TAG=<tag-name>                       (only on STATUS=ok for stages with suggest_tag —
                                                       caller MUST run `git tag <name>` immediately after committing.
                                                       Currently: stage 1 → harness/<key>/stage2-base,
                                                                  stage 5 → harness/<key>/done)
         AUTO_FIXED=<msg>                            (informational — script auto-resolved
                                                      a build-artifact untracked binary by
                                                      unstage+rm+gitignore (Opt 1, harness-
                                                      changelog 2026-05-01 §I), an unexpected
                                                      subagent .md (Opt 2, 2026-05-03 §A), or
                                                      a redundant process-marker .json
                                                      (issue #8, v0.1.39))
         PLANNING_ARTIFACT=<path>                    (informational on STATUS=ok — spec-declared
                                                      planning-artifacts writeback staged with
                                                      this commit via the `planning_artifacts:`
                                                      frontmatter whitelist; issue #9)
         CACHED_STAT=<git diff --cached --stat output>  (only on STATUS=ok)
    8. Exit code:
         0 = ready to commit (caller runs git commit with HEREDOC)
         1 = halt (caller MUST NOT commit; pass output to user verbatim)
         2 = no changes, skip this commit step (only for *-fallback / *-done
             stages where empty worktree is normal)

The script never runs `git commit`. The commit message is suggested but
the actual commit is the main agent's responsibility (so HEREDOC formatting
+ Co-Authored-By: trailer stays consistent with the git-safety protocol
in the system prompt).

Exit code 1 means halt. The main agent must paste this script's stdout
into the §3 halt template verbatim — the diagnostic lines (BLACKLIST=,
CROSS_STORY=, UNEXPECTED_ARTIFACT=, FORBIDDEN=, UNSTAGED=) are designed
to slot into "违反规则" verbatim.
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from harness_config import get_artifacts_root, get_sprint_status_path  # noqa: E402

def _compute_artifacts_dir_str() -> str:
    repo_root = Path(__file__).resolve().parents[3]
    rel = get_artifacts_root().relative_to(repo_root)
    return str(rel) + "/"

# --- Build-artifact auto-fix (Opt 1, see harness-changelog 2026-05-01 §I) ---
#
# Detection: untracked-or-newly-added file directly inside a Go module root
# (any directory containing `go.mod`, including the repo root), name matches
# `[a-z][a-z0-9-]+` (typical Go cmd binary naming), executable bit set,
# size > 1 MB, git-binary content. All criteria must hold to trigger.
#
# When triggered, the script:
#   1. git restore --staged <path>  (unstage if already added)
#   2. os.remove(<path>)            (delete from worktree)
#   3. add `/<full_relative_path>` to repo-root .gitignore  (anchored — won't
#                                    shadow intentional same-named files
#                                    elsewhere in the tree)
#   4. git add -- .gitignore
#   5. emit AUTO_FIXED=binary-blob <path> action=unstaged+rm+gitignored size=<N>MB
#
# Coverage covers `go build` from repo root and from any nested module root
# (e.g. `some-module/some-binary` when go build was run from a nested module).
# The Go-module-root gate keeps false positives narrow: PNG icons stay below
# 1 MB, ML models / sample data live in non-module subdirs, intentional Go
# binaries should be at `bin/` or similar (also outside module roots).
BUILD_ARTIFACT_NAME_RE = re.compile(r"^[a-z][a-z0-9-]+$")
BUILD_ARTIFACT_MIN_SIZE = 1_000_000  # 1 MB; below this we don't auto-fix


# --- Subagent-spilled artifact auto-prune (Opt 2, harness-changelog 2026-05-03 §A) ---
#
# Detection: untracked-or-newly-added file directly inside
# `_bmad-output/implementation-artifacts/`, name matches `<KEY>.<extra>.md`
# where `<extra>` is one of {bmad-code-review, review-summary, dev-notes,
# review-report}, and the path is NOT in the stage's expected-output spec.
#
# Why these specific extras: bmad-code-review and dev-story BMad workflows
# sometimes emit extra freelance reports alongside the canonical artifacts
# (`<KEY>.review-progress.json` / `<KEY>.review-findings.json`). The review
# content already lives in the story md `### Review Findings` section + the
# progress JSON, so the loose `.md` is redundant noise. Auto-pruning keeps
# the commit clean without involving the user.
#
# Only trips for **untracked / newly-added** paths (xy starts with "?" or
# contains "A"). Modified existing files never auto-delete — that would
# silently revert legitimate edits.
#
# When triggered, the script:
#   1. git restore --staged <path>  (unstage if already added)
#   2. os.remove(<path>)            (delete from worktree)
#   3. emit AUTO_FIXED=unexpected-md <path> action=unstaged+rm extra=<tag>
SUBAGENT_EXTRA_TAGS = ("bmad-code-review", "review-summary", "dev-notes", "review-report")


# --- Process-marker auto-prune (issue #8 / issue #9 finding 3, v0.1.39) ---
#
# Detection: untracked-or-newly-added file at exactly
# `<ARTIFACTS_DIR><KEY>.<tag>.json` where `<tag>` ∈ PROCESS_MARKER_TAGS —
# sandbox/build process markers a dev subagent sometimes spills alongside the
# sanctioned dev-result.json (observed: `<KEY>.maven-skipped.json` recording
# "backend tests skipped, no mvn in sandbox"). The marker's content is fully
# redundant: the skip is already captured by dev-result.json
# `checks.<x>="skip"` + `checks_skip_reasons` (+ a registered FU-Test item),
# so deleting it loses zero information. Same risk tier as the unexpected-md
# prune above (untracked, no credentials, no cross-story reach) — auto-prune
# instead of UNEXPECTED_ARTIFACT halt, per the "halt is reserved for REAL
# danger" red line (review 2026-06-10 findings #1/#7).
#
# The tag set is an EXPLICIT enumeration — never generalize to `*.json` or
# `*-skipped.json`: `<KEY>.codex-skipped.json` and
# `<KEY>.codex-skipped.resolved.json` are schema artifacts (STAGES story_json
# entries) and must never be swallowed. A new marker variant keeps halting
# until it is deliberately added here.
#
# Only untracked / newly-added paths trip; tracked modifications never
# auto-delete (same invariant as the other two auto-fixers).
#
# When triggered, the script:
#   1. git restore --staged <path>  (unstage if already added)
#   2. os.remove(<path>)            (delete from worktree)
#   3. emit AUTO_FIXED=process-marker <path> action=unstaged+rm tag=<tag>
PROCESS_MARKER_TAGS = ("maven-skipped", "sandbox-skipped")


def find_go_module_roots():
    """Return set of dir paths (relative to repo root, "" for root) that
    contain go.mod. Repo root is always included so root-level binaries still
    auto-fix even when there is no top-level go.mod."""
    roots = {""}  # repo root always in scope
    r = run(["git", "ls-files", "--cached", "--others", "--exclude-standard"])
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.endswith("go.mod") and (line == "go.mod" or line.endswith("/go.mod")):
            d = os.path.dirname(line)
            roots.add(d)
    return roots


def detect_build_artifacts(paths):
    """Return list of paths that look like accidental Go build artifacts.

    paths: iterable of (xy, path) from porcelain_paths()
    """
    out = []
    module_roots = find_go_module_roots()
    for xy, p in paths:
        # Must be untracked (??) or newly added (A_ / _A) — never modify existing
        if not (xy.startswith("?") or "A" in xy):
            continue
        # Parent dir must be a Go module root (or repo root)
        parent = os.path.dirname(p)
        if parent not in module_roots:
            continue
        # Must match Go cmd-binary naming: [a-z][a-z0-9-]+ (no extension)
        basename = os.path.basename(p)
        if not BUILD_ARTIFACT_NAME_RE.fullmatch(basename):
            continue
        # Must exist on disk + executable + over size threshold
        try:
            st = os.stat(p)
        except OSError:
            continue
        if not (st.st_mode & 0o111):
            continue
        if st.st_size < BUILD_ARTIFACT_MIN_SIZE:
            continue
        # Final check: git treats as binary (numstat shows `-\t-\t...` for binary)
        r = run(["git", "diff", "--no-index", "--numstat", "/dev/null", p])
        # Note: git diff --no-index returns rc=1 when files differ (which they always do
        # against /dev/null), so we don't check rc — only stdout content.
        first_line = r.stdout.splitlines()[0] if r.stdout else ""
        if not first_line.startswith("-\t-\t"):
            continue
        out.append((p, st.st_size))
    return out


def auto_resolve_build_artifact(path):
    """Unstage + rm + gitignore. Returns size_mb on success, None on failure."""
    try:
        st = os.stat(path)
        size_mb = round(st.st_size / 1_000_000, 1)
    except OSError:
        return None
    # Unstage if currently staged (idempotent — no-op if not staged)
    run(["git", "restore", "--staged", "--", path])
    # Delete from worktree
    try:
        os.remove(path)
    except OSError:
        return None
    # Add anchored pattern to .gitignore
    pattern = f"/{path}"
    gitignore = ".gitignore"
    try:
        with open(gitignore, "r", encoding="utf-8") as f:
            content = f.read()
    except OSError:
        content = ""
    existing_lines = set(line.strip() for line in content.splitlines())
    if pattern not in existing_lines:
        with open(gitignore, "a", encoding="utf-8") as f:
            if content and not content.endswith("\n"):
                f.write("\n")
            f.write(f"# Auto-added by harness-commit: build artifact (Go cmd binary)\n")
            f.write(f"{pattern}\n")
        run(["git", "add", "--", gitignore])
    return size_mb


def detect_subagent_extras(paths, key):
    """Return list of paths that match `<KEY>.<extra>.md` for known extra tags
    AND are untracked/newly-added (xy starts with "?" or contains "A").
    Modified files never trigger auto-prune.
    """
    out = []
    prefix = f"{ARTIFACTS_DIR}{key}."
    for xy, p in paths:
        if not (xy.startswith("?") or "A" in xy):
            continue
        if not p.startswith(prefix):
            continue
        # Must be `<KEY>.<tag>.md` — strip the `<KEY>.` prefix and check
        suffix = p[len(prefix):]
        if not suffix.endswith(".md"):
            continue
        tag = suffix[: -len(".md")]
        if tag in SUBAGENT_EXTRA_TAGS:
            out.append((p, tag))
    return out


def auto_prune_subagent_extra(path):
    """Unstage + rm. Returns True on success, False on failure."""
    run(["git", "restore", "--staged", "--", path])
    try:
        os.remove(path)
    except OSError:
        return False
    return True


def detect_process_markers(paths, key):
    """Return list of (path, tag) for `<KEY>.<tag>.json` process markers
    (tag in PROCESS_MARKER_TAGS) that are untracked/newly-added (xy starts
    with "?" or contains "A"). Tracked modifications never trigger — same
    invariant as detect_subagent_extras."""
    out = []
    prefix = f"{ARTIFACTS_DIR}{key}."
    for xy, p in paths:
        if not (xy.startswith("?") or "A" in xy):
            continue
        if not p.startswith(prefix):
            continue
        suffix = p[len(prefix):]
        if not suffix.endswith(".json"):
            continue
        tag = suffix[: -len(".json")]
        if tag in PROCESS_MARKER_TAGS:
            out.append((p, tag))
    return out


# §-1.d step 2 — global blacklist patterns. Custom glob with gitignore-style
# `**` (any number of directory segments, INCLUDING zero — `**/.env*` matches
# repo-root `.env` too; review 2026-06-10 finding #7).
#
# v0.1.32 (issue #2): `**/*credentials*` was too wide — any file whose path
# contained the substring "credentials" matched, including legitimate
# engineering artifacts where the **business domain itself is "credentials"**
# (e.g. epic 53 in caller repo had 4 backlog stories with `credentials` in
# the slug → every stage 1 spec md / migration sql / source file halted).
# Replaced with a precise set matching only actual credential-file naming
# conventions: bare `credentials` (e.g. `~/.aws/credentials`), `credentials.*`
# with common credential-format suffixes, `*-credentials[.ext]`, and
# `*.credentials` suffix form. Business filenames with "credentials" in the
# middle (e.g. `credentials_service.go`, `*-credentials-table.md`) no longer
# match. Defense-in-depth: `matches_blacklist()` also allow-lists BMad
# artifacts/ subtree so future broad patterns can't hit spec/json/yaml there.
#
# Two tiers (review 2026-06-10 findings #1/#7 red line — halt is reserved for
# REAL danger, i.e. credentials about to enter git history):
#   - BLACKLIST_PATTERNS (halt tier): credential/secret files + protected
#     harness/BMad infra paths. Hit → STATUS=halt.
#   - JUNK_PATTERNS (auto-skip tier): OS/editor/bytecode droppings. Hit on a
#     path NOT in HEAD → the path is dropped from the working set (never
#     staged, never a halt) with one `NOTE: skipped junk file: <path>` line on
#     stderr. Paths IN HEAD (tracked) are never junk-filtered — a tracked
#     access.log edit or a `git rm`'d .DS_Store commits normally (R1).
#     Previously `*.tmp` / `*.swp` / `.DS_Store` lived in the halt tier, which
#     would have turned every stray Finder/vim dropping into a pipeline halt
#     once the -uall + `**` fixes made root/new-dir files visible to the scan.
BLACKLIST_PATTERNS = [
    "**/.env*",
    "**/*.pem",
    "**/*.key",
    "**/*.p12",
    # Credential file naming — precise formats only (issue #2)
    "**/credentials",
    "**/credentials.json",
    "**/credentials.yaml",
    "**/credentials.yml",
    "**/credentials.ini",
    "**/credentials.txt",
    "**/*-credentials",
    "**/*-credentials.json",
    "**/*-credentials.yaml",
    "**/*-credentials.yml",
    "**/*-credentials.ini",
    "**/*.credentials",
    "**/secrets/**",
    ".claude/settings*",
    ".claude/commands/**",
    ".claude/skills/**",
    ".claude/harness/scripts/**",
    ".claude/harness/answer-policy.md",
    "_bmad/**",
    # NOTE: the `<bmad-output-parent>/.harness-logs/**` pattern is appended
    # below, derived from the configured artifacts_root (finding #33) —
    # see the block right after ARTIFACTS_DIR is computed.
]

# Junk tier — auto-skip + stderr NOTE, never halt, never committed.
#
# Scope (regression fix 2026-06-10 R1): patterns here must ONLY match
# unambiguous OS/editor/bytecode droppings. `**/*.log` was removed — .log is a
# common LEGITIMATE project file suffix (committed sample logs, test fixtures,
# changelogs); real build logs are the project .gitignore's job. Additionally,
# filter_junk_paths() only applies these patterns to paths NOT in HEAD —
# tracked files always flow through the normal pipeline (see its docstring).
JUNK_PATTERNS = [
    "**/*.tmp",
    "**/*.swp",
    "**/.DS_Store",
    "**/__pycache__/**",
    "**/*.pyc",
]

# v0.1.32 (issue #2) — BMad artifacts allow-list (defense layer 2).
# Files under the configured artifacts dir with engineering-product
# suffixes (md/json/yaml/yml) are exempt from blacklist scanning entirely.
# Premise: users don't drop real credential files (`.pem`, `aws-credentials.json`)
# into the spec directory — that path is a curated BMad output tree. If a real
# credential ever lands there, it's caught by review (not commit blacklist).
#
# Review 2026-06-10 finding #33: the prefix used to be the hardcoded literal
# "_bmad-output/implementation-artifacts/" while ARTIFACTS_DIR is config-
# driven (harness-project-config.yaml `artifacts_root`) — on projects with a
# custom artifacts_root the exemption silently pointed at the wrong tree.
# `_ARTIFACTS_ALLOW_PREFIX` is now assigned from ARTIFACTS_DIR right after
# it is computed (see below).
_ARTIFACTS_ALLOW_SUFFIXES = (".md", ".json", ".yaml", ".yml")

# v0.1.35 (issue #5) — i18n locale allow-list (blacklist defense exemption).
# Locale JSON files are commonly named `<feature>-credentials.json` when the
# feature *domain* is "credentials" (e.g.
# `web/src/i18n/locales/zh-CN/personal-credentials.json` — pure UI translation
# strings, zero secret fields). These false-positived on the
# `**/*-credentials.json` blacklist pattern → stage 2 STATUS=halt. Any `.json`
# whose path contains a conventional i18n directory segment is exempt from
# blacklist scanning entirely (mirrors the BMad artifacts allow-list above).
# Real credential files never live in a locale tree; if one ever does it's
# caught by review, not the commit blacklist.
_I18N_LOCALE_DIR_SEGMENTS = ("i18n", "locales", "locale")

ARTIFACTS_DIR = _compute_artifacts_dir_str()
ARTIFACT_RE = re.compile(r"^" + re.escape(ARTIFACTS_DIR) + r"([^/]+\.(?:md|json|yaml|yml))$")

# Finding #33: blacklist-exemption prefix follows the configured artifacts_root
# instead of the original project's hardcoded "_bmad-output/implementation-artifacts/".
_ARTIFACTS_ALLOW_PREFIX = ARTIFACTS_DIR

# v0.1.35 (issue #5) — out-of-scope _bmad-output/ guard prefixes.
# `implementation-artifacts/` is the ONLY curated story-output subtree; sibling
# subdirs (brainstorming/, planning-artifacts/, research/, ...) hold cross-
# cutting BMad planning docs that are frequently edited in a *parallel* bmad
# session unrelated to the active story. The classifier used to bucket those as
# "project code" and auto-`git add` them into the story commit, silently
# mislabeling them under the current story. Derived from ARTIFACTS_DIR so the
# guard follows a project's configured artifacts_root. _BMAD_OUTPUT_PREFIX is
# None when ARTIFACTS_DIR has no parent segment (guard disabled — fail-open).
_BMAD_OUTPUT_INSCOPE_PREFIX = ARTIFACTS_DIR
_bmad_output_parent = "/".join(ARTIFACTS_DIR.rstrip("/").split("/")[:-1])
_BMAD_OUTPUT_PREFIX = (_bmad_output_parent + "/") if _bmad_output_parent else None

# Finding #33: the harness-logs blacklist entry follows the configured
# artifacts_root parent (default `_bmad-output/`) instead of a hardcoded
# literal. Falls back to the original literal when ARTIFACTS_DIR has no
# parent segment (guard disabled — same fail-open posture as the
# out-of-scope guard above).
BLACKLIST_PATTERNS.append(
    (_BMAD_OUTPUT_PREFIX + ".harness-logs/**")
    if _BMAD_OUTPUT_PREFIX else "_bmad-output/.harness-logs/**"
)

# --- Test artifact regex (chore: codex review F1 fix, 2026-05-04) ---
#
# Matches `_bmad-output/implementation-artifacts/test_artifacts/<filename>`
# (one segment under test_artifacts/; spec.ts files live in console-web/tests/
# e2e/ and are out of scope here). Group(1) is the filename.
#
# F1 enforces 4 legal name shapes for every test artifact path AND requires
# the `<key>` / `<epic>` prefix to match the current commit's KEY / EPIC arg.
# Closes the cross-story bypass codex flagged: previously test_artifacts/*
# fell through to project-code bucket with no key-prefix check, so a path
# like `test_artifacts/<other-key>.atdd-checklist.md` could be silently
# committed under the current story.
TEST_ARTIFACTS_DIR = ARTIFACTS_DIR + "test_artifacts/"
TEST_ARTIFACT_RE = re.compile(r"^" + re.escape(TEST_ARTIFACTS_DIR) + r"(.+)$")


def classify_test_artifact(filename, key, epic):
    """Validate `<filename>` (the part after test_artifacts/) against the 4
    legal patterns and the required key/epic prefix.

    Returns one of:
        ("ok",  <pattern-tag>)            — accepted; tag identifies which shape matched
        ("wrong_key", <pattern-tag>)      — shape valid but key/epic prefix mismatches
        ("unexpected", None)              — shape doesn't match any of the 4 patterns

    Pattern tags: "atdd-checklist" / "test-result" / "epic-test-design" / "skipped".
    """
    # Order matters: check the most-specific prefixes first so greedy `.+`
    # captures don't swallow a sibling pattern's suffix.
    # Pattern 3: epic-<EPIC>-test-design.md  (EPIC arg validates, not key)
    m = re.fullmatch(r"epic-([0-9A-Za-z._-]+)-test-design\.md", filename)
    if m:
        if epic and m.group(1) == epic:
            return ("ok", "epic-test-design")
        return ("wrong_key", "epic-test-design")
    # Pattern 4: skipped-<KEY>-<YYYY-MM-DD>.md
    m = re.fullmatch(r"skipped-(.+)-(\d{4}-\d{2}-\d{2})\.md", filename)
    if m:
        if m.group(1) == key:
            return ("ok", "skipped")
        return ("wrong_key", "skipped")
    # Pattern 1: <KEY>.atdd-checklist.md
    m = re.fullmatch(r"(.+)\.atdd-checklist\.md", filename)
    if m:
        if m.group(1) == key:
            return ("ok", "atdd-checklist")
        return ("wrong_key", "atdd-checklist")
    # Pattern 2: <KEY>-test-result.json
    m = re.fullmatch(r"(.+)-test-result\.json", filename)
    if m:
        if m.group(1) == key:
            return ("ok", "test-result")
        return ("wrong_key", "test-result")
    return ("unexpected", None)


# --- F2 worktree clean check (chore: codex review F2 fix, 2026-05-04) ---
#
# Stages 5-5 / T1 / T3 / T4 had `project_code: True` so the classifier
# silently let any non-artifact path through — meaning a dirty worktree
# (e.g. epic-4 in-progress changes) could be swept into a test-harness
# commit. F2 restricts these stages' project bucket to:
#   - test_artifacts/<key>-* (already validated by F1 above)
#   - test_artifacts/epic-<epic>-test-design.md (T1 only — schema-checked)
#   - test_artifacts/skipped-<key>-<date>.md
#   - ${E2E_SPEC_PREFIX}<key>* (the e2e spec dir, out of artifacts root)
# Anything else → halt DIRTY_WORKTREE= with explicit guidance to commit/stash.
TEST_HARNESS_STAGES = ("5-5", "T1", "T3", "T4")

# Review 2026-06-10 finding #9: E2E_SPEC_PREFIX used to be the hardcoded
# constant "console-web/tests/e2e/" while check_test_harness_env.sh /
# eval_test_stage_triggers.sh already read `frontend_dir` / `e2e_test_subdir`
# from harness-project-config.yaml (the v0.1.18+ portability contract). On
# projects with frontend_dir != console-web that mismatch made the F2 check
# halt (DIRTY_WORKTREE) on the project's REAL e2e spec dir. Derive the prefix
# from the same config getters; fall back to the original default when the
# deployed harness_config.py predates the getters (asset version skew) or
# config reading fails for any reason — fail-open, aligned with the
# harness_config fallback policy.
try:
    from harness_config import get_e2e_test_subdir, get_frontend_dir  # noqa: E402
    E2E_SPEC_PREFIX = f"{get_frontend_dir()}/{get_e2e_test_subdir()}/"
except Exception:  # ImportError on stale deployed harness_config.py, etc.
    E2E_SPEC_PREFIX = "console-web/tests/e2e/"


def is_e2e_spec_for_key(path, key):
    """Return True if `path` is a ${E2E_SPEC_PREFIX}<key>* file."""
    if not path.startswith(E2E_SPEC_PREFIX):
        return False
    suffix = path[len(E2E_SPEC_PREFIX):]
    # Allow either `<key><whatever>` or `<key>/<file>` (subdirs under the key).
    return suffix.startswith(key)

# --- Story status reader (used by dev-result / review-findings consistency check) ---
#
# Review 2026-06-10 finding #76: the capture group used to be `(\w+)`, which
# only accepted single-word statuses — `Status: in-progress`,
# `Status: Ready for Review`, `Status: done ✅` and `**Status**: review`
# (colon after the closing stars) all returned None and were mis-reported by
# the stage 2/5 gates as "md missing Status line", sending solo-dev hunting
# for a line that exists. Widened to a whole-segment capture + decoration
# strip; callers can now also distinguish "line present but unparsable" from
# "line absent" via _read_story_status_ex.
_STATUS_LINE_RE = re.compile(
    r"^\s*(?:[-*]\s+)?\*{0,2}Status\*{0,2}\s*[:：]\s*(.*?)\s*$",
    re.IGNORECASE,
)


def _normalize_status_value(raw):
    """Strip markdown decoration / trailing emoji from a Status value and
    lowercase it: `*review*` → `review`, `done ✅` → `done`,
    `Ready for Review` → `ready for review`. Returns "" when nothing
    survives the strip."""
    v = raw.strip().strip("`").strip()
    v = v.strip("*_").strip()
    v = re.sub(r"[^\w-]+$", "", v)  # trailing emoji / punctuation decoration
    return v.lower()


def _read_story_status_ex(key):
    """Return (status, line_seen) for the story md Status field.

    status: normalized lowercased value (first parseable Status line), or
    None when no line yields a usable value. line_seen: True when at least
    one Status-shaped line exists — lets the stage 2/5 gates distinguish
    "Status line present but value unrecognized" from "no Status line at
    all" (finding #76)."""
    path = f"{ARTIFACTS_DIR}{key}.md"
    line_seen = False
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                m = _STATUS_LINE_RE.match(line)
                if not m:
                    continue
                line_seen = True
                v = _normalize_status_value(m.group(1))
                if v:
                    return v, True
    except FileNotFoundError:
        return None, False
    return None, line_seen


def read_story_status(key):
    """Read the Status field from story md; returns lowercased value or None.

    Tolerates common renderings:
        Status: review
        **Status:** review
        **Status**: review
        - Status: in-progress
        Status: Ready for Review
        Status: done ✅
    """
    return _read_story_status_ex(key)[0]


# --- dev-result.json schema validation (stage 2 gate) ---
#
# Accepts both the legacy schema and the new tri-state schema:
#
# Legacy:
#   {"checks": {"<x>_passed": bool}, "checks_skipped": [<str>...]}
#   - any check whose value is False AND key not in checks_skipped → fail
#   - checks_skipped membership is matched by literal key OR `<key>:` prefix
#     (the latter forgives the format the 1-3 dev agent first wrote)
#
# Tri-state (preferred — see harness-changelog 2026-05-01 §C):
#   {"checks": {"<x>": "pass" | "fail" | "skip"}, "checks_skip_reasons": {"<x>": "<reason>"}}
#   - any check whose value is "fail" → fail
#
# Both formats must also satisfy:
#   - top-level `final_story_status` matches story md Status segment
#
# Returns list of (code, message) tuples; empty list = pass.

def validate_dev_result(key):
    path = f"{ARTIFACTS_DIR}{key}.dev-result.json"
    if not os.path.exists(path):
        return [("DEV_RESULT_MISSING", f"{path} not found — stage 2 requires the machine-readable completion gate")]
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        return [("DEV_RESULT_FAIL_PARSE", f"{path} parse error: {e}")]

    # Subagent-produced JSON is untrusted — guard top-level type before .get()
    # (review 2026-06-10 finding #31 sweep).
    if not isinstance(d, dict):
        return [("DEV_RESULT_FAIL_PARSE", f"top-level JSON is not an object (got {type(d).__name__})")]

    errors = []
    checks = d.get("checks", {})
    if not isinstance(checks, dict):
        errors.append(("DEV_RESULT_FAIL_PARSE", "checks field is not an object"))
        return errors

    # Detect schema variant by inspecting the first value.
    is_tristate = any(isinstance(v, str) for v in checks.values())

    if is_tristate:
        for k, v in checks.items():
            if v == "fail":
                errors.append(("DEV_RESULT_FAIL_CHECK", f"{k}=fail (tri-state schema; checks_skip_reasons may explain skips but `fail` is unrecoverable)"))
            elif v not in ("pass", "skip"):
                errors.append(("DEV_RESULT_FAIL_CHECK", f"{k}={v!r} — not a valid tri-state value (expected pass / fail / skip)"))
    else:
        skipped_raw = d.get("checks_skipped", [])
        if not isinstance(skipped_raw, (list, tuple)):
            # Non-list (e.g. a bare string / int) used to crash the iteration
            # below with a traceback — surface as a structured parse error
            # instead (finding #31 sweep).
            errors.append(("DEV_RESULT_FAIL_PARSE",
                           f"checks_skipped is not a list (got {type(skipped_raw).__name__})"))
            skipped_raw = []
        # Accept literal key OR `<key>:` prefix in checks_skipped (forgive the format the 1-3 dev agent first wrote).
        skipped_keys = set()
        for entry in skipped_raw:
            if not isinstance(entry, str):
                continue
            stripped = entry.strip()
            if ":" in stripped:
                skipped_keys.add(stripped.split(":", 1)[0].strip())
            else:
                skipped_keys.add(stripped)
        for k, v in checks.items():
            if v is False and k not in skipped_keys:
                errors.append(("DEV_RESULT_FAIL_CHECK", f"{k}=false and not listed in checks_skipped (legacy schema)"))

    md_status, status_line_seen = _read_story_status_ex(key)
    json_status = d.get("final_story_status")
    if md_status is not None and json_status and md_status != str(json_status).lower():
        errors.append(("DEV_RESULT_STATUS_MISMATCH", f"json={json_status!r} md={md_status!r}"))
    elif md_status is None:
        # Finding #76: distinguish "line exists but value unrecognized" from
        # "no Status line" — same error code (output contract unchanged),
        # precise message so solo-dev fixes the right thing.
        if status_line_seen:
            errors.append(("DEV_RESULT_STATUS_MISSING",
                           f"Status line exists in {ARTIFACTS_DIR}{key}.md but its value could not be parsed — fix the line format (e.g. `Status: review`)"))
        else:
            errors.append(("DEV_RESULT_STATUS_MISSING",
                           f"could not read Status from {ARTIFACTS_DIR}{key}.md (no Status line found)"))

    return errors


# --- review-findings.json schema validation (stage 5 gate) ---
#
# Required shape (loose; only fields used for gates are enforced):
#   {"unresolved": {"critical": int, "high": int, "medium": int, "low": int},
#    "final_story_status": "done" | "review"}
#
# Gates:
#   - critical + high + medium > 0 → fail
#   - final_story_status ≠ story md Status → fail

def validate_review_findings(key):
    path = f"{ARTIFACTS_DIR}{key}.review-findings.json"
    if not os.path.exists(path):
        return [("REVIEW_FINDINGS_MISSING", f"{path} not found — stage 5 requires the machine-readable completion gate")]
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        return [("REVIEW_FINDINGS_FAIL_PARSE", f"{path} parse error: {e}")]

    # Subagent-produced JSON is untrusted — guard top-level type before .get()
    # (review 2026-06-10 finding #31 sweep).
    if not isinstance(d, dict):
        return [("REVIEW_FINDINGS_FAIL_PARSE", f"top-level JSON is not an object (got {type(d).__name__})")]

    errors = []
    u = d.get("unresolved", {})
    if not isinstance(u, dict):
        errors.append(("REVIEW_FINDINGS_FAIL_PARSE", "unresolved field is not an object"))
        return errors

    # Review 2026-06-10 finding #31: `int(u.get("critical", 0) or 0)` crashed
    # with an uncaught ValueError/TypeError when the subagent wrote a
    # non-numeric value (e.g. `"critical": "none"`) — traceback on stderr,
    # ZERO STATUS=/REASON= lines on stdout, breaking the "paste stdout into
    # the §3 halt template verbatim" contract. Coerce defensively and turn
    # bad values into a structured FAIL_PARSE error (same handling tier as
    # JSONDecodeError).
    counts = {}
    for level in ("critical", "high", "medium", "low"):
        raw = u.get(level, 0)
        try:
            counts[level] = int(raw or 0)
        except (TypeError, ValueError):
            errors.append(("REVIEW_FINDINGS_FAIL_PARSE",
                           f"unresolved.{level} 不是整数: {raw!r}"))
    if errors:
        return errors
    crit = counts["critical"]
    high = counts["high"]
    med  = counts["medium"]
    low  = counts["low"]
    if crit + high + med > 0:
        errors.append(("REVIEW_FINDINGS_UNRESOLVED", f"critical={crit} high={high} medium={med} low={low}"))

    md_status, status_line_seen = _read_story_status_ex(key)
    json_status = d.get("final_story_status")
    if md_status is not None and json_status and md_status != str(json_status).lower():
        errors.append(("REVIEW_FINDINGS_STATUS_MISMATCH", f"json={json_status!r} md={md_status!r}"))
    elif md_status is None:
        # Finding #76: same distinction as validate_dev_result above.
        if status_line_seen:
            errors.append(("REVIEW_FINDINGS_STATUS_MISSING",
                           f"Status line exists in {ARTIFACTS_DIR}{key}.md but its value could not be parsed — fix the line format (e.g. `Status: done`)"))
        else:
            errors.append(("REVIEW_FINDINGS_STATUS_MISSING",
                           f"could not read Status from {ARTIFACTS_DIR}{key}.md (no Status line found)"))

    return errors

# §0.5 expected-output spec per stage.
# Fields:
#   story_md         — $KEY.md is expected
#   story_json       — list of suffixes ($KEY<suf>); e.g. [".dev-result.json"]
#   story_codex      — $KEY.codex-review.md is expected
#   global_files     — list of artifact filenames (e.g. ["sprint-status.yaml"])
#   epic_retro       — epic-${EPIC}-retro-*.md is expected
#   project_code     — non-artifact paths are allowed (project source, configs, ...)
#   commit_msg       — message template, supports {key} / {epic}
#   skip_if_empty    — if True and worktree has no changes, exit 2 (skip commit)
#   validate_dev     — if True, run dev-result.json schema gate before staging (stage 2)
#   validate_review  — if True, run review-findings.json schema gate before staging (stage 5)
#   tag_after_commit — git tag name (lightweight) to write AFTER caller commits.
#                      Implemented as a *suggestion* on stdout (`SUGGEST_TAG=`);
#                      the script itself doesn't commit, so it can't tag-after-commit
#                      atomically — see runtime block in main()
#
# Codex graceful-degradation markers (issue #4 / review 2026-06-10 finding #4):
# when codex-in-cc is unavailable, run.md §1 ③ writes
# `<KEY>.codex-skipped.json` into the artifacts dir and skips stages 3/4;
# /harness-zh:codex-catchup §4.7 later archives it to
# `<KEY>.codex-skipped.resolved.json`. Both must be in the expected-output
# spec, otherwise §0.5 classifies them unexpected_artifact and the very
# mechanism that exists to keep the pipeline running halts it:
#   - `.codex-skipped.json` → stages 2/4/5 (stage 5 commits the marker as part
#     of story close-out; 2/4 are defensive for resumed/continued runs)
#   - `.codex-skipped.resolved.json` → stages 3/4/5 (catchup reruns stage 3+4
#     commits after archiving; 5 is defensive for late archives)
STAGES = {
    "1": {
        "story_md":         True,
        "story_json":       [],
        "story_codex":      False,
        "global_files":     ["sprint-status.yaml"],
        "epic_retro":       False,
        "project_code":     False,
        "commit_msg":       "story({key}): create story spec",
        "skip_if_empty":    False,
        "validate_dev":     False,
        "validate_review":  False,
        "suggest_tag":      "harness/{key}/stage2-base",  # tag stage1 commit so stage3/5 can read base
    },
    "2": {
        "story_md":         True,
        "story_json":       [".dev-result.json", ".codex-skipped.json"],
        "story_codex":      False,
        "global_files":     ["sprint-status.yaml", "deferred-work.md"],
        "epic_retro":       False,
        "project_code":     True,
        "commit_msg":       "story({key}): initial implementation",
        "skip_if_empty":    False,
        "validate_dev":     True,
        "validate_review":  False,
        "suggest_tag":      None,
    },
    "3": {
        "story_md":         False,
        "story_json":       [".codex-skipped.resolved.json"],
        "story_codex":      True,
        "global_files":     [],
        "epic_retro":       False,
        "project_code":     False,
        "commit_msg":       "story({key}): codex adversarial review report",
        "skip_if_empty":    False,
        "validate_dev":     False,
        "validate_review":  False,
        "suggest_tag":      None,
    },
    "4": {
        "story_md":         True,
        "story_json":       [".codex-skipped.json", ".codex-skipped.resolved.json"],
        "story_codex":      False,
        "global_files":     ["deferred-work.md"],
        "epic_retro":       False,
        "project_code":     True,
        "commit_msg":       "story({key}): apply codex review fixes",
        "skip_if_empty":    False,
        "validate_dev":     False,
        "validate_review":  False,
        "suggest_tag":      None,
    },
    "5": {
        "story_md":         True,
        "story_json":       [".review-findings.json", ".review-progress.json",
                             ".codex-skipped.json", ".codex-skipped.resolved.json"],
        "story_codex":      False,
        "global_files":     ["sprint-status.yaml", "deferred-work.md"],
        "epic_retro":       False,
        "project_code":     True,
        "commit_msg":       "story({key}): final review fixes & done",
        "skip_if_empty":    False,
        "validate_dev":     False,
        "validate_review":  True,
        "suggest_tag":      "harness/{key}/done",  # tag completion commit
    },
    "5-fallback": {
        "story_md":         False,
        "story_json":       [],
        "story_codex":      False,
        "global_files":     ["sprint-status.yaml"],
        "epic_retro":       False,
        "project_code":     False,
        "commit_msg":       "sprint({key}): mark done",
        "skip_if_empty":    True,
        "validate_dev":     False,
        "validate_review":  False,
        "suggest_tag":      None,
    },
    "6": {
        "story_md":         False,
        "story_json":       [],
        "story_codex":      False,
        "global_files":     ["sprint-status.yaml", "deferred-work.md"],
        "epic_retro":       True,
        "project_code":     False,
        "commit_msg":       "epic({epic}): retrospective",
        "skip_if_empty":    False,
        "validate_dev":     False,
        "validate_review":  False,
        "suggest_tag":      None,
    },
    "6-5": {
        # Chore C10 retro residue processor — converts retro_action_items pending/partial
        # entries into chore-retro-c${EPIC}-<code>-<slug>.md spec files (path B manual mode).
        # Allowed paths: chore-retro-c${epic}-*.md (NEW) + sprint-status.yaml (MODIFY only —
        # `chore_spec:` field per processed entry).
        "story_md":         False,
        "story_json":       [],
        "story_codex":      False,
        "global_files":     ["sprint-status.yaml"],
        "epic_retro":       False,
        "chore_retro":      True,
        "project_code":     False,
        "commit_msg":       "chore(retro-c{epic}): process residue → {count} chore specs",
        "skip_if_empty":    True,
        "validate_dev":     False,
        "validate_review":  False,
        "suggest_tag":      None,
    },
    "6-done": {
        "story_md":         False,
        "story_json":       [],
        "story_codex":      False,
        "global_files":     ["sprint-status.yaml"],
        "epic_retro":       False,
        "project_code":     False,
        "commit_msg":       "epic({epic}): mark done",
        "skip_if_empty":    True,
        "validate_dev":     False,
        "validate_review":  False,
        "suggest_tag":      None,
    },
    "retro-fulfill": {
        # issue #3 — retro DEV items 兑现前置 gate（/harness-zh:run §0.A.0）。
        # 把一条 category: dev 的 retro action item 的 chore_spec 实现成项目代码，
        # 在 stage 1 创建新 epic 4-6 story spec 之前就清掉 pre-commit gate ① 的
        # 阻塞，避免「spawn stage-1 subagent → commit 被 hook 拦 → halt」的 token 浪费。
        #
        # `key` 位参 = retro action item 的 code（如 D7），不是 story key（本 stage
        # 没有 story 概念）。commit_msg 用 {epic}+{key} 拼成 chore(retro-cN-CODE)。
        # 允许路径 = 项目代码 + sprint-status.yaml（主 agent Edit 翻 retro_action_items
        # 对应 code 的 status → done）+ deferred-work.md（实现中遇到的延后项）+
        # chore-retro-c{epic}-*.md（dev 勾 Tasks checkbox；chore_retro 通道豁免，与
        # stage 6-5 同）。_sync_sprint_status_for_stage 对本 stage no-op —— retro_action_items
        # 的 status flip 没有 sprint-status.py setter，由主 agent Edit 落地后这里 stage。
        "story_md":         False,
        "story_json":       [],
        "story_codex":      False,
        "global_files":     ["sprint-status.yaml", "deferred-work.md"],
        "epic_retro":       False,
        "chore_retro":      True,
        "project_code":     True,
        "commit_msg":       "chore(retro-c{epic}-{key}): fulfill retro dev item",
        "skip_if_empty":    False,
        "validate_dev":     False,
        "validate_review":  False,
        "suggest_tag":      None,
    },
    # ----------------------------------------------------------------------
    # Test harness stages (chore C-bootstrap; F1+F2 fixes 2026-05-04):
    #
    # `5-5` is run-sprint stage 5.5 — the test harness embed point right after
    # bmad-code-review completes and before retrospective triggers. Allowed
    # outputs are the union of T3 + T4 since stage 5.5 may invoke both atdd
    # (red-phase scaffold) and e2e (actual run) in one shot when env permits.
    #
    # `T1` / `T3` / `T4` are independent stages used by `/harness-zh:run-test`
    # (the dedicated test orchestrator). They ALSO emit through this commit
    # helper for path-whitelist symmetry with the run-sprint pipeline.
    #
    # Path classification (post-F1): `test_artifacts/<filename>` paths get
    # validated by `classify_test_artifact()` BEFORE the regular classifier
    # runs (see main()). The validator enforces 4 legal filename shapes
    # (`<key>.atdd-checklist.md` / `<key>-test-result.json` /
    # `epic-<epic>-test-design.md` / `skipped-<key>-<date>.md`) AND requires
    # the embedded key/epic to match the current commit's KEY / EPIC arg.
    # Failures halt with CROSS_STORY= or UNEXPECTED_ARTIFACT= — closing the
    # bypass codex flagged where mis-keyed test_artifacts/ paths could slip
    # into project-code bucket.
    #
    # Worktree cleanliness (post-F2): on the four test-harness stages,
    # `check_worktree_clean()` restricts the project bucket to test_artifacts/
    # <key>-* and console-web/tests/e2e/<key>* paths only; any unrelated
    # in-progress code change halts with DIRTY_WORKTREE= and tells solo-dev
    # to commit/stash first (no auto-stash — see chore spec §Boundaries).
    "5-5": {
        # Stage 5-5 has three legitimate branches (chore-harness-epic-4-
        # orchestration-observations T2.3 — back-compat fallback path):
        #   (a) worktree clean → STATUS=skip (the new default — run-test-sprint
        #       internally commits via T3+T4, leaving nothing for 5-5).
        #   (b) worktree has stage 5.5 expected products (test-result.json /
        #       skipped-*.md / sprint-status test_status updates / deferred-
        #       work.md FU-Test rows) → STATUS=ok (the legacy path, kept for
        #       direct callers that bypass run-test-sprint internal commits).
        #   (c) worktree has paths outside the test-harness whitelist
        #       (F2 §4.25 in main()) → STATUS=halt with DIRTY_WORKTREE=.
        # Branch (a) is now the default after T2.1 rewires run-sprint stage
        # 5.5 to review-only; branch (b) is kept so the 5-5 command signature
        # stays stable for any cron / external automation that already runs it.
        "story_md":         False,
        "story_json":       [],
        "story_codex":      False,
        "global_files":     ["sprint-status.yaml", "deferred-work.md"],
        "epic_retro":       False,
        "project_code":     True,
        "commit_msg":       "test({key}): atdd + e2e (run-sprint stage 5.5)",
        "skip_if_empty":    True,
        "validate_dev":     False,
        "validate_review":  False,
        "suggest_tag":      None,
    },
    "T1": {
        "story_md":         False,
        "story_json":       [],
        "story_codex":      False,
        "global_files":     ["sprint-status.yaml"],
        "epic_retro":       False,
        "project_code":     True,
        "commit_msg":       "test(epic-{epic}): test-design",
        "skip_if_empty":    True,
        "validate_dev":     False,
        "validate_review":  False,
        "suggest_tag":      None,
    },
    "T3": {
        "story_md":         False,
        "story_json":       [],
        "story_codex":      False,
        "global_files":     ["sprint-status.yaml"],
        "epic_retro":       False,
        "project_code":     True,
        "commit_msg":       "test({key}): atdd red-phase scaffold",
        "skip_if_empty":    False,
        "validate_dev":     False,
        "validate_review":  False,
        "suggest_tag":      None,
    },
    "T4": {
        # T4 commit_msg suffix "(run-sprint stage 5.5)" is unconditional —
        # see chore-harness-epic-4-orchestration-observations T2.2: stage 5.5
        # is the only invocation path that produces T4 commits in run-sprint
        # pipeline; suffix lets `git log --grep "stage 5.5"` find them stably
        # whether invoked via /harness-zh:run-test --story (standalone) or via
        # /harness-zh:run stage 5.5 spawn. Standalone-only invocations do not
        # generate run-sprint commits — keeping the suffix is harmless noise
        # and the grep stability requirement trumps the "looks misleading"
        # cost (Q3 RESOLVED 2026-05-04).
        "story_md":         False,
        "story_json":       [],
        "story_codex":      False,
        "global_files":     ["sprint-status.yaml", "deferred-work.md"],
        "epic_retro":       False,
        "project_code":     True,
        "commit_msg":       "test({key}): atdd + e2e (run-sprint stage 5.5)",
        "skip_if_empty":    False,
        "validate_dev":     False,
        "validate_review":  False,
        "suggest_tag":      None,
    },
}


# --- Sprint-status auto-sync helpers (chore-harness-epic-4-orchestration-observations T1) ---
#
# Three helpers replace the scattered "main agent fallback `sprint-status.py
# set ...`" pattern in run-sprint.md §1 阶段 ②/⑤/⑥. Sync responsibility now
# lives entirely in harness-commit.py — main agent doesn't have to remember
# which stage maps to which set call, and BMad skill漏 sync 的口子被堵死。
#
# All three helpers raise RuntimeError on IO/subprocess failure; the caller
# turns that into STATUS=halt + REASON= line (no retry, no auto-reconcile —
# Q1 RESOLVED 2026-05-04: same "halt 不 reconcile" pattern as D3).
#
# Idempotent by construction:
#   - _sync_sprint_status_for_stage: skips if current == target value.
#   - _seed_retro_action_items: skips D items already in the block (Q2 RESOLVED).
#   - _fill_chore_spec_field: skips entries that already have chore_spec field.


def _atomic_write_file(path, content):
    """temp + fsync + os.replace. Mirrors sprint-status.py _atomic_write."""
    parent = os.path.dirname(path) or "."
    try:
        src_mode = os.stat(path).st_mode & 0o777
    except FileNotFoundError:
        src_mode = 0o644
    fd, tmp_path = tempfile.mkstemp(dir=parent, prefix=f".{os.path.basename(path)}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp_path, src_mode)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def _sync_sprint_status_for_stage(stage, key, epic):
    """Auto-advance sprint-status.yaml entries based on stage.

    Mapping (T1.1):
        stage 2     → set <key> review
        stage 5     → set <key> done
        stage 6     → set epic-<epic>-retrospective done + epic-<epic> done
        stage 6-5   → no-op (前置 stage 6 已翻完 — 不重复 set per Verification
                      manual check #1)
        其它 stage  → no-op

    Returns list of (yaml_key, new_status) tuples actually changed (may be
    empty if all transitions are no-ops). Raises RuntimeError on failure
    (caller halts; Q1 推荐：不自动重试).
    """
    sync_script = str(Path(__file__).resolve().parent / "sprint-status.py")
    transitions = []
    if stage == "2":
        transitions.append((key, "review"))
    elif stage == "5":
        transitions.append((key, "done"))
    elif stage == "6":
        if epic:
            transitions.append((f"epic-{epic}-retrospective", "done"))
            transitions.append((f"epic-{epic}", "done"))
    # stage 6-5 / 6-done / 1 / 3 / 4 / 5-fallback / 5-5 / T1 / T3 / T4 → no-op

    # Review 2026-06-10 finding #77 — two-pass read-then-set:
    #
    # Pass 1 reads the current value of EVERY key in `transitions` BEFORE any
    # write. sprint-status.py `status` now resolves epic-* keys too
    # (include_epic_keys — the read/write asymmetry that previously forced an
    # epic-* "skip the read, set unconditionally" workaround here is fixed at
    # the root). This restores idempotency for stage 6 reruns (no-op
    # transitions no longer rewrite the file / bump last_updated / emit bogus
    # SPRINT_STATUS_AUTO_SYNC lines) and makes the stage 6 double-key flip
    # (epic-N-retrospective → epic-N) atomic w.r.t. the known failure mode:
    # a missing key (yaml schema bug) is detected up front and raises BEFORE
    # the first set lands, instead of halting between the two sets and
    # leaving half-flipped state on disk.
    applied = []
    to_set = []
    for k, new_status in transitions:
        r = subprocess.run([sys.executable, sync_script, "status", k],
                           capture_output=True, text=True, check=False)
        if r.returncode != 0:
            # Missing key is a hard error (yaml schema bug) — surface it
            # before any write so no partial state is left behind. cmd_status
            # rc=1 prints nothing (and stderr may only carry harness_config
            # WARN noise), so add the likely cause explicitly.
            stderr_sig = "\n".join(
                ln for ln in r.stderr.strip().splitlines()
                if ln.strip() and not ln.lstrip().startswith("WARN")
            ).strip()
            detail = stderr_sig or r.stdout.strip() or \
                f"key {k!r} not found in development_status (yaml schema bug — check sprint-status.yaml)"
            raise RuntimeError(
                f"sprint-status.py status {k} failed: {detail} (rc={r.returncode})"
            )
        current = r.stdout.strip()
        if current == new_status:
            continue  # idempotent — already at target
        to_set.append((k, new_status))

    for k, new_status in to_set:
        r = subprocess.run([sys.executable, sync_script, "set", k, new_status],
                           capture_output=True, text=True, check=False)
        if r.returncode != 0:
            raise RuntimeError(
                f"sprint-status.py set {k} {new_status} failed: {r.stderr.strip() or r.stdout.strip()} (rc={r.returncode})"
            )
        applied.append((k, new_status))
    return applied


def _epic_letter(epic):
    """Map epic number to a capital-letter prefix using bijective base-26
    ("spreadsheet column" scheme): 1→A, 26→Z, 27→AA, 52→AZ, 53→BA, ...
    Returns None only when epic is not a positive integer.

    v0.1.35 (issue #5): previously capped at 26 (returned None for epic > 26),
    which silently disabled retro_action_items seeding at stage 6 + the stage
    ⑥.5 residue pipeline for ANY epic > 26 (e.g. the 50s-numbered epics in the
    caller repo). The bijective base-26 extension keeps the 1→A..26→Z contract
    fully backward-compatible (codes for epic ≤ 26 are byte-for-byte unchanged)
    while giving epic > 26 a deterministic multi-letter prefix. The retro
    markdown contract (`### {letter}{N} — title`) defers to this function, so
    multi-letter codes like `### AZ1` are emitted/parsed automatically for
    epic > 26 — see prompt-suffixes/bmad-retrospective-suffix.md §1.
    """
    try:
        n = int(epic)
    except (TypeError, ValueError):
        return None
    if n < 1:
        return None
    letters = []
    while n > 0:
        n, rem = divmod(n - 1, 26)
        letters.append(chr(ord("A") + rem))
    return "".join(reversed(letters))


def _find_latest_retro_md(epic):
    """Find the most-recent epic-<epic>-retro-*.md path under ARTIFACTS_DIR.

    Returns absolute path or None when no match. Latest is by alphabetical
    sort of filename (file naming convention `epic-N-retro-YYYY-MM-DD.md`
    means lex sort == chronological sort).
    """
    pattern = os.path.join(ARTIFACTS_DIR, f"epic-{epic}-retro-*.md")
    matches = sorted(glob.glob(pattern))
    if not matches:
        return None
    return matches[-1]


# Review 2026-06-10 finding #29 — per-item `**Category**: dev|harness`
# declaration line inside a Form 1 H3 block (bmad-retrospective-suffix.md
# §5/§6 contract). Tolerated renderings:
#   **Category**: dev        (canonical)
#   - **Category**: dev      (bullet)
#   **Category:** harness    (colon inside bold — common LLM rendering)
#   **Category**：dev        (CJK fullwidth colon)
#   Category: dev            (bold dropped)
_CATEGORY_LINE_RE = re.compile(
    r"^\s*(?:[-*]\s+)?\*{0,2}Category\*{0,2}\s*[:：]\s*\*{0,2}\s*([A-Za-z][A-Za-z-]*)",
    re.IGNORECASE | re.MULTILINE,
)


def _extract_item_category(block_text, code, retro_md_path):
    """Extract the `**Category**` declaration from one Form 1 H3 block body.

    Returns "dev" / "harness", or None when the declaration is absent or its
    value is outside the two-value enum (NOCAT — the seeder then omits the
    `category` subkey; check_retro_action_items.sh keeps treating the item as
    non-blocking WARN. Missing/illegal declarations never halt — finding #29).
    """
    m = _CATEGORY_LINE_RE.search(block_text)
    if not m:
        return None
    val = m.group(1).lower()
    if val in ("dev", "harness"):
        return val
    print(
        f"WARN: retro action item {code} declares **Category**: {m.group(1)!r} "
        f"(expected dev|harness) in {retro_md_path}; writing no category subkey "
        f"(NOCAT) — see prompt-suffixes/bmad-retrospective-suffix.md §6.",
        file=sys.stderr,
    )
    return None


def _parse_retro_action_items(retro_md_path, letter):
    """Parse retro markdown action items from §"Action items" section.

    Three accepted forms (canonical = Form 1; Forms 2/3 are backward-compat
    fallbacks for retro markdown not following the canonical contract — see
    `prompt-suffixes/bmad-retrospective-suffix.md` §"Action items markdown
    格式契约" for the declared schema):

      Form 1 — H3 heading (canonical):
        `### {letter}{N} — title`        e.g. `### A1 — 流程改进 X`
        `### {letter}-<kebab> — title`   e.g. `### A-route-authz — 重构鉴权`

      Form 2 — markdown table row (BMad 中文化衍生兜底):
        `| AI-{S}.{I} | <title> | ... |`
        Normalized to code `{letter}-{S}-{I}` (epic 1 / AI-2.3 → A-2-3).
        Emits stderr WARN to push migration to canonical form.

      Form 3 — bold inline bullet (§"自我约束"-style 兜底):
        `**{letter}{N}** title`
        `**{letter}1/{letter}2/{letter}3** shared-title`
        Emits stderr WARN.

    Form 1 wins; Forms 2/3 only consulted when Form 1 yields 0 items.

    Section detection: any `## ` heading whose title contains the substring
    "action item" (case-insensitive) or "行动项". When the section IS found
    but **all 3 forms yield 0 items**, raises RuntimeError (fail-loud at
    stage 6 — schema drift detection; previously this silently returned []
    and only surfaced as an unrelated stage ⑥.5 block-missing error). When
    no Action Items section is found at all, returns [] peacefully (legit
    minimal retro).

    Category extraction (review 2026-06-10 finding #29): each Form 1 H3 block
    is scanned for the `**Category**: dev|harness` declaration required by
    bmad-retrospective-suffix.md §5/§6. Missing or illegal values yield
    category=None (the seeder then omits the `category` subkey — gate side
    keeps its NOCAT/WARN behavior; never a halt). Form 2/3 fallback items
    have no per-item declaration channel and always yield category=None.

    Returns list of (code, title, category) tuples where category is
    "dev" / "harness" / None. Raises RuntimeError on file IO failure or
    schema drift.
    """
    try:
        with open(retro_md_path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        raise RuntimeError(f"could not read retro md {retro_md_path}: {e}")

    # Find Action Items section: any `## ` heading containing "action item"
    # (English) or "行动项" (Chinese).
    #
    # v0.1.31 (issue #1): retro md may include a §"Epic N retro Action items
    # follow-through" section (BMad SKILL Step 3 prev-retro check) — that
    # section recaps the *previous* epic's items and must NOT be seeded as
    # the current epic's new action items. Filter such follow-through /
    # carryover sections out by keyword; prefer the last remaining section
    # (canonical §"Action items" sits near the end of BMad retros).
    section_re = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)
    section_starts = [(m.start(), m.group(1)) for m in section_re.finditer(text)]

    follow_through_kw = (
        "follow-through", "follow through", "follow up", "follow-up",
        "followup", "carryover", "carry-over",
    )

    candidate_sections = []
    for i, (pos, title) in enumerate(section_starts):
        tlow = title.lower()
        if "action item" not in tlow and "行动项" not in title:
            continue
        if any(kw in tlow for kw in follow_through_kw):
            continue
        end = section_starts[i + 1][0] if i + 1 < len(section_starts) else len(text)
        candidate_sections.append(text[pos:end])

    section_text = text  # default: scan whole file
    section_found = False
    if candidate_sections:
        # Prefer last canonical Action Items section — BMad retros place the
        # new-this-epic action items near the end (§"Action items"), while
        # any follow-through sections (already filtered above) sit earlier.
        section_text = candidate_sections[-1]
        section_found = True
    else:
        # Review 2026-06-10 finding #72: the whole-file fallback used to scan
        # `text` verbatim, so when the new action-items heading drifted away
        # from the "action item"/"行动项" keywords (e.g. 中文化『## 改进计划』)
        # the prev-epic `| AI-N.M |` rows inside a follow-through section were
        # normalized into CURRENT-epic codes and seeded — the exact pollution
        # v0.1.31 (issue #1) closed on the canonical path. Excise every `## `
        # section whose title matches follow_through_kw (same keyword set as
        # the candidate filter) BEFORE the 3-form scan.
        drop_spans = []
        for i, (pos, title) in enumerate(section_starts):
            if any(kw in title.lower() for kw in follow_through_kw):
                end = section_starts[i + 1][0] if i + 1 < len(section_starts) else len(text)
                drop_spans.append((pos, end))
        if drop_spans:
            parts = []
            cursor = 0
            for s, e in drop_spans:
                parts.append(text[cursor:s])
                cursor = e
            parts.append(text[cursor:])
            section_text = "".join(parts)
            print(
                f"WARN: _parse_retro_action_items found no canonical Action "
                f"Items section in {retro_md_path}; falling back to whole-file "
                f"scan with {len(drop_spans)} follow-through section(s) excised. "
                f"Retro headings should contain 'action item' / '行动项' — see "
                f"prompt-suffixes/bmad-retrospective-suffix.md "
                f"§'Action items markdown 格式契约'.",
                file=sys.stderr,
            )

    items = []

    # Form 1 — H3 heading (canonical)
    h3_re = re.compile(
        rf"^###\s+({re.escape(letter)}[A-Za-z0-9-]*)\b\s*(?:[—–-]\s*(.+?))?\s*$",
        re.MULTILINE,
    )
    heading_re = re.compile(r"^#{2,3}\s", re.MULTILINE)
    for m in h3_re.finditer(section_text):
        code = m.group(1)
        # Filter: must be `<letter><digits>` or `<letter>-<lowercase-kebab>` to
        # exclude false positives like `### A — Action items overview`.
        if re.fullmatch(rf"{re.escape(letter)}\d+", code) or \
           re.fullmatch(rf"{re.escape(letter)}-[a-z][a-zA-Z0-9-]+", code):
            # Finding #29: the H3 block body (up to the next ##/### heading)
            # carries the per-item `**Category**: dev|harness` declaration.
            nxt = heading_re.search(section_text, m.end())
            block_end = nxt.start() if nxt else len(section_text)
            category = _extract_item_category(
                section_text[m.end():block_end], code, retro_md_path
            )
            items.append((code, (m.group(2) or "").strip(), category))

    if items:
        return items

    # Form 2 fallback — markdown table row, accepts (col 1 variants):
    #   `| AI-N.M | title | ... |`            (canonical fallback)
    #   `| AI-N.X1 | title | ... |`            (sub-id is letter+digits like Y2)
    #   `| AI-N.X (注释) | title | ... |`       (parenthetical annotation)
    #   `| **AI-N.X (注释)** | title | ... |`   (bold-wrapped col 1)
    # v0.1.31 expansion (issue #1): empirically BMad retrospective skill
    # consistently writes sub-id as letter+digits (Y1..Y6, X1..X6, Z2 ...),
    # often with bold + parenthetical annotation. Form 2 now accepts all.
    # Normalized to code `{letter}-{S}-{I}` (epic 1 / AI-2.Y3 → A-2-Y3).
    # The separator row `| --- | --- |` won't match (col 1 = "---").
    table_re = re.compile(
        r"^\|\s*\**\s*AI-(\d+)\.([A-Za-z]\w*|\d+)"
        r"\s*(?:\([^)\n]*\))?\s*\**\s*\|"
        r"\s*([^|\n]+?)\s*\|",
        re.MULTILINE,
    )
    form2_hit = False
    seen_codes = set()
    for m in table_re.finditer(section_text):
        sec, idx = m.group(1), m.group(2)
        title = m.group(3).strip()
        code = f"{letter}-{sec}-{idx}"
        if code in seen_codes:
            continue
        seen_codes.add(code)
        items.append((code, title, None))  # table rows carry no Category (#29)
        form2_hit = True

    # v0.1.31: Form 2 no longer short-circuits — BMad retros frequently mix
    # markdown tables (§8.1-§8.4) with bold-inline bullets (§8.5 团队约定).
    # Run Form 3 too and merge (dedup by code) so the hybrid retro layout
    # produces full retro_action_items seed.

    # Form 3 fallback — bold inline. Accepts:
    #   `**A1** title`           (canonical fallback — code in bold, title outside)
    #   `**A1/A2/A3** shared`     (slash-shared codes)
    #   `**A1 — title**`          (whole-bold, em/en/hyphen sep)
    #   `**A1（title）**：rest`    (whole-bold, CJK paren sep — empirical BMad
    #                              §"团队约定" 写法, v0.1.31 added per issue #1)
    bold_re = re.compile(
        rf"\*\*({re.escape(letter)}\d+(?:/{re.escape(letter)}\d+)*)"
        rf"(?:\s*[—–\-（(]\s*([^*\n]+?))?\*\*"
        rf"\s*([^\n*]*)",
    )
    form3_hit = False
    for m in bold_re.finditer(section_text):
        code_span = m.group(1)
        inner_title = (m.group(2) or "").strip().rstrip("）)").strip()
        outer_title = (m.group(3) or "").strip()
        # Strip leading CJK / ascii colon (whole-bold form leaves `：rest` after `**`)
        outer_title = outer_title.lstrip("：:").strip()
        title = inner_title or outer_title
        for code in code_span.split("/"):
            code = code.strip()
            if code in seen_codes:
                continue
            seen_codes.add(code)
            items.append((code, title, None))  # bold bullets carry no Category (#29)
            form3_hit = True

    if items:
        used = []
        if form2_hit:
            used.append("Form 2 (markdown table `| AI-N.M |` / `| AI-N.X1 |` / "
                        "`| **AI-N.X (注释)** |`)")
        if form3_hit:
            used.append("Form 3 (bold inline `**" + letter + "N**` / "
                        "`**" + letter + "N（title）**`)")
        print(
            f"WARN: _parse_retro_action_items used {' + '.join(used)} fallback "
            f"for {retro_md_path}; canonical form is `### {letter}1 — title`. "
            f"See prompt-suffixes/bmad-retrospective-suffix.md "
            f"§'Action items markdown 格式契约'.",
            file=sys.stderr,
        )
        return items

    # All 3 forms yielded 0. If a §"Action items" section was found, that's
    # schema drift — fail loud at stage 6 (vs silently deferring to ⑥.5).
    if section_found:
        raise RuntimeError(
            f"retro markdown has Action Items section but parser found 0 items "
            f"matching any of 3 forms: "
            f"(1) H3 `### {letter}N — title`, "
            f"(2) markdown table `| AI-N.M |` / `| AI-N.X1 |` / "
            f"`| **AI-N.X (注释)** |`, "
            f"(3) bold inline `**{letter}N** title` / `**{letter}N（title）**`. "
            f"Schema drift — see prompt-suffixes/bmad-retrospective-suffix.md "
            f"§'Action items markdown 格式契约' for canonical format. "
            f"Path: {retro_md_path}"
        )

    return []


def _seed_retro_action_items(epic, retro_md_path, sprint_status_path):
    """Stage 6 commit-time: seed retro_action_items.epic-<epic>-retro block.

    Idempotent: if block exists, only adds codes not already present (Q2
    RESOLVED — 不覆盖 solo-dev 已手工补的 chore_spec 字段). If the
    `epic-N-retro:` subblock is absent under the `retro_action_items:` parent,
    creates the subblock. If the top-level `retro_action_items:` key itself is
    absent, auto-bootstraps it at EOF (v0.1.36, issue #6) — symmetric with the
    subblock auto-create; no longer halts + suggests /bmad-sprint-planning.

    Each new entry is `<code>: pending  # <title from md>`, followed by a
    `      category: dev|harness` subkey line when the retro md's Form 1 H3
    block declares `**Category**: dev|harness` (review 2026-06-10 finding #29
    — the declaration is now machine-consumed; the over-indented subkey shape
    matches what check_retro_action_items.sh / grep_pending_dev_retro_items.sh
    awk state machines read). Undeclared/illegal category → no subkey written
    (gate-side NOCAT behavior unchanged). No chore_spec — that's stage 6-5's
    responsibility per spec Boundaries.

    Returns list of newly-seeded (code, title, category) tuples. Raises
    RuntimeError only on IO failure (or schema drift surfaced earlier by
    _parse_retro_action_items — a §Action items section present but yielding
    0 parseable items).
    """
    letter = _epic_letter(epic)
    if letter is None:
        # v0.1.35 (issue #5): _epic_letter now supports epic > 26 via bijective
        # base-26 (27→AA, ...), so the only remaining None case is a malformed
        # epic arg (non-integer or non-positive) — a caller bug, not user-
        # controllable schema drift. WARN + return [] keeps stage 6 commit
        # non-blocking (the epic arg comes from the orchestrator, not the retro
        # md; a bad arg shouldn't hard-halt an otherwise-valid retro commit).
        # Schema drift (retro md HAS an Action Items section but parser finds 0)
        # is still raised inside _parse_retro_action_items below.
        print(
            f"WARN [_seed_retro_action_items]: epic={epic!r} → _epic_letter "
            f"returned None (epic arg is not a positive integer). Skipping "
            f"retro_action_items seed; stage 6 commit continues.",
            file=sys.stderr,
        )
        return []

    items = _parse_retro_action_items(retro_md_path, letter)
    if not items:
        return []  # legit empty (no Action Items section in retro md)

    if not os.path.exists(sprint_status_path):
        raise RuntimeError(f"sprint-status.yaml not found: {sprint_status_path}")
    with open(sprint_status_path, "r", encoding="utf-8") as f:
        text = f.read()
    lines = text.splitlines(keepends=True)
    # Review 2026-06-10 finding #8: normalize a missing EOF newline ONCE,
    # right after splitting — this covers every insert branch below (append
    # at the end of an existing block / new subblock at section end / parent
    # key bootstrap at EOF). The v0.1.36 fix only patched the bootstrap
    # branch; the other EOF insert points still glued new lines onto the last
    # physical line, producing corrupted single-line YAML that the pre-commit
    # gate then silently passed. The missing-trailing-newline human-edit
    # footgun is an acknowledged real scenario (issue #6).
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"

    rai_marker = "retro_action_items:"
    block_marker_prefix = f"  epic-{epic}-retro:"

    rai_idx = None
    block_idx = None
    block_end_idx = None
    for i, line in enumerate(lines):
        stripped_nl = line.rstrip("\n")
        if stripped_nl == rai_marker or stripped_nl.startswith(rai_marker + " "):
            rai_idx = i
            continue
        if rai_idx is not None and block_idx is None:
            if stripped_nl.startswith(block_marker_prefix):
                block_idx = i
                continue
        if block_idx is not None and block_end_idx is None:
            # End of block: blank line followed by non-indented or new top-level
            stripped = line.lstrip()
            if line.strip() == "":
                continue
            # block lines are indented ≥ 4 spaces ("    A1: pending" or
            # "      chore_spec: ..."); anything less ends the block
            if not line.startswith("    "):
                block_end_idx = i
                break
        if rai_idx is not None and block_idx is None:
            # Detect end of retro_action_items: itself when a top-level (non-
            # indented, non-comment, non-blank) line appears
            if not line.startswith(" ") and not line.startswith("\t") and \
               line.strip() and not line.lstrip().startswith("#"):
                # rai_idx is the line of `retro_action_items:` so any later
                # top-level line ends the section. We only care if block was
                # not yet found — if so, we'll insert before this line.
                if block_idx is None:
                    # Stop scanning; block doesn't exist — note insertion point
                    block_end_idx = i  # repurpose to mark rai end
                    break
    if block_idx is not None and block_end_idx is None:
        block_end_idx = len(lines)

    code_re = re.compile(r"^    ([A-Za-z][A-Za-z0-9-]*):\s")
    existing_codes = set()
    if block_idx is not None:
        for i in range(block_idx + 1, block_end_idx):
            m = code_re.match(lines[i])
            if m:
                existing_codes.add(m.group(1))

    new_items = [it for it in items if it[0] not in existing_codes]
    if not new_items:
        return []  # idempotent

    insert_lines = []
    if block_idx is None:
        # Create new subblock at end of retro_action_items section
        insert_lines.append(f"  epic-{epic}-retro:\n")
    for code, title, category in new_items:
        comment = f"      # {title}" if title else ""
        if comment:
            insert_lines.append(f"    {code}: pending{comment}\n")
        else:
            insert_lines.append(f"    {code}: pending\n")
        if category:
            # Finding #29: over-indented sub-field, same non-standard shape as
            # the stage 6-5 `chore_spec:` fill (see check_retro_action_items.sh
            # "Format note" header comment).
            insert_lines.append(f"      category: {category}\n")

    if block_idx is not None:
        # Append at end of existing block
        new_text = "".join(lines[:block_end_idx] + insert_lines + lines[block_end_idx:])
    elif rai_idx is not None:
        # Parent `retro_action_items:` key exists but the epic-N-retro subblock is
        # missing; insert_lines already begins with the `  epic-N-retro:` header.
        # Insert at the recorded section end (or EOF when rai is the last block).
        insert_at = block_end_idx if block_end_idx is not None else len(lines)
        new_text = "".join(lines[:insert_at] + insert_lines + lines[insert_at:])
    else:
        # v0.1.36 (issue #6): the top-level `retro_action_items:` key itself is
        # absent. Auto-bootstrap it at EOF rather than halting + suggesting
        # /bmad-sprint-planning (which would regenerate the entire sprint —
        # disproportionate for bootstrapping one empty parent key). Symmetric
        # with the subblock auto-create above. EOF-newline normalization now
        # happens once at read time (finding #8), so `lines[-1]` is guaranteed
        # newline-terminated here — the v0.1.36 branch-local patch was removed
        # as redundant.
        prefix = list(lines)
        # Separate the new top-level block from preceding content with one blank
        # line (matches the file's block style) unless EOF is already blank.
        sep = [] if (not prefix or prefix[-1].strip() == "") else ["\n"]
        # insert_lines already starts with `  epic-N-retro:`; prepend the parent
        # key so the result is a well-formed two-level block.
        new_text = "".join(prefix + sep + [f"{rai_marker}\n"] + insert_lines)

    _atomic_write_file(sprint_status_path, new_text)
    return new_items


def _fill_chore_spec_field(epic, sprint_status_path, artifacts_dir):
    """Stage 6-5 commit-time: fill chore_spec field for retro_action_items
    entries by globbing chore-retro-c<epic>-<code>-*.md files.

    Idempotent: skips entries that already have a chore_spec sub-field.
    Returns list of (code, filename) tuples newly filled.

    Implementation note (2026-05-05 codex review F2 fix): uses **code-first
    lookup** (iterate yaml codes → glob filename) instead of filename-first
    regex extraction. Filename-first regex `[A-Z][A-Za-z0-9-]*?` was non-greedy
    and parsed `chore-retro-cN-C-bootstrap-foo.md` as code `C` (wrong); even
    greedy would fail on multi-word slugs like `C-bootstrap-foo-bar.md`
    (capture=`C-bootstrap-foo` instead of `C-bootstrap`). Code-first lookup
    avoids this ambiguity entirely — for each known code from yaml, glob for
    `chore-retro-c<epic>-<code>-*.md`; ambiguity only arises if two codes
    share a common prefix (e.g. `C` and `C-bootstrap`), in which case we
    fail-loud with a WARN.
    """
    if not os.path.exists(sprint_status_path):
        raise RuntimeError(f"sprint-status.yaml not found: {sprint_status_path}")
    if not os.path.isdir(artifacts_dir):
        return []
    with open(sprint_status_path, "r", encoding="utf-8") as f:
        text = f.read()
    lines = text.splitlines(keepends=True)
    # Finding #8 (same as _seed_retro_action_items): normalize a missing EOF
    # newline so the reverse-order inserts below can never glue a
    # `      chore_spec: ...` line onto the last physical line.
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"

    block_marker_prefix = f"  epic-{epic}-retro:"
    rai_marker = "retro_action_items:"

    rai_idx = None
    block_idx = None
    block_end_idx = None
    for i, line in enumerate(lines):
        stripped_nl = line.rstrip("\n")
        if stripped_nl == rai_marker or stripped_nl.startswith(rai_marker + " "):
            rai_idx = i
            continue
        if rai_idx is not None and block_idx is None:
            if stripped_nl.startswith(block_marker_prefix):
                block_idx = i
                continue
        if block_idx is not None and block_end_idx is None:
            if line.strip() == "":
                continue
            if not line.startswith("    "):
                block_end_idx = i
                break
    if block_idx is None:
        return []  # nothing to fill
    if block_end_idx is None:
        block_end_idx = len(lines)

    code_re = re.compile(r"^    ([A-Z][A-Za-z0-9-]*):\s")
    chore_spec_re = re.compile(r"^      chore_spec:\s")

    # 1) Walk yaml block — collect codes that need chore_spec fill.
    codes_needing_fill = []  # (insert_idx, code)
    i = block_idx + 1
    while i < block_end_idx:
        line = lines[i]
        m = code_re.match(line)
        if m:
            code = m.group(1)
            j = i + 1
            has_chore_spec = False
            while j < block_end_idx:
                nxt = lines[j]
                if chore_spec_re.match(nxt):
                    has_chore_spec = True
                    break
                if code_re.match(nxt):
                    break  # next code entry
                if nxt.startswith("      ") or nxt.lstrip().startswith("#") or nxt.strip() == "":
                    j += 1
                    continue
                break
            if not has_chore_spec:
                codes_needing_fill.append((i + 1, code))
        i += 1

    if not codes_needing_fill:
        return []

    # 2) Code-first lookup: for each code, glob chore-retro-c<epic>-<code>-*.md.
    #    Slug is `[a-z0-9-]+` so glob `<code>-*.md` plus regex narrowing avoids
    #    ambiguity even when codes share prefix (`C` vs `C-bootstrap`): we
    #    require the char immediately after `<code>-` to be lowercase or digit.
    inserts = []
    listing = sorted(os.listdir(artifacts_dir))
    for insert_idx, code in codes_needing_fill:
        prefix = f"chore-retro-c{epic}-{code}-"
        # Slug matcher: starts with [a-z0-9] (excludes uppercase to disambiguate
        # codes whose prefix is itself a valid code, e.g. `C` vs `C-bootstrap`)
        slug_re = re.compile(rf"^{re.escape(prefix)}[a-z0-9][a-z0-9-]*\.md$")
        candidates = [f for f in listing if slug_re.match(f)]
        if not candidates:
            continue
        if len(candidates) > 1:
            # Multiple matching files for one code — surface as WARN (don't fill;
            # let solo-dev resolve manually). Should not happen in practice
            # (residue processor outputs one spec per code).
            print(
                f"WARN [_fill_chore_spec_field]: code {code!r} matched "
                f"{len(candidates)} files: {candidates}; skipping fill",
                file=sys.stderr,
            )
            continue
        fname = candidates[0]
        inserts.append((insert_idx, f"      chore_spec: '{fname}'\n", code, fname))

    if not inserts:
        return []

    # Apply inserts in reverse-order to preserve indices
    new_lines = list(lines)
    for idx, line, _c, _f in sorted(inserts, key=lambda x: -x[0]):
        new_lines = new_lines[:idx] + [line] + new_lines[idx:]
    new_text = "".join(new_lines)
    _atomic_write_file(sprint_status_path, new_text)

    return [(c, f) for _, _, c, f in inserts]


def _run_seed_simulation(epic):
    """Test fixture: simulate stage 6 retro_action_items seed without
    touching real sprint-status.yaml / worktree.

    1. Build a fake sprint-status.yaml with empty retro_action_items section.
    2. Synthesize a retro markdown with 5 D items (always "D" letter — this
       is a fixture, not a real seed; epic arg only controls block name).
    3. Run _seed_retro_action_items against the temp file (it'll detect the
       hardcoded D items if epic letter resolves to D, else skip — test
       infrastructure verifies both paths).
    4. Print resulting block + which items were seeded.

    Synthetic items always use letter "D"; when the supplied epic's letter is
    not "D" (i.e. epic != 4 — _epic_letter is bijective base-26 since v0.1.35,
    so epic 27 → "AA", never None for positive ints), the seed falls back to
    `seed_epic=4` so the D items still seed and the block-creation path is
    still exercised (review 2026-06-10 finding #75 docstring refresh).
    """
    sim_letter = "D"  # synthetic items always use D regardless of epic
    real_letter = _epic_letter(epic)
    tmpdir = tempfile.mkdtemp(prefix="harness-commit-sim-")
    try:
        fake_sprint = os.path.join(tmpdir, "sprint-status.yaml")
        with open(fake_sprint, "w", encoding="utf-8") as f:
            f.write(
                "development_status:\n"
                f"  epic-{epic}: backlog\n"
                "\n"
                "retro_action_items:\n"
                "  epic-1-retro:\n"
                "    A1: done\n"
                "\n"
                "test_status: {}\n"
            )
        fake_md = os.path.join(tmpdir, f"epic-{epic}-retro-2026-05-04.md")
        with open(fake_md, "w", encoding="utf-8") as f:
            f.write(f"# Epic {epic} Retrospective (simulation)\n\n## 6. Action Items\n\n")
            for n in range(1, 6):
                f.write(f"### {sim_letter}{n} — synthetic action item {n}\n")
                # Items 1-2 declare dev, 3 declares harness, 4-5 omit the
                # declaration — exercises the finding #29 category round trip
                # (dev / harness / NOCAT) in one fixture.
                if n <= 2:
                    f.write("**Category**: dev\n")
                elif n == 3:
                    f.write("**Category**: harness\n")
                f.write("Action: simulated\n\n")

        # For real seed exercising, override epic to one whose letter == sim_letter
        # so the seed picks up the synthetic items. We seed under the user-
        # supplied epic block name regardless (so block-creation path still works).
        seed_epic = epic if real_letter == sim_letter else "4"  # fallback to epic-4 (D)
        if seed_epic != epic:
            # Rewrite the fake yaml's existing retro_action_items entry to match seed_epic
            with open(fake_sprint, "r", encoding="utf-8") as f:
                yaml_text = f.read()
            yaml_text = yaml_text.replace("epic-1-retro:", f"epic-{seed_epic}-retro-old:")
            with open(fake_sprint, "w", encoding="utf-8") as f:
                f.write(yaml_text)

        seeded = _seed_retro_action_items(seed_epic, fake_md, fake_sprint)
        emit(f"STATUS=ok")
        emit(f"REASON=stage 6 seed simulation (epic={epic} sim_letter={sim_letter} seed_epic={seed_epic})")
        emit(f"SEEDED_COUNT={len(seeded)}")
        for code, title, category in seeded:
            emit(f"SEEDED_ITEM={code} title={title!r} category={category or 'NOCAT'}")
        with open(fake_sprint, "r", encoding="utf-8") as f:
            yaml_text = f.read()
        # Print block-only excerpt
        block_marker = f"  epic-{seed_epic}-retro:"
        in_block = False
        for ln in yaml_text.splitlines():
            if ln.startswith(block_marker):
                in_block = True
                emit(f"YAML={ln}")
                continue
            if in_block:
                # Stop block when line is non-indented (top-level)
                if ln and not ln.startswith(" "):
                    break
                emit(f"YAML={ln}")
    finally:
        # cleanup
        for n in os.listdir(tmpdir):
            try:
                os.remove(os.path.join(tmpdir, n))
            except OSError:
                pass
        try:
            os.rmdir(tmpdir)
        except OSError:
            pass


def run(cmd):
    # Two CJK-safety fixes baked in for every subcommand:
    #
    # (a) Inject `-c core.quotepath=false` for git so CJK paths are returned as
    #     raw UTF-8 instead of C-style octal escapes — otherwise CJK story keys
    #     (e.g. `1-1-后端工程脚手架与公共基础设施.md`) come out double-quoted
    #     and miss every artifact-classifier regex downstream.
    #
    # (b) `errors="replace"` on text decode — `git diff --stat` truncates long
    #     filenames at column width and can chop a multi-byte UTF-8 sequence
    #     mid-codepoint; default strict decode would raise UnicodeDecodeError
    #     and crash the commit pipeline. Replacement char is harmless here
    #     since stat output is human-readable summary, not parsed.
    if cmd and cmd[0] == "git" and (len(cmd) < 3 or cmd[1] != "-c" or not cmd[2].startswith("core.quotepath")):
        cmd = ["git", "-c", "core.quotepath=false"] + list(cmd[1:])
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace", check=False)


def glob_match(path, pattern):
    """fnmatch with gitignore-style `**`, `*` as single-segment, `?` as single-char.

    `**` semantics (review 2026-06-10 finding #7):
      - leading/interior `**/` = ZERO or more whole directory segments, so
        `**/.env*` matches both repo-root `.env` and `config/.env`. The old
        translation turned every `**` into `.*`, compiling `**/.env*` to
        `.*/\\.env[^/]*` — the literal `/` forced at least one parent dir and
        every repo-root credential file silently bypassed the blacklist.
      - trailing `/**` = the directory itself plus anything beneath it
        (`secrets/api.txt` now matches `**/secrets/**` at the repo root too).
      - `**` embedded inside a segment (e.g. `a**b`) keeps the legacy
        any-chars `.*` semantics for backward compat (no shipped pattern
        uses this form).
    """
    segs = pattern.split("/")
    n = len(segs)
    regex_parts = []
    for i, seg in enumerate(segs):
        last = (i == n - 1)
        if seg == "**":
            if last:
                # Trailing `**` — match the already-consumed prefix itself or
                # anything beneath it. A bare `**` pattern matches everything.
                regex_parts.append(".*" if i == 0 else "(?:/.*)?")
            else:
                # `**/` — zero or more whole segments, each group iteration
                # consumes its own trailing slash (so no "/" joiner below).
                regex_parts.append("(?:[^/]+/)*")
            continue
        sub = []
        j = 0
        while j < len(seg):
            if seg.startswith("**", j):
                sub.append(".*")  # embedded `**` — legacy any-chars semantics
                j += 2
            elif seg[j] == "*":
                sub.append("[^/]*")
                j += 1
            elif seg[j] == "?":
                sub.append("[^/]")
                j += 1
            else:
                sub.append(re.escape(seg[j]))
                j += 1
        regex_parts.append("".join(sub))
        if not last:
            # Joiner slash — except before a trailing `**`, whose `(?:/.*)?`
            # group supplies its own optional slash.
            if not (segs[i + 1] == "**" and i + 1 == n - 1):
                regex_parts.append("/")
    return re.fullmatch("".join(regex_parts), path) is not None


def is_i18n_locale_json(path):
    """Return True if `path` is a `.json` file living under a conventional
    i18n / locale directory segment (issue #5). Used to exempt UI-translation
    files (e.g. `.../i18n/locales/zh-CN/personal-credentials.json`) from the
    credentials blacklist. The dir segment must be an interior path component
    (not the basename), so a top-level file literally named `i18n.json` won't
    qualify."""
    if not path.endswith(".json"):
        return False
    segments = path.split("/")
    return any(seg in _I18N_LOCALE_DIR_SEGMENTS for seg in segments[:-1])


def is_out_of_scope_bmad_output(path):
    """Return True if `path` lives under the _bmad-output/ tree but OUTSIDE the
    in-scope implementation-artifacts/ subtree (issue #5). Such paths are
    sibling BMad planning docs (brainstorming/, planning-artifacts/, research/,
    ...) that must not be swept into a story commit. Returns False when the
    guard is disabled (_BMAD_OUTPUT_PREFIX is None)."""
    if _BMAD_OUTPUT_PREFIX is None:
        return False
    if not path.startswith(_BMAD_OUTPUT_PREFIX):
        return False
    return not path.startswith(_BMAD_OUTPUT_INSCOPE_PREFIX)


def matches_blacklist(path):
    # v0.1.32 (issue #2): BMad artifacts engineering products are exempt from
    # blacklist scanning entirely — see _ARTIFACTS_ALLOW_PREFIX comment block
    # above for the design rationale.
    if path.startswith(_ARTIFACTS_ALLOW_PREFIX) and \
       path.endswith(_ARTIFACTS_ALLOW_SUFFIXES):
        return None
    # v0.1.35 (issue #5): i18n locale JSON files are exempt — see
    # _I18N_LOCALE_DIR_SEGMENTS comment block above.
    if is_i18n_locale_json(path):
        return None
    for pat in BLACKLIST_PATTERNS:
        if glob_match(path, pat):
            return pat
    return None


def matches_junk(path):
    """Return the JUNK_PATTERNS pattern `path` matches, or None.

    Junk tier (review 2026-06-10 findings #1/#7 red line): OS/editor/bytecode
    droppings are auto-skipped — never staged, never a halt. Pure pattern
    match, no artifacts/i18n exemptions (those exist to prevent halts on
    legitimate files; junk patterns can't match legitimate artifacts). The
    tracked-vs-untracked scoping lives in the callers (filter_junk_paths /
    step-6 exemption), which pair this with a HEAD-membership check."""
    for pat in JUNK_PATTERNS:
        if glob_match(path, pat):
            return pat
    return None


def path_in_head(path):
    """True if `path` exists in the HEAD tree (i.e. it is a tracked file).

    On an unborn branch (no HEAD yet) every path reports False — nothing is
    tracked, so junk filtering applies to the whole worktree, which is the
    correct fresh-repo behavior."""
    r = run(["git", "cat-file", "-e", f"HEAD:{path}"])
    return r.returncode == 0


_junk_noted = set()


def _note_junk(path):
    """Emit one `NOTE: skipped junk file:` stderr line per path per run."""
    if path not in _junk_noted:
        _junk_noted.add(path)
        print(f"NOTE: skipped junk file: {path}", file=sys.stderr)


def filter_junk_paths(paths, dry_run=False):
    """Drop junk-tier paths that are NOT in HEAD from a porcelain_paths() list.

    Scope (regression fix 2026-06-10 R1 — the old version unstaged/dropped
    EVERY junk-pattern match, so a tracked access.log edit was silently
    excluded from the commit and a `git rm`'d .DS_Store deletion was unstaged
    and never committed):

      - xy == '??' (untracked): dropped outright — classic OS/editor dropping.
      - xy[0] == 'A' (newly added to the index, confirmed absent from HEAD via
        `git cat-file -e`): `git restore --staged` to unstage, then dropped —
        but ONLY if the restore succeeds. On a non-zero restore exit the path
        STAYS in the list and flows through normal classification; it is never
        silently lost. When dry_run, the restore is skipped and the path is
        dropped as if it had succeeded (dry-run never mutates the index).
      - Everything else (tracked modifications ' M'/'M ', deletions 'D',
        renames, ...): KEPT — tracked files always flow through the regular
        pipeline, mirroring the auto-prune invariant 'Modified existing files
        never auto-delete'.

    For each dropped path, emit one `NOTE: skipped junk file: <path>` line on
    stderr (once per path per run — re-fetches don't repeat the note)."""
    kept = []
    for xy, p in paths:
        if matches_junk(p):
            if xy == "??":
                _note_junk(p)
                continue
            if xy[0] == "A" and not path_in_head(p):
                if dry_run:
                    _note_junk(p)
                    continue
                r = run(["git", "restore", "--staged", "--", p])
                if r.returncode == 0:
                    _note_junk(p)
                    continue
                # restore failed — fall through to kept: the path goes
                # through normal classification instead of being silently
                # dropped while still staged.
        kept.append((xy, p))
    return kept


def read_cross_story_allowlist(key):
    """Parse story md frontmatter for `cross_story_artifacts:` field.

    Returns set of allowed cross-story artifact filenames (just the basename
    inside _bmad-output/implementation-artifacts/, not full paths). Empty set
    if frontmatter missing or field absent.

    Format (in story md head, before any `## ` heading):

        ---
        cross_story_artifacts:
          - 1-7-proxy-fork-addon-framework-unix-socket.md
          - spec-deferred-cleanup-2026-05-02-console-web-container-build.md
        ---

    Restrictions enforced here:
    - Each entry must be a bare basename (no `/`, no `..`).
    - Each entry must end with `.md` (declarative spec / story files only;
      cross-story `.json` / `.yaml` would be a different threat surface).
    - Entries must NOT be `<KEY>.*` (that's the current story's own artifacts,
      already allowed by default — listing redundantly is a smell).
    Invalid entries are silently dropped (the field is best-effort).
    """
    path = f"{ARTIFACTS_DIR}{key}.md"
    if not os.path.exists(path):
        return set()
    allowed = set()
    in_frontmatter = False
    in_field = False
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line_idx, line in enumerate(f):
                stripped = line.rstrip()
                if line_idx == 0:
                    if stripped == "---":
                        in_frontmatter = True
                        continue
                    # No frontmatter — bail out. Story md without `---` head
                    # cannot declare cross_story_artifacts; the field requires
                    # a YAML frontmatter block to live in.
                    return set()
                if not in_frontmatter:
                    return set()  # already past frontmatter, nothing to find
                if stripped == "---":
                    return allowed  # end of frontmatter
                if not in_field:
                    if stripped.startswith("cross_story_artifacts:"):
                        in_field = True
                    continue
                # In field — accept `  - <basename>` lines until next non-list
                m = re.match(r"^\s+-\s+(.+?)\s*$", line)
                if m:
                    val = m.group(1).strip().strip("'").strip('"')
                    # Validate: basename only, .md suffix, not own story
                    if "/" in val or ".." in val:
                        continue
                    if not val.endswith(".md"):
                        continue
                    if val == f"{key}.md" or val.startswith(f"{key}."):
                        continue
                    allowed.add(val)
                else:
                    # Non-list-item line ends the field
                    in_field = False
                    if stripped.startswith("cross_story_artifacts:"):
                        in_field = True  # weird repeat, tolerate
    except OSError:
        return set()
    return allowed


def _lookup_chore_spec_from_yaml(epic, code):
    """Read the `chore_spec:` sub-field recorded for `code` in the
    sprint-status.yaml `retro_action_items.epic-<epic>-retro` block.

    Returns the validated filename (basename) or None. The value must match
    `chore-retro-c<epic>-<code>-<slug>.md` exactly — a stale/foreign value
    falls back to None rather than authorizing the wrong spec.

    Path note: uses the CWD-relative `ARTIFACTS_DIR` form (same as every
    other file op in this module) rather than get_sprint_status_path() —
    the two are equivalent in production (CWD = repo root,
    sprint_status = artifacts_root/sprint-status.yaml) and the relative form
    keeps the function testable against tmp fixture repos."""
    try:
        with open(f"{ARTIFACTS_DIR}sprint-status.yaml", "r", encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    block_marker_prefix = f"  epic-{epic}-retro:"
    rai_seen = False
    in_block = False
    in_entry = False
    code_re = re.compile(r"^    ([A-Za-z][A-Za-z0-9-]*):\s")
    chore_spec_re = re.compile(r"^      chore_spec:\s*['\"]?([^'\"\n]+?)['\"]?\s*$")
    for line in lines:
        stripped_nl = line.rstrip("\n")
        if stripped_nl == "retro_action_items:" or \
           stripped_nl.startswith("retro_action_items: "):
            rai_seen = True
            continue
        if not rai_seen:
            continue
        if not in_block:
            if stripped_nl.startswith(block_marker_prefix):
                in_block = True
            continue
        if line.strip() and not line.startswith("    "):
            break  # end of the epic-N-retro block
        m = code_re.match(line)
        if m:
            in_entry = (m.group(1) == code)
            continue
        if in_entry:
            m = chore_spec_re.match(line)
            if m:
                val = m.group(1).strip()
                if re.fullmatch(
                    rf"chore-retro-c{re.escape(str(epic))}-{re.escape(code)}-[a-z0-9][a-z0-9-]*\.md",
                    val,
                ):
                    return val
                return None
    return None


def _resolve_spec_md_path(key, epic, stage):
    """Resolve the spec md whose frontmatter governs this commit (issue #9).

    Story stages: `<ARTIFACTS_DIR><key>.md` (key is the story key). Stage
    retro-fulfill: `key` is the retro action item code (e.g. E11), not a
    story key — the governing spec is the chore spec
    `chore-retro-c<epic>-<code>-<slug>.md`. Resolution order:

    1. The `chore_spec:` field recorded for this code in sprint-status.yaml
       retro_action_items (written by stage 6-5; §0.A.0 only fulfills items
       that have it) — authoritative and immune to code-prefix ambiguity.
    2. Fallback glob `chore-retro-c<epic>-<code>-*.md` with the same slug
       shape as _fill_chore_spec_field. NOTE: the `[a-z0-9]` slug-start only
       blocks UPPERCASE continuations (`C` vs `C2`); two lowercase-kebab
       codes that prefix each other (`E-flyway` vs `E-flyway-extra`) DO
       cross-match here, which is why the yaml field is consulted first.
       Multiple candidates → WARN + None (fail-closed: frontmatter
       whitelists are simply not honored for this commit).

    Returns None when no unambiguous spec exists.
    """
    if stage == "retro-fulfill":
        if not epic:
            return None
        fname = _lookup_chore_spec_from_yaml(epic, key)
        if fname:
            path = f"{ARTIFACTS_DIR}{fname}"
            if os.path.exists(path):
                return path
        prefix = f"chore-retro-c{epic}-{key}-"
        slug_re = re.compile(rf"^{re.escape(prefix)}[a-z0-9][a-z0-9-]*\.md$")
        try:
            listing = sorted(os.listdir(ARTIFACTS_DIR.rstrip("/")))
        except OSError:
            return None
        candidates = [f for f in listing if slug_re.match(f)]
        if len(candidates) > 1:
            print(
                f"WARN [_resolve_spec_md_path]: code {key!r} matched "
                f"{len(candidates)} chore specs: {candidates}; ignoring "
                f"frontmatter whitelists for this commit",
                file=sys.stderr,
            )
            return None
        if not candidates:
            return None
        return f"{ARTIFACTS_DIR}{candidates[0]}"
    path = f"{ARTIFACTS_DIR}{key}.md"
    return path if os.path.exists(path) else None


# The only _bmad-output/ sibling subtree a spec may declare writebacks into
# (issue #9). brainstorming/ / research/ etc. stay halt-only — no observed
# legitimate story-pipeline writeback target outside planning-artifacts/.
_PLANNING_ARTIFACTS_SUBDIR = "planning-artifacts/"


def read_planning_artifacts_allowlist(key, epic, stage):
    """Parse spec md frontmatter for `planning_artifacts:` field (issue #9).

    A chore/story spec may explicitly mandate writing back planning docs —
    the observed case: a forward-only remediation chore (epic-5 retro E11)
    whose Tasks require updating `_bmad-output/planning-artifacts/epics.md`
    (AC text + drift-registry table). Without a declaration channel the
    out-of-scope guard (step 2.5, issue #5) halts on exactly the writeback
    the spec demands, forcing a manual out-of-band commit. This whitelist is
    the pass-through: declared paths bypass the step-2.5 halt and are staged
    as project paths with an informational `PLANNING_ARTIFACT=` line.

    Format (spec md head, before any `## ` heading) — full repo-relative
    paths, deliberately NOT bare basenames (unlike `cross_story_artifacts:`)
    so the declaration is unambiguous about which tree it touches:

        ---
        planning_artifacts:
          - _bmad-output/planning-artifacts/epics.md
        ---

    Restrictions enforced here (invalid entries silently dropped — the field
    is best-effort, same posture as cross_story_artifacts):
    - entry must live under `<bmad-output-parent>/planning-artifacts/`
      (prefix derived from the configured artifacts_root, so the field
      follows a custom artifacts_root like everything else)
    - entry must end with `.md` (planning docs only; .yaml/.json planning
      state would be a different threat surface)
    - no `..` traversal, no absolute paths

    Returns set of repo-relative path strings; empty set when the spec md is
    missing/ambiguous, frontmatter absent, field absent, or the out-of-scope
    guard is disabled (_BMAD_OUTPUT_PREFIX is None — nothing to exempt from).

    Parser structure deliberately mirrors read_cross_story_allowlist (same
    frontmatter walk, same tolerance for a repeated field header) — kept as a
    separate function rather than refactoring the reviewed original.
    """
    if _BMAD_OUTPUT_PREFIX is None:
        return set()
    spec_path = _resolve_spec_md_path(key, epic, stage)
    if spec_path is None:
        return set()
    required_prefix = _BMAD_OUTPUT_PREFIX + _PLANNING_ARTIFACTS_SUBDIR
    allowed = set()
    in_frontmatter = False
    in_field = False
    try:
        with open(spec_path, "r", encoding="utf-8") as f:
            for line_idx, line in enumerate(f):
                stripped = line.rstrip()
                if line_idx == 0:
                    if stripped == "---":
                        in_frontmatter = True
                        continue
                    return set()
                if not in_frontmatter:
                    return set()
                if stripped == "---":
                    return allowed  # end of frontmatter
                if not in_field:
                    if stripped.startswith("planning_artifacts:"):
                        in_field = True
                    continue
                m = re.match(r"^\s+-\s+(.+?)\s*$", line)
                if m:
                    val = m.group(1).strip().strip("'").strip('"')
                    if val.startswith("/") or ".." in val:
                        continue
                    if not val.endswith(".md"):
                        continue
                    if not val.startswith(required_prefix):
                        continue
                    allowed.add(val)
                else:
                    in_field = False
                    if stripped.startswith("planning_artifacts:"):
                        in_field = True  # weird repeat, tolerate
    except OSError:
        return set()
    return allowed


def cross_story_ok(path, key, epic, cross_story_allowlist=None, chore_retro=False):
    """Return True if path is allowed under §-1.d step 3.

    cross_story_allowlist: optional set of cross-story artifact basenames
    declared in the story md frontmatter (`cross_story_artifacts:`). If a
    path's basename is in this set, it's treated as a legitimate cross-story
    deliverable — see harness-changelog 2026-05-03 §B.

    chore_retro: when True (stage 6-5), allow chore-retro-c${epic}-*.md as
    legitimate cross-story artifacts (no story key concept — chore residue
    processor batches multiple chore specs in one commit).
    """
    m = ARTIFACT_RE.match(path)
    if not m:
        return True  # non-artifact paths aren't subject to this rule
    fname = m.group(1)
    if fname == f"{key}.md" or fname.startswith(f"{key}."):
        return True
    if fname in ("sprint-status.yaml", "deferred-work.md"):
        return True
    if epic and re.fullmatch(rf"epic-{re.escape(epic)}-retro-.+\.md", fname):
        return True
    if chore_retro and epic and re.fullmatch(rf"chore-retro-c{re.escape(epic)}-[A-Z][A-Za-z0-9-]*-[a-z0-9-]+\.md", fname):
        return True
    if cross_story_allowlist and fname in cross_story_allowlist:
        return True
    return False


def is_expected_artifact(path, key, epic, spec, cross_story_allowlist=None):
    m = ARTIFACT_RE.match(path)
    if not m:
        return False
    fname = m.group(1)
    if spec["story_md"] and fname == f"{key}.md":
        return True
    for suf in spec["story_json"]:
        if fname == f"{key}{suf}":
            return True
    if spec["story_codex"] and fname == f"{key}.codex-review.md":
        return True
    if fname in spec["global_files"]:
        return True
    if spec["epic_retro"] and epic and re.fullmatch(rf"epic-{re.escape(epic)}-retro-.+\.md", fname):
        return True
    if spec.get("chore_retro") and epic and re.fullmatch(rf"chore-retro-c{re.escape(epic)}-[A-Z][A-Za-z0-9-]*-[a-z0-9-]+\.md", fname):
        return True
    # Frontmatter `cross_story_artifacts:` whitelist — symmetric with gate 1
    # (cross_story_ok line 1481). Both gates must honor the same declaration,
    # else a properly-declared spec passes §-1.d step 3 but trips §0.5.
    if cross_story_allowlist and fname in cross_story_allowlist:
        return True
    return False


def classify(path, key, epic, spec, cross_story_allowlist=None):
    """Return one of: 'expected', 'unexpected_artifact', 'project', 'forbidden'.

    'project' = staged. No path-level allowlist anymore — any project code is fine
    on stages that allow project_code (2/4/5). Real safety lives in BLACKLIST_PATTERNS
    (creds / .claude / _bmad), cross-story isolation, and schema gates.
    See harness-changelog 2026-05-01 §J.

    Review 2026-06-10 finding #32: any path under ARTIFACTS_DIR that is
    neither a direct-child md/json/yaml/yml (ARTIFACT_RE) nor under
    test_artifacts/ (validated separately by the F1 gate, step 3.5) is an
    unexpected artifact — previously such paths (e.g. a nested
    `implementation-artifacts/notes/<other-story>.md`) fell through to the
    project-code bucket and were silently committed under the current story,
    bypassing artifact classification AND cross-story isolation.
    """
    if ARTIFACT_RE.match(path):
        if is_expected_artifact(path, key, epic, spec, cross_story_allowlist):
            return "expected"
        return "unexpected_artifact"
    if path.startswith(ARTIFACTS_DIR) and not TEST_ARTIFACT_RE.match(path):
        # In the artifacts tree but not a recognized artifact shape and not a
        # test artifact (those passed F1 already) → never project code (#32).
        return "unexpected_artifact"
    if spec["project_code"]:
        return "project"
    return "forbidden"


def _parse_porcelain_z(out):
    """Parse `git status --porcelain -z` output into a list of (xy, path).

    -z entries are NUL-terminated `XY <path>` records; rename/copy entries
    carry the ORIGINAL path as one extra NUL-terminated field after the new
    path (we keep the new path, skip the original). Review 2026-06-10
    finding #79: the line-oriented parser consumed C-quoted paths literally
    (`?? "weird\\"quote.txt"` — core.quotepath=false only unescapes
    non-ASCII, not quotes/control chars), so os.stat / classifiers /
    `git add` all operated on a nonexistent literal path; and the ` -> `
    substring split mis-parsed untracked filenames containing a literal
    ` -> `. With -z, paths are always raw bytes (never quoted) and renames
    are unambiguous fields — both failure modes are gone.
    """
    fields = out.split("\0")
    entries = []
    i = 0
    while i < len(fields):
        f = fields[i]
        if len(f) < 4 or f[2] != " ":
            i += 1
            continue
        xy = f[:2]
        path = f[3:]
        entries.append((xy, path))
        # Rename/copy: skip the following orig-path field.
        if "R" in xy or "C" in xy:
            i += 2
        else:
            i += 1
    return entries


def porcelain_paths():
    """Return list of (xy, path) from `git status --porcelain -uall -z`. For renames, take the new path.

    `-uall` (review 2026-06-10 finding #1): without it, a fully-untracked new
    directory collapses into a single `?? dir/` line, so files inside (e.g.
    `config/.env`) were invisible to the blacklist scan and the whole dir got
    `git add`ed as one opaque path. `-uall` expands every untracked file into
    its own line. The step-6 unstaged-remainder check uses the same flags so
    both reads share one path universe.

    `-z` (finding #79): NUL-delimited raw paths — no C-quoting for filenames
    containing quotes/backslashes/newlines, no ` -> ` rename ambiguity. CJK
    paths arrive as raw UTF-8 (with -z that holds even without the
    core.quotepath=false the `run()` helper injects).
    """
    r = run(["git", "status", "--porcelain", "-uall", "-z"])
    if r.returncode != 0:
        return None, r.stderr.strip()
    out = []
    seen = set()
    for xy, rest in _parse_porcelain_z(r.stdout):
        if rest not in seen:
            seen.add(rest)
            out.append((xy, rest))
    return out, None


def emit(line):
    """Emit one key=value status line on stdout."""
    print(line)


def main():
    parser = argparse.ArgumentParser(description="Sprint pipeline commit helper")
    parser.add_argument("stage", choices=list(STAGES.keys()))
    parser.add_argument("key", help="story key, e.g. 1-2-console-api-skeleton")
    parser.add_argument("--epic", default=None, help="epic number, required for stages 6 / 6-done")
    parser.add_argument("--dry-run", action="store_true", help="do everything except `git add`")
    parser.add_argument(
        "--simulate-retro-md-with-d-items",
        action="store_true",
        help=(
            "Test-only: run a self-contained stage-6 seed simulation "
            "(synthetic retro md with 5 D items, tempdir-isolated copy of "
            "sprint-status.yaml). Requires stage 6 + --epic; exits before any "
            "git interaction, so real worktree/state is never touched "
            "(--dry-run not required — review 2026-06-10 finding #75)."
        ),
    )
    args = parser.parse_args()

    spec = STAGES[args.stage]
    key = args.key
    epic = args.epic

    # Self-contained simulation path (T1.2 verification fixture; bypasses git
    # + real sprint-status.yaml entirely). Synthesizes a retro md with D1..D5
    # under a tempdir, calls _seed_retro_action_items against a tempdir copy
    # of sprint-status.yaml, prints diff, exits 0. Does NOT modify real state.
    if args.simulate_retro_md_with_d_items:
        if args.stage != "6":
            emit("STATUS=halt")
            emit("REASON=--simulate-retro-md-with-d-items only valid for stage 6")
            sys.exit(1)
        if not epic:
            emit("STATUS=halt")
            emit("REASON=--simulate-retro-md-with-d-items requires --epic")
            sys.exit(1)
        _run_seed_simulation(epic)
        sys.exit(0)

    if args.stage in ("6", "6-5", "6-done", "T1", "retro-fulfill") and not epic:
        emit("STATUS=halt")
        emit(f"REASON=stage {args.stage} requires --epic")
        sys.exit(1)

    paths, err = porcelain_paths()
    if paths is None:
        emit("STATUS=halt")
        emit(f"REASON=git status failed: {err}")
        sys.exit(1)

    # 1b — junk-tier auto-skip (review 2026-06-10 findings #1/#7 red line;
    # scope narrowed by R1 regression fix): untracked/newly-added .DS_Store /
    # *.tmp / *.swp / __pycache__ / *.pyc paths NOT in HEAD are dropped from
    # the working set before ANY gate runs — never staged, never a halt. One
    # stderr NOTE per file. Tracked junk-pattern paths flow through the
    # normal pipeline. A worktree that contains ONLY (untracked) junk counts
    # as empty (skip_if_empty stages exit 2 as usual).
    paths = filter_junk_paths(paths, dry_run=args.dry_run)

    if not paths:
        if spec["skip_if_empty"]:
            emit("STATUS=skip")
            emit(f"REASON=no worktree changes for stage {args.stage}; skip commit (already covered by previous step)")
            sys.exit(2)
        emit("STATUS=halt")
        emit(f"REASON=no worktree changes for stage {args.stage} but stage requires non-empty output")
        sys.exit(1)

    # 1.5 — auto-resolve build artifacts (Opt 1; harness-changelog 2026-05-01 §I)
    # Only on stages that allow project_code (2/4/5) — other stages forbid project
    # code anyway, so a binary blob there is a real protocol violation.
    auto_fixes = []
    if spec["project_code"] and not args.dry_run:
        for p, size in detect_build_artifacts(paths):
            size_mb = auto_resolve_build_artifact(p)
            if size_mb is not None:
                auto_fixes.append((p, size_mb))
        if auto_fixes:
            # Re-fetch worktree state (we removed files + added .gitignore)
            paths, err = porcelain_paths()
            if paths is None:
                emit("STATUS=halt")
                emit(f"REASON=git status failed after auto-resolve: {err}")
                sys.exit(1)
            paths = filter_junk_paths(paths, dry_run=args.dry_run)

    # 1.6 — auto-prune subagent-spilled extra .md artifacts (Opt 2;
    # harness-changelog 2026-05-03 §A) + redundant process-marker .json
    # files (issue #8, v0.1.39). Applies to all stages; both rules check
    # exact suffix shape against an explicit tag enumeration so they can't
    # match canonical artifacts.
    extra_prunes = []
    marker_prunes = []
    if not args.dry_run:
        for p, tag in detect_subagent_extras(paths, key):
            if auto_prune_subagent_extra(p):
                extra_prunes.append((p, tag))
        for p, tag in detect_process_markers(paths, key):
            if auto_prune_subagent_extra(p):
                marker_prunes.append((p, tag))
        if extra_prunes or marker_prunes:
            paths, err = porcelain_paths()
            if paths is None:
                emit("STATUS=halt")
                emit(f"REASON=git status failed after extra-prune: {err}")
                sys.exit(1)
            paths = filter_junk_paths(paths, dry_run=args.dry_run)
            # A worktree that contained ONLY auto-pruned spills is now empty —
            # re-run the step-1b emptiness branch so the caller gets skip/halt
            # instead of a STATUS=ok that would suggest committing nothing.
            if not paths:
                if spec["skip_if_empty"]:
                    emit("STATUS=skip")
                    emit(f"REASON=worktree contained only auto-pruned files for stage {args.stage}; nothing left to commit")
                    sys.exit(2)
                emit("STATUS=halt")
                emit(f"REASON=worktree contained only auto-pruned files (extra .md / process markers) for stage {args.stage} — nothing left to commit but stage requires non-empty output")
                for p, tag in extra_prunes:
                    emit(f"AUTO_FIXED=unexpected-md {p} action=unstaged+rm extra={tag}")
                for p, tag in marker_prunes:
                    emit(f"AUTO_FIXED=process-marker {p} action=unstaged+rm tag={tag}")
                sys.exit(1)
    else:
        # dry-run: detect read-only and exclude would-be prunes from
        # classification, so a dry-run predicts the real-run outcome instead
        # of halting UNEXPECTED_ARTIFACT on a marker the real run auto-fixes
        # (same posture as filter_junk_paths dry_run handling). Scoped to
        # process markers (new in v0.1.39); the extra-md dry-run divergence
        # is pre-existing Opt 2 behavior and unchanged here.
        marker_prunes = detect_process_markers(paths, key)
        if marker_prunes:
            pruned = {p for p, _ in marker_prunes}
            paths = [(xy, p) for xy, p in paths if p not in pruned]
            if not paths:
                if spec["skip_if_empty"]:
                    emit("STATUS=skip")
                    emit(f"REASON=worktree contained only auto-pruned files for stage {args.stage}; nothing left to commit")
                    sys.exit(2)
                emit("STATUS=halt")
                emit(f"REASON=worktree contained only auto-pruned files (extra .md / process markers) for stage {args.stage} — nothing left to commit but stage requires non-empty output")
                for p, tag in marker_prunes:
                    emit(f"AUTO_FIXED=process-marker {p} action=planned-unstage+rm-dry-run tag={tag}")
                sys.exit(1)

    # 1.7 — sprint-status auto-sync (chore-harness-epic-4-orchestration-observations T1)
    #
    # Replaces main agent fallback `sprint-status.py set ...` pattern in
    # run-sprint.md §1 阶段 ②/⑤/⑥. Sync runs BEFORE blacklist/classification
    # so the modified sprint-status.yaml gets picked up in the regular
    # porcelain re-fetch + classified as a global_files allowed path.
    auto_sync_log = []
    if not args.dry_run:
        # NOTE (review 2026-06-10 finding #75): --simulate-retro-md-with-d-items
        # exits earlier in main() via _run_seed_simulation (tempdir-isolated);
        # a second, unreachable simulation branch used to live here — it would
        # have written `_simulated-epic-N-retro.md` into the REAL artifacts
        # dir had anyone resurrected it. Removed as dead code.
        try:
            applied = _sync_sprint_status_for_stage(args.stage, key, epic)
            for k, v in applied:
                auto_sync_log.append(("set", k, v))
        except RuntimeError as e:
            emit("STATUS=halt")
            emit(f"REASON=sprint-status auto-sync failed (stage {args.stage}): {e}")
            sys.exit(1)

        # Stage 6: also seed retro_action_items.epic-${epic}-retro from retro md
        if args.stage == "6" and epic:
            try:
                retro_md = _find_latest_retro_md(epic)
                if retro_md:
                    seeded = _seed_retro_action_items(epic, retro_md, str(get_sprint_status_path()))
                    for code, _title, _category in seeded:
                        auto_sync_log.append(("seed", f"epic-{epic}-retro.{code}", "pending"))
            except RuntimeError as e:
                emit("STATUS=halt")
                emit(f"REASON=retro_action_items seed failed (stage 6): {e}")
                sys.exit(1)

        # Stage 6-5: fill chore_spec field by globbing chore-retro-c<epic>-*.md
        if args.stage == "6-5" and epic:
            try:
                filled = _fill_chore_spec_field(
                    epic,
                    str(get_sprint_status_path()),
                    ARTIFACTS_DIR.rstrip("/"),
                )
                for code, fname in filled:
                    auto_sync_log.append(("fill", f"epic-{epic}-retro.{code}.chore_spec", fname))
            except RuntimeError as e:
                emit("STATUS=halt")
                emit(f"REASON=chore_spec auto-fill failed (stage 6-5): {e}")
                sys.exit(1)

        # Re-fetch porcelain to reflect sprint-status.yaml mutations
        if auto_sync_log:
            paths, err = porcelain_paths()
            if paths is None:
                emit("STATUS=halt")
                emit(f"REASON=git status failed after auto-sync: {err}")
                sys.exit(1)
            paths = filter_junk_paths(paths, dry_run=args.dry_run)

    # 2 — global blacklist
    blacklist_hits = []
    for _, p in paths:
        pat = matches_blacklist(p)
        if pat:
            blacklist_hits.append((p, pat))
    if blacklist_hits:
        emit("STATUS=halt")
        emit("REASON=blacklist hit (§-1.d step 2)")
        for p, pat in blacklist_hits:
            emit(f"BLACKLIST={p} ({pat})")
        emit("CHANGED_ALL=" + "; ".join(p for _, p in paths))
        sys.exit(1)

    # 2.5 — out-of-scope _bmad-output/ guard (§-1.d; issue #5) + spec-declared
    # planning-artifacts writeback whitelist (issue #9).
    # Files under _bmad-output/ but OUTSIDE implementation-artifacts/ (e.g.
    # brainstorming/, planning-artifacts/, research/) are cross-cutting BMad
    # planning docs — often produced by a *parallel* bmad session unrelated to
    # the active story. They previously fell through to the project-code bucket
    # and were auto-`git add`ed into the story commit, mislabeling them under
    # the current story. Halt and require the solo-dev to commit them
    # separately (same spirit as cross-story isolation within
    # implementation-artifacts/). Runs after the blacklist gate, so blacklisted
    # _bmad-output/ paths (e.g. .harness-logs/**) still report as BLACKLIST=.
    #
    # Exception (issue #9): a spec whose Tasks explicitly mandate a planning
    # doc writeback (e.g. forward-only remediation updating epics.md) declares
    # the exact paths in its frontmatter `planning_artifacts:` list — those
    # paths bypass the halt and flow on into the project bucket (staged with
    # this commit, reported as PLANNING_ARTIFACT= lines on STATUS=ok).
    #
    # The whitelist only takes effect on stages whose spec allows project
    # code (2/4/5/retro-fulfill, ...): on project_code=False stages an
    # exempted path would just fall through classify() into the opaque
    # FORBIDDEN halt — keeping the gate here yields the clearer
    # OUT_OF_SCOPE_BMAD diagnosis with stage-appropriate guidance.
    planning_allowlist = (
        read_planning_artifacts_allowlist(key, epic, args.stage)
        if spec["project_code"] else set()
    )
    out_of_scope_bmad = []
    planning_writebacks = []
    for _, p in paths:
        if not is_out_of_scope_bmad_output(p):
            continue
        if p in planning_allowlist:
            planning_writebacks.append(p)
            continue
        out_of_scope_bmad.append(p)
    if out_of_scope_bmad:
        emit("STATUS=halt")
        emit("REASON=_bmad-output/ file outside implementation-artifacts/ — out of scope for story commits (issue #5)")
        for p in out_of_scope_bmad:
            emit(f"OUT_OF_SCOPE_BMAD={p}")
        if spec["project_code"]:
            declare_hint = (
                f"If the spec for this commit explicitly mandates the "
                f"writeback (e.g. forward-only remediation updating "
                f"epics.md), declare the path in the spec frontmatter "
                f"`planning_artifacts:` list "
                f"(`{_BMAD_OUTPUT_PREFIX}{_PLANNING_ARTIFACTS_SUBDIR}*.md` "
                f"only — issue #9) and re-run. Otherwise commit"
            )
        else:
            declare_hint = (
                f"The `planning_artifacts:` frontmatter whitelist (issue #9) "
                f"does not apply on stage {args.stage} (stage forbids project "
                f"code) — commit"
            )
        emit(
            f"GUIDANCE=paths under {_BMAD_OUTPUT_PREFIX} but outside "
            f"{_BMAD_OUTPUT_INSCOPE_PREFIX} (e.g. brainstorming/, "
            f"planning-artifacts/) are not story artifacts. {declare_hint} "
            f"them separately outside the sprint pipeline (likely from a "
            f"parallel bmad session), or move them under "
            f"implementation-artifacts/ if they are genuine story "
            f"deliverables."
        )
        emit("CHANGED_ALL=" + "; ".join(p for _, p in paths))
        sys.exit(1)

    # 3 — cross-story isolation (with `cross_story_artifacts:` frontmatter
    # whitelist per harness-changelog 2026-05-03 §B)
    cross_story_allowlist = read_cross_story_allowlist(key)
    chore_retro_flag = bool(spec.get("chore_retro"))
    cross_hits = [p for _, p in paths if not cross_story_ok(p, key, epic, cross_story_allowlist, chore_retro=chore_retro_flag)]
    if cross_hits:
        emit("STATUS=halt")
        emit("REASON=cross-story isolation hit (§-1.d step 3)")
        for p in cross_hits:
            emit(f"CROSS_STORY={p}")
        if cross_story_allowlist:
            emit("CROSS_STORY_ALLOWLIST=" + "; ".join(sorted(cross_story_allowlist)))
        emit("CHANGED_ALL=" + "; ".join(p for _, p in paths))
        sys.exit(1)

    # 3.5 — test_artifact validation (chore: codex F1 fix, 2026-05-04)
    # Every path under _bmad-output/implementation-artifacts/test_artifacts/
    # must match one of 4 legal filename shapes AND embed the current KEY/EPIC.
    # Closes the cross-story bypass: previously test_artifacts/* fell through
    # to project bucket without key-prefix enforcement.
    test_artifact_unexpected = []
    test_artifact_wrong_key = []
    for _, p in paths:
        m = TEST_ARTIFACT_RE.match(p)
        if not m:
            continue
        status, _tag = classify_test_artifact(m.group(1), key, epic)
        if status == "ok":
            continue
        if status == "wrong_key":
            test_artifact_wrong_key.append(p)
        else:  # "unexpected"
            test_artifact_unexpected.append(p)
    if test_artifact_unexpected:
        emit("STATUS=halt")
        emit("REASON=test_artifacts/ filename does not match any of the 4 legal shapes (F1)")
        for p in test_artifact_unexpected:
            emit(f"UNEXPECTED_ARTIFACT={p}")
        emit("CHANGED_ALL=" + "; ".join(p for _, p in paths))
        sys.exit(1)
    if test_artifact_wrong_key:
        emit("STATUS=halt")
        emit(f"REASON=test_artifacts/ key/epic prefix does not match KEY={key} EPIC={epic or '(none)'} (F1)")
        for p in test_artifact_wrong_key:
            emit(f"CROSS_STORY={p}")
        emit("CHANGED_ALL=" + "; ".join(p for _, p in paths))
        sys.exit(1)

    # 4 — classify
    expected = []
    unexpected_artifacts = []
    project = []
    forbidden = []
    for _, p in paths:
        kind = classify(p, key, epic, spec, cross_story_allowlist)
        if kind == "expected":
            expected.append(p)
        elif kind == "unexpected_artifact":
            unexpected_artifacts.append(p)
        elif kind == "project":
            project.append(p)
        else:  # forbidden
            forbidden.append(p)

    if unexpected_artifacts:
        emit("STATUS=halt")
        emit(f"REASON=artifact file outside stage {args.stage} expected-output spec (§0.5)")
        for p in unexpected_artifacts:
            emit(f"UNEXPECTED_ARTIFACT={p}")
        emit("CHANGED_ALL=" + "; ".join(p for _, p in paths))
        sys.exit(1)

    if forbidden:
        emit("STATUS=halt")
        emit(f"REASON=non-artifact path in stage {args.stage} which forbids project code")
        for p in forbidden:
            emit(f"FORBIDDEN={p}")
        emit("CHANGED_ALL=" + "; ".join(p for _, p in paths))
        sys.exit(1)

    # 4.25 — worktree-clean check on test-harness stages (chore: codex F2 fix, 2026-05-04)
    # On stages 5-5/T1/T3/T4 the project bucket is restricted to test artifacts
    # for this KEY plus the e2e spec dir. Anything else means a dirty worktree
    # (likely epic-N in-progress code) and we halt rather than auto-stage —
    # solo-dev must commit/stash unrelated changes before re-invoking.
    if args.stage in TEST_HARNESS_STAGES and project:
        dirty = []
        for p in project:
            if TEST_ARTIFACT_RE.match(p):
                # Already validated by F1 above — key prefix is correct.
                continue
            if is_e2e_spec_for_key(p, key):
                continue
            dirty.append(p)
        if dirty:
            emit("STATUS=halt")
            emit(f"REASON=worktree contains paths outside the stage {args.stage} test-harness whitelist (F2)")
            for p in dirty:
                emit(f"DIRTY_WORKTREE={p}")
            emit(f"GUIDANCE=stages {'/'.join(TEST_HARNESS_STAGES)} only commit test_artifacts/<key>-* and {E2E_SPEC_PREFIX}<key>* paths; commit or stash unrelated changes before re-invoking (no auto-stash by design — see chore-harness-codex-review-fixes-2026-05-04 §Boundaries)")
            emit("CHANGED_ALL=" + "; ".join(p for _, p in paths))
            sys.exit(1)

    # 4.5 — schema gates (dev-result.json on stage 2, review-findings.json on stage 5)
    schema_errors = []
    if spec["validate_dev"]:
        schema_errors.extend(validate_dev_result(key))
    if spec["validate_review"]:
        schema_errors.extend(validate_review_findings(key))
    if schema_errors:
        emit("STATUS=halt")
        emit(f"REASON=machine-readable completion gate failed (stage {args.stage})")
        for code, msg in schema_errors:
            emit(f"{code}={msg}")
        sys.exit(1)

    # 5 — git add (unless dry-run)
    #
    # R1 follow-up (2026-06-10): entries whose worktree column is clean
    # (xy[1] == " ") are already fully staged — there is nothing left to add.
    # For staged deletions ('D ', e.g. a `git rm`'d tracked .DS_Store) a
    # `git add -- <path>` would even hard-fail ("pathspec did not match any
    # files" — the path exists in neither index nor worktree), turning a
    # perfectly staged deletion into a bogus halt. Skipping clean-worktree
    # entries is a no-op for 'A '/'M '/'R ' (already staged, file on disk)
    # and the only correct behavior for 'D '.
    xy_by_path = {p: xy for xy, p in paths}
    paths_to_add = [p for p in expected + project
                    if xy_by_path.get(p, "??")[1] != " "]
    if paths_to_add and not args.dry_run:
        r = run(["git", "add", "--"] + paths_to_add)
        if r.returncode != 0:
            emit("STATUS=halt")
            emit(f"REASON=git add failed: {r.stderr.strip()}")
            for p in paths_to_add:
                emit(f"WANTED_ADD={p}")
            sys.exit(1)

    # 6 — sanity check (skip detailed check on dry-run)
    if not args.dry_run:
        r_stat = run(["git", "diff", "--cached", "--stat"])
        cached_stat = r_stat.stdout.strip()
        # -uall -z keeps this check's path universe identical to
        # porcelain_paths() (finding #1 — otherwise add'ed files inside a new
        # dir would re-fold; finding #79 — same raw-path parsing, no C-quoting).
        r_status = run(["git", "status", "--porcelain", "-uall", "-z"])
        unstaged = []
        for xy, rest in _parse_porcelain_z(r_status.stdout):
            # Junk-tier files NOT in HEAD were intentionally skipped (never
            # staged) — they are not "unstaged remainders" and must never halt
            # (findings #1/#7 red line). Tracked junk-pattern paths went
            # through the normal pipeline (R1 regression fix), so they get NO
            # exemption here — same judgment as filter_junk_paths.
            if matches_junk(rest) and not path_in_head(rest):
                continue
            # Worktree column is xy[1]; non-space means unstaged remainder
            if xy[1] != " ":
                unstaged.append(rest)
        if unstaged:
            emit("STATUS=halt")
            emit("REASON=unstaged remainders after add (§-1.d step 5)")
            for p in unstaged:
                emit(f"UNSTAGED={p}")
            sys.exit(1)
    else:
        cached_stat = "(dry-run; not running git add / git diff --cached)"

    # 7 — ok
    # For stage 6-5, count = number of staged chore-retro-c${epic}-*.md files.
    chore_retro_count = 0
    if spec.get("chore_retro") and epic:
        chore_retro_re = re.compile(rf"^{re.escape(ARTIFACTS_DIR)}chore-retro-c{re.escape(epic)}-[A-Z][A-Za-z0-9-]*-[a-z0-9-]+\.md$")
        chore_retro_count = sum(1 for p in expected if chore_retro_re.match(p))
    msg = spec["commit_msg"].format(key=key, epic=epic or "", count=chore_retro_count)
    emit("STATUS=ok")
    emit(f"REASON=ready to commit (stage {args.stage})")
    for action, k, v in auto_sync_log:
        emit(f"SPRINT_STATUS_AUTO_SYNC={action} key={k} value={v}")
    for p, size_mb in auto_fixes:
        emit(f"AUTO_FIXED=binary-blob {p} action=unstaged+rm+gitignored size={size_mb}MB")
    for p, tag in extra_prunes:
        emit(f"AUTO_FIXED=unexpected-md {p} action=unstaged+rm extra={tag}")
    for p, tag in marker_prunes:
        action = "planned-unstage+rm-dry-run" if args.dry_run else "unstaged+rm"
        emit(f"AUTO_FIXED=process-marker {p} action={action} tag={tag}")
    for p in planning_writebacks:
        emit(f"PLANNING_ARTIFACT={p}")
    for p in expected:
        emit(f"STAGED={p}")
    for p in project:
        emit(f"STAGED={p}")
    emit(f"SUGGEST_COMMIT_MSG={msg}")
    if spec["suggest_tag"]:
        tag_name = spec["suggest_tag"].format(key=key, epic=epic or "")
        emit(f"SUGGEST_TAG={tag_name}")
    if cached_stat:
        # Multi-line — prefix every line so caller can grep them out.
        for ln in cached_stat.splitlines():
            emit(f"CACHED_STAT={ln}")
    sys.exit(0)


if __name__ == "__main__":
    main()
