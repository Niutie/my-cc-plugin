# Harness Changelog

> **2026-05-04 路径布局迁移**：本 changelog 含早于 `chore-harness-layout-consolidation`（commit 2026-05-04）的历史叙事，引用 `_bmad/scripts/...` / `.claude/scripts/...` / `.claude/harness-architecture.md` / `.claude/answer-policy.md` 等旧路径——这些是历史快照，**不**改写。现行布局见 [`.claude/harness/architecture.md`](architecture.md) §一。新条目按当前路径写。

每次对 `/run-sprint` 编排器（`.claude/harness/scripts/*.py` + `.claude/commands/run-sprint.md` + `.claude/harness/answer-policy.md`）的优化在这里追加一条记录。**新条目放最上面**。每条包含：

- 日期 + story 来源（哪条 story 跑流水线时暴露的痛点）
- 改了哪些文件
- 为什么改（痛点描述 + 不改的代价）
- 改了什么（行为差异）
- 对未来流水线的影响（什么变好了 / 注意事项）

---

## 2026-05-05 — answer-policy + dev-story Q6 项目特定内容 yaml-driven 动态注入（可移植性 L1+L2+L3）

**story 来源**：solo-dev 审查 harness clone-time 修改清单时发现两处硬编码项目泄漏 — (1) `.claude/harness/answer-policy.md` line 5-15 §项目语境段写死"智盾 AI 审计平台 / 中型企业 IT / i18n-ready / 私有化部署"等 9 条决策语境，所有 subagent 在按代答政策自决时都按这个 Aegis 语境跑；(2) `_bmad/customize/bmad-dev-story.toml:22` Q6 全栈贯通 review 7 sub-bullet 写死"sink.AuditEvent / buildevent.go / buildOpenSearchDoc / AuditTemplateBody / canonical_pin tests / i18n locales / console-web 详情页"等 Aegis 具体组件。每次 dev subagent 跑 stage 2 都被注入这段，clone 后新项目无这些组件 → subagent 跑偏。User 论点："代答策略应该是 harness 自动化过程中需要决策点的回答策略，不应该混入项目特定语境"——判断对。

### §A: harness-project-config.yaml 加 2 字段（L1+L2 数据层）

- `extra.project_context:` 多行 `|` 块字段 — 项目产品定位 + 关键决策原则（产线给原 Aegis 9 条作为 default fixture）
- `extra.fullstack_review_steps:` list of `{label, file_path}` — 项目核心数据写入 / 序列化 / 渲染 / i18n 路径列表（产线给原 Aegis 7 条作为 default fixture）

### §B: harness_config.py 加 2 reader（L1+L2 helper 层）

- `get_project_context()` — 读 multi-line block；缺失 fallback 到"项目语境未配置 — clone 后请填..."提示 + WARN
- `get_fullstack_review_steps()` — 读 list of dict；缺失 fallback 到空 list + WARN（dev-story Q6 整段降级跳过）
- harness_config.py CLI smoke 同步加这 2 字段输出

### §C: harness-prompt-suffix.py inline 注入（L1+L2 prompt 层）

- `ANSWER_POLICY_BLOCK` 改为 f-string — 内联 `_PROJECT_CONTEXT` 字段（模块加载时一次性 resolve），subagent 在 prompt 后缀直接拿到完整决策上下文 + 通用决策原则文件指针，无需 Read 第二个文件
- 新增 `Q6_FULLSTACK_REVIEW_BLOCK`（stage 2 only）— 渲染 `_FULLSTACK_REVIEW_STEPS` list → (a)-(z) sub-bullet 行；letter 函数支持 ≥27 项（用 item-N fallback）；空 list 时整段降级为标注语句（dev agent 跳过 Q6）
- `Q6_STAGES = {"2"}` 加入 stage 2 emit 列表

### §D: BMad customize toml + suffix.md 去硬编码（L2 prompt 层）

- `_bmad/customize/bmad-dev-story.toml:22` Q6 sub-bullet 描述去掉具体组件名（"sink.AuditEvent / buildevent.go / ..."）— 改为指向 `harness-prompt-suffix.py` stage 2 渲染块 + 引用 yaml 字段；保留"适用条件 / 默认答复体例"通用语义
- `.claude/harness/prompt-suffixes/bmad-dev-story-suffix.md` Q6 段去掉硬编码 (a)-(g) list — 改为说明"由 harness-prompt-suffix.py 动态注入；clone 时改 yaml 即可"+ 保留答复格式 + reference examples

### §E: answer-policy.md 重构（L1 文件层）

- §项目语境段 (line 5-15) 整段删除 — 项目语境通过 prompt suffix 注入而非读文件
- 新增引言段：明确"本文件只含跨项目通用流程决策原则；项目特定语境由 harness-prompt-suffix.py 内联注入"
- 保留 §决策原则（4 条不发问 / 优先继续 / 写交付物 / 登记 follow-up）+ §适用范围

### §F: /run-sprint-init §2 加字段 15-16（L1+L2 init 层）

- 14 → 16 字段提取规则
- 字段 15（project_context）: BMad source = `product-brief.md` 或 `prd.md`；语义提取产品定位 + 关键决策原则段；fallback 多行块 + WARN
- 字段 16（fullstack_review_steps）: BMad source = `architecture/data-model.md` / `component-architecture.md` / `repo-structure.md`；语义按数据流 7 段提取 `{label, file_path}` list；fallback 空 list + WARN
- 加"字段 15-16 特殊语义"段说明 yaml-driven 动态注入路径 + fallback 不阻流

### §G: architecture.md §十二 文档化（L3）

- §12.2 Clone 拷贝清单整理（去掉 🔧 行）
- 新增 §12.3「Clone 后必改文件」表 — 仅 `harness-project-config.yaml`（自动化）+ `run_retro_self_audit.sh`（手工）2 项
- 显式列出"不需要再改的文件"（answer-policy.md / bmad-dev-story-suffix.md / customize toml — 因为 yaml-driven 动态注入解耦了项目特定）
- 「新项目 onboarding 三步」：clone → /run-sprint-init → 改 retro audit + simulate_clone_test 验证

### §H: 影响

- **clone 痛点解决**：原本需要手工改 4 处（answer-policy.md / bmad-dev-story-suffix.md / customize toml line 22 / harness-project-config.yaml）→ 现在仅需改 1 处（harness-project-config.yaml；其它由 prompt-suffix.py 动态读 yaml）；且 yaml 由 /run-sprint-init 自动从 BMad planning artifacts 提取
- **subagent 决策质量保留**：prompt 中既有跨项目通用决策原则，又有项目特定语境（inline）；信息密度无损失
- **零回归**：5/5 self-test PASS（check_retro_action_items / process_retro_residue / backfill_resolved_markers / harness_config / simulate_clone_test）
- **Q6 弹性提升**：原硬编码 7 sub-bullet → 现按 yaml list 长度任意（letter 自动从 a..z；≥27 用 item-N）；不同项目数据流深度不一也覆盖

---

## 2026-05-05 — retro_action_items 按 category 分流（B 方案 — 解耦 dev / harness blast radius）

**story 来源**：solo-dev 复盘 D5 sealed-patterns inheritance hook 事故 — 一个 harness 类 retro action item 落地后引入的 pre-commit gate ② 误伤 epic-5 stage ③ codex-review.md，迫使 v1.3 整段删除该 gate（见 `.claude/harness/git-hooks/pre-commit` 头部 v1.3 注释）。根因：`retro_action_items` 把 dev 类（产品代码 / 测试 / NFR / ADR）和 harness 类（流程脚本 / hook / skill / template / schema）共用同一个表 + 同一个 pre-commit gate，blast radius 不对称 — harness 改动一旦出 bug 跨所有后续 epic 的所有 story，与 dev 改动局限于一个 story / 一个 epic 不同，但两类被强制画等号阻塞 epic 推进。

### §A: schema 升级 + 40 条历史回填（同 commit）

- `_bmad-output/implementation-artifacts/sprint-status.yaml` 顶部 retro_action_items schema 文档段重写 — 新增 `category: dev | harness` 必填字段定义 + 两类 gate 行为差异 + 模糊归 harness 保守原则
- 40 条历史 retro_action_items 全部回填 category（epic-1-retro 8 / epic-2-retro 9 / epic-3-retro 18 / epic-4-retro 5）
- 分类比例实测 dev:harness = 9:31 — 印证假说"retro 主要产出是 harness 优化建议，开发类反而少数"
- dev 类（9）：A1 / A2 / A4 / A5 / A8 / B9 / C6 / C8 / D4
- harness 类（31）：A3 / A6 / A7 / B1-B8 / C1-C12 / C-bootstrap / C-cond-triggers / C-codex-fixes / C-layout-consolidation / C-path-externalization / C-run-sprint-init / D1 / D2 / D3 / D5

### §B: checker v2 + hook v1.5 分流

- `.claude/harness/scripts/check_retro_action_items.sh` v2 重写 — awk 状态机扫块时同步识别 `category:` 子字段；输出三段 stderr WARN：(i) PENDING_DEV 计入 exit code（阻 epic）/ (ii) PENDING_HARNESS 仅 WARN 不计 / (iii) PENDING_NOCAT schema drift 提示
- 扩展 item code regex 从 `[A-Z][0-9]+` 到 `[A-Z][A-Za-z0-9-]*` — 支持 `C-bootstrap` / `C-cond-triggers` / `C-run-sprint-init` 等 alphanumeric-dash code（修复 v1 隐性遗漏）
- self-test 从 8 fixture → 12 fixture（新增 i: 仅 harness pending 不阻 / j: 混合 dev+harness pending 仅 dev 计 / k: 缺 category NOCAT WARN / l: alphanumeric-dash code 兼容）；全 12 PASS
- `.claude/harness/git-hooks/pre-commit` v1.5 错误文案分流 — 明确"仅 dev 类阻 gate；harness 类显示为 WARN 但不阻 epic 推进"+ 新增"harness 类待评估"处理路径

### §C: residue processor + 起步约定分流

- `.claude/harness/scripts/process_retro_residue_prompt.md` 加 "Category 分类 rubric" 段（dev/harness 判定标准 + 边界判定 + 模糊归 harness 保守原则）+ MANIFEST block 输出契约（fresh agent 末尾输出 `=== MANIFEST === / <code>: <dev|harness> / === END MANIFEST ===`，主 agent 据此写 sprint-status.yaml `category:` 字段）
- `.claude/harness/scripts/process_retro_residue.sh` 输出要求段同步加 MANIFEST block 说明
- 自检清单加 4 项 category / MANIFEST 强制项
- `.claude/commands/run-sprint.md` 阶段 ⑥.5 闭环 — 步骤 5 新增"主 agent 解析 MANIFEST block 得 code→category 映射"；步骤 6 写 yaml 时 chore_spec + category 两字段一并落；sanity check 加"MANIFEST 行数 == FILE block 数"+ checker 退出 ≤ 200 (不引入新 NOCAT)；halt 触发加"category 不在 {dev,harness}"+ "MANIFEST 与 FILE 数量不一致"
- `CLAUDE.md` 起步约定段重写「会话起步约定」— 按 category 分两段通知（dev 主通知阻 epic / harness 仅在 dev 全 done 时作次通知，且必须 solo-dev 显式触发"评估 harness 优化"或"继续 harness <id>"才进实施流程）

### §D: 决策文档

- `.claude/harness/architecture.md` §六 标题升 4 个 Decisions + 加 Q4 决策段（Problem / Decision / Why not A / Why not C / D5 反例 / 实施落地）
- §七 实施 roadmap 加"Q4 B 方案"到当前已落清单

### §E: 影响

- **观测**：D5 类 harness 改动失败不再阻 epic 推进 — 即使 inheritance hook 全坏掉，dev 类 retro pending=0 时 epic-5 spec 仍能正常创建；harness 类作为"建议"出现在 stderr WARN 而非 ERROR
- **行为变化**：solo-dev 在 dev 类全 done 时收到次通知"另有 N 项 harness 优化建议待评估"，需显式说"评估 harness 优化"或"继续 harness <id>"才进入实施流程；非显式触发时主 agent **不**主动跑 harness chore（避免会话被打断 + harness 改动 blast radius 可控）
- **不变**：dev 类完全保留原 pre-commit gate 强约束（产品代码 / NFR / ADR / 测试 pending 仍阻 epic 4-6 spec 创建）；chore 实施流程本身不变（按 spec ## Tasks & Acceptance 逐条 + 单 commit + 翻 status）
- **B 不是 A 不是 C**：A 方案完全分离（harness 搬出 sprint-status.yaml 到 improvement-backlog 完全手动）代价是 critical path 类 harness 改动（schema 升级 / test harness 接通）会被习惯性拖延；C 方案物理拆两表代价是分类启发式错分进 backlog 不可逆。B 方案保留同表 + tag 分流，错分一眼能改

---

## 2026-05-04 — deferred-work schema v1：280 自由文本 FU → 301 schema-tagged FU + 工具链切换

**story 来源**：solo-dev 实测发现 `_bmad-output/implementation-artifacts/deferred-work.md` 1002 行/292KB 格式过乱（多视角并存 / inline 后缀拼接状态 / FU-RETRO-* 重复登记 / review finding 散记无 FU id 等），grep 工具链靠 word-boundary regex + Resolved-by-Story 文本剔除 hack 兜底。

### §A: schema 文档落地（commit-1: efb7c27）
- 新增 `.claude/harness/conventions/deferred-work-schema.md`（260 行）
- 内容：每条 FU 用 4-tag 头 `[status:...] [bucket:...] [target:...] [source:...]` + 4 字段（修复方向 / 触发条件 / 关联 / 历史）；7 status 枚举 / 8 bucket 枚举；状态变迁路径；§5 历史回填策略；§6 工具链对接；§7 prompt-suffix 约束；§8 v1 → v2 演进锚（>1000 bullet / >6 tag 字段时升级）
- 取代 chore C11 / C12（保留 done 状态 + frontmatter superseded_by）

### §B: 历史 280 FU bullets 重写（commit-2: 35d8411）
- `_bmad-output/implementation-artifacts/deferred-work.md`（1002 → 1631 行；1244 insertions / 615 deletions / 83% rewrite）
- 由 fresh agent 逐章手工重写（多会话；280 老 + 33 short-id (F-N/AA-N/BR-N/EC-N) promote + 4 desc-only promote + 11 FU-RETRO-3.C1.A..K rename → FU-C1-A..K + 8 FU-RETRO-3.C2..C9 dropped + 9 dups in Resolved-by-Story-1.12 dropped → 301 schema-tagged）
- 删 4 整章节：Resolved-by-Story-1.12 / epic-2-retro B6 placeholder / bmad-quick-dev multi-goal split / Resolved by Epic 3 retro (C8) chore prose
- 章节标题改名：§X — Test Harness FU items → Deferred from: chore-test-harness-bootstrap (2026-05-04)
- 单 FU 顶级章节迁移：## FU-A1.REAL-ACTUATION → 新 ## Deferred from: epic-1-retro 2026-05-04 (chore-retro-c1-A1 scaffold) 章节内 schema bullet
- §1 顶部桶计数表替换 AUTO-GENERATED placeholder；§1.1/§1.2/§1.3 critical evaluation 段保留

### §C: 工具链 + 收尾（commit-3 + commit-4）
- `.claude/harness/scripts/grep_deferred_buckets.sh` 重写（323 → 200 行）— 切到读 schema tag；新增 `--emit-section1` flag 输出 markdown 段填到 §1 AUTO-GENERATED 块
- `.claude/harness/scripts/grep_pending_deferred_for_story.sh` 重写 — 切到 `[target:Story X.Y]` 精确匹配
- `.claude/harness/scripts/grep_deferred_status.sh` 重写 — 切到 schema tag；3 段输出（pending / closed / 同 epic 孤儿）
- `.claude/harness/prompt-suffixes/{bmad-create-story,bmad-dev-story,bmad-retrospective}-suffix.md` 加 schema v1 写入约束段
- `_bmad-output/implementation-artifacts/sprint-status.yaml` `retro_action_items.epic-3-retro.C11/C12` 加 inline `superseded by deferred-work-schema-v1` comment
- `chore-retro-c11/c12.md` frontmatter 加 `superseded_by` / `superseded_date` / `superseded_note` 字段
- `architecture.md` §九引用段加 conventions 路径
- `deferred-work.md` §1 桶计数表自动填入：Epic 6=42 / v0.2+=65 / v1.0+=20 / sandbox=40（3 类 breach）+ open 262 + closed 39
- **(commit-4) `.claude/harness/git-hooks/pre-commit` 加 gate ② schema v1 hard enforcement**：staged diff 含 deferred-work.md 改动时仅扫新增行，3 个 sub-check — (a) FU bullet 头必带 4-tag 完整块；(b) 老 inline `— Resolved by Story X.Y (date)` 后缀模式拒绝；(c) FU-RETRO-* 命名空间拒绝。`--no-verify` 显式 bypass 保留（与 gate ① retro check 同款）。配套 `pre_commit_deferred_schema_test.sh` 4-fixture 回归测试入仓。

### §D: 影响
- **观测**：solo-dev 用 `bash .claude/harness/scripts/grep_deferred_buckets.sh` 直接看 8-bucket open 计数 + 3 breach 状态；`--show-resolved` 看 needs-review 单列；`--emit-section1` 落地 §1 总账
- **stage 1 prompt injection**：`grep_pending_deferred_for_story.sh <key>` 输出该 Story 待消化 FU 准确列表（按 `[target:Story X.Y]` 精确匹配，比 word-boundary regex 0 false positive）
- **dev / retro agent 写入**：3 份 prompt-suffix 注入约束让新 FU 必走 schema；老 inline `— Resolved by Story X.Y` 模式废弃
- **FU-RETRO-* 命名空间禁止进 deferred-work.md**（retro action items 100% 归 sprint-status retro_action_items 块）
- **schema 锁 v1**：bullet 总数 > 1000 / tag 字段 > 6 / 工具链 awk-only 不够时再演进 v2

---

## 2026-05-04 — chore-harness-epic-4-orchestration-observations: 4 条 epic-4 跑通后观察落地

**story 来源**：epic-4 全 7 条 story 跑通 + retro 完成后实测发现的 4 条 orchestration 优化痛点（与 D3 互补 — D3 处理 harness-commit/state pre-flight snapshot 一致性检查；本 chore 处理 4 条邻接但不同的 orchestration 路径问题）。

### §A: `harness-commit.py` 自动 sync sprint-status + seed retro_action_items + fill chore_spec（T1）

**痛点**：`bmad-dev-story` 不翻 `<KEY>: review`、`bmad-code-review` 不翻 `<KEY>: done`、`bmad-retrospective` 不翻 `epic-${N}-retrospective: done` / `epic-${N}: done`，**也不 seed `retro_action_items.epic-${N}-retro` 块**（导致 `process_retro_residue.sh --epic 4` 报 `block not found`，靠主 agent 手工 Edit yaml seed D1-D5 才能继续）。当前兜底方式是主 agent 在 stage 2/5/6 commit 前手工调 `python sprint-status.py set ...`，遗漏一个就静默错。
**改了什么**：`harness-commit.py` 加 3 个助手：
- `_sync_sprint_status_for_stage(stage, key, epic)`：stage 2 → set <key> review；stage 5 → set <key> done；stage 6 → set epic-<epic>-retrospective + epic-<epic> done；stage 6-5 → no-op；其它 stage → no-op。idempotent（current==target 时跳过）。
- `_seed_retro_action_items(epic, retro_md, sprint_status)`：grep retro markdown §6 `^### {letter}[0-9]+`（letter 由 epic 推出：1→A / 4→D），提取 D items 自动 seed `retro_action_items.epic-${epic}-retro` 块；idempotent（已 seed 的 D items 不重复）。
- `_fill_chore_spec_field(epic, sprint_status, artifacts_dir)`：stage 6-5 commit 前按 `chore-retro-c${epic}-D[0-9]+-*.md` glob 匹配 + 自动 fill `chore_spec` 字段；idempotent（已有 chore_spec 的 entry 跳过）。
- 集成在 main() step 1.7（auto-prune 之后、blacklist 之前）；任何 IO 失败 → STATUS=halt（Q1 RESOLVED：halt 不 reconcile，与 D3 同款）。
- run-sprint.md §1 阶段 ②/⑤/⑥ 删除主 agent "兜底 set" 段，责任全压在脚本。
- 新加 `--simulate-retro-md-with-d-items` test-only flag（生成 5 D items synthetic md + 临时 yaml，验证 seed 逻辑；不污染真实状态）。
**影响**：BMad skill 漏 sync 不再静默错；主 agent prompt 复杂度降低（不再需要记忆"哪个 stage 后调哪个 set"）；retro_action_items seed 自动化（process_retro_residue.sh 不再 `block not found`）。

### §B: stage 5.5 commit 路径统一（T2）

**痛点**：epic-4 实测 4-1/4-2/4-3/4-4 走 5-5 单 commit 路径，4-5/4-6/4-7 走 T3+T4 双 commit 路径（subagent 内部 commit）— 7 条 story 同款 stage 但 commit history 颗粒度 + message 不一致；主 agent 行为依赖 subagent 是否"主动 commit"。
**改了什么**：
- run-sprint.md §1 阶段 ⑤.5 改写为 review-only：spawn → 等返回 → 验收产物 → 跑 5-5 期待 STATUS=skip → 跳过；删除"sandbox-graceful-skip 主 agent 写文件"段（移交 run-test-sprint 内部）。
- run-test-sprint.md T4 commit message 加 "(run-sprint stage 5.5)" 后缀（任一调用路径下都用同一后缀，让 grep "stage 5.5" 能稳定找）；§0.0.5 加"5-5 commit 由本 subagent 内部 T4 stage 完成，主 agent 不再调用 5-5 commit" 说明。
- harness-commit.py 5-5 stage 保留 STAGES dict 既有签名（back-compat fallback）；新增 docstring 解释三条合法分支：(a) worktree clean → STATUS=skip（新默认）；(b) worktree 有 stage 5.5 期望产物 → STATUS=ok（旧路径兼容）；(c) 不期望路径残留 → STATUS=halt。
**影响**：commit history 颗粒度细（atdd 红相 vs e2e 绿相分阶段诊断）；commit message 模板对所有 epic-X 同款；5-5 命令签名不破（防 cron 化的工作流断链）。Q3 RESOLVED：选 T3+T4 双 commit SoT。

### §C: `harness-state.py --resume-prompt --stage 2` 增强 3 段（T3）

**痛点**：4-4 stage 2 quota halt 续作时脚本输出 `Tasks checkbox: 0/104 已 [x]`，但 worktree 已有 18 个文件落地（5 yaml + 3 测试文件 + testdata 目录 + 1 修改 schema 等）— `bmad-dev-story` skill 推 task checkbox 与 worktree 落地异步，脚本只 grep checkbox，fresh subagent 拿到的"前情提要"与实际 worktree 状态严重 diverge — 必须额外 Read worktree 文件交叉验证才能 truthfully tick。
**改了什么**：`harness-state.py` 加 3 个新 helper：
- `_format_worktree_landing_summary()`：`git status --porcelain` 按一级目录 group + count + size sum；前 10 desc by file count；超 5 文件的目录二级展开（Q4 RESOLVED — 一级优先，过 5 才二级）。
- `_format_git_diff_stat_summary()`：`git diff --stat HEAD` 前 20 行 + "... and N more files"；失败 fallback 不 halt。
- `_format_dev_result_summary(key)`：dev-result.json 字段一览（checks / files_changed_count / files_changed_count_code / final_story_status）；缺则输出 "**未写**（机器可读完成门必交付）"。
- 集成进 `--resume-prompt --stage 2` 输出（保留既有 checkbox 字段 — 互补不替代）。
**影响**：fresh subagent 拿到 prompt 时能立刻看到 "checkbox 0/104 但 worktree 已有 X 文件落地 + git diff 显示 +Y/-Z + dev-result.json 已写 checks 全 pass" 三层 ladder up — 信息密度更高，不再被 "0/104" 误导。

### §D: `harness-state.py --halt-recovery-check` 新子命令（T4）

**痛点**：4-5 stage 5 quota 在 subagent return summary 时耗尽 — review-progress.json + review-findings.json + story md Status=done 都已落地、harness-commit.py 5 直接走通；但当前 §3 死循环防护表只有"重启 stage"一种续作方式，不区分"work 真没做" vs "work 已做但 message 丢失"。本次靠主 agent 手工 ls + cat 检查产物文件做出"直接 commit"决策，**该决策当前是手工的**，需要脚本化。
**改了什么**：
- `harness-state.py` 加 `--halt-recovery-check --stage N` 子命令，按 stage 预期产物清单（hard-coded HALT_RECOVERY_SPECS map）验证 worktree。
- 输出 3 类 verdict：`READY_TO_COMMIT`（stage_marker 全在 + Status 一致 → 建议 `harness-commit.py N <KEY>`）/ `NEED_RESUME`（stage_marker 全缺 + 无 partial → 建议 spawn fresh subagent）/ `INCONSISTENT`（部分齐 / Status 不一致 → 建议手工介入）。
- run-sprint.md §3 halt 模板加"选项 0：先跑 halt-recovery-check 探 ground truth"段，放在 1-5 之前作为 first-class try（配额耗尽 halt 优先 try 此项）。
- Q5+Q6 RESOLVED：仅诊断，**不**自动跑 commit / reset / stash；只输出 ground truth + 建议命令，决策权留给主 agent。
- 新增 verdict 逻辑：stage_marker（stage-specific 关键产物）+ partial（incremental progress）+ expect_status（仅在 marker 全在时 enforce）三层判定，避免"shared baseline 产物"（如 story md）让 NEED_RESUME 路径误判为 INCONSISTENT。
**影响**：4-5 那种 work-done-but-msg-lost 路径主 agent 可直接走 commit 路径不必 respawn — 配额耗尽 halt 后续作成本下降；fresh subagent vs 直接 commit 决策有可重复 ground truth。

### §E: 17-fixture self-test + Justfile 2 recipe + changelog（T5）

- `.claude/harness/scripts/orchestration_observations_test.sh` — NEW，552 行，T1=5 / T2=3 / T3=4 / T4=5 fixture，全 mock 不依赖 git runtime。
- `Justfile` — 加 `orchestration-observations-test` + `halt-recovery-check KEY STAGE` 2 recipe。
- 本 changelog 条目（§A-§E）。

### Commit 拆 4-5 commits

按 chore spec T7 拆分：T1 / T2 / T3 / T4 各一 + 1 commit 收尾测试 + changelog。每 commit `chore(harness-orchestration): T<N> ...`；HEREDOC + Co-Authored-By。

---

## 2026-05-03 — Tier 0+1: 减少 halt + 续作 deterministic（epic-2 retro 8 halt 事件复盘）

**story 来源**：epic-2 全 8 条 story 完成后回顾，触发 8 次"halt 类事件"——5 次配额耗尽（runtime 限制无法消除）+ 3 次伪触发（cross-story / unexpected-artifact / sprint-status 解析器跳过 inline comment）。目标是把所有伪触发自动化，让"稳定自动开发"这条产品承诺尽量贴近事实。

### §A: `harness-commit.py` 自动 prune subagent-spilled 额外 .md artifacts

**痛点**：本轮 2-6 stage ⑤ subagent 创建了 `2-6-...bmad-code-review.md` 这种白名单外的 .md 报告。harness-commit.py 的 UNEXPECTED_ARTIFACT 规则会 halt 拒收。但这种报告内容已经在 `<KEY>.review-progress.json` + Story md `### Review Findings` 段里——独立 .md 是冗余噪音，不是错误。
**改了什么**：`harness-commit.py` 在 stage 检测前增加 §1.6 自动剔除步骤——untracked / newly-added 路径如果匹配 `_bmad-output/implementation-artifacts/<KEY>.<extra>.md`（`<extra>` ∈ `{bmad-code-review, review-summary, dev-notes, review-report}`）就 unstage + rm + 输出 `AUTO_FIXED=unexpected-md ...` 行。仅对 untracked 路径触发，modified 文件永不自动删（保护合法编辑）。
**影响**：subagent 偏离 schema 的多产 .md 不再触发 halt。本轮 2-6 case 主 agent 不需要手工 `rm`。

### §B: `harness-commit.py` 支持 spec frontmatter `cross_story_artifacts:` 白名单

**痛点**：本轮 2-5 stage ② commit 因为 spec 显式约束的 cross-story 改动（修 1-7 typo + spec-deferred-cleanup frontmatter）被 cross-story isolation halt——但这两项是 Story 2.5 spec 的合法 deliverable（FU-1.5.M 强制并入约定）。用户只能用"双独立 chore commit"绕开。
**改了什么**：harness-commit.py 调用 `read_cross_story_allowlist(key)` 解析 story md frontmatter `---` 段里的 `cross_story_artifacts:` YAML list。基本名（不允许 `/` / `..`）、必须 .md 后缀、不能是 `<KEY>.*` 自身。命中 allowlist 的路径从 cross-story 检查里豁免；CROSS_STORY halt 的诊断输出会同时打印 `CROSS_STORY_ALLOWLIST=` 行帮助调试。
**影响**：未来 epic 中 spec 显式声明"我会改 X 跨 story 文件"的 case，stage ② commit 直接通过；不需要双独立 chore commit。

### §C: `sprint-status.py` STORY_KEY_RE 容忍 inline comment

**痛点**：本轮 2-5 行尾带的 inline comment（`2-5-foo: backlog  # MUST merge ...`）让原正则 `^\s+([A-Za-z0-9_\-]+):\s*(\S+)\s*$` 整行匹配失败——`next` / `count` / `epic-all-done` 都把 2-5 当作不存在，主循环差点跳过它。
**改了什么**：正则改为 `^\s+([A-Za-z0-9_\-]+):\s*(\S+)\s*(?:#.*)?$`（YAML inline comment 标准）。仅一行变更。
**影响**：未来 yaml 加 inline hint 不再静默漏算。standalone comment 仍是首选写法（更易读），但 inline 也兼容。

### §D: `harness-state.py --resume-prompt` — 续作 prompt 自动生成

**痛点**：本轮 5 次配额 halt 后，主 agent 每次都要手动跑 `git status --porcelain` + grep story md Status + check JSON 文件、然后手工拼一个超长 prompt 描述给 fresh subagent。每次都重做相同的侦察工作，且 prompt 拼接漏字段就让 fresh agent 走偏（曾在 2-4 续作时 progress JSON 字段名被忘了）。
**改了什么**：`harness-state.py` 加 `--resume-prompt --stage <N>` 子模式。探测 stage-internal micro-progress（stage 2: tasks `[x]/[ ]` 计数 + dev-result.json 存在 + worktree 改动按 `console-api/` / `console-web/src/` / `tests/` 等 prefix 分组；stage 4: codex-review.md finding 数 vs Story md `### Codex Review Handling` 行数 + 缺口；stage 5: review-progress.json findings 状态分布 + review-findings.json 存在 + Review Findings 段存在），输出纯文本 ready-to-paste prompt 段。
**影响**：续作从"主 agent 凭推理拼 prompt"变成"调脚本→输出粘贴"。主 agent 跨会话续作的准确率从 fragile 升到 deterministic。

### §M: subagent 退出前强制 `git status --porcelain` 自报

**痛点**：本轮 2-7 stage ① subagent 跑 /bmad-create-story 时，BMad workflow 内部的子工作流偷偷改了 main.go（修了 Story 2.6 chi panic regression）——subagent 自报"未对该文件执行任何 Edit/Write/Bash 写入"，但 git diff 显示 95 行改动。subagent 的 self-narration 不可信。
**改了什么**：`harness-prompt-suffix.py` 给所有 stage 加 `GIT_STATUS_SELF_REPORT_BLOCK`——subagent 在 stop 前必须跑一次 `git status --porcelain` 并把输出 verbatim 贴进返回 message。主 agent 看到结构化输出后做交叉验证，不再依赖"subagent 说我没改 X"。
**影响**：worktree 污染在 subagent 返回的瞬间被发现；主 agent 不需要后续 stage commit prep 才暴露问题（早发现 = 早便宜）。

### §N: stage ⑤ subagent prompt 固化 `review-progress.json` schema + 额外 artifact 禁令

**痛点**：本轮 2-5 stage ⑤ subagent 写出 list 结构 findings（不是 dict），主 agent 后来要做 schema 容错。手工在 stage ⑤ prompt 里加 schema 约束至少 3 次——应当进 `harness-prompt-suffix.py` 标准输出。
**改了什么**：`harness-prompt-suffix.py 5` 末尾加 `STAGE5_PROGRESS_SCHEMA_BLOCK`：findings 必须 dict 结构 + 字段规范 + phase 取值 + **每完成一条立即增量 Write**（让配额耗尽时仍有 partial progress 留下）+ 重申"额外 artifact 禁令"（与 §A 自动剔除互补）。
**影响**：主 agent 不再需要每次手贴 schema 约束。fresh-spawn 续作时 review-progress.json 结构稳定，`harness-state.py --resume-prompt --stage 5` 的 micro-progress 探测准确。

### Two commits

落地分两次：
1. **Tier 0**（§A / §B / §C）：`108c102 chore(harness): Tier 0 — relax 3 false-positive halt conditions` — 把 3 类伪触发自动化掉。
2. **Tier 1**（§D / §M / §N）：`f3357d6 chore(harness): Tier 1 — deterministic resume prompts + git status self-report` — 让续作 prompt deterministic + 让 subagent 跑偏的 worktree 污染早发现。

### Tier 2 — 暂不落地（评估过但决定 epic 3+ 实测后再决定）

复盘时识别出 2 个"值得做但本轮不做"的优化点。**不实施的理由**：epic 2 实测中没真触发足够大的痛点，提前做有 over-engineer 风险。在这里登记**触发条件**，未来跑 epic 时如果命中条件就重启评估。

1. **§1 阶段 ① 末尾正式加 sprint-status 兜底（协议固化）**
   - 痛点（已实证）：本轮 2-3 stage ① subagent 配额耗尽时已写出 story md，但忘了 `sprint-status.yaml` set ready-for-dev——主 agent 临时手工兜底通过。
   - 现状：协议只在 stage 2 / 5 末尾要求兜底，stage 1 没明文（虽然主 agent 实际做了）。
   - **触发重启评估的条件**：epic 3+ 再发生一次 stage ① subagent 漏 sync sprint-status 导致 `harness-commit.py 1` 不识别本 story 进度。
   - 改动设想：`harness-commit.py` stage 1 commit 前自动跑 `sprint-status.py set $KEY ready-for-dev`（无脑兜底，状态已 ready 是 no-op）。

2. **主 agent 调度子 agent 前 git status 快照 + 返回 diff**
   - 痛点（已实证）：本轮 2-7 stage ① subagent 跑 /bmad-create-story 时 BMad workflow 内部子工作流偷偷改了 main.go——靠 §M（subagent 自报 git status）能在子 agent 退出瞬间发现，但**无法在调度前预防**。
   - 现状：Tier 1 §M 已经把发现时间从"stage 1 commit prep"提前到"子 agent 返回瞬间"，已经是一大步。
   - **触发重启评估的条件**：epic 3+ 再发生一次 subagent 跑偏修了多个 worktree 文件、靠 §M 抓到但介入成本仍很高的 case；或者 §M 失效（子 agent 没按要求自报）的 case 出现 ≥ 2 次。
   - 改动设想：主 agent 调度子 agent 前 `BEFORE=$(git status --porcelain | sort)`，子 agent 返回后 `AFTER=$(git status --porcelain | sort)`，diff 自动 emit 警告——把"调度前 worktree 状态"封进结构化变量，不依赖 subagent 的自报靠不靠谱。

未来若需要落地：在本 changelog 追加新的 `## YYYY-MM-DD — Tier 2: ...` 段，引用本段作为决策上下文。

---

## 2026-05-02 — §M: stage ⑥ 漏 mark `epic-N: done`（epic-1 跑完手动补完发现）

**story 来源**：epic 1 收官 — 12 条 story + retrospective 全 done 后，`sprint-status.yaml` 仍显示 `epic-1: in-progress`，用户手动指出。

**痛点**：playbook 阶段 ⑥ 只有一行状态推进——`set epic-${EPIC}-retrospective done`，从未推进 `epic-${EPIC}` 自身。`bmad-retrospective` skill 也不维护 epic 顶层状态字段。结果是每个 epic 跑完，retro key 翻 done，但 epic key 永远卡在 `in-progress`，要靠人工事后补。`/run-sprint --epic <num>` 模式的"epic 全 done 且 retro = done → 直接退出"判断仍能走通（不依赖 epic key 自身），所以 bug 没炸——只是 sprint dashboard 永远是错的。

**改了什么**：

1. `.claude/commands/run-sprint.md`
   - §0.5 commit 表 line 167：`epic($EPIC): mark retrospective done` → `epic($EPIC): mark done`，括号里说明 6-done commit 同时翻两个 key（`epic-${EPIC}-retrospective` + `epic-${EPIC}`）。
   - §1 阶段 ⑥ line 522~523：`状态推进` 一行拆成两步：先 `set epic-${EPIC}-retrospective done`，再 `set epic-${EPIC} done`，并明文注释"epic 状态没有任何 skill 维护，主 agent 必须显式做"+引用本条 changelog。前置 `epic-all-done` 已经在阶段 ⑥ 入口做过，无需再校验。
2. `.claude/scripts/harness-commit.py`
   - stage `6-done` 的 `commit_msg` 从 `epic({epic}): mark retrospective done` 改成 `epic({epic}): mark done`，反映 commit 实际带走的状态翻转范围（retro + epic 两个）。
3. `_bmad-output/implementation-artifacts/sprint-status.yaml`
   - 手动补：`epic-1: in-progress` → `epic-1: done`（用 `python3 .claude/scripts/sprint-status.py set epic-1 done`，命令本身已支持 epic-* key，旧 playbook 只是没调）。

**对未来流水线的影响**：

- 之后每个 epic 收官时，`sprint-status.yaml` 里 epic 顶层状态字段会自动从 `in-progress` 翻成 `done`，不再需要人工事后补。
- 两个 `set` 都打到同一份 yaml，stage `6-done` 仍是单 commit、产物范围不变（仅 `sprint-status.yaml`），harness-commit 白名单无需调。
- commit subject 从 `mark retrospective done` 变成 `mark done` —— git log grep 老 subject 的脚本（如果有的话）需要更新。当前仓里只有 epic-1 的 6-done commit 走过老 subject，量小，影响可忽略。
- **副作用提醒**：`sprint-status.py status <epic-key>` 当前不支持 epic-* key（`cmd_status` 没传 `include_epic_keys=True`），查 epic 状态会返回退出码 1。本次没改这个——使用方都是直接 grep yaml 或调 `epic-all-done` / `epic-retro-status`，不依赖 `status` 命令查 epic key。如果未来 playbook 要查 epic key 状态，再补 `cmd_status` 即可。

---

## 2026-05-01 — §L: deferred-work 接入流水线（stage ② 软扫描 + stage ⑤ 趋势输出）

**触发场景**：用户回看 §K 后追问"`deferred-work.md` 经常产生条目（44 条带 `回头处理时机`），有些显式指向后续 story 处理；每个 story 跑流水线时需不需要主动扫一遍 deferred 把相关项一起处理掉？BMad 最佳实践是什么？合不合适接进 harness？"

**调研结果**：
- 当前 `deferred-work.md`：99 行 / 25KB / 44 条带"回头处理时机"标记 / 5 条已 inline 标 `Resolved by Story X` —— 说明"后续 story 顺手处理 deferred"是真实发生的，但靠 dev agent 自己想起来读，**没有自动注入**机制。
- BMad 模块全集合（bmm / cis / bmb / core / tea）**搜不到**任何处理 deferred / followup 的 skill 或 workflow。BMad 原生设计是把 follow-up 写进 story md 的 dev notes 段，不是单独一份 `deferred-work.md`——后者是这个项目自己加的中间层，所以处理流程也得自己定义。
- 5/44 = 11% 的 manual resolution rate 说明现有约定不够强；有提示但缺少"引导 dev agent 回头看"的钩子。

**为什么插在 stage ② 而不是 stage ①**：
- create-story（stage ①）的输入是 PRD / epics / 上游 story md（依赖关系），不读 deferred-work；让它读会引导 spec 偏移（spec 阶段 LLM 决策粒度太细，deferred 信息没法被它"用"）。
- dev（stage ②）才是 implementation 决策发生的地方——读 deferred-work 是顺水推舟（dev agent 已经在写 deferred 条目了，扫一眼现有条目零额外成本）。

**为什么是软提示、不卡 commit**：
- 强制"必须 resolve 列表全部"会引发 scope creep（dev agent 把 N 条 deferred 一起塞进单 story，违反 single-story 原则）；
- 强制"必须明确跳过"会逼 dev agent 写大量"why skipped"理由（即便绝大多数 skip 都是"显然不在本 story scope"的废话）；
- 软提示让 dev agent 用 answer-policy 的"够用就好"原则自决——代价是没法 100% 命中，但 inline-resolution rate 应能从 11% 显著上升。

**改了什么**（A → C）：

**A. `harness-prompt-suffix.py` 加 `DEFERRED_SCAN_BLOCK`，仅 stage 2 输出**

- 新增常量 `DEFERRED_SCAN_BLOCK`（~30 行 Markdown）+ 集合 `DEFERRED_SCAN_STAGES = {"2"}`。`main()` 在 stage 2 时把它插到 RESUME_BLOCK 和 ANSWER_POLICY_BLOCK 之间，三段用 `---` 分隔。stage 1/3/4/5/6 输出无变化。
- 块内容核心：
  - 写入约定用**短格式** `Story <epic>.<seq>`（如 `Story 1.7`）—— 与 deferred-work.md 既有条目（`Resolved by Story 1.5` / `Partial resolution by Story 1.7`）格式对齐，便于趋势统计 grep。
  - 三态决策：**resolve**（自然 scope 内顺手解决+追加 `Resolved by Story <短>` 标记）/ **partial**（只能 close 一部分+追加 `Partial resolution by Story <短>`）/ **跳过**（不动条目，不写理由）。
  - 禁止：scope creep / 改写已有条目内容 / 写"假性 resolved"。

**B. `run-sprint.md` §1 阶段 ② 顶部 reference 段加一行说明**

- 指向新的 prompt suffix 块 + 强调"软提示，无结构化校验"。让人回头看协议时不会困惑这一段是从哪冒出来的。

**C. `run-sprint.md` §1 阶段 ⑤ commit 后加 deferred-trend 输出 Bash**

- commit row 5 + done tag 之后跑：
  ```bash
  DW=_bmad-output/implementation-artifacts/deferred-work.md
  SHORT=$(echo "$KEY" | awk -F- '{print $1"."$2}')
  CLOSED_THIS=$(grep -cE "Resolved by Story $SHORT|Partial resolution by Story $SHORT" "$DW")
  TOTAL_RESOLVED=$(grep -cE "Resolved by Story|Partial resolution by Story" "$DW")
  TOTAL_ITEMS=$(grep -cE "^- \*\*" "$DW")
  echo "deferred-work: 本 story（$SHORT）关闭/部分关闭 $CLOSED_THIS 条；deferred-work.md 累计 resolved $TOTAL_RESOLVED / $TOTAL_ITEMS 条"
  ```
- 注意 `grep -c` 退出码非零仍会 stdout `0`，**不能**加 `|| echo 0`（双输出 bug，初稿踩坑）。
- 不命中阈值、不 halt——纯趋势可视，让用户对 deferred 累积速率有感。

**实测**（用历史 story `1-7-proxy-fork-addon-framework-unix-socket`）：
- `SHORT=1.7`
- `CLOSED_THIS=1`（FU-1.1.E **proxy 端**已 partial resolved by 1.7）
- `TOTAL_RESOLVED=3` / `TOTAL_ITEMS=45`（11% rate；预期未来逐步上升）
- prompt-suffix stage 2 输出 3 段（resume + deferred-scan + answer-policy），分隔符 `---` × 2 ✅；stage 4 输出 2 段 ✅；stage 1 输出 1 段（仅 answer-policy）✅。

**与 §J/§K 的关系**：§J/§K 都是减法（删 PROJECT_CODE 白名单 / 删过度防御 halt）；§L 是少有的**加**——但加的是软提示 + grep 可视化，没有新的硬规则、没有新的 halt、没有结构化校验。一致原则："让主 agent 在常规路径上能跑完整条 story 而不打扰用户"，§L 是顺手再多关掉几条 deferred。

**对未来流水线的影响**：

- ✅ stage ② dev agent 会主动扫 deferred-work，命中本 story 短格式的条目自然处理；inline-resolution rate 应从 11% 上升。
- ✅ 用户在 stage ⑤ 完成后看到一行趋势，对 deferred backlog 的累积速率 / 关闭速率有可视感。
- ✅ 短格式 `Story 1.7` 与 deferred-work.md 既有 5 条 resolved 标记的格式一致——历史与新写入条目共享统计 pipeline，零迁移。
- ⚠️ 软提示不可观测：dev agent 偷懒"扫了但没 resolve 任何"无法被结构化层抓到。如果未来发现 inline-resolution rate 反而不上升，可以加 stage ⑤ 的"本 story 改了的源码路径 vs deferred-work.md 命中条目所引用路径"交叉检查（heavy 启发式，慎做）。
- ⚠️ epic 级 deferred（`Story 1.x` 这种泛指）无法被精确匹配；这一类条目通常需要人工重读决策。短格式约定不解决这个，但也不引入新坑。
- ⚠️ TOTAL_ITEMS 统计基于 `^- \*\*` pattern。如果未来有人改 deferred-work.md 条目格式（比如改成 `* **...`），统计会失真——pattern 是保守的，按现有所有条目实测 45 条，肉眼对照符合预期。

---

## 2026-05-01 — §K: 主 agent 自决取消不必要的 halt（接近全自动化）

**触发场景**：用户回看 §J 后给出方向："harness 自动化要接近完全自动化，不必要的、你能做出最佳决策的 halt 全部取消"。逐条审视 §3 防护表的 halt 条件，识别哪些其实是主 agent 能直接自决的、把它们改写为自决路径。

**审视原则**：
- **保留 halt** 的：(a) 真正的安全门（黑名单 / 跨 story 隔离 / FORBIDDEN / UNSTAGED）；(b) schema gate 失败（dev-result.json / review-findings.json）；(c) Status 不是 done（review 真出了 critical）；(d) 配额耗尽（runtime 信号）；(e) 预期产物缺失（重试代价高）；(f) runaway 防护（>6 子 agent / 第二次 review-fix 循环）；(g) 同 subagent 连续 2 次发问（异常 prompt 行为）。
- **改自决** 的：(1) 启动时 dirty worktree；(2) start tag 已存在但未传 `--continue`；(3) stage2-base tag 缺失；(4) 广义错误词文本扫描 false positive 高；(5) retro 状态推进 halt（兜底 set 已无条件跑）。

**改了什么**（A → F 一刀整理）：

**A. §0.A 启动 dirty worktree → 自动切续作（不 halt）**
- `.claude/commands/run-sprint.md` §0.A：worktree 不为空时**不再 halt**。改为：调 `python3 .claude/scripts/sprint-status.py find-by-status review` 找最近 review 状态的 story；找到就切 §0.B 续作流程；找不到才 halt（说明 worktree 有未知工作）。
- §3 表里"0.A 模式 worktree 不为空 → halt"行收紧条件：仅在 `find-by-status review` 也找不到时才 halt。

**B. start tag 已存在但未 `--continue` → 主 agent 自决切续作**
- `.claude/commands/run-sprint.md` §1 阶段 ①：start tag 已存在不再 halt。主 agent 调 `harness-state.py $KEY` 拿状态 JSON，按 `next_action_code` 自动切到对应阶段（`stage1/2/3/4/5/tag-only/blocked-dirty`）。**仅** `next_action_code == "done"` halt（story 早已完成）。
- §3 表删除"同 key start tag 已存在 + 未传 --continue → halt"行（条件已无意义）。

**C. stage2-base tag 缺失 → 主 agent 自动补打（不 halt）**
- `.claude/commands/run-sprint.md` §1 阶段 ②：把 `STAGE2_BASE=$(git rev-parse harness/$KEY/stage2-base)` 改成"先调 `harness-state.py` 拿 `stage2_base_sha` 字段（脚本已经 fallback 到 stage1 commit subject 匹配），tag 不存在时主 agent 自动 `git tag harness/$KEY/stage2-base $STAGE2_BASE`"。
- 阶段 ③/⑤ 引用同一流程（"用阶段 ② 介绍的 `harness-state.py + 自动补 tag` 流程"），不再各自手 `git rev-parse <tag>`。
- §3 表删除"stage ① commit 后 stage2-base tag 没打 → halt"行。

**D. 广义错误词文本扫描 → 删（信任结构化校验）**
- `.claude/commands/run-sprint.md` §-1.b 步骤 (a)：原版要扫子 agent 返回里的 `error` / `failed` / `halted` / `cannot` / `无法`，false positive 高（"我加了 error handling"等正常完成描述全命中），且**真正的失败一定能被结构化校验抓到**：产物缺失 → 验收 halt；schema 不合规 → `harness-commit.py` 退出码 1；漏 stage 推进 → sprint-status 兜底 set 暴露不一致；patch 没改对 → 下一轮 review 发现。删掉广义文本扫描。
- 例外保留：`hit your limit` / `rate limit` / `usage limit` / `quota` / `reset` 这一类 runtime quota 信号在结构化层不可见，仍要扫文本（halt 模板选项 5）。
- §3 表第 1 行"广义错误词信号 → halt"删除；保留配额耗尽这一行。

**E. stage ⑥ retro 状态推进 halt → 删（兜底 set 已无条件跑）**
- `.claude/commands/run-sprint.md` §1 阶段 ⑥ 已经包含**无条件**的 `python3 .claude/scripts/sprint-status.py set epic-${EPIC}-retrospective done`，所以 §3 表"retro 状态没推进 → halt"行从未实际触发过——纯粹是早期防御性留白。删除。

**F. 顺手修：`sprint-status.py` 缺 `find-by-status` 子命令（doc bug）**
- 原 §0.B 写"调 `python3 .claude/scripts/sprint-status.py status-of-status review`"，但该子命令不存在（`sprint-status.py` 只有 `next/count/status/set/epic-of/epic-all-done/epic-retro-status`）。续作流程从未真正运行过这一行——一直靠主 agent 自由判断 `<KEY>`。
- 加 `cmd_find_by_status(state)`：按 yaml 出现顺序输出最后一条匹配 `<state>` 的 story key（"最近推进到该状态的 story"），找不到退出码 1。doc 同步加段。
- `run-sprint.md` §0.B 第 1 步把"`status-of-status review`"改成"`find-by-status review`"。
- 新 §0.A auto-pivot 也用这条命令。

**实测**：跑 `python3 .claude/scripts/sprint-status.py find-by-status done` → 输出 `1-7-proxy-fork-addon-framework-unix-socket`（最后一条 done story）；跑 `find-by-status review` → 退出码 1（当前无 review 状态 story）。

**与 §J 的关系**：§J 删 PROJECT_CODE 白名单，本质是"删一层从未真正改变过决策的标记机制"；§K 是同一思路的延续——删一批"主 agent 实际能自决而被规则绑死"的 halt。两者合起来，主 agent 在常规路径上能跑完整条 story 而不打扰用户。

**与 §-1.b 失败防护的关系**：§-1.b 的核心仍然是"信任结构化校验"。本次只是把曾经叠在结构化校验之上的"防御性文本扫描"层撤掉——结构化层（产物 / schema / commit 脚本退出码）一直在跑，它们的 halt 触发器没有任何变化。

**新一代 halt 类条件**（§3 防护表精简后）：
1. 配额耗尽（runtime quota 信号）
2. 预期产物缺失/为空（每阶段验收）
3. `harness-commit.py` 退出码 1（黑名单 / 跨 story / 预期外 artifact / FORBIDDEN / UNSTAGED）
4. dev-result.json schema 失败（DEV_RESULT_*）
5. review-findings.json schema 失败（REVIEW_FINDINGS_*）
6. stage ⑤ 完成后 Status 不是 done
7. stage ② → ④ 之间产物被改回（status 回到 in-progress）
8. >6 子 agent 调用（runaway 防护）
9. 第二次进入 review-fix 循环
10. 0.A 启动 worktree 不为空 **且** 无 review 状态 story 可续作
11. 同一 subagent 连续 2 次发问

**对未来流水线的影响**：

- ✅ 启动时 dirty worktree 不再粗暴 halt——主 agent 能自动找回中断的 story 续作。
- ✅ 重启 / `--continue` 模式 doc bug（`status-of-status` 不存在）修复，续作路径真的能跑通。
- ✅ stage2-base tag 缺失从 halt 改自决——`harness-state.py` 已经 fallback 了 SHA 来源，tag 缺失时主 agent 自动补打。
- ✅ 删掉广义错误词扫描，子 agent 写"我加了 error handling"等正常描述不再触发误 halt。
- ✅ retro halt 删掉，§3 防护表少一条永远不触发的纸面规则。
- ⚠️ 结构化校验是新的最后一道防线——如果未来 schema gate / commit 脚本本身有 bug，错误会"放过"（之前广义文本扫描偶尔能补漏）。但实测中文本扫描的 true positive 几乎为零，这个交易是赚的。
- ⚠️ `find-by-status review` 在多 story 同时 review 状态时只返回"最后一条"——单 track sprint 一般同时只有 1 条 review，多条会出现的话主 agent 拿到的可能不是想要的那条。极端场景预期不会出现；如出现则用户用 `--story <key>` 显式指定。

---

## 2026-05-01 — §J: 删 PROJECT_CODE 白名单机制 + build-artifact 自动剔除 + stage ③ 路径预解析

**触发场景**：跑 `1-7-proxy-fork-addon-framework-unix-socket` 流水线 stage ④ 时，dev sub-agent 跑 `go build` 把 21MB 的 `aegis-api` Mach-O 二进制留在 repo 根。脚本输出 `STATUS=ok` + `PROJECT_CODE=aegis-api`，但主 agent 看到 21MB 二进制选择 halt 让用户决策（不愿写进 git 历史，那是不可逆膨胀）。

用户的反思：白名单驱动的设计本质上有点"打补丁"味道——每出新场景就要打白名单，halt 太频繁。建议简化。

**痛点 + 思考**：

1. **白名单 miss 本身不导致 halt**——它只决定主 agent 要不要在 commit message 列 "Unexpected paths:" 段（标记本身从来没改变过任何 commit 决策，只是噪音）。
2. **真正的安全门**：BLACKLIST_PATTERNS（凭据 / `.claude/**` / `_bmad/**`）+ cross-story 隔离 + schema gate + unexpected_artifact——这些与"PROJECT_CODE"机制完全正交。
3. **本次 halt 的真因**是主 agent 在没明确危险信号时过度保守（21MB 二进制 build 残留 = 路径模式足够明确，应该自决），不是白名单 miss。

**改了什么**（一刀两段）：

**A. 删掉整个 PROJECT_CODE / 白名单机制（§J 主刀）**
- 删除 `.claude/harness-allowed-paths.txt`
- `.claude/scripts/harness-commit.py`：
  - 删 `ALLOWED_PATHS_FILE` / `_allowed_patterns_cache` / `load_allowed_patterns()` / `matches_allowed()`（约 30 行）
  - `classify()` 返回值 `'project_allowed' | 'project_flagged'` 合并为 `'project'`
  - `main()` 不再 emit `PROJECT_CODE=<path>` 行
  - 文档头部输出说明同步更新
- `.claude/commands/run-sprint.md`：
  - §−1.d step 4 删"项目代码白名单"段、补"项目代码处理：脚本一律放行 stage"段
  - §0.5 删"白名单 + 标记"三段式说明、补 halt 类条件清单

**B. Build-artifact 自动剔除（消除本次 halt 类）**
- `.claude/scripts/harness-commit.py` 新增 `detect_build_artifacts(paths)` + `auto_resolve_build_artifact(path)`
- 检测条件 all-AND（避免误伤）：
  - status xy 是 `??` 或 `A` 开头（untracked / 新增 staged，从不动 modify）
  - 路径在 repo 根（无 `/`）
  - 名字匹配 `^[a-z][a-z0-9-]+$`（典型 Go cmd binary 命名，无扩展名）
  - 文件 executable bit 置位
  - 文件大小 > 1 MB
  - git 视为 binary（`git diff --no-index --numstat /dev/null <p>` 输出 `-\t-\t`）
- 触发后自动：①`git restore --staged --` ②`os.remove()` ③把 `/<path>` 加到 `.gitignore`（anchored，root-only，不影响子目录同名文件）④`git add -- .gitignore` ⑤emit `AUTO_FIXED=binary-blob <path> action=unstaged+rm+gitignored size=<N>MB`
- 仅在 `project_code: True` 的 stage（2/4/5）启用。

**C. stage ③ 主 agent 预解析 codex companion 路径**
- `.claude/commands/run-sprint.md` §1 阶段 ③：把 `<CODEX_COMPANION_PATH>` 提升为占位符，与 `<STAGE2_BASE>` 同等地位，由主 agent 调度前用 Bash 预解析：
  ```bash
  CODEX_COMPANION_PATH="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/codex-companion.mjs}"
  [ -z "$CODEX_COMPANION_PATH" ] || [ ! -f "$CODEX_COMPANION_PATH" ] && \
    CODEX_COMPANION_PATH=$(ls ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)
  ```
- prompt 模板里的命令直接拿 `<CODEX_COMPANION_PATH>` 替换，sub-agent 不再摸索 env var（spawn 的 sub-agent 子进程不一定继承）。

**与 §B 的关系**：§J 撤销了 §B（"项目代码白名单"机制）。§B 当时的目标是消除 commit message 里的 "Unexpected paths:" 段噪音——但更干净的做法是直接删掉这层标记机制，而不是配置一份永远在增长的白名单。

**不影响**：
- BLACKLIST_PATTERNS 不变（凭据 / `.claude/**` 子集 / `_bmad/**` 等仍 halt）
- cross-story 隔离不变
- schema gate（dev-result.json / review-findings.json）不变
- stage ①/③/`5-fallback`/⑥/`6-done` 仍拒绝项目代码（与 stage 配置 `project_code: False` 一致）
- `harness-prompt-suffix.py` / `sprint-status.py` / `harness-state.py` 接口不变

**影响**：
- ✅ 本次 halt 类（21MB build artifact）不再发生：harness 自决处理（unstage + rm + gitignore）。
- ✅ "动不动加白名单"的维护工作消失。`harness-allowed-paths.txt` 文件已删除，`.claude/scripts/harness-commit.py` 删 ~30 行。
- ✅ commit message 不再有 "Unexpected paths:" 段——主 agent 写 commit 时少一层心智负担。
- ✅ stage ③ sub-agent 不再摸索 codex-companion.mjs 路径。
- ⚠️ 失去了"非典型路径出现时的轻量审计提示"——但实际审计价值低（commit message 里列一堆路径没人会真去逐一审）。如果未来出现"sub-agent 把代码写到了不该写的位置"的事故，再考虑用 git path-pattern 加专门的 halt 触发器，而不是恢复白名单。
- ⚠️ Build-artifact auto-fix 是有写盘副作用的——但触发条件极窄（root + 全小写 + 无扩展名 + executable + ≥1MB + 二进制），实际只命中 Go cmd binary。误伤风险评估：(a) PNG 图标 < 1 MB；(b) ML 模型在子目录；(c) 字体文件通常有扩展名。

**回归测试**：在隔离 git repo 用 `dd if=/dev/urandom of=fake-binary bs=1M count=2; chmod +x fake-binary` + 一个不在原白名单里的路径 `random/sub/go.mod`，运行 `harness-commit.py 2 test-1` 输出：
- `STATUS=ok`
- `AUTO_FIXED=binary-blob fake-binary action=unstaged+rm+gitignored size=2.1MB`
- `STAGED=random/sub/go.mod`（之前会被打 PROJECT_CODE，现在直接 STAGED）
- 没有 PROJECT_CODE / Unexpected paths 字段

`fake-binary` 已删除，`.gitignore` 已 append `/fake-binary`。

---

## 2026-05-01 — stage2-base 不再前推 + stage ⑤ review 用 pathspec 排除 harness 路径 + stage ⑥ deferred-work.md 加白名单

**触发场景**：`1-5-console-web-scaffold-design-tokens-i18n-shadcn` 流水线中 stage ④ 因 dev fix subagent 把 deferred follow-up 写到 `deferred-work.md` 而 halt（`UNEXPECTED_ARTIFACT`）。修补 stage ④ 白名单后回看，发现两个更严重的 latent bug：

1. **stage2-base tag 前推会塌掉 stage ⑤ bmad review 覆盖率**（高危静默失败）
   - 这一 story 因 stage ④ halt → harness 元修改 → 续作，期间插入了一条 `harness:` commit。按当时 `run-sprint.md` §1 阶段 ②"边界情况"指令，主 agent 把 `harness/<KEY>/stage2-base` tag 前推到该 harness commit。
   - 后果：stage ⑤ bmad review 用 `<stage2-base>..HEAD` 作为 base，其中 stage ② 的 76 文件 / 9640 行（整个 console-web scaffold 主体）被排除出 review window。bmad 实际只看到 290 / 9941 行 = **2.9% 覆盖率**——但流水线伪通过、status 推进到 done、commit 上链。
   - 静默失败比 halt 严重得多：halt 会让人介入，伪通过会让缺陷上链。

2. **stage ⑥ retro 也可能写 `deferred-work.md` 但 stage 6 spec 不允许**（风险预防）
   - retro 工作流让 LLM 把 epic 级别 action item / 延后项写进 retro 文档；在已有 deferred-work.md 索引的项目，LLM 顺手 append 是合理推断。stage 6 spec 之前不在白名单，等下次 epic 收尾才会撞 halt。

**改了什么**：

A. `.claude/scripts/harness-commit.py`：
- `STAGES["4"]["global_files"]: [] → ["deferred-work.md"]`（与 stage 2/5 一致；stage ④ prompt 明确允许 deferred 决策建立 follow-up note）。
- `STAGES["6"]["global_files"]: [...] + "deferred-work.md"`（retro 期间发现的 epic 级延后项）。

B. `.claude/commands/run-sprint.md`：
- §1 阶段 ②"边界情况"段重写：**禁止**前推 stage2-base tag；改为让 tag 留在原位 + review prompt 用 `git diff <base>..HEAD -- . ':!.claude'` pathspec 把 harness 改动从 review diff 里排除。说明前推为什么坏（含本次 2.9% 覆盖率事故的具体数字）。
- §1 阶段 ⑤ bmad review prompt：`git diff <STAGE2_BASE>..HEAD` → `git diff <STAGE2_BASE>..HEAD -- . ':!.claude'`，且 prompt 内追加一段说明"为什么不前推 tag、用 pathspec 替代"。
- §1 阶段 ⑤ STAGE2_BASE 准备行：去掉"如有元修改 commit 插入则前推 tag"的旧引用。
- §0.5 表 stage 6 行：预期产出加上 `deferred-work.md`。

**stage ③ codex 维持现状**：codex companion 只支持 `--base/--scope`，不支持 pathspec。stage ② → ③ 之间出现 harness commit 的窗口很窄（实测 < 5%），且 codex review-only 不会基于看到的内容写代码——容忍噪声。

**第 3 点（stage prompt 与 commit spec 漂移自动同步）评估**：**不做**。理由：(1) 历史上仅发生 1 次（本轮），base rate 不足以支持抽象；(2) `harness-prompt-suffix.py` 要 parse 另一脚本的 STAGES 字典，强行耦合两份独立职责；(3) 把"允许写哪些路径"明文给子 agent 反而可能引导子 agent 偷懒（应写 deferred-work.md 的改塞进 story md）；(4) 真因不是机械漂移，是 stage ④ spec 设计时漏一种合法落点（已修对）；(5) `UNEXPECTED_ARTIFACT=` halt 信号 + halt 模板已经能让人秒级定位、< 1 分钟修复。重新评估的触发：同类漂移再发 2 次 / 出现"漂移让流水线伪通过"的 silent failure。

**对未来流水线的影响**：

- ✅ stage ⑤ bmad review 覆盖率永远等于 stage ② 引入的全部代码（不会再被 harness commit 截断）。
- ✅ stage ⑥ retro 不会再因为 LLM 顺手 append `deferred-work.md` 而 halt。
- ⚠️ stage ⑤ review prompt 现在依赖 git pathspec `:!.claude`——如果未来引入 `.claude/` 之外的 harness 路径（比如 `harness-tooling/`），需要更新 pathspec。
- ⚠️ 历史上已经用前推 tag 跑过的 story（即 stage2-base 已经移过位的）的 bmad review 覆盖率仍然不足；理论上需要重 review，但实操不强制——下次该 story 触发 review 时人工抽检即可。

---

## 2026-05-01 — Stage ③ prompt 直接给 codex 兜底命令 + prompt-suffix 按 stage 只输出本阶段进度约定

**触发场景**：`1-4-opensearch-ilm-minio-buckets` 流水线收尾时回顾发现两个低 ROI 摩擦：
1. stage ③ codex review 子 agent 必须摸索"`/codex:adversarial-review` Skill 调不动 → 用 node 命令兜底"。本轮子 agent 摸索成功，但每次新 agent 都要重摸一次，浪费时间且有失败风险。
2. `harness-prompt-suffix.py` 给 stage 2/4/5 的子 agent 输出**全部 3 段**断点续作约定（stage 2 + 4 + 5），子 agent 拿到一堆和自己阶段无关的进度源信息。

**改了什么**：

A. `.claude/scripts/harness-prompt-suffix.py`：
- 把 `RESUME_BLOCK` 拆成 `RESUME_PROGRESS_LINES = {"2": ..., "4": ..., "5": ...}` 和 `resume_block(stage)` 函数。
- 每个 stage 的进度源行从"- **stage X**: ..."改成"- **本阶段**: ..."——子 agent 视角更直接。
- stage 1 / 3 / 6 输出无变化（仍只贴 answer-policy）。

B. `.claude/commands/run-sprint.md` §1 阶段 ③：
- 顶部说明段加一句：`/codex:adversarial-review` 是 `disable-model-invocation: true`，Skill tool 调不动，直接给底层命令。
- prompt 模板第 1 步改成"不要试 Skill tool；直接 Bash 跑 `node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs" adversarial-review --wait --base <STAGE2_BASE> "review focus: ..."`"，把 review focus 文本作为命令尾部 free-text 参数传入。

**不影响**：
- `harness-commit.py` 行为完全不变（只动 prompt-suffix 和 manual）。
- 主 agent 调用 `harness-prompt-suffix.py <stage>` 的接口不变（只是输出更短）。
- stage ②/④/⑤ 子 agent 实际进度行为不变——只是看到的 prompt 少了 2 段无关信息。

**影响**：
- stage ③ 子 agent 不再需要"摸索"路径——开局就跑 node 命令。这把"每次新 agent 摸索一次"的失败风险消掉了（如果某次摸索失败就 halt）。
- stage 2/4/5 prompt 大约省 200~400 token，多次跑能积累。
- 子 agent 不被无关进度源干扰（stage ② dev agent 不需要知道 stage ⑤ 的 review-progress.json schema）。

---

## 2026-05-01 — Stage ② 允许写 `deferred-work.md`

**触发场景**：跑 `1-4-opensearch-ilm-minio-buckets` 的 stage ②（dev 实现）时，dev agent 在沙箱里没法跑 docker / 完整 stack 冒烟，按既有 FU-1.4.A 模式把"沙箱延后到 CI / 后续 story"的项目登记到 `deferred-work.md`。结果 `harness-commit.py 2` 退出码 1，因为 §0.5 旧规则只允许 stage ⑤ 写 `deferred-work.md`。

**痛点**：dev 阶段在沙箱里发现"这部分要 follow-up"是常态（缺工具、缺真实环境、跨 story 才能完成的子任务）。让 dev 当场登记 follow-up 比强制憋到 stage ⑤ 由 review agent 转登记更准确——dev 自己最清楚为什么 deferred、哪些 AC 受影响、对应哪个测试用例。

**改了什么**：
- `.claude/scripts/harness-commit.py` STAGE_SPEC["2"]["global_files"] 增加 `"deferred-work.md"`
- `.claude/commands/run-sprint.md` §0.5 stage ② 行注明允许 `deferred-work.md`

**不影响**：跨 story 隔离规则未变（line 440 已经把 `deferred-work.md` 列为全局允许文件）。stage ⑤ 仍允许写。stage ①/③/④/⑥ 仍拒绝。

**影响**：dev agent 阶段遇到"这块要 follow-up"可以直接登记到 `deferred-work.md`，不必 hack 到 story md 里某个 dev notes 段再让 review agent 搬家。

---

## 2026-05-01 — Stage ④ freelance 是有意设计（design rationale，非代码改动）

**触发场景**：用户在审视各 stage 是否都走 BMad 工作流时发现 stage ④ 是 freelance（不调任何 skill），怀疑是个一致性漏洞。

**结论：stage ④ freelance 是对的，不要"修"**。

**rationale**（用户的判断）：stage ④ 本质是 **stage ② 的延续**——codex review 列出的每条 finding 都是"stage ② 没做好或漏掉的部分"，stage ④ 就是把这些缺口补上。和"重新启动一个独立工种"不一样。

**为什么没有契合的 BMad skill**：
- `/bmad-dev-story` 状态机是"in-progress → review"，没有"已 review 后修反馈"的状态；强行调用打乱状态机。
- `/bmad-quick-dev` 是为"按用户意图实现新东西"设计，不是为"按对抗式 review 反馈修旧东西"设计，语义错位。
- 没有契合的现成工作流 → 直接 freelance + 用 prompt + 断点续作约定（story md `### Codex Review Handling (Stage 3)` 段每条一行）约束行为。这与 stage ②/⑤ 走 skill 工作流并不矛盾——后者是有清晰流程的独立工种，前者是"延续上一轮工作"。

**改了什么**：仅文档——`run-sprint.md` §1 阶段 ④ 顶部加一段 rationale 注释，明确"本阶段不走 BMad 工作流是有意设计，不是漏洞"。代码无改动。

**影响**：后人（包括未来的 Claude）回头审视时不会再把 stage ④ freelance 当作不一致漏洞去"修"。如果未来真出现一个契合"按 review 反馈修代码"的 BMad skill，再来重新评估。

---

## 2026-05-01 — 7 optimizations from `1-3-postgresql-baseline-schema` runtime feedback

**触发场景**：续作 `--one 继续完成当前这个story` 时，dev agent 把 `dev-result.json.checks_skipped` 写成 `["lint_passed: golangci-lint binary not installed..."]` 长字符串而不是纯 key 数组，导致主 agent 后置 python 校验 halt + 用户介入。同时暴露：续作模式没建模、STAGE2_BASE 跨会话靠运气、stage ④ SendMessage 跨会话必废、commit message 要手贴 N 个 PROJECT_CODE 路径。

### A. 新建 `.claude/harness-changelog.md`
- 文件：本文件
- 为什么：之前对 harness 的优化散落在 commit message 和 retrospective 文件里，没有单一的"对照表"。下次想知道"为什么 X 是这样设计的"必须翻多个 commit。
- 影响：以后所有 harness 元修改在这里留一笔，跨会话可追溯。

### B. 项目代码白名单 — `harness-allowed-paths.txt`
- 文件：新增 `.claude/harness-allowed-paths.txt`，改 `.claude/scripts/harness-commit.py`
- 痛点：stage ②/④/⑤ 的项目代码被脚本统一打 `PROJECT_CODE=` 标记，主 agent 必须把它们全部列进 commit message 的 "Unexpected paths:" 段（本次 stage ② 33 个、stage ④ 13 个，纯复制粘贴）。这些路径本来就是预期的项目代码，标记本身就是噪音。
- 改了什么：新增 `.claude/harness-allowed-paths.txt`（纯文本，`#` 注释 + 一行一 pattern，零依赖）配置项目源码 / 文档 / 配置等的允许前缀（`console-api/**`、`docs/**`、`.github/workflows/**`、`Justfile`、…）。`harness-commit.py` 加载它，命中前缀的不再打 `PROJECT_CODE=`，落在白名单外的才标记。
- 影响：stage ②/④/⑤ commit message 不再需要手贴路径数组。落在白名单外的真"超预期"路径仍然标记 + 留痕。

### C. `dev-result.json` schema 自带校验
- 文件：改 `.claude/scripts/harness-commit.py`（stage 2 分支）
- 痛点：dev agent 写 `checks_skipped: ["lint_passed: 原因..."]` 是按 prompt 字面理解，但校验脚本用 `k not in sk` 字面值匹配 key，导致格式问题被当 halt。完成门校验放在主 agent prompt 而不是脚本里，跨会话 / 子 agent 角色变更时容易漏跑。
- 改了什么：`harness-commit.py` 在 stage 2 path 自带 dev-result.json schema 校验：①JSON 解析失败 → halt；②`checks` 字段三态化（pass / fail / skip），fail 直接 halt（与 checks_skipped 列表的奇怪交互彻底消除）；③`final_story_status` 必须等于 story md Status 段字面值，否则 halt。同时在 stage 5 path 自带 review-findings.json schema 校验（`unresolved.critical+high+medium == 0` + `final_story_status` 一致性）。
- 影响：消灭"格式问题被当 halt"的整类事故。dev / review agent 写错 schema 时脚本直接给出可读诊断，不再需要主 agent 后置 python 一行兜底。

### D. STAGE2_BASE / done tag 自动化
- 文件：改 `.claude/scripts/harness-commit.py`
- 痛点：`STAGE2_BASE` 是 stage ② 进入前算的会话内变量，跨会话续作时主 agent 只能从 git log 倒推。本次能续作纯属运气——stage ① commit 是 `cbcd18a`、message 一望可识别。换个更糟的中断点没法可靠重建。
- 改了什么：`harness-commit.py` 在 stage 1 commit 路径完成后自动 `git tag harness/$KEY/stage2-base HEAD`（指向 stage ① commit，即 stage ② 的 review base）；在 stage 5 commit 路径完成后自动 `git tag harness/$KEY/done HEAD`。主 agent 不再手工打 tag。
- 影响：stage ③/⑤ 的 review base 永远从 `git rev-parse harness/$KEY/stage2-base` 读，跨会话续作零推理。`harness/$KEY/done` 仍然作为 story 完成的可视游标。

### E. `harness-state.py` — 单一状态查询
- 文件：新增 `.claude/scripts/harness-state.py`
- 痛点：续作时主 agent 要并行查 sprint-status + git tags + dev-result.json + git log 倒推阶段，每次推理都是 fragile 的判断。
- 改了什么：`python3 .claude/scripts/harness-state.py <KEY>` 输出 JSON：`{"key", "story_status", "stage2_base", "stage1_committed", "stage2_committed", "stage3_committed", "stage4_committed", "stage5_committed", "done_tag_exists", "next_action"}`。基于 git tags + git log + sprint-status.yaml + 各 progress JSON 综合判断。
- 影响：续作时主 agent 调一次脚本就知道从哪 stage 切入，不再 fragile。

### F. `harness-prompt-suffix.py` — 统一 prompt 后缀
- 文件：新增 `.claude/scripts/harness-prompt-suffix.py`
- 痛点：每个 stage 子 agent prompt 末尾的"§1.x 断点续作约定 + §−1.b 代答政策附带段"靠主 agent 手贴。一处漏了行为就走偏，本次 5 段 prompt 都需要逐字粘贴。
- 改了什么：`python3 .claude/scripts/harness-prompt-suffix.py <stage>` 输出统一后缀文本（包括代答政策附带段；stage 2/4/5 还包括断点续作约定）。主 agent 写 prompt 时只关心核心指令，结尾用 Bash 输出拼接。
- 影响：主 agent 漏粘风险归零。后续若要调整代答政策 / 断点续作约定，只改一处脚本，不需改 5 段 prompt 描述。

### G. `--continue` 模式 + stage ④ fresh agent + `STAGE2_BASE` from tag + §3 表更新
- 文件：改 `.claude/commands/run-sprint.md`
- 痛点四项：①§0.2 要求 worktree 干净，但续作模式合法用法是 worktree 不干净（dev 中段中断），导致协议自相矛盾，本次靠主 agent 自由判断违规放行。②stage ④ 协议要求 SendMessage 用 stage ② dev agentId 续作，但 agentId 跨会话失效，本次 spawn fresh 是"协议外"操作。③`STAGE2_BASE` 从 git rev-parse HEAD 取的会话内变量，续作就丢。④§3 防护表没覆盖 dev-result.json schema fail / review-findings.json schema fail / git tag 缺失等新引入的硬错误。
- 改了什么：①新增 `--continue` 显式分支，跳过 §0.2 干净 check，先调 `harness-state.py` 决定从哪 stage 切入。②stage ④ 文档统一改为"spawn fresh general-purpose agent，让它读 story md / codex review / 代码续作"，删除 SendMessage 跨会话 agentId 的设计假设。③stage ③/⑤ 的 `STAGE2_BASE` 改为从 `git rev-parse harness/$KEY/stage2-base` 读，由 stage 1 commit 时自动打 tag 提供。④§3 表新增条目：harness-state.py / dev-result.json / review-findings.json schema 校验 fail 都触发 halt。
- 影响：续作模式从"靠主 agent 自由判断"升级为"协议合规"。stage ④ 的"复用上下文"幻想清除（实测跨会话不可用）。`STAGE2_BASE` 来源单一可信。

### H. Single commit
- `harness: 7 optimizations from 1-3-postgresql-baseline-schema runtime feedback`
- 参照 `c544aeb` 的提交模式，所有 A-G 改动一次提交，commit message 引用本 changelog 段。
