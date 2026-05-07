#!/usr/bin/env python3
"""
harness-state.py — single-source-of-truth state query for /harness-zh:run.

Usage:
    # JSON state query (default mode):
    python3 .claude/harness/scripts/harness-state.py <story_key> [--json | --plain]

    # Resume-prompt mode (post-quota-halt continuation):
    python3 .claude/harness/scripts/harness-state.py <story_key> --resume-prompt --stage <N>

Outputs JSON (default) or human-readable text describing where the story
sits in the 5-stage pipeline. The main agent uses this in `--continue` mode
(or any restart scenario) to decide which stage to dispatch next, without
having to grep git log + parse sprint-status.yaml + check tags by hand.

When called with `--resume-prompt --stage <N>`, the script outputs a
ready-to-paste prompt段 describing stage-internal micro-progress (which
tasks are checked off, which JSON gates exist, which path groups have
worktree changes), so fresh-spawn subagents can reconstruct context
without the main agent having to assemble the description by hand.

Fields (JSON output):
    key                       — story key (echoed)
    story_status              — value from sprint-status.yaml ("backlog" / "review" / "done" / ...)
    worktree_clean            — bool, `git status --porcelain` empty
    start_tag_exists          — bool, `harness/<key>/start` exists
    stage2_base_tag_exists    — bool, `harness/<key>/stage2-base` exists
    done_tag_exists           — bool, `harness/<key>/done` exists
    stage2_base_sha           — string|null. SHA at which stage ② review base sits.
                                Source priority:
                                1) `harness/<key>/stage2-base` tag (preferred)
                                2) the SHA of the stage-1 commit (fallback for legacy stories)
                                Use `git diff <stage2_base_sha>..HEAD` for stage 3 / stage 5 review.
    stage1_committed..5       — bool, has the canonical commit message for that stage landed?
    next_action               — human-readable suggestion, e.g. "dispatch stage 3: codex review"
    next_action_code          — machine code: "stage1" / "stage2" / "stage3" / "stage4" / "stage5"
                                / "done" / "tag-only" / "blocked-dirty" / "not-started"

Exit code:
    0 — state read successfully (regardless of where in pipeline)
    1 — git / IO error
    2 — usage error
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from harness_config import (  # noqa: E402
    get_artifacts_root,
    get_path_classifiers,
    get_verification_commands,
)

# Repo-relative artifacts dir as string (terminating slash for legacy regex prefix
# checks; absolute path via get_artifacts_root() if needed).
def _compute_artifacts_dir_str() -> str:
    repo_root = Path(__file__).resolve().parents[3]
    rel = get_artifacts_root().relative_to(repo_root)
    return str(rel) + "/"

ARTIFACTS_DIR = _compute_artifacts_dir_str()

# Canonical stage commit subjects (must stay in sync with STAGES.commit_msg in harness-commit.py).
STAGE_SUBJECTS = {
    "stage1_committed": "story({key}): create story spec",
    "stage2_committed": "story({key}): initial implementation",
    "stage3_committed": "story({key}): codex adversarial review report",
    "stage4_committed": "story({key}): apply codex review fixes",
    "stage5_committed": "story({key}): final review fixes & done",
}


def run(cmd):
    # Two CJK-safety fixes baked in for every subcommand:
    #
    # (a) Inject `-c core.quotepath=false` for git so CJK paths come back as
    #     raw UTF-8 instead of C-style octal escapes — required for `git status
    #     --porcelain` / `git diff --stat` to match downstream regexes against
    #     CJK story keys (e.g. `1-1-后端工程脚手架与公共基础设施.md`).
    #
    # (b) `errors="replace"` on text decode — `git diff --stat` truncates long
    #     filenames at column width and can chop a multi-byte UTF-8 sequence
    #     mid-codepoint; default strict decode would raise UnicodeDecodeError
    #     and crash status reporting.
    if cmd and cmd[0] == "git" and (len(cmd) < 3 or cmd[1] != "-c" or not cmd[2].startswith("core.quotepath")):
        cmd = ["git", "-c", "core.quotepath=false"] + list(cmd[1:])
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace", check=False)


def tag_exists(tag):
    return run(["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}"]).returncode == 0


def tag_sha(tag):
    r = run(["git", "rev-parse", tag])
    if r.returncode == 0:
        return r.stdout.strip()
    return None


def find_commit_subject(subject):
    """Return SHA of the most recent commit whose subject equals `subject`, or None."""
    r = run(["git", "log", "--format=%H %s"])
    if r.returncode != 0:
        return None
    for line in r.stdout.splitlines():
        sha, _, subj = line.partition(" ")
        if subj == subject:
            return sha
    return None


def read_sprint_status(key):
    r = run([sys.executable, ".claude/harness/scripts/sprint-status.py", "status", key])
    if r.returncode == 0:
        return r.stdout.strip()
    return None


def compute_state(key):
    state = {
        "key": key,
        "story_status": read_sprint_status(key),
        "start_tag_exists": tag_exists(f"harness/{key}/start"),
        "stage2_base_tag_exists": tag_exists(f"harness/{key}/stage2-base"),
        "done_tag_exists": tag_exists(f"harness/{key}/done"),
    }

    # stage2_base_sha source priority: tag → stage 1 commit (legacy fallback)
    stage2_base = None
    if state["stage2_base_tag_exists"]:
        stage2_base = tag_sha(f"harness/{key}/stage2-base")
    if not stage2_base:
        stage2_base = find_commit_subject(STAGE_SUBJECTS["stage1_committed"].format(key=key))
    state["stage2_base_sha"] = stage2_base

    # Stage commit detection
    for k, subj_tpl in STAGE_SUBJECTS.items():
        state[k] = find_commit_subject(subj_tpl.format(key=key)) is not None

    # Worktree clean check
    r = run(["git", "status", "--porcelain"])
    state["worktree_clean"] = (r.returncode == 0) and (r.stdout.strip() == "")

    # Decide next action (highest-stage-completed wins)
    if state["done_tag_exists"]:
        next_action_code = "done"
        next_action = f"story {key} already complete; harness/{key}/done tag set"
    elif state["stage5_committed"]:
        next_action_code = "tag-only"
        next_action = f"stage 5 committed but harness/{key}/done tag missing — run `git tag harness/{key}/done`"
    elif state["stage4_committed"]:
        if state["worktree_clean"]:
            next_action_code = "stage5"
            next_action = "dispatch stage 5: bmad final adversarial review (spawn general-purpose agent)"
        else:
            next_action_code = "blocked-dirty"
            next_action = "stage 5 review work in progress (worktree not clean); verify review-findings.json + commit via harness-commit.py 5"
    elif state["stage3_committed"]:
        if state["worktree_clean"]:
            next_action_code = "stage4"
            next_action = "dispatch stage 4: spawn FRESH general-purpose dev agent to handle codex findings (do not rely on stage-2 dev agentId — it is session-scoped and may be unreachable)"
        else:
            next_action_code = "blocked-dirty"
            next_action = "stage 4 dev fix in progress (worktree not clean); commit via harness-commit.py 4 once handling rows are written"
    elif state["stage2_committed"]:
        if state["worktree_clean"]:
            next_action_code = "stage3"
            next_action = f"dispatch stage 3: codex adversarial review (use --base {stage2_base or '<stage2_base_sha missing>'})"
        else:
            next_action_code = "blocked-dirty"
            next_action = "stage 3 codex review report in progress (worktree not clean); commit via harness-commit.py 3 once codex-review.md is written"
    elif state["stage1_committed"]:
        if state["worktree_clean"]:
            next_action_code = "stage2"
            next_action = "dispatch stage 2: dev implementation (write dev-result.json with tri-state checks per harness-changelog 2026-05-01 §C)"
        else:
            next_action_code = "blocked-dirty"
            next_action = "stage 2 dev work in progress (worktree not clean); validate dev-result.json + commit via harness-commit.py 2"
    elif state["start_tag_exists"]:
        next_action_code = "stage1"
        next_action = "dispatch stage 1: create story spec via /bmad-create-story"
    else:
        next_action_code = "not-started"
        next_action = f"story {key} not started — verify it is in sprint-status.yaml backlog, then `git tag harness/{key}/start` and dispatch stage 1"

    state["next_action_code"] = next_action_code
    state["next_action"] = next_action
    return state


def format_plain(state):
    lines = [
        f"story_key:               {state['key']}",
        f"story_status:            {state['story_status']}",
        f"worktree_clean:          {state['worktree_clean']}",
        "",
        f"tag harness/.../start:        {state['start_tag_exists']}",
        f"tag harness/.../stage2-base:  {state['stage2_base_tag_exists']}",
        f"tag harness/.../done:         {state['done_tag_exists']}",
        f"stage2_base_sha:         {state['stage2_base_sha']}",
        "",
        f"stage 1 committed:       {state['stage1_committed']}",
        f"stage 2 committed:       {state['stage2_committed']}",
        f"stage 3 committed:       {state['stage3_committed']}",
        f"stage 4 committed:       {state['stage4_committed']}",
        f"stage 5 committed:       {state['stage5_committed']}",
        "",
        f"next_action_code:        {state['next_action_code']}",
        f"next_action:             {state['next_action']}",
    ]
    return "\n".join(lines)


# --- Resume-prompt mode (Tier 1, harness-changelog 2026-05-03 §C) ---
#
# When a stage-2 / 4 / 5 subagent gets quota-killed mid-flight, the main
# agent needs to spawn a fresh subagent that picks up where the old one
# left off. Prior to this mode, the main agent had to hand-assemble the
# resume prompt by running git status + grep story md + check JSON files
# — every restart re-did the same recon, with subtle drift each time.
#
# This mode emits a deterministic prompt fragment describing stage-internal
# micro-progress, ready to paste at the head of a fresh-spawn subagent's
# task prompt:
#   - stage 2: tasks `[x]/[ ]` count, dev-result.json existence, worktree
#     change groups by directory (backend / frontend / locales / tests)
#   - stage 4: codex-review.md finding count vs Story md `### Codex Review
#     Handling (Stage 3)` row count
#   - stage 5: review-progress.json findings status distribution,
#     review-findings.json existence, story md `### Review Findings`
#     section presence
#
# Output is plain text (no JSON wrapping). Just paste it into the subagent
# Agent({ prompt: ... }) call.

import re

# Path-group regexes for grouping worktree changes by purpose.
# Order matters — first match wins. Catch-all `other` at the end.
# Sourced from harness-project-config.yaml `extra.path_classifiers`. Falls
# back to hardcoded defaults if missing (see harness_config.get_path_classifiers).
PATH_GROUPS = get_path_classifiers()


def group_worktree_changes(porcelain_output):
    """Parse `git status --porcelain` output. Returns dict of {group_name: count}.
    Excludes _bmad-output/ paths (those are artifacts, tracked separately).
    """
    counts = {}
    for line in porcelain_output.splitlines():
        if len(line) < 4:
            continue
        rest = line[3:]
        if " -> " in rest:
            rest = rest.split(" -> ", 1)[1]
        if rest.startswith("_bmad-output/"):
            continue  # artifacts handled separately by stage spec
        matched = None
        for name, pat in PATH_GROUPS:
            if pat.match(rest):
                matched = name
                break
        key = matched or "other"
        counts[key] = counts.get(key, 0) + 1
    return counts


def count_artifact_changes(porcelain_output):
    """Count _bmad-output/implementation-artifacts/ changes by suffix. Returns dict."""
    counts = {}
    for line in porcelain_output.splitlines():
        if len(line) < 4:
            continue
        rest = line[3:]
        if " -> " in rest:
            rest = rest.split(" -> ", 1)[1]
        if not rest.startswith(ARTIFACTS_DIR):
            continue
        fname = rest[len(ARTIFACTS_DIR):]
        if fname.endswith(".md"):
            counts["md"] = counts.get("md", 0) + 1
        elif fname.endswith(".json"):
            counts["json"] = counts.get("json", 0) + 1
        elif fname.endswith(".yaml") or fname.endswith(".yml"):
            counts["yaml"] = counts.get("yaml", 0) + 1
    return counts


def count_story_tasks(key):
    """Read story md, count `- [ ]` and `- [x]` Tasks checkboxes (case-insensitive
    on x). Returns (done, todo, total) — only counts under the top-level
    `## Tasks` (or `## Tasks / Subtasks`) heading and its `### Phase N` subheadings;
    exits the Tasks block when a non-Phase `## ` heading or `# ` heading appears.
    """
    path = f"{ARTIFACTS_DIR}{key}.md"
    if not os.path.exists(path):
        return (0, 0, 0)
    done = 0
    todo = 0
    in_tasks_block = False  # True between `## Tasks` and the next `## ` / `# ` heading
    try:
        with open(path, "r") as f:
            for line in f:
                m = re.match(r"^(#+)\s+(.+?)\s*$", line)
                if m:
                    level = len(m.group(1))
                    title = m.group(2).lower()
                    if level <= 2:
                        # `## ` / `# ` headings can switch the Tasks block on/off
                        if level <= 2 and ("task" in title) and ("notes" not in title) and ("findings" not in title):
                            in_tasks_block = True
                        else:
                            in_tasks_block = False
                    # `### ` and deeper preserve in_tasks_block (they're sub-phases)
                    continue
                if not in_tasks_block:
                    continue
                m = re.match(r"^\s*-\s*\[([ xX])\]\s", line)
                if m:
                    if m.group(1).lower() == "x":
                        done += 1
                    else:
                        todo += 1
    except OSError:
        pass
    return (done, todo, done + todo)


def count_codex_findings(key):
    """Read <KEY>.codex-review.md, count `[critical]` / `[high]` / `[medium]` /
    `[low]` markers. Returns (sev_counts, total_estimated)."""
    path = f"{ARTIFACTS_DIR}{key}.codex-review.md"
    if not os.path.exists(path):
        return ({}, 0)
    sev = {}
    try:
        with open(path, "r") as f:
            content = f.read()
    except OSError:
        return ({}, 0)
    for label in ("critical", "high", "medium", "low", "info"):
        sev[label] = len(re.findall(rf"\[{label}\]", content, re.IGNORECASE))
    total = sum(sev.values())
    return (sev, total)


def count_codex_handling_rows(key):
    """Count `- [F-N <sev>]` rows under `### Codex Review Handling` section in story md."""
    path = f"{ARTIFACTS_DIR}{key}.md"
    if not os.path.exists(path):
        return 0
    in_section = False
    rows = 0
    try:
        with open(path, "r") as f:
            for line in f:
                m = re.match(r"^(#+)\s+(.+?)\s*$", line)
                if m:
                    title = m.group(2).lower()
                    in_section = "codex review handling" in title
                    continue
                if in_section and re.match(r"^\s*-\s*\[F-\d+", line):
                    rows += 1
    except OSError:
        pass
    return rows


def parse_review_progress(key):
    """Read <KEY>.review-progress.json. Returns dict with phase + findings status counts.
    Tolerates both list-of-objects and dict-of-objects shapes."""
    path = f"{ARTIFACTS_DIR}{key}.review-progress.json"
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r") as f:
            d = json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"phase": "unparseable", "findings_total": 0, "findings_by_status": {}}
    findings = d.get("findings", {})
    items = []
    if isinstance(findings, dict):
        items = list(findings.values())
    elif isinstance(findings, list):
        items = findings
    by_status = {}
    for item in items:
        if not isinstance(item, dict):
            continue
        st = item.get("status", "unknown")
        by_status[st] = by_status.get(st, 0) + 1
    return {
        "phase": d.get("phase", "unknown"),
        "findings_total": len(items),
        "findings_by_status": by_status,
    }


def has_section(key, section_title_substring):
    path = f"{ARTIFACTS_DIR}{key}.md"
    if not os.path.exists(path):
        return False
    try:
        with open(path, "r") as f:
            for line in f:
                m = re.match(r"^(#+)\s+(.+?)\s*$", line)
                if m and section_title_substring.lower() in m.group(2).lower():
                    return True
    except OSError:
        pass
    return False


# --- Stage 2 enhanced summaries (chore-harness-epic-4-orchestration-observations T3) ---
#
# Three helpers cross-validate the Tasks-checkbox count (which dev-story
# skill maintains async with worktree state) against ground-truth signals:
#   T3.1: directory-grouped worktree landing summary
#   T3.2: git diff --stat summary
#   T3.3: dev-result.json field summary
#
# Goal: fresh subagent reading the resume prompt sees "checkbox 0/104 BUT
# worktree has 18 files landed + 2300 LOC delta + dev-result.json checks
# all pass" cross-comparison instead of mistakenly assuming nothing's done.


def _format_worktree_landing_summary():
    """Group git status --porcelain by first-level directory; expand
    second-level when count > 5 (Q4 RESOLVED). Top 10 desc by count.
    """
    r = run(["git", "status", "--porcelain"])
    if r.returncode != 0:
        return "**worktree 落地清单**：（无法读 git status — fallback 到 no-op）"
    paths = []
    for line in r.stdout.splitlines():
        if len(line) < 4:
            continue
        rest = line[3:]
        if " -> " in rest:
            rest = rest.split(" -> ", 1)[1]
        paths.append(rest)
    if not paths:
        return "**worktree 落地清单**：（空）"

    # Group by first-level dir
    first_level = {}  # dir → list of paths
    for p in paths:
        if "/" in p:
            first = p.split("/", 1)[0] + "/"
        else:
            first = "(root)"
        first_level.setdefault(first, []).append(p)

    # Expand 2nd-level when > 5
    rows = []  # list of (dir_label, count, total_size_bytes)
    for d, group_paths in first_level.items():
        if len(group_paths) > 5 and d != "(root)":
            second = {}
            for p in group_paths:
                parts = p.split("/", 2)
                if len(parts) >= 3:
                    sub = parts[0] + "/" + parts[1] + "/"
                else:
                    sub = parts[0] + "/" + (parts[1] if len(parts) > 1 else "")
                second.setdefault(sub, []).append(p)
            for sd, sg in second.items():
                rows.append((sd, len(sg), _sum_file_size(sg)))
        else:
            rows.append((d, len(group_paths), _sum_file_size(group_paths)))

    rows.sort(key=lambda x: -x[1])
    out = ["**worktree 落地清单**（按目录分组，前 10 desc by file count）："]
    for d, cnt, size in rows[:10]:
        out.append(f"- `{d}`: {cnt} 文件 ({_humanize_size(size)})")
    if len(rows) > 10:
        out.append(f"- ... and {len(rows) - 10} more directories")
    return "\n".join(out)


def _sum_file_size(paths):
    total = 0
    for p in paths:
        try:
            total += os.path.getsize(p)
        except OSError:
            pass
    return total


def _humanize_size(b):
    if b < 1024:
        return f"{b}B"
    if b < 1024 ** 2:
        return f"{b / 1024:.1f}KB"
    if b < 1024 ** 3:
        return f"{b / 1024 ** 2:.1f}MB"
    return f"{b / 1024 ** 3:.2f}GB"


def _format_git_diff_stat_summary():
    """git diff --stat HEAD output, top 20 lines, "... and N more files" overflow."""
    r = run(["git", "diff", "--stat", "HEAD"])
    if r.returncode != 0:
        return "**git diff --stat 摘要**：（无法读 git diff — fallback 到 no-op）"
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    if not lines:
        return "**git diff --stat 摘要**：（空 — HEAD 与 worktree 一致）"
    out = ["**git diff --stat 摘要**（前 20 行）：", "```"]
    for ln in lines[:20]:
        out.append(ln)
    if len(lines) > 20:
        out.append(f"... and {len(lines) - 20} more files")
    out.append("```")
    return "\n".join(out)


def _format_dev_result_summary(key):
    """dev-result.json existence + key field overview, or "**未写**" notice."""
    path = f"{ARTIFACTS_DIR}{key}.dev-result.json"
    if not os.path.exists(path):
        return "**dev-result.json**: **未写**（机器可读完成门必交付）"
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        return f"**dev-result.json**: 已写但解析失败：{e}"
    out = ["**dev-result.json**（已写，字段一览）："]
    checks = d.get("checks", {})
    if isinstance(checks, dict) and checks:
        # Show tri-state values inline
        items = ", ".join(f"{k}={v!r}" for k, v in checks.items())
        out.append(f"- checks: {items}")
    files_changed = d.get("files_changed_count")
    if files_changed is not None:
        out.append(f"- files_changed_count: {files_changed}")
    code_count = d.get("files_changed_count_code")  # D2 chore field; harmless if absent
    if code_count is not None:
        out.append(f"- files_changed_count_code: {code_count}")
    final_status = d.get("final_story_status")
    if final_status:
        out.append(f"- final_story_status: `{final_status}`")
    return "\n".join(out)


def emit_resume_prompt(key, stage):
    """Print a ready-to-paste fresh-spawn prompt fragment for the given stage."""
    state = compute_state(key)
    porcelain = run(["git", "status", "--porcelain"]).stdout
    worktree_total = sum(1 for line in porcelain.splitlines() if line.strip())
    path_groups = group_worktree_changes(porcelain)
    artifact_counts = count_artifact_changes(porcelain)

    out = []
    out.append(f"**前情提要（由 harness-state.py --resume-prompt 自动生成）**：前一个 subagent 跑这个 stage 时被中断（典型：runtime quota 耗尽）。worktree 已有部分进度落地，**先读现场再决定动作**——不要从零重做。")
    out.append("")
    out.append(f"**当前状态**（从 sprint-status / git tags / worktree 探测）：")
    out.append(f"- story_key: `{key}`")
    out.append(f"- story md Status 段: `{read_story_status_for_resume(key)}`")
    out.append(f"- sprint-status.yaml 状态: `{state['story_status']}`")
    out.append(f"- worktree 干净: `{state['worktree_clean']}`（{worktree_total} 个文件改动）")
    out.append(f"- harness/<key>/start tag: `{state['start_tag_exists']}`")
    out.append(f"- stage2_base_sha: `{state['stage2_base_sha']}`")
    out.append("")

    if path_groups:
        out.append("**worktree 改动分组**（按目录 prefix 推断）：")
        for name, count in sorted(path_groups.items(), key=lambda kv: -kv[1]):
            out.append(f"- {name}: {count} 文件")
        out.append("")
    if artifact_counts:
        out.append(f"**implementation-artifacts/ 改动**: {artifact_counts}")
        out.append("")

    if stage == 2:
        done, todo, total = count_story_tasks(key)
        out.append(f"**Stage 2 micro-progress**：")
        out.append(f"- Tasks checkbox: `{done}/{total}` 已 [x]（剩余 [ ] {todo} 项）")
        out.append("")
        # T3.1 + T3.2 + T3.3 (chore-harness-epic-4-orchestration-observations)
        # — checkbox 与 worktree 落地异步，三段交叉对比让 fresh subagent 不被
        # "0/104" 误导。互补不替代：checkbox 仍然显示。
        out.append(_format_worktree_landing_summary())
        out.append("")
        out.append(_format_git_diff_stat_summary())
        out.append("")
        out.append(_format_dev_result_summary(key))
        out.append("")
        out.append("**fresh agent 续作动作**（按顺序）：")
        out.append("1. 先 Read story md 看哪些 task 实际完成（worktree 文件落地 ≠ task checkbox 推进，dev-story skill 经常漏同步）。")
        out.append("2. 交叉对比上面 3 段：worktree 已落地 N 文件 + git diff 显示 +X/-Y + dev-result.json 是否齐 → 三个信号都看，不要只信 checkbox。")
        verification_lines = get_verification_commands().splitlines()
        out.append(f"3. 跑 verification ({' + '.join(f'`{ln}`' for ln in verification_lines)})；任何 fail 就修。")
        out.append("4. 把实际已完成的 task checkbox 从 `[ ]` 翻成 `[x]`。")
        out.append("5. 完成剩余未做的 task（若有）。")
        out.append("6. 把 story md Status 推进到 `review`。")
        out.append("7. 用 Write 工具产出 `<KEY>.dev-result.json`（tri-state schema）。")
        out.append("")
        out.append("**禁止**：不要从零重写 worktree 已落地的代码；不要做任何 git 操作；不要扩 scope。")

    elif stage == 4:
        sev, total_findings = count_codex_findings(key)
        handling_rows = count_codex_handling_rows(key)
        out.append(f"**Stage 4 micro-progress**：")
        sev_str = ", ".join(f"{k}={v}" for k, v in sev.items() if v > 0)
        out.append(f"- codex-review.md 中 finding 计数（按严重度标签估算）: {sev_str or 'n/a'}（合计约 {total_findings}）")
        out.append(f"- story md `### Codex Review Handling (Stage 3)` 段已记录: `{handling_rows}` 条")
        out.append(f"- 缺口: 约 `{max(0, total_findings - handling_rows)}` 条 finding 待处理")
        out.append("")
        out.append("**fresh agent 续作动作**（按顺序）：")
        out.append("1. Read codex-review.md + story md `### Codex Review Handling (Stage 3)` 段，确认已处理 finding（按 F-N 编号 dedupe）")
        out.append("2. **从中断处接着处理**剩余 finding（按 critical → high → medium → low 顺序）")
        out.append("3. 每条 finding 处理后立即在 Codex Review Handling 段追加一行（fixed/wontfix/deferred）")
        out.append("4. 任务结束条件：所有 codex finding 各有一条处理记录")
        out.append("")
        out.append("**禁止**：不要重新发现已经处理的 finding；不要做任何 git 操作。")

    elif stage == 5:
        rp = parse_review_progress(key)
        rf_exists = os.path.exists(f"{ARTIFACTS_DIR}{key}.review-findings.json")
        rf_section = has_section(key, "review findings")
        out.append(f"**Stage 5 micro-progress**：")
        if rp is None:
            out.append(f"- review-progress.json: **不存在**（fresh agent 从零开始 review）")
        else:
            out.append(f"- review-progress.json phase: `{rp['phase']}`，findings 总数: `{rp['findings_total']}`")
            for st, n in sorted(rp['findings_by_status'].items()):
                out.append(f"  - `{st}`: {n}")
        out.append(f"- review-findings.json (机器完成门): {'已写' if rf_exists else '**未写**（必交付）'}")
        out.append(f"- story md `### Review Findings` 段: {'已加' if rf_section else '未加'}")
        out.append("")
        out.append("**fresh agent 续作动作**（按顺序）：")
        if rp and rp.get("findings_total", 0) > 0:
            out.append("1. Read review-progress.json + story md，**信任 status != pending 的条目**（已 finalize），仅处理 pending 项")
            out.append("2. 跑 verification 确认 worktree 已 patch 的代码不破坏既有测试")
            out.append("3. 把所有 pending finding 推进到 patched/deferred/dismissed 之一")
        else:
            out.append("1. 跑完整 review（按 prompt 模板）")
        out.append("4. 必须用 Write 工具产出 review-findings.json（unresolved 计数 + final_story_status）")
        out.append("5. 若 unresolved.{critical+high+medium} == 0 → 把 story md Status 推到 `done`，progress JSON phase 设为 `done`")
        out.append("")
        out.append("**review-progress.json schema 强制约束**：findings 字段必须用 dict 结构 `{F1: {...}, F2: {...}}`（不要用 list）。")
        out.append("**禁止额外 artifact**：在 implementation-artifacts/ 下**只允许** `<KEY>.md` / `<KEY>.review-progress.json` / `<KEY>.review-findings.json` / `sprint-status.yaml` / `deferred-work.md`。**不要写** `<KEY>.bmad-code-review.md` 等额外 .md（harness 会自动剔除但增加 commit 噪音）。")
        out.append("**禁止**：不要重新 review 已 finalize 的 finding；不要做任何 git 操作；不要扩 scope。")

    else:
        out.append(f"**Stage {stage} 暂未支持 resume-prompt 模式**。")
        out.append("当前支持的 stage: 2 / 4 / 5（产生大量 worktree 中间状态的阶段）。")
        out.append("Stage 1 / 3 / 6 因为产物边界小，配额耗尽后通常重跑成本可接受。")

    print("\n".join(out))


# --- Halt-recovery check (chore-harness-epic-4-orchestration-observations T4) ---
#
# Three-state verdict for the "work-done-but-message-lost" path identified
# in epic-4 retro: stage 5 quota halt fired AFTER the subagent had already
# written all expected products + advanced story md Status — but before the
# return message reached the main agent. Previously the only continuation
# pattern was "spawn fresh subagent and re-do"; this command lets the main
# agent (or solo-dev) check ground truth instead and choose a faster path.
#
# Outputs (Q5 + Q6 RESOLVED — 仅诊断，不副作用，建议命令但不自动跑):
#   READY_TO_COMMIT — all expected products present + Status consistent
#   NEED_RESUME      — expected products absent → fresh subagent path
#   INCONSISTENT     — partial: some products present, others missing →
#                      manual intervention required (typical: progress.json
#                      exists but findings.json was never written → patching
#                      was interrupted mid-flight)
#
# Stage product specs are hard-coded — they mirror harness-commit.py STAGES
# expected-output table. The main agent can run this check from the §3 halt
# template (option 0) before deciding spawn-vs-commit.

# Stage product specs:
#   stage_marker — products that uniquely indicate this-stage work landed
#                  (their absence implies stage hasn't started). When present,
#                  Status check applies. When all absent, verdict = NEED_RESUME.
#   partial      — incremental progress products (review-progress.json etc.).
#                  Their presence with stage_marker missing → INCONSISTENT.
#   expect_status — story md Status value implied by stage being complete.
#                   Mismatch only matters when stage_marker products exist
#                   (otherwise stage hasn't finished — Status diff is normal).
HALT_RECOVERY_SPECS = {
    "1": {
        "stage_marker": [("{ARTIFACTS_DIR}{key}.md", "story md")],
        "partial":  [],
        "expect_status": None,
    },
    "2": {
        "stage_marker": [
            ("{ARTIFACTS_DIR}{key}.dev-result.json", "dev-result.json"),
        ],
        "partial": [],
        "expect_status": "review",
    },
    "3": {
        "stage_marker": [("{ARTIFACTS_DIR}{key}.codex-review.md", "codex-review.md")],
        "partial":  [],
        "expect_status": None,
    },
    "4": {
        # Stage 4 has no machine-readable marker file beyond story md edits.
        # Use story md presence + Status=review (still review at end of stage 4).
        "stage_marker": [("{ARTIFACTS_DIR}{key}.md", "story md (Codex Review Handling 段)")],
        "partial":  [],
        "expect_status": "review",
    },
    "5": {
        "stage_marker": [
            ("{ARTIFACTS_DIR}{key}.review-findings.json", "review-findings.json"),
        ],
        "partial": [
            ("{ARTIFACTS_DIR}{key}.review-progress.json", "review-progress.json (incremental)"),
        ],
        "expect_status": "done",
    },
}


def emit_halt_recovery_check(key, stage):
    """Print 3-state verdict + suggested next command. Always exit 0 (the
    diagnostic itself succeeds — caller interprets the verdict line)."""
    stage_str = str(stage)
    spec = HALT_RECOVERY_SPECS.get(stage_str)
    if spec is None:
        sys.stderr.write(
            f"unknown stage: {stage} — supported stages: {sorted(HALT_RECOVERY_SPECS.keys())}\n"
        )
        sys.exit(1)

    present_marker = []
    missing_marker = []
    for tpl, label in spec["stage_marker"]:
        path = tpl.format(ARTIFACTS_DIR=ARTIFACTS_DIR, key=key)
        if os.path.exists(path):
            present_marker.append((path, label))
        else:
            missing_marker.append((path, label))

    present_partial = []
    for tpl, label in spec["partial"]:
        path = tpl.format(ARTIFACTS_DIR=ARTIFACTS_DIR, key=key)
        if os.path.exists(path):
            present_partial.append((path, label))

    consistency_issues = []
    actual_status = read_story_status_for_resume(key)
    # Only enforce Status when stage_marker is fully present (otherwise stage
    # hasn't completed and a "wrong" Status is normal — e.g., Status=review
    # while stage 5 hasn't started yet is the expected baseline).
    if spec["expect_status"] and not missing_marker:
        if actual_status is None:
            consistency_issues.append(f"story md Status 行缺失（无法读 `{ARTIFACTS_DIR}{key}.md` Status 段）")
        elif actual_status != spec["expect_status"]:
            consistency_issues.append(
                f"story md Status='{actual_status}' 但 stage {stage_str} 期望 '{spec['expect_status']}'"
            )

    # Verdict logic:
    #   stage_marker all present + Status matches  → READY_TO_COMMIT
    #   stage_marker all present + Status mismatch → INCONSISTENT
    #   stage_marker partially present             → INCONSISTENT
    #   stage_marker all missing + partial exists  → INCONSISTENT
    #   stage_marker all missing + no partial      → NEED_RESUME
    if not missing_marker:
        verdict = "INCONSISTENT" if consistency_issues else "READY_TO_COMMIT"
    elif present_marker or present_partial:
        verdict = "INCONSISTENT"
    else:
        verdict = "NEED_RESUME"

    print(verdict)
    print(f"# halt-recovery-check stage={stage_str} key={key}")
    print(f"# verdict: {verdict}")
    if present_marker:
        print("# present stage_marker products:")
        for p, label in present_marker:
            print(f"#   - {p} ({label})")
    if present_partial:
        print("# present partial products:")
        for p, label in present_partial:
            print(f"#   - {p} ({label})")
    if missing_marker:
        print("# MISSING stage_marker products:")
        for p, label in missing_marker:
            print(f"#   - {p} ({label})")
    if consistency_issues:
        print("# CONSISTENCY issues:")
        for issue in consistency_issues:
            print(f"#   - {issue}")

    if verdict == "READY_TO_COMMIT":
        print(f"# suggested next: python3 .claude/harness/scripts/harness-commit.py {stage_str} {key}")
    elif verdict == "NEED_RESUME":
        print(
            f"# suggested next: spawn fresh general-purpose subagent for stage {stage_str};"
            f" use `python3 .claude/harness/scripts/harness-state.py {key} --resume-prompt --stage {stage_str}`"
            " for the resume prompt fragment"
        )
    else:  # INCONSISTENT
        print(
            "# suggested next: manual intervention — read the partial products"
            " above + decide whether to (a) backfill missing products from"
            " present partial state, or (b) revert + spawn fresh subagent."
            " halt-recovery-check 不自动跑 commit / reset / stash（Q5+Q6 RESOLVED — 仅诊断）。"
        )

    sys.exit(0)


def read_story_status_for_resume(key):
    """Lightweight Status reader (mirrors harness-commit.read_story_status without the import dance)."""
    path = f"{ARTIFACTS_DIR}{key}.md"
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r") as f:
            for line in f:
                m = re.match(r"^\s*\*?\*?Status:?\*?\*?\s*(\w+)\s*$", line, re.IGNORECASE)
                if m:
                    return m.group(1).lower()
    except OSError:
        pass
    return None


def main():
    parser = argparse.ArgumentParser(description="Single-source-of-truth state query for /harness-zh:run")
    parser.add_argument("key", help="story key, e.g. 1-3-postgresql-baseline-schema")
    fmt = parser.add_mutually_exclusive_group()
    fmt.add_argument("--json", action="store_const", dest="format", const="json", default="json")
    fmt.add_argument("--plain", action="store_const", dest="format", const="plain")
    parser.add_argument("--resume-prompt", action="store_true",
                        help="emit a ready-to-paste fresh-spawn prompt fragment for stage continuation")
    parser.add_argument("--halt-recovery-check", action="store_true",
                        help="(chore-harness-epic-4-orchestration-observations T4) emit halt-recovery verdict (READY_TO_COMMIT / NEED_RESUME / INCONSISTENT)")
    parser.add_argument("--stage", type=int, choices=[1, 2, 3, 4, 5, 6],
                        help="(with --resume-prompt or --halt-recovery-check) which stage to inspect")
    args = parser.parse_args()

    if args.resume_prompt:
        if args.stage is None:
            sys.stderr.write("error: --resume-prompt requires --stage <N>\n")
            sys.exit(2)
        emit_resume_prompt(args.key, args.stage)
        return

    if args.halt_recovery_check:
        if args.stage is None:
            sys.stderr.write("error: --halt-recovery-check requires --stage <N>\n")
            sys.exit(2)
        emit_halt_recovery_check(args.key, args.stage)
        return

    state = compute_state(args.key)
    if args.format == "json":
        print(json.dumps(state, indent=2))
    else:
        print(format_plain(state))


if __name__ == "__main__":
    main()
