# bmad-create-story prompt suffix（项目层）

> 由 epic-3 retro C2 (2026-05-04) 立。CLAUDE.md 严禁动 `.claude/skills/bmad-*/`
> 上游 SKILL —— 本文件作为项目层 prompt 拼接路径。
>
> **加载机制**：`run.md` 阶段 ① 的 create-story dispatch prompt **显式要求**
> spec 作者 subagent 先 Read 本文件，再按其中 deferred-work schema /
> cross-story artifacts / Finalize sub-steps 约束写 spec。本文件不靠
> skill 自动加载，也不靠主 agent 临场发挥——注入指令固化在 run.md 阶段 ①
> 的 dispatch prompt 模板里。
>
> 历史：
> - 2026-05-04 C2: spec 长度 hard 上限 800 + D-decisions extract 提议
>   finalize 子项。
> - 2026-05-04 C7: Epic 第一个 story 继承段约束（X-1-* 且 X > 1）。
> - 2026-05-04 deferred-work-schema-v1: spec 引入新 FU bullet 时按 schema v1
>   格式（详 §"deferred-work schema v1 写入约束"）。
> - 2026-05-08 cross-story-artifacts: spec 写入跨 story implementation
>   artifact 时必须声明 frontmatter 白名单 + 派给 dev agent 而非"主 agent"
>   （详 §"cross-story artifacts 声明约束"；触发场景：retro AI 收口 / 跨
>   story 引用状态翻转）。
> - 2026-06-12 planning-artifacts (issue #9, v0.1.39): spec 要求回写
>   `_bmad-output/planning-artifacts/*.md`（如 forward-only remediation 回写
>   epics.md）时必须声明 frontmatter `planning_artifacts:` 白名单（详
>   §"planning-artifacts 回写声明约束"）。

---

## deferred-work schema v1 写入约束

spec author 在 spec dev notes 内登记新 FU bullet（"deferred-work 登记预告" 段）
或更新 `_bmad-output/implementation-artifacts/deferred-work.md` 时**必须**按
schema v1 格式（权威：`.claude/harness/conventions/deferred-work-schema.md`）：

```markdown
- **FU-X.Y.Z** `[status:pending]` `[bucket:<B>]` `[target:<T>]` `[source:dev-of-X.Y]` — 一句话描述（≤120 字）
  - **修复方向**：...
  - **触发条件**：...（machine-checkable: Story X.Y / Epic N / customer-feedback / N/A）
  - **关联**：FU-A.B.C / ADR-N（多项 ` / ` 分隔；可省）
```

- 4 tag 头**必填**且顺序固定（`status` → `bucket` → `target` → `source`）
- bucket 8 值枚举：`epic-6` / `v0.2+` / `v1.0+` / `v2.0+` / `sandbox` / `cross-story` / `test-harness` / `other`
- status 7 值枚举：`pending` / `in-progress` / `partial` / `resolved` / `skipped` / `superseded` / `needs-review`（新条目默认 `pending`）
- **禁止**写 `FU-RETRO-*` 命名空间到 deferred-work.md（retro action items 100% 归 sprint-status `retro_action_items` 块）
- **禁止**用 inline 后缀 `— Resolved by Story X.Y (date): ...` 标记状态变迁（status 字段才是真值；变迁记入 `历史` audit log 子项）

详细变迁路径 + audit log 格式见 schema 文档 §3 / §2.2。

---

## cross-story artifacts 声明约束

某些 spec 需要让 dev agent 在 stage 2 修改**不属于本 story** 的
`_bmad-output/implementation-artifacts/*.md` 文件 —— 典型场景：retro action
item 收口（翻 epic-N-retro-*.md 表格行状态）、跨 story 引用文件状态翻转。
这类动作**必须**在 spec frontmatter 声明白名单，否则 stage 2 commit 时被
`harness-commit.py` cross-story isolation gate 阻断（权威实现：`scripts/
harness-commit.py` `cross_story_ok` / `read_cross_story_allowlist`）。

### 何时声明

spec body / Tasks / AC 要求 dev agent 写改下列任一文件时声明：

- 其它 story 的 spec md（如 `1-7-proxy-fork-addon-framework-unix-socket.md`）
- 跨 story 共享文件（如 `epic-N-retro-YYYY-MM-DD.md`、`spec-deferred-cleanup-*.md`）
- `chore-retro-c<epic>-*.md`（含只翻其状态行的场景——见下面契约说明）
- 任何 `_bmad-output/implementation-artifacts/` 下、basename 不是 `<本 story key>.*` 的 `.md`

> 默认已放行（不需要声明）：`<本 story key>.md` / `<本 story key>.dev-result.json`
> / `deferred-work.md` / `sprint-status.yaml`

> **chore-retro spec 契约**（harness-commit.py 真实行为，照做否则 halt）：
> `chore-retro-c<epic>-*.md` 仅在 stage ⑥.5（residue 流程，`chore_retro` flag
> 的 stage `6-5` / `retro-fulfill`）被无条件放行——该类文件由 stage ⑥.5 的
> residue 流程**创建并 commit**。**create-story 阶段不要创建该类文件**；
> story dev/fix 提交（stage 2/4/5）要写改既有 chore-retro spec（如翻状态行）
> 时，**必须**在 frontmatter `cross_story_artifacts` 声明该文件名，否则
> 撞 cross-story isolation gate halt。

### frontmatter 写法

spec 头部第一行必须是 `---`，frontmatter 内加 `cross_story_artifacts:` list：

```markdown
---
cross_story_artifacts:
  - epic-1-retro-2026-05-07.md
  - 1-7-proxy-fork-addon-framework-unix-socket.md
---

# Story X-Y-...
```

**约束**（违反则该条目被静默丢弃）：

- 每条必须是 bare basename（不能含 `/` 或 `..`）
- 必须 `.md` 结尾（`.json` / `.yaml` 是不同威胁面，不允许通过此白名单）
- 不能列本 story 自己的文件（已默认放行；列了是 smell）

## planning-artifacts 回写声明约束（issue #9，v0.1.39）

某些 spec（典型：retro 残余转化出的 forward-only remediation chore）显式要求
dev agent 回写 `_bmad-output/planning-artifacts/` 下的规划文档——比如把修正后
的 AC 文本 / drift-registry 表回写 `epics.md`（spec source of truth 本身就是
交付物）。这类路径默认命中 `harness-commit.py` 的 `OUT_OF_SCOPE_BMAD` halt
（issue #5 守卫），**必须**在 spec frontmatter 声明 `planning_artifacts:`
白名单才放行（权威实现：`scripts/harness-commit.py`
`read_planning_artifacts_allowlist`）。

### frontmatter 写法

与 `cross_story_artifacts:` 不同，本字段写**完整 repo-relative 路径**（不是
bare basename）——声明必须无歧义地指明回写的是哪棵树：

```markdown
---
status: ready-for-dev
planning_artifacts:
  - _bmad-output/planning-artifacts/epics.md
---
```

**约束**（违反则该条目被静默丢弃）：

- 必须位于 `_bmad-output/planning-artifacts/` 子树（brainstorming/ /
  research/ 等其它兄弟子树不在豁免范围，仍 halt）
- 必须 `.md` 结尾；禁 `..` / 绝对路径
- 仅声明 spec Tasks 真正要求的回写路径——不是给"顺手想改的规划文档"开后门

retro-fulfill 路径下（spec = `chore-retro-c<epic>-<code>-*.md`）该 frontmatter
同样生效——harness-commit.py 优先按 sprint-status.yaml 的 `chore_spec:` 字段
解析 chore spec，缺失时 code-first glob 兜底。

**适用范围**：白名单仅在允许 project code 的 stage（②/④/⑤/retro-fulfill）
生效；回写动作必须派给 dev/fulfill agent 在这些 stage 执行（stage ① 创建
spec 时不要顺手改 planning 文档——会命中 OUT_OF_SCOPE_BMAD halt）。

### 编排措辞：动作必须派给 dev agent，不是"主 agent"

spec Tasks / AC 提到 cross-story 文件修改时，**必须**派给 dev agent，**不要**写
"主 agent 在编排路径中 …"：

- ❌ "主 agent 在编排路径中翻 retro AI-3.3 状态 [resolved]" — run.md 5 阶段
  流水线没有"主 agent 自己改 implementation artifacts"的动作；dev agent
  看到 spec 任务会接手做，但若 frontmatter 没声明就撞 commit gate。
- ✓ "dev agent 在 stage 2 任务 T8.3 中翻 retro AI-3.3 状态 [resolved]
  （已在 frontmatter `cross_story_artifacts` 声明 epic-1-retro-2026-05-07.md）"

## Finalize sub-steps

spec 写完、返回主 agent 之前，spec 作者 subagent（即读到本文件的你）必须按
顺序运行以下脚本自检（这是 run.md 阶段 ① dispatch prompt 要求 Read 本文件
的目的之一）。**全程无人值守**：脚本报非零时按下述路径自动修正 + 重跑，
不要停下来等人确认。

### 1. spec 长度 lint

```bash
bash .claude/harness/scripts/check_spec_length.sh <spec-path>
```

- 退出码 0 → 通过（≤ 500 行）
- 退出码 2 → warn 通过（500 < N ≤ 800；或 > 800 行但 frontmatter 已有
  `large_spec_justification`）—— spec 头部写一句超 soft 上限说明即可继续
- 退出码 1 → 阻断（> 800 行 + 无 frontmatter `large_spec_justification` 字段）
  - 自动修正路径：优先精简 spec 到 ≤ 800 行；确实压不下去时在 spec
    frontmatter 加 `large_spec_justification: <≥ 1 句话理由>` 字段后重跑
- 退出码 3 → 参数 / 文件路径错误（检查 spec-path 后重跑）

### 2. D-decisions extract 提议

```bash
bash .claude/harness/scripts/extract_d_decisions.sh <spec-path>
```

- 退出码 0：< 5 个 `### DX.Y.z` 锚点静默通过；≥ 5 个打印 extract 提议
  （**仅 visibility，不阻断**——脚本不改 spec；提议内容是后续把
  D-decisions 迁移到 `architecture/decisions/d-{epic}-{story}.md` sharded
  文件、主 spec 留标题 + 一行摘要 + 链接。是否当场迁移由你按
  answer-policy 自决，不迁移也不影响流水线）
- 退出码 2 → 参数 / 文件路径错误

### 3. Epic 第一个 story 继承段约束（X-1-*, X > 1）

```bash
bash .claude/harness/scripts/check_inheritance_block.sh <spec-path>
```

仅在 story id 匹配 `^X-1-` 且 X > 1 时触发；其它 story id / 不可解析文件名
直接 PASS。检查项（缺任一 → exit 1）：

- `## 继承自前序 Epic patterns` H2 锚（精确行匹配）
- 段内 ≥ 5 行 `- ` 起始 sub-bullet
- 段内含 `Epic {X-1} Story` 引用
- **epic ≥ 5 额外要求**：段内含 `sealed-patterns-epic-{X-1}.md` 链接 OR
  retro §9.5 锚点引用——**同一行内**引用 retro 文件名 + §9.5，如
  `epic-{X-1}-retro-YYYY-MM-DD.md §9.5`（`Epic {X-1} retro §9.5` 大写空格
  形式脚本同样接受）（v2，Epic 4 retro D5 立）

exit 1 时自动修正路径：按 §"Epic 第一个 story 继承段约束（C7）"模板补全
继承段后重跑；exit 2 → 参数 / 文件路径错误。

---

## Epic 第一个 story 继承段约束（C7）

由 epic-3 retro C7 (2026-05-04) 立。每个新 epic 的第一个 story（如 4-1-*,
5-1-*, 6-1-*）必须在 spec 头部 frontmatter 之后、`## Intent` 段之前含
`## 继承自前序 Epic patterns` H2 段，含 ≥ 5 个 sub-bullet。**通用模板**
（`<...>` 占位符按本项目前序 epic 实际沉淀的 patterns 填写）：

```markdown
## 继承自前序 Epic patterns

- (a) **5-question self-review gate** — 沿用 Epic {X-1} Story {X-1}.<n> spec 中的 self-review 5 问 pattern（详 bmad-dev-story-suffix.md §Self-review）。
- (b) **Mech-verify dry-run** — 沿用 Epic {X-1} Story {X-1}.<n> spec 中的 mech-verify dry-run 段 + 4 项验证 tag pattern（详 bmad-dev-story-suffix.md §Mech-verify）。
- (c) **<本项目核心实现 pattern>** — 沿用 Epic {X-1} Story {X-1}.<n> spec 中的 <pattern 描述>（详 <本项目 architecture 沉淀文档路径>）。
- (d) **<本项目第二个实现 pattern / sealed patterns 引用>** — 沿用 Epic {X-1} Story {X-1}.<n> 的 <pattern 描述>；epic ≥ 5 时本行（或任一行）必须引用 `sealed-patterns-epic-{X-1}.md`，或在同一行内写 retro 文件名 + §9.5 锚点（如 `epic-{X-1}-retro-YYYY-MM-DD.md §9.5`；`Epic {X-1} retro §9.5` 形式亦可）。
- (e) **与 Epic {X-1} retro action items 状态对齐** — 已查 sprint-status.yaml retro_action_items.epic-{X-1}-retro 块；状态 = <done / pending 列表>；本 spec Tasks 引用 / 解决相关项。
```

每 sub-bullet 必须 quote 至少 1 个**本项目真实存在的**先行 story 路径
（`Epic {X-1} Story` 字样必须出现——脚本 grep 这个引用）。**禁止照抄下面
示例里模板项目的 story 路径 / 类型名**——新项目里那些文件不存在，照抄等于
编造引用。脚本检查项详见 §Finalize sub-steps 第 3 条。

### 示例（来自模板项目 Epic 4 Story 4.1，仅体例参考）

> 以下 Story 3.4/3.6/3.8、ProviderResolver、canonical_pin_story_3_8_test.go、
> D18 等均为模板项目产物；新项目以自身前序 epic 实际 story 与
> `harness-project-config.yaml` extra 字段为准。

```markdown
## 继承自前序 Epic patterns

- (a) **5-question self-review gate** — 沿用 Epic 3 Story 3.4 spec self-review 5 问 pattern（hostile review 视角 / silent failure / 状态机边界 / 资源泄漏 / 默认值陷阱）。
- (b) **Mech-verify dry-run** — 沿用 Epic 3 Story 3.6 mech-verify dry-run 段 + 4 项 tag（grep 真命中 / file-exist / 退出码语义 / dependencies 可达）。
- (c) **DI / 测试矩阵 / canonical pin** — 沿用 Epic 3 Story 3.8 spec DI 注入 + canonical_pin_story_3_8_test.go pattern；新 risk_tag enum 需新加 canonical pin 测试。
- (d) **plugin-ready 注册** — 沿用 Epic 3 Story 3.6 ProviderResolver registry pattern；DetectionRule 注册同款 plugin framework（D18）。
- (e) **与 Epic 3 retro action items 状态对齐** — 已查 retro_action_items.epic-3-retro：C1 done / C2-C9 pending 待本 epic 入口 chore 兑现；本 spec 不直接修复 C7 已立 chore（外置）。
```
