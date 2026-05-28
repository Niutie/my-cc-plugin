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
    1. List worktree changes (git status --porcelain).
    2. Run global blacklist scan (§-1.d step 2). Any hit → halt.
    3. Run cross-story isolation scan on _bmad-output/implementation-artifacts/*
       (§-1.d step 3). Any miss → halt.
    4. Classify each changed path against the stage's expected-output spec
       (§0.5 table).
    5. git add -- <path> the union of (expected artifacts ∪ project code).
       Refuses to add paths that fail any rule.
    6. Sanity check: git diff --cached --stat + git status --porcelain
       (must show no unstaged remainders).
    7. Print key=value lines on stdout:
         STATUS=ok|halt|skip
         REASON=<short>
         STAGED=<path>                              (one line per path that was staged)
         BLACKLIST=<path> (<pattern>)                (only on halt — global blacklist hit)
         CROSS_STORY=<path>                          (only on halt — wrong story key)
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
                                                      unstage+rm+gitignore; see Opt 1 in
                                                      harness-changelog 2026-05-01 §I)
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


# §-1.d step 2 — global blacklist patterns. Custom glob with ** = any-segment.
BLACKLIST_PATTERNS = [
    "**/.env*",
    "**/*.pem",
    "**/*.key",
    "**/*.p12",
    "**/*credentials*",
    "**/secrets/**",
    ".claude/settings*",
    ".claude/commands/**",
    ".claude/skills/**",
    ".claude/harness/scripts/**",
    ".claude/harness/answer-policy.md",
    "_bmad/**",
    "_bmad-output/.harness-logs/**",
    "**/*.tmp",
    "**/*.swp",
    "**/.DS_Store",
]

ARTIFACTS_DIR = _compute_artifacts_dir_str()
ARTIFACT_RE = re.compile(r"^" + re.escape(ARTIFACTS_DIR) + r"([^/]+\.(?:md|json|yaml|yml))$")

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
#   - console-web/tests/e2e/<key>* (the e2e spec dir, out of artifacts root)
# Anything else → halt DIRTY_WORKTREE= with explicit guidance to commit/stash.
TEST_HARNESS_STAGES = ("5-5", "T1", "T3", "T4")
E2E_SPEC_PREFIX = "console-web/tests/e2e/"


def is_e2e_spec_for_key(path, key):
    """Return True if `path` is a console-web/tests/e2e/<key>* file."""
    if not path.startswith(E2E_SPEC_PREFIX):
        return False
    suffix = path[len(E2E_SPEC_PREFIX):]
    # Allow either `<key><whatever>` or `<key>/<file>` (subdirs under the key).
    return suffix.startswith(key)

# --- Story status reader (used by dev-result / review-findings consistency check) ---

_status_re_lines = [
    re.compile(r"^\s*\*?\*?Status:?\*?\*?\s*(\w+)\s*$", re.IGNORECASE),
    re.compile(r"^\s*-\s*\*?\*?Status:?\*?\*?\s*(\w+)\s*$", re.IGNORECASE),
]


def read_story_status(key):
    """Read the Status field from story md; returns lowercased value or None.

    Tolerates a few common renderings:
        Status: review
        **Status:** review
        - Status: review
    """
    path = f"{ARTIFACTS_DIR}{key}.md"
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                for pat in _status_re_lines:
                    m = pat.match(line)
                    if m:
                        return m.group(1).lower()
    except FileNotFoundError:
        return None
    return None


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

    md_status = read_story_status(key)
    json_status = d.get("final_story_status")
    if md_status is not None and json_status and md_status != str(json_status).lower():
        errors.append(("DEV_RESULT_STATUS_MISMATCH", f"json={json_status!r} md={md_status!r}"))
    elif md_status is None:
        errors.append(("DEV_RESULT_STATUS_MISSING", f"could not read Status from {ARTIFACTS_DIR}{key}.md"))

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

    errors = []
    u = d.get("unresolved", {})
    if not isinstance(u, dict):
        errors.append(("REVIEW_FINDINGS_FAIL_PARSE", "unresolved field is not an object"))
        return errors

    crit = int(u.get("critical", 0) or 0)
    high = int(u.get("high", 0) or 0)
    med  = int(u.get("medium", 0) or 0)
    low  = int(u.get("low", 0) or 0)
    if crit + high + med > 0:
        errors.append(("REVIEW_FINDINGS_UNRESOLVED", f"critical={crit} high={high} medium={med} low={low}"))

    md_status = read_story_status(key)
    json_status = d.get("final_story_status")
    if md_status is not None and json_status and md_status != str(json_status).lower():
        errors.append(("REVIEW_FINDINGS_STATUS_MISMATCH", f"json={json_status!r} md={md_status!r}"))
    elif md_status is None:
        errors.append(("REVIEW_FINDINGS_STATUS_MISSING", f"could not read Status from {ARTIFACTS_DIR}{key}.md"))

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
        "story_json":       [".dev-result.json"],
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
        "story_json":       [],
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
        "story_json":       [],
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
        "story_json":       [".review-findings.json", ".review-progress.json"],
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

    applied = []
    for k, new_status in transitions:
        # Read current status; missing key is a hard error (yaml schema bug)
        r = subprocess.run([sys.executable, sync_script, "status", k],
                           capture_output=True, text=True, check=False)
        if r.returncode != 0:
            # Key not found in development_status — for epic-* keys we need
            # to retry: sprint-status.py status only iterates dev keys by
            # default; epic-* keys also live in the same block so this should
            # work via cmd_status which calls _iter_dev_status without
            # include_epic_keys. The cmd_status caller doesn't pass
            # include_epic_keys; epic-* keys are filtered out → not found.
            # Workaround: fall through to set directly (set uses
            # include_epic_keys=True), which will succeed if key exists.
            if k.startswith("epic-"):
                pass  # don't read current; rely on set being idempotent
            else:
                raise RuntimeError(
                    f"sprint-status.py status {k} failed: {r.stderr.strip() or r.stdout.strip()} (rc={r.returncode})"
                )
        else:
            current = r.stdout.strip()
            if current == new_status:
                continue  # idempotent — already at target

        r = subprocess.run([sys.executable, sync_script, "set", k, new_status],
                           capture_output=True, text=True, check=False)
        if r.returncode != 0:
            raise RuntimeError(
                f"sprint-status.py set {k} {new_status} failed: {r.stderr.strip() or r.stdout.strip()} (rc={r.returncode})"
            )
        applied.append((k, new_status))
    return applied


def _epic_letter(epic):
    """Map epic number to capital-letter prefix (1→A, 4→D, ...). Returns
    None if epic is not a 1..26 integer."""
    try:
        n = int(epic)
    except (TypeError, ValueError):
        return None
    if 1 <= n <= 26:
        return chr(ord("A") + n - 1)
    return None


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

    Returns list of (code, title) tuples. Raises RuntimeError on file IO
    failure or schema drift.
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

    items = []

    # Form 1 — H3 heading (canonical)
    h3_re = re.compile(
        rf"^###\s+({re.escape(letter)}[A-Za-z0-9-]*)\b\s*(?:[—–-]\s*(.+?))?\s*$",
        re.MULTILINE,
    )
    for m in h3_re.finditer(section_text):
        code = m.group(1)
        # Filter: must be `<letter><digits>` or `<letter>-<lowercase-kebab>` to
        # exclude false positives like `### A — Action items overview`.
        if re.fullmatch(rf"{re.escape(letter)}\d+", code) or \
           re.fullmatch(rf"{re.escape(letter)}-[a-z][a-zA-Z0-9-]+", code):
            items.append((code, (m.group(2) or "").strip()))

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
        items.append((code, title))
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
            items.append((code, title))
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
    RESOLVED — 不覆盖 solo-dev 已手工补的 chore_spec 字段). If block is
    absent under retro_action_items: parent, creates the subblock.

    Each new entry is `<code>: pending  # <title from md>` (no chore_spec —
    that's stage 6-5's responsibility per spec Boundaries).

    Returns list of newly-seeded (code, title) tuples. Raises RuntimeError
    on schema violation (parent block missing) or IO failure.
    """
    letter = _epic_letter(epic)
    if letter is None:
        # v0.1.21 codex review fix #3：原 0.1.17 的 raise 把"plugin range
        # 限制（epic > 26 或非整数）"和"用户写错 retro md schema"混在一起
        # 处理；前者是 plugin 限制（用户无法控制），后者是 schema drift
        # （用户能修）。区分语义：
        #   - epic 越界 → WARN + return []（不阻 stage 6 commit；
        #     plugin 的 1..26 letter mapping 是已知限制）
        #   - schema drift（retro md 有 Action Items section 但 parser 0
        #     命中）→ raise（用户应修 retro md 格式）
        # 避免 stage 6 commit 在 epic 27+ 时因 plugin 限制 hard-halt。
        print(
            f"WARN [_seed_retro_action_items]: epic={epic!r} → _epic_letter "
            f"returned None (plugin maps 1..26 only). Skipping retro_action_items "
            f"seed; stage 6 commit continues. If you have epic 27+, file a "
            f"feature request for multi-letter codes (AA/AB/...).",
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

    new_items = [(c, t) for c, t in items if c not in existing_codes]
    if not new_items:
        return []  # idempotent

    insert_lines = []
    if block_idx is None:
        # Create new subblock at end of retro_action_items section
        insert_lines.append(f"  epic-{epic}-retro:\n")
    for code, title in new_items:
        comment = f"      # {title}" if title else ""
        if comment:
            insert_lines.append(f"    {code}: pending{comment}\n")
        else:
            insert_lines.append(f"    {code}: pending\n")

    if block_idx is not None:
        # Append at end of existing block
        new_text = "".join(lines[:block_end_idx] + insert_lines + lines[block_end_idx:])
    else:
        if rai_idx is None:
            raise RuntimeError(
                "retro_action_items: parent block not found in sprint-status.yaml — "
                "schema violation; cannot seed (run /bmad-sprint-planning to bootstrap)"
            )
        # Insert before rai_end (= block_end_idx if rai_idx is set + block missing)
        # Trim trailing blank lines from insert region
        insert_at = block_end_idx if block_end_idx is not None else len(lines)
        new_text = "".join(lines[:insert_at] + insert_lines + lines[insert_at:])

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

    For epic numbers out of 1..26 range, no items will seed (epic_letter
    returns None) but the block-creation path still gets exercised.
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
        for code, title in seeded:
            emit(f"SEEDED_ITEM={code} title={title!r}")
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
    """fnmatch with `**` as multi-segment wildcard, `*` as single-segment, `?` as single-char."""
    parts = pattern.split("**")
    regex_parts = []
    for i, part in enumerate(parts):
        if i > 0:
            regex_parts.append(".*")
        sub = []
        for ch in part:
            if ch == "*":
                sub.append("[^/]*")
            elif ch == "?":
                sub.append("[^/]")
            else:
                sub.append(re.escape(ch))
        regex_parts.append("".join(sub))
    return re.fullmatch("".join(regex_parts), path) is not None


def matches_blacklist(path):
    for pat in BLACKLIST_PATTERNS:
        if glob_match(path, pat):
            return pat
    return None


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
    """
    if ARTIFACT_RE.match(path):
        if is_expected_artifact(path, key, epic, spec, cross_story_allowlist):
            return "expected"
        return "unexpected_artifact"
    if spec["project_code"]:
        return "project"
    return "forbidden"


def porcelain_paths():
    """Return list of (xy, path) from `git status --porcelain`. For renames, take the new path.

    `core.quotepath=false` is injected by the `run()` helper so CJK paths
    arrive as raw UTF-8 (otherwise the artifact classifier regex misses them).
    """
    r = run(["git", "status", "--porcelain"])
    if r.returncode != 0:
        return None, r.stderr.strip()
    out = []
    seen = set()
    for line in r.stdout.splitlines():
        if len(line) < 4:
            continue
        xy = line[:2]
        rest = line[3:]
        if " -> " in rest:
            rest = rest.split(" -> ", 1)[1]
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
            "Test-only: synthesize an in-memory retro markdown with 5 D items "
            "(D1..D5) for stage 6 seed verification. Skips actual file IO and "
            "requires --dry-run. Used by orchestration_observations_test.sh "
            "T6.5 fixture."
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

    if args.stage in ("6", "6-5", "6-done", "T1") and not epic:
        emit("STATUS=halt")
        emit(f"REASON=stage {args.stage} requires --epic")
        sys.exit(1)

    paths, err = porcelain_paths()
    if paths is None:
        emit("STATUS=halt")
        emit(f"REASON=git status failed: {err}")
        sys.exit(1)

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

    # 1.6 — auto-prune subagent-spilled extra .md artifacts (Opt 2;
    # harness-changelog 2026-05-03 §A). Applies to all stages; the rule
    # checks suffix shape so it can't match canonical artifacts.
    extra_prunes = []
    if not args.dry_run:
        for p, tag in detect_subagent_extras(paths, key):
            if auto_prune_subagent_extra(p):
                extra_prunes.append((p, tag))
        if extra_prunes:
            paths, err = porcelain_paths()
            if paths is None:
                emit("STATUS=halt")
                emit(f"REASON=git status failed after extra-prune: {err}")
                sys.exit(1)

    # 1.7 — sprint-status auto-sync (chore-harness-epic-4-orchestration-observations T1)
    #
    # Replaces main agent fallback `sprint-status.py set ...` pattern in
    # run-sprint.md §1 阶段 ②/⑤/⑥. Sync runs BEFORE blacklist/classification
    # so the modified sprint-status.yaml gets picked up in the regular
    # porcelain re-fetch + classified as a global_files allowed path.
    auto_sync_log = []
    if not args.dry_run or args.simulate_retro_md_with_d_items:
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
                if args.simulate_retro_md_with_d_items:
                    # Test-only: write a synthetic retro md to a temp file
                    # and seed from it. Does not touch real worktree.
                    tmp_md = os.path.join(ARTIFACTS_DIR.rstrip("/"), f"_simulated-epic-{epic}-retro.md")
                    synthetic = (
                        f"# Epic {epic} Retrospective (synthetic test fixture)\n\n"
                        f"## 6. Action Items\n\n"
                    )
                    letter = _epic_letter(epic) or "Z"
                    for n in range(1, 6):
                        synthetic += f"### {letter}{n} — synthetic action item {n}\nAction: do thing {n}\n\n"
                    os.makedirs(os.path.dirname(tmp_md), exist_ok=True)
                    with open(tmp_md, "w", encoding="utf-8") as f:
                        f.write(synthetic)
                    retro_md = tmp_md
                else:
                    retro_md = _find_latest_retro_md(epic)
                if retro_md:
                    seeded = _seed_retro_action_items(epic, retro_md, str(get_sprint_status_path()))
                    for code, _title in seeded:
                        auto_sync_log.append(("seed", f"epic-{epic}-retro.{code}", "pending"))
                if args.simulate_retro_md_with_d_items:
                    # cleanup synthetic md
                    try:
                        os.remove(tmp_md)
                    except OSError:
                        pass
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
    paths_to_add = expected + project
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
        r_status = run(["git", "status", "--porcelain"])
        unstaged = []
        for line in r_status.stdout.splitlines():
            if len(line) < 4:
                continue
            xy = line[:2]
            rest = line[3:]
            if " -> " in rest:
                rest = rest.split(" -> ", 1)[1]
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
