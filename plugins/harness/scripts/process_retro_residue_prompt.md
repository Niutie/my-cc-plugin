# Fresh Agent Prompt — Retro Residue Processor (Chore C10)

> 此 prompt 由 `.claude/harness/scripts/process_retro_residue.sh` 注入到 fresh general-purpose agent 上下文中。
> 主 agent 在 spawn fresh agent 时把本文件全文 + 当前 epic 的 retro action items snapshot 一起喂给 fresh agent。
> Fresh agent 输出将由主 agent 解析 `=== FILE: <name>.md ===` 块并逐个 Write；任何越界改动 → halt。

## 你的任务

你正在为 ${project_display_name} 项目把 retro action items 转为可执行的 chore-retro-* 前置 spec。

`_bmad-output/implementation-artifacts/sprint-status.yaml` 的 `retro_action_items` 块累计 26+ 项跨 3 个 epic（epic-1 retro 8 项 A1-A8、epic-2 retro 9 项 B1-B9、epic-3 retro 9+ 项 C1-C12）。其中相当比例 status = pending / partial / in-progress 但**没有任何机制把这些项转成可执行 spec → 上路径 B 手工实施流水线消化**。结果：retro→action gap 在三轮 retro 实证已是结构性 bug。

你的工作：对**当前 EPIC**（你会被告知是 EPIC=1 / 2 / 3 之一）下的 retro action items，仅对 **status ∈ {pending, in-progress, partial} 且 chore_spec 字段缺失** 的项，逐项按 spec-retro-c1 的 frozen-after-approval 范式生成 `chore-retro-c${N}-<code>-<slug>.md` 单个 chore spec。

## 输入清单（主 agent 会喂给你）

1. **本 prompt 模板全文**（含范式 spec-retro-c1 全文 + 输出格式硬约定 + 边界声明）
2. **当前 epic 的 retro markdown 文件全文**（`epic-${N}-retro-*.md`）— 含每个 action item 的详细 problem / approach / success criteria / rationale 描述，是 fresh agent 提炼 chore intent 的核心证据
3. **当前 retro_action_items 块 yaml snapshot**（仅 epic-${N}-retro 子段）— 用于核对每项当前 status
4. **待 process 列表**（已由 shell 脚本计算）— 每行 `<code>: <current_status>` 形式
5. **已有 chore_spec 字段清单**（黑名单）— 已经生成过 chore spec 的项，跳过不再生成

## Category 分类 rubric（v2 — 2026-05-05 起强制）

每生成一个 chore spec，你必须为它判一个 `category` ∈ {`dev`, `harness`}，依据：

**`dev` — 产品代码 / 产品测试 / 产品文档 / NFR / ADR / 业务功能优先级**
- 例：补 console-api 单元测试、加 NFR baseline ADR、补 architecture/index.md 产品架构文档、业务功能优先级评估
- 判定：失败的 blast radius 局限于一个 story / 一个 epic 的产品交付
- 实例：A1 e2e-smoke / A4 admin-init 单测 / A5 NFR52 baseline / A8 architecture 索引 / B9 baseline-bundle / C6 baseline-decisions / C8 resource-safety-tests / D4 RPC 优先级

**`harness` — 流程脚本 / hook / skill / template / convention / sprint-status schema / deferred-work tooling / 通用化 / test harness 接通**
- 例：加 pre-commit hook、写 grep 工具脚本、改 BMad customize TOML、加 Justfile recipe、prompt suffix、retro self-audit、test harness bootstrap
- 判定：失败的 blast radius 跨所有后续 epic 的所有 story（影响 metasystem）
- 实例：A3 5q-gate skill / B1 retro-items prepend / B7 spec-length-check / B8 mirror-codegen / C1-C12 全部 / C-bootstrap / D1 D-decisions extract / D5 sealed-patterns

**模糊归 harness**（保守原则：harness gate 是 warn 不阻，错分进 harness 的代价 = solo-dev 自己看 WARN 决定优先级；错分进 dev 的代价 = 阻塞 epic 推进）。

边界判定：如果 chore 主体交付物是产品代码 / 产品架构文档 / 产品测试，但**附带**一些 harness 工具（如 review template），主体决定 category；harness 占比 ≥ 50% 归 harness。

## 输出格式（硬约定）

输出**多个 markdown 文件 block** + **一个 MANIFEST block** + **一段总结**。

每个 markdown 文件 block 严格以下面 marker 起止：

```
=== FILE: chore-retro-c${EPIC}-<code>-<slug>.md ===
{完整 markdown 文件内容，含 frontmatter + 5 大段}
=== END FILE ===
```

文件名规则：
- `${EPIC}` = 当前处理的 epic 编号（1/2/3/4...）
- `<code>` = 原始 retro 编号（A1 / A4 / B5 / B7 / B8 / B9 / C2-C9 / D2 等，**保持大小写**；alphanumeric-dash code 如 `C-bootstrap` 也保留）
- `<slug>` = 简短英文 kebab 描述，由你从 retro 文字提炼，长度 ≤ 40 字符；不含数字 / 标点 / 中文

**所有 FILE block 之后**输出一个 MANIFEST block，列每条 chore 的 code → category 映射，主 agent 据此写 sprint-status.yaml 的 `category:` 字段：

```
=== MANIFEST ===
A1: dev
A4: dev
B5: harness
C7: harness
=== END MANIFEST ===
```

MANIFEST 行格式：`<code>: <dev|harness>`（一行一项；只列你**本次生成 spec** 的 code；已 done / deferred / 黑名单的不列）。

**输出结尾**另起一段给主 agent 的简短总结（≤ 200 字）：处理项数 / 成功生成数 / dev:harness 分类比例 / 任何异常情况（如某项 retro 描述模糊到无法立 chore，或 category 边界判定有不确定性）。

## 严格禁止（违反 → 主 agent 丢弃你的输出）

1. ❌ **不改 retro markdown 本身**（retro 是 frozen 历史文档；只读不写）
2. ❌ **不改 sprint-status.yaml**（chore_spec 字段写入由主 agent 接管）
3. ❌ **不改任何 _bmad-output/implementation-artifacts/[1-6]-*.md**（已 done epic 的 story spec 不动）
4. ❌ **不为已 done 项生成 chore spec**（done 是终态）
5. ❌ **不为 deferred 项生成 chore spec**（trigger 未到期）
6. ❌ **不为已有 chore_spec 字段的项再次生成**（黑名单兜底）
7. ❌ **生成的 chore spec 内不能含"自动生成 / fresh agent / auto-generated"字样** — spec 一旦生成视为 human-owned intent
8. ❌ **不脑补 retro 之外的内容**（chore spec 的 Tasks 必须基于 retro 文字描述提炼，不能凭空增项）
9. ❌ **不输出任何解释 / 工作记录 / markdown 分析段** — 仅输出 FILE block 序列 + 末尾 ≤ 200 字总结
10. ❌ **不跳过自检清单**（输出前必须按末尾自检表自查）

## 每个 chore spec 必含 5 大段（与范式 spec-retro-c1 完全对齐）

**spec 文件结构（强制）：**

```markdown
---
title: 'Chore <code> — <一句话标题>'
type: 'chore'
created: '<retro 文件创建日期>'
status: 'ready-for-dev'
baseline_commit: '<retro 文件 baseline_commit 字段；缺则用 9d7a052b507eda2e198fccceec0aac99f666c7f2>'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-${EPIC}-retro-<日期>.md'
  - '{project-root}/_bmad-output/implementation-artifacts/sprint-status.yaml'
  - <其它可选 context 文件路径，如相关 story spec>
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** <从 retro 该 action item 的 §问题 / Action / Rationale 段提炼，1-2 段，含具体证据：grep / 文件路径 / 实测数据 / 跨 epic 兑现度 等>

**Approach:** <从 retro Action 段 + Success criteria 提炼具体落地路径，含子步骤；标注每步触及的文件路径 + 校验手段>

## Boundaries & Constraints

**Always:**
- <硬约束 1，从 retro Rationale + Success criteria 提炼>
- <硬约束 2>
- <硬约束 3-N>

**Ask First:**
- **(Q1) <第一个待 solo-dev 决策项 + 你的推荐答案 + 推荐理由>**
- **(Q2) <第二个>**（若适用）

**Never:**
- <反向约束 1，常见：不动 BMad skill / 不引 runtime 依赖 / 不改 retro markdown / 不跨 epic 推理>
- <反向约束 2-N>

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| <happy path 1> | <state> | <expected> | <error> |
| <edge case 1> | <state> | <expected> | <error> |
| <edge case 2-N，至少 4 行> | ... | ... | ... |

</frozen-after-approval>

## Code Map

- `<相对路径 1>` — NEW / UPDATE，<动作描述>
- `<相对路径 2>` — NEW / UPDATE，<动作描述>
- ...

## Tasks & Acceptance

**Execution:**
- [ ] `<相对路径>` -- <具体步骤 a/b/c/d，从 retro Action 段拆分>
- [ ] `<相对路径>` -- <具体步骤>
- [ ] 跑 `<verify command>` — expected: <预期>

**Acceptance Criteria:**
- Given <前置>，when <动作>，then <预期>。
- Given <前置>，when <动作>，then <预期>。
- ...

## Design Notes

**为什么 <某关键决策>：** <从 retro Rationale 段引用 + 提炼>

**为什么 <某另一决策>：** <同上>

## Verification

**Commands:**
- `<verify cmd 1>` — expected: <预期>
- `<verify cmd 2>` — expected: <预期>

**Manual checks:**
- <人肉 spot-check 1>
```

## 范式 spec-retro-c1 全文（few-shot example — 严格按此结构生成）

下面整段是 `_bmad-output/implementation-artifacts/spec-retro-c1-pre-commit-hook-retro-action-items.md` 全文（C1 已 done 的 chore，是 5 段范式最完整体现）：

---

```markdown
---
title: 'Retro C1 — git pre-commit hook + sprint-status.yaml retro_action_items 字段'
type: 'chore'
created: '2026-05-03'
status: 'done'
baseline_commit: '9d7a052b507eda2e198fccceec0aac99f666c7f2'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-retro-2026-05-03.md'
  - '{project-root}/_bmad-output/implementation-artifacts/sprint-status.yaml'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Epic 1 retro 8 项 / Epic 2 retro 9 项 跨两轮 retro 兑现度仅 50% 加权（Epic 1=25% / Epic 2=44.4%），三轮"承诺式 enforce"已被实证失效；Epic 4 Story 4.1 spec 创建前必须有"物理 enforce"层把未兑现 retro action items 拦在 4-* spec creation 之外。

**Approach:** 在仓库内交付（① bash checker 脚本扫 `sprint-status.yaml.retro_action_items` 块，输出 pending/in-progress 数量并 exit=count；② 仓库追踪的 `pre-commit` hook 源 + 一次性 install 脚本 + Justfile recipe，hook 仅当 staged diff 含 `_bmad-output/implementation-artifacts/[4-6]-*.md` 时触发 checker；③ sprint-status.yaml 加 `retro_action_items` 块，seed Epic 1/2/3 三 epic 共 26 项的当前状态）。`--no-verify` 保留作为爆炸半径兜底。

## Boundaries & Constraints

**Always:**
- hook 仅在 staged diff 命中 `_bmad-output/implementation-artifacts/[4-6]-*.md` 时执行 checker；其它 commit（包括 C2-C9 本身、Epic 1-3 改动、文档、tests）一概不触发。
- `--no-verify` 显式保留可绕过；hook 输出必须告诉 solo-dev "如需绕过：`git commit --no-verify` + 在 retro action item status 里加备注解释"。
- checker 脚本 exit code = `pending + in-progress` 计数（成功路径 = 0）；hook 把退出码翻译为人类可读消息。
- 所有新文件必须 `chmod +x`；hook 源放 `.claude/harness/git-hooks/`（仓库追踪），install 脚本把它 cp 到 `.git/hooks/pre-commit`（git 不追踪 `.git/hooks/`）。
- `retro_action_items` yaml 块的 status enum：`pending` / `in-progress` / `partial` / `deferred` / `done`；前两个计入 exit code，后三个通过。

**Ask First:**
- **(Q1) hook 工具选 raw `.git/hooks/` 还是 husky？** retro §C1 写 husky 是基于"console-web 已用 husky"的误判（实测无）。我推荐 raw + install 脚本（zero dep / 跨语言中立 / solo-dev 重新 clone 时一行 `just install-git-hooks`）。等你确认后落地。
- **(Q2) seed `retro_action_items` 时 C1 自身状态写 `done` 还是 `in-progress`？** 本 spec commit 落地即 C1 完成；写 `done` 时 hook 不会自卡（hook 仅在 4-* 触发）。我推荐 `done`，与本 commit 同 atomic。
- **(Q3) checker 是否做 trigger_condition 字符串 grep 过滤？** retro §C1 提"用文本字符串 grep 实现"但语义模糊。我推荐 MVP 不做过滤——任意 `pending` / `in-progress` 都计入；trigger 过滤留 v0.2+。

**Never:**
- 不引 Python / Node / 其它 runtime 依赖；checker 必须纯 bash + 标准 unix tools（grep / awk / sed），保证 sandbox / CI / 任意 dev 机器可跑。
- 不动 BMad workflow / SKILL 文件（C2 / C3 / C9 范围）。
- 不实现 trigger_condition 复杂解析、不做 yaml 严格 parser（用 grep + 块定界字符串足够）、不做"自动翻 status"路径（status 翻动是 retro / 当前 spec 的人类决策）。
- 不把 C1 自身以外的 retro action items 在本 spec 里改 status；只 seed 当前状态快照（A1-A8 / B1-B9 / C1-C9 26 项）。

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Hook 不触发 | commit 不含 `[4-6]-*.md` | hook 静默通过；checker 不跑 | N/A |
| Hook 触发 + 全 done | commit 含 `4-1-*.md`；checker 报 0 pending | hook PASS；stderr 输出 `retro action items: all clear` | N/A |
| Hook 触发 + 有 pending | commit 含 `4-1-*.md`；checker 报 N>0 | hook FAIL exit 1；stderr 列出每项 epic/code/status + `--no-verify 兜底提示` | exit 1 |
| `retro_action_items` 块缺失 | sprint-status.yaml 未 seed | checker exit 1 + `ERROR: retro_action_items block missing — run C1 seed first` | exit 1 |
| sprint-status.yaml 不存在 | 路径错 / 文件被删 | checker exit 2 + `ERROR: sprint-status.yaml not found at <path>` | exit 2 |
| Hook 未安装 | `.git/hooks/pre-commit` 不存在或非 exec | git 不调用 hook；commit 通过 — 由 `just install-git-hooks` recipe 兜底（README onboarding 提示） | N/A — 由 onboarding 路径解 |

</frozen-after-approval>

## Code Map

- `.claude/harness/scripts/check_retro_action_items.sh` — NEW，主 checker 脚本；扫 `retro_action_items:` 块、计 pending+in-progress、exit=count。
- `.claude/harness/scripts/check_retro_action_items_test.sh` — NEW，bash 自测试；3 fixture 走完 happy / pending / missing-block 路径。
- `.claude/harness/git-hooks/pre-commit` — NEW，仓库追踪的 hook 源；staged-diff 命中 `[4-6]-*.md` 时调 checker。
- `.claude/harness/scripts/install_git_hooks.sh` — NEW，一次性 install；cp `.claude/harness/git-hooks/*` → `.git/hooks/` + chmod +x；幂等（已存在则 backup 旧 hook 到 `.git/hooks/<name>.bak`）。
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — UPDATE，append `retro_action_items:` 块；seed Epic 1/2/3 共 26 项；C1=done。
- `Justfile` — UPDATE，加 `retro-check`（调 checker）+ `install-git-hooks`（调 install 脚本）两个 recipe。

## Tasks & Acceptance

**Execution:**
- [x] `.claude/harness/scripts/check_retro_action_items.sh` -- 实现 checker；输入路径 default = `_bmad-output/implementation-artifacts/sprint-status.yaml`；用 `awk '/^retro_action_items:/,/^[a-z_]+:[^ ]/'` 圈定块边界 + `grep -E "^\s+[A-Z][0-9]+:\s*(pending|in-progress)\b"` 计数；exit code = count；stderr 列每项；同步加 `set -euo pipefail` + 路径不存在时 exit 2 + 块缺失时 exit 1
- [x] 跑 `just retro-check` 预期 exit ≠ 0；跑 `just install-git-hooks` 安装；`git commit --allow-empty -m test` 通过

**Acceptance Criteria:**
- Given C1 落地后，when solo-dev 跑 `just retro-check`，then exit code = pending + in-progress 计数（≠0），stderr 按行列每项 epic / code / status / 简述。
- Given C1 落地后，when 任意 commit 不触及 `_bmad-output/implementation-artifacts/[4-6]-*.md`，then pre-commit hook 静默通过，不调用 checker。
- Given 一台新 dev 机器 clone 仓库，when 跑 `just install-git-hooks`，then `.git/hooks/pre-commit` 存在且可执行；既有 `.git/hooks/pre-commit` 被 backup 到 `.bak.<ts>` 而非覆盖。

## Design Notes

**为什么 raw `.git/hooks/` 而非 husky：** husky 需要 console-web pnpm 依赖 + `prepare` script + `.husky/` 目录，会让"clone 仓库 → cd console-web → pnpm install"成为 hook 生效前提；solo-dev 在 console-api / proxy / 仓库根目录工作时不会跑前端的 pnpm install，hook 形同虚设。raw + install 脚本只需一行 `just install-git-hooks`，与栈无关。

**为什么用 `awk` 块定界 + `grep` 计数而不上 yq：** yq 是 Go 二进制需独立分发（违反"不引 runtime 依赖"原则）；`retro_action_items:` 块结构稳定（顶层 key + 二级 epic key + 三级 action item key + 四级 status：scalar），bash + awk + grep 4 行覆盖足够。

## Verification

**Commands:**
- `bash .claude/harness/scripts/check_retro_action_items_test.sh` — expected: exit 0；3 fixture 全过
- `just retro-check` — expected: exit 非 0（C1 done 后剩 17 pending）
- `just install-git-hooks` — expected: exit 0；`.git/hooks/pre-commit` 存在 + exec

**Manual checks:**
- 在 GitHub Issues / git log 留痕本 spec 的 C1 落地 commit；retro §C1 success criteria 4 条全过。
```

---

## 命名 / 风格细节

**chore 标题前缀：** `Chore <code> — ...`（不含 epic 数字；epic 已在 baseline 文件名中）

**chore status 段：** 一律写 `'ready-for-dev'`（fresh agent 不做实施判断 — 主 agent 后续按 CLAUDE.md 自动续作约定逐条实施）

**status enum 处理：**
- 当前 status=pending → spec 写 status: 'ready-for-dev'
- 当前 status=in-progress → spec 写 status: 'ready-for-dev'（in-progress 与 pending 在 chore 化时同等对待）
- 当前 status=partial → spec 写 status: 'ready-for-dev'（partial 升级到 done 也是 chore 工作）

**Ask First 段写法（重要）：** 你**不是**要实施 chore，而是为 chore 立 spec。Ask First 段写"如果 solo-dev 决定实施时可能要回答的问题"——但你**自己锁定推荐答案**。solo-dev 看到 Ask First 段时通常直接接受推荐答案，与 spec-retro-c1 同款。

**chore_spec 字段格式（参考）：** 仅供主 agent 写入用；fresh agent 不输出此字段。形式将类似：

```yaml
retro_action_items:
  epic-1-retro:
    A1: pending
      chore_spec: 'chore-retro-c1-A1-end-to-end-smoke.md'
```

但 yaml 实际格式由主 agent 决定（你只生成 spec 文件本身）。

## 自检清单（输出前自查）

输出前必须逐条自查：

- [ ] 我只为 status ∈ {pending, in-progress, partial} 且 chore_spec 字段缺失的项生成 spec？
- [ ] 我跳过了所有 status=done / status=deferred 项？
- [ ] 我跳过了已在黑名单（已有 chore_spec 字段）的项？
- [ ] 每个 spec 都包裹在 `=== FILE: ... ===` / `=== END FILE ===` 之间？
- [ ] 每个 spec 文件名严格符合 `chore-retro-c${EPIC}-<code>-<slug>.md`？
- [ ] `<slug>` ≤ 40 字符 + 全英文 kebab？
- [ ] 每个 spec 都含 frontmatter（title / type / created / status / baseline_commit / context）+ 5 段（Intent / Boundaries & Constraints / I/O Matrix / Code Map / Tasks & Acceptance / Design Notes / Verification）？
- [ ] frozen-after-approval 段位置正确（包裹 Intent / Boundaries / I/O Matrix 三段）？
- [ ] 我没有写"自动生成 / fresh agent / auto-generated"字样？
- [ ] 我没有改 retro markdown / sprint-status.yaml / 任何 [1-6]-*.md story spec？
- [ ] **每条生成的 chore 都按 rubric 判了 category ∈ {dev, harness}，模糊归 harness？**
- [ ] **末尾输出了 MANIFEST block（=== MANIFEST === / === END MANIFEST ===），每行 `<code>: <dev|harness>`？**
- [ ] **MANIFEST 仅列本次生成 spec 的 code，与 FILE block 数量一致？**
- [ ] 我末尾给主 agent 的总结 ≤ 200 字 + 不在任何 FILE block / MANIFEST block 内 + 含 dev:harness 分类比例？
