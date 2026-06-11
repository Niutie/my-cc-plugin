#!/usr/bin/env python3
"""
harness-prompt-suffix.py — emit standardized subagent prompt suffix.

Usage:
    python3 .claude/harness/scripts/harness-prompt-suffix.py <stage>

stage ∈ {1, 2, 3, 4, 5, 6}

Output (stdout): text block to append to a subagent prompt. Currently:

  - All stages: §−1.b answer-policy attachment (points subagent at .claude/harness/answer-policy.md
    and tells it to self-decide rather than ask).
  - Stages 2 / 4 / 5: §1.x resume-from-checkpoint convention. Only the **current
    stage's** progress-source line is emitted (not all three) so the subagent
    isn't distracted by other stages' progress conventions.
  - Stage 2: deferred-work scan convention (§L; harness-changelog 2026-05-01;
    schema v1 升级 2026-05-04; 文本契约修正 2026-05-05).
    Tells dev agent to scan deferred-work.md for items targeting this story
    (matched via schema v1 [target:Story X.Y] tag), resolve relevant ones by
    flipping [status:pending] → [status:resolved] + appending a 历史 sub-entry.
    Soft prompt — no structural enforcement of resolve/skip decision (avoids
    scope creep risk), but pre-commit hook gate ② will reject any legacy
    `Resolved by Story X.Y (date)` inline-suffix writes.

The main agent uses this to avoid hand-pasting these blocks into every
Agent({prompt: ...}) call. A miss in any one prompt causes the subagent to
ask for confirmation, which violates the non-interactive contract.

Exit code:
    0 — printed; caller appends to its prompt
    2 — usage / unknown stage
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from harness_config import (  # noqa: E402
    get_artifacts_root,
    get_deferred_work_path,
    get_fullstack_review_steps,
    get_project_context,
)

# Resolve once at module load (relative-to-repo paths used in prompt strings)
_REPO_ROOT = Path(__file__).resolve().parents[3]


def _rel_to_repo(p):
    """Repo-relative str for prompt text; degrades to the absolute path + WARN.

    Belt for review 2026-06-10 findings #73/#80: harness_config.get_artifacts_root()
    already normalizes absolute / repo-escaping artifacts_root values, but this
    script runs before every subagent spawn (run.md §−1.b) — a module-load
    ValueError here would stall the whole pipeline with a bare traceback. If a
    future regression lets an out-of-repo path through, the absolute string is
    still perfectly usable inside prompt text, so never raise.
    """
    try:
        return str(p.relative_to(_REPO_ROOT))
    except ValueError:
        print(
            f"WARN [harness-prompt-suffix]: path '{p}' is not under repo root "
            f"'{_REPO_ROOT}'; using the absolute path in prompt text",
            file=sys.stderr,
        )
        return str(p)


_ARTIFACTS_REL = _rel_to_repo(get_artifacts_root())
_DEFERRED_WORK_REL = _rel_to_repo(get_deferred_work_path())
_PROJECT_CONTEXT = get_project_context()
_FULLSTACK_REVIEW_STEPS = get_fullstack_review_steps()


# 代答政策 — answer-policy.md (跨项目通用决策原则) + 项目特定语境（从
# harness-project-config.yaml extra.project_context 读，inline 到 prompt 后缀）。
# 这样 subagent 在 prompt 中直接拿到完整决策上下文 — 无需 Read 第二个文件。
ANSWER_POLICY_BLOCK = f"""**代答政策**：本次任务以非交互模式运行。请先 Read `.claude/harness/answer-policy.md`（跨项目通用流程决策原则），按其中的决策原则 + 下面的项目语境自决，不要发问。每个非显然的选择都要把理由写进你最终交付的产物里。

**项目语境（按字面意思应用，不要二次解读）**：

{_PROJECT_CONTEXT}"""


# §M (harness-changelog 2026-05-03) — subagent self-report git status block.
# Without this, subagents that BMad-workflow-internally trigger sub-tools
# can modify files outside their own awareness (the 2-7 main.go incident
# during a /bmad-create-story call). Forcing a final `git status --porcelain`
# self-report into the return message lets the main agent verify worktree
# state structurally instead of trusting subagent self-narration.
GIT_STATUS_SELF_REPORT_BLOCK = """**Worktree 自报（强制，stop 前最后一步）**：在你最终返回 message **之前**，必须用 Bash 工具跑一次 `git status --porcelain` 并把完整输出**逐字粘贴**进返回 message 中（用代码块包裹）。这是为了让主 agent 验证 worktree 实际状态，而不是依赖你自报"我没改过 X 文件"——BMad workflow 内部子工作流可能在你不知情的情况下改文件（typical 症状：你以为只用 Edit 工具改了 a.go，但 workflow 触发的 subworkflow 偷偷改了 b.go）。

**禁止跳过此步**：哪怕你确信只动了 prompt 显式列出的文件，也必须跑 `git status --porcelain`——这是结构化校验，不是冗余动作。"""

# §N (harness-changelog 2026-05-03) — stage 5 review-progress.json strict schema.
# Promotes the dict-not-list convention out of ad-hoc main-agent prompt edits
# and into the standardized stage 5 suffix.
STAGE5_PROGRESS_SCHEMA_BLOCK = f"""**review-progress.json schema 强制约束**：

- `findings` 字段**必须**是 dict 结构 `{{"F1": {{...}}, "F2": {{...}}}}`，**不要**用 list `[{{"id": "F1", ...}}, ...]`。主 agent 后续会按 dict key 索引读取该文件做 micro-progress 探测；list 结构会破坏续作探测。
- 每个 finding 对象至少含字段：`status`（"patched" / "deferred" / "dismissed" / "decision_needed_resolved" / "pending"）、`severity`（"critical" / "high" / "medium" / "low" / "info"）。
- 顶层 `phase` 字段：`"reviewing"` / `"triage-complete"` / `"patching"` / `"done"`。完成所有 finding 决议后必须设为 `"done"`。
- 每完成一条 finding 处理就立即增量写入这个 JSON（不要积攒到最后一次 Write）——这样配额耗尽时仍有 partial progress 留下。

**禁止额外 artifact**：在 `{_ARTIFACTS_REL}/` 下**只允许**的本 stage 产物路径：`<KEY>.md` / `<KEY>.review-progress.json` / `<KEY>.review-findings.json` / `sprint-status.yaml` / `deferred-work.md`。**不要写** `<KEY>.bmad-code-review.md` / `<KEY>.review-summary.md` / 任何其它独立 .md 报告——所有 review 内容必须落进 Story md 的 `### Review Findings` 段。harness-commit.py 会自动剔除这些额外 .md 文件，但增加无意义的 commit 噪音。"""

RESUME_PROGRESS_LINES = {
    "2": "- **本阶段**: progress = story md 的 Tasks checkbox（dev-story skill 原生维护，逐 task 推进时即时更新）。dev-result.json 用三态 `checks: {x: \"pass\" | \"fail\" | \"skip\"}` schema（见 .claude/harness/changelog.md 2026-05-01 §C），写完 dev 工作时一次性产出。",
    "4": "- **本阶段**: progress = story md 的 `### Codex Review Handling` 段（每条 finding 一行 `fixed/wontfix/deferred` 标记，处理一条写一行）。",
    "5": f"- **本阶段**: progress = `{_ARTIFACTS_REL}/$KEY.review-progress.json`（每完成一条 finding 决议 / patch 时增量更新；结构：`{{\"findings\": {{\"F1\": {{\"status\": \"patched\", \"files\": [...], \"ts\": \"...\"}}, ...}}, \"phase\": \"patching|done\"}}`）。",
}


# §O (harness-changelog 2026-05-03) — stage 1 deferred-work injection notice.
# Tells the create-story subagent that the prompt header carries an
# auto-injected `## Deferred-work 待消化提示` section (produced by
# `.claude/harness/scripts/grep_pending_deferred_for_story.sh`, prepended by the main
# agent in run-sprint stage 1). The grep itself runs in the main agent's
# shell; harness-prompt-suffix.py only emits the static notice that points the
# subagent at it. Soft prompt: dev agent must evaluate each candidate, but is
# NOT required to merge them all (avoids scope creep).
STAGE1_DEFERRED_INJECTION_NOTICE_BLOCK = """**Deferred-work 注入提示（§O — auto-injected 静态说明）**：本 prompt 头部紧接 `harness-prompt-suffix.py 1` 输出之前还有一段 `## Deferred-work 待消化提示（auto-injected by C11）` 段，由主 agent 用 `.claude/harness/scripts/grep_pending_deferred_for_story.sh <KEY>` 生成。那段列出了 deferred-work.md 里命中本 story key 且仍 pending（未 Resolved）的 FU-* 条目（≤15 条）。

**你（spec 作者 subagent）需要做的事**：
1. 在写 spec 时显式评估每条候选项：是否应当并入本 story 的 acceptance criteria / Tasks / Code Map（自然 scope 内）。
2. 决定 merge 的 → 在 spec 的 ## Tasks & Acceptance 段相应位置写明（带 FU-id 引用）。
3. 决定不 merge 的 → 不需要写理由（按 .claude/harness/answer-policy.md 自决；scope creep 风险高的就放过，stage 2 dev 仍会扫一次）。
4. 注入段为空（"No pending deferred items targeting <key>"）→ 跳过本约定。

**禁止**：① 因注入项把 scope 扩大到原 spec 自然边界以外（违反 single-story 原则）；② 假装"已并入"但实际 spec 没体现（stage 2 dev 会发现不一致）；③ 修改 deferred-work.md 本身（resolve 是 stage 2 dev 的事）。"""


# Q6 全栈贯通 review (forward-looking from Epic 4 — stage 2 only).
# 渲染 fullstack_review_steps yaml list → 项目特定 (a)-(z) sub-bullet 行；
# clone 到新项目时改 yaml 即可，suffix.py 不需动。空 list 时整段降级为
# 标注语句（dev agent 跳过 Q6）。
def _q6_block() -> str:
    if not _FULLSTACK_REVIEW_STEPS:
        return """**Q6 — 全栈贯通 review（项目未配置）**：harness-project-config.yaml 的 `extra.fullstack_review_steps:` list 为空 — 跳过本 Q6 段。新项目按 architecture markdown 核心数据写入路径填该 list 后会自动渲染。"""
    letter = lambda i: chr(ord('a') + i) if i < 26 else f"item-{i+1}"
    bullets = "\n".join(
        f"- ({letter(i)}) `{step['file_path']}`（{step['label']}）：✓ / N/A / deferred-to-FU-X.Y.Z"
        for i, step in enumerate(_FULLSTACK_REVIEW_STEPS)
    )
    return f"""**Q6 — 全栈贯通 review (forward-looking)**：本 story 引入新审计字段 / 新 enum / 新 i18n key 时，dev agent 必须按下面 {len(_FULLSTACK_REVIEW_STEPS)} sub-bullet 端到端追溯每条写入面，每行答 `✓` / `N/A` / `deferred-to-FU-X.Y.Z`：

{bullets}

纯重构 / 无新字段 story 整体答 `(a)-({letter(len(_FULLSTACK_REVIEW_STEPS)-1)}) 全部不适用 — 本 story 无新字段`（仍显式 {len(_FULLSTACK_REVIEW_STEPS)} 行）。

参考本项目已落地 dev story Dev Agent Record 的 Q6 答复模式建立答复体例（答复结构契约详 `.claude/harness/prompt-suffixes/bmad-dev-story-suffix.md` Q6 段；尚无已落地 story 时按上面 sub-bullet 格式直接作答）。"""


Q6_FULLSTACK_REVIEW_BLOCK = _q6_block()


# §L (harness-changelog 2026-05-01 / schema v1 升级 2026-05-04 / 文本契约修正
# 2026-05-05) — stage 2 deferred-work scan.
# Soft prompt; no structural validator. Goal: opportunistically close items
# targeting this story without forcing scope creep. **schema v1 后**用 status
# tag 翻 + 历史子段，**禁止**老 inline 后缀模式（pre-commit hook gate ② 拒收）。
DEFERRED_SCAN_BLOCK = f"""**Deferred-work 扫描约定**（schema v1 — 2026-05-04 起强制）：启动后先 Read `{_DEFERRED_WORK_REL}` 和 `.claude/harness/conventions/deferred-work-schema.md`（schema 权威）。schema v1 用 4-tag 头 `[status:...] [bucket:...] [target:...] [source:...]` + 字段（修复方向 / 触发条件 / 关联 / 历史）。

**短格式约定**：本 story 的 key 形如 `<epic>-<seq>-<slug>`，对应短格式 `<epic>.<seq>`。例：key `1-7-proxy-fork-...` → short `1.7`。下面写"短格式"即指此。

**识别命中条目**（按 schema v1 — 不再用文本 grep）：

- 看 FU bullet 头的 `[target:Story <短格式>]` tag（精确匹配；如 `[target:Story 1.7]`）
- `[status:resolved]` / `[status:partial]` 的条目**跳过**——已处理
- 仅 `[status:pending]` 项进入下面决策

对**每条 pending 命中条目**自决：

- **resolve**（自然 scope 内能顺手解决，不扩 acceptance criteria）：
  1. 改对应代码
  2. 把 FU bullet 头的 `[status:pending]` 改为 `[status:resolved]`
  3. 在 bullet body 末尾加 / 扩展 `历史` 子段：
     ```
     - **历史**：
       - YYYY-MM-DD `pending → resolved` by Story <短格式> — <短证据 ≤120 字，引 1-2 个文件路径>
     ```
- **partial**（本 Story 只能 close 一部分，典型：跨 component 项的本端）：
  1. 翻 `[status:partial]`
  2. 历史子段加一行 `pending → partial` by Story <短格式>
  3. 残余路径**新立** FU（不嵌套），用本 FU 的 `关联` 字段交叉指 `FU-X.Y.Z-residual`
- **跳过**（判断"与本 Story scope 不直接相关"或"resolve 会让 scope creep"）：不动条目，按 answer-policy.md 自决

**严格禁止**（pre-commit hook gate ② 会真拒，不是建议）：
- ❌ **老 inline 后缀模式** —— 不要写 `— **Resolved by Story X.Y** (date): ...` 或 `— **Partial resolution by Story X.Y** (date): ...` 拼接到 bullet 末尾。schema v1 §3.1 已废弃此模式，pre-commit hook gate ② 检测到新增此类行直接拒 commit。**status 字段 + 历史子段才是真值**。
- ❌ 因 deferred 项把 scope 扩大到 acceptance criteria 之外（违反 single-story 原则）
- ❌ 写"假性 resolved"（没真改代码就翻 status）；不确定就跳过
- ❌ 写 `FU-RETRO-*` 命名空间到 deferred-work.md（归 sprint-status retro_action_items；schema v1 §3.2）
- ❌ 直接编辑 `<!-- AUTO-GENERATED-BUCKETS-* -->` 块（用 `bash .claude/harness/scripts/grep_deferred_buckets.sh --emit-section1` 重新生成）

详细 schema 写入约束 + reference example 见 `.claude/harness/prompt-suffixes/bmad-dev-story-suffix.md` 的 `deferred-work schema v1 写入约束` 段。"""


def resume_block(stage):
    """Emit per-stage resume convention. Only the current stage's progress source is included."""
    return f"""**断点续作约定**：如果你启动时发现 worktree 已有变更（说明上一次本任务被中断、未由主 agent 清理）或本 story 文件 / progress JSON 里已有部分进度记录，**先读已有产物，跳过已完成项，从中断点续作**。每完成一项原子工作（例如修复一条 finding），立即把进度写入相应 progress 来源——这样下次中断也能续接：
{RESUME_PROGRESS_LINES[stage]}

中断恢复 ≠ 重新发现已经发现的问题——已进度文件里出现的 finding 都视为"已处理"，不要重新 review / 重新决议。"""


# Which stages get the resume block.
RESUME_STAGES = {"2", "4", "5"}

# Which stages get the deferred-scan block (only stage 2 — see §L rationale).
DEFERRED_SCAN_STAGES = {"2"}

# Q6 全栈贯通 review block — only stage 2 (dev implementation).
Q6_STAGES = {"2"}

# §N — only stage 5 emits the strict review-progress schema + extra-artifact ban.
STAGE5_SCHEMA_STAGES = {"5"}

# §O — only stage 1 emits the deferred-work injection notice (paired with the
# main-agent-prepended `## Deferred-work 待消化提示` section).
STAGE1_DEFERRED_INJECTION_NOTICE_STAGES = {"1"}

# §M — git status self-report goes on every stage (1/2/3/4/5/6). The 2-7
# main.go incident showed even stage 1 (/bmad-create-story) can spill changes.
GIT_STATUS_STAGES = {"1", "2", "3", "4", "5", "6"}

VALID_STAGES = {"1", "2", "3", "4", "5", "6"}


def main():
    parser = argparse.ArgumentParser(description="Emit standardized subagent prompt suffix")
    parser.add_argument("stage", help="stage number: 1 / 2 / 3 / 4 / 5 / 6")
    args = parser.parse_args()
    stage = args.stage.strip()

    if stage not in VALID_STAGES:
        print(f"unknown stage: {stage!r}; expected one of {sorted(VALID_STAGES)}", file=sys.stderr)
        sys.exit(2)

    blocks = []
    if stage in RESUME_STAGES:
        blocks.append(resume_block(stage))
    if stage in DEFERRED_SCAN_STAGES:
        blocks.append(DEFERRED_SCAN_BLOCK)
    if stage in Q6_STAGES:
        blocks.append(Q6_FULLSTACK_REVIEW_BLOCK)
    if stage in STAGE1_DEFERRED_INJECTION_NOTICE_STAGES:
        blocks.append(STAGE1_DEFERRED_INJECTION_NOTICE_BLOCK)
    if stage in STAGE5_SCHEMA_STAGES:
        blocks.append(STAGE5_PROGRESS_SCHEMA_BLOCK)
    if stage in GIT_STATUS_STAGES:
        blocks.append(GIT_STATUS_SELF_REPORT_BLOCK)
    blocks.append(ANSWER_POLICY_BLOCK)

    # Two newlines + horizontal rule between blocks for clean rendering when pasted into a prompt.
    print("\n\n---\n\n".join(blocks))


if __name__ == "__main__":
    main()
