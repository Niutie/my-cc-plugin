# bmad-build-auto 实现清单（项目层）

> 旧名 `bmad-dev-story-suffix.md`（BMad 6.11 起 bmad-dev-story 并入
> bmad-build-auto，本文件 v0.2.0 改名）。上游 SKILL 不改，本文件作为项目层
> 清单让「复制粘贴 pattern」沉淀成标准 checklists。
>
> **加载机制**：bmad-build-auto 规划时按 `bmad-build-auto-suffix.md` §2 把本文件
> 挂进 spec frontmatter `context:`；实现子 agent 启动时按 spec 要求 Read 本文件。
> 开始实现前先跑一次：
>
> ```bash
> python3 .claude/harness/scripts/harness-prompt-suffix.py implement
> ```
>
> 它输出本项目的 Q6 全栈追溯清单（从 `harness-project-config.yaml` 渲染）和其它
> 项目级约束。
>
> 历史：
> - 2026-05-04 C2: 5-question self-review gate / Mech-verify dry-run / Dev
>   Agent Record 标准 checklists 抽出到本文件。
> - 2026-05-04 C3: 增 Q6 — 全栈贯通 review 7 sub-bullet。
> - 2026-05-04 deferred-work-schema-v1: dev agent 翻 status / 加 partial /
>   spawn 新 FU 时按 schema v1（详 §"deferred-work schema v1 写入约束"）。
> - 2026-10-27 v0.2.0: 改为 bmad-build-auto 实现子 agent 的清单；记录位置从
>   story md 的 Dev Agent Record 改为 spec 末尾的 `## Dev Agent Record` H2。

---

## deferred-work schema v1 写入约束

实现子 agent 在 implementation 过程中需更新
`_bmad-output/implementation-artifacts/deferred-work.md` 时（解决 FU / 标 partial
/ 立新 FU），**必须**按 schema v1 格式（权威：
`.claude/harness/conventions/deferred-work-schema.md`）：

### 翻 status 路径

dev 实现使某 FU 完全消化时：
1. 找到该 FU 的 schema bullet（`grep '^- \*\*<FU id>\*\*'`）
2. 把 `[status:pending]` 改为 `[status:resolved]`
3. 在 bullet body 末尾加 / 扩展 `历史` 子段：
   ```
   - **历史**：
     - YYYY-MM-DD `pending → resolved` by Story X.Y — <短证据 ≤120 字，引 1-2 个文件路径>
   ```

partial 解析（部分覆盖、残余路径仍 open）路径：
- 翻 `[status:partial]`
- 历史子段加一行 `pending → partial` by Story X.Y
- 残余路径**新立** FU（不嵌套），用本 FU 的 `关联` 字段交叉指（`FU-X.Y.Z-residual`）

### spawn 新 FU 路径

实现中发现、但不属于本 spec 的延后项，优先在返回报告的「left incomplete or
risky」里说明，由 bmad-build-auto 的 review 归入 spec frontmatter `deferred:`
（harness build-sync 统一导入 ledger）。确实需要直接登记时，按 4-tag 头 +
字段格式：

```markdown
- **FU-X.Y.Z** `[status:pending]` `[bucket:<B>]` `[target:<T>]` `[source:build-of-X.Y]` — 一句话描述
  - **修复方向**：...
  - **触发条件**：...
  - **关联**：FU-A.B.C / ADR-N（可省）
```

### 严格禁止

- **不要**用 inline 后缀 `— Resolved by Story X.Y (date): ...` 拼接（schema v1
  废弃此模式）；status 字段才是真值
- **不要**写 `FU-RETRO-*` 到 deferred-work.md（归 sprint-status retro_action_items）
- **不要**直接编辑 `<!-- AUTO-GENERATED-BUCKETS-* -->` 块（`bash
  .claude/harness/scripts/grep_deferred_buckets.sh --emit-section1` 重新生成）

---

## Standard checklists

实现完成后，在 spec 文件**末尾**追加（或续写）`## Dev Agent Record` H2，填写以下
self-review 子段，每子段格式严格遵守。这个段在 `<intent-contract>` 之外，可以写；
`<intent-contract>` 内的内容只读。

### Self-review (5-question gate)

dev agent 必须在 stage handover 前显式回答以下 5 问（每条独立答；不允许一字答 yes/no）。

source-of-truth：**本段即权威**（模板项目曾沉淀
`_bmad-output/implementation-artifacts/dev-story-self-review-gate.md` 详述文档；
该文件在新项目不存在——若本项目后续沉淀同类文档，可在此追加引用）。

#### 1. 可观测性反向验证

> spec mech-verify 命令当攻击者跑能否绕过？

**答**：<具体路径 / 反向验证结果>

#### 2. 状态机边界

> 当前 story 引入的状态机，每两状态间 crash / restart / cancel / timeout / retry 如何降级？

**答**：<状态机图 + 降级路径分析>

#### 3. 错误吞掉清单

> `_ = err` / `if err != nil { log.Warn; continue }` 路径有无 silent data loss / silent success？

**答**：<grep 结果 + 每命中点的合理性论证>

#### 4. 资源泄漏

> channel / file / connection / cgroup 资源，崩溃 / 取消 / 超时 / 关闭顺序有无 race？

**答**：<资源生命周期 + race detector 结果>

#### 5. 可移植性 / 默认值陷阱

> 关键 cfg flag 默认值是否安全？

**答**：<默认值清单 + worst-case 假设>

---

### Mech-verify dry-run results

dev agent 必须跑 spec 中所有 mech-verify 命令并贴 dry-run 结果到此段。

source-of-truth：**本段即权威**（模板项目曾沉淀
`_bmad-output/implementation-artifacts/mech-verify-dry-run-protocol.md` 详述文档；
该文件在新项目不存在——若本项目后续沉淀同类文档，可在此追加引用）。

| Command | Tag | Output excerpt | Notes |
|---------|-----|----------------|-------|
| `<command-1>` | `[local-verified]` / `[sandbox-skipped]` / `[FAIL]` | `<1-2 行输出片段>` | `<Q2 修复路径或备注>` |
| ... | ... | ... | ... |

**4 项验证维度**（每命令必标）：
1. **grep 真命中**：命令针对当前文件状态多行结构 / 命名差异都覆盖。
2. **file existence check 路径正确**：命令引用的文档 / 产物路径真实存在；
   警惕"同名内容多源"footgun——同一决策 / 字段可能记录在多个架构文档里，
   核对命令查的是事实来源（模板项目案例：D20 实际在
   architecture-validation-results.md 而非 core-architectural-decisions.md）。
3. **退出码语义一致**：exit 0 / 1 / 2 与 spec 描述对齐。
4. **命令依赖可达**：命令依赖的外部工具 / 容器名 / schema 文件在当前环境
   可达（按本项目实际工具链核对；模板项目示例：docker exec 容器名 /
   sqlc schema 文件）。

---

### Q6 — 全栈贯通 review (forward-looking from Epic 4)

由 Epic 3 retro C3 (2026-05-04) 立（立项依据来自模板项目：其 Epic 3 codex
high finding 14 项中 ≥ 6 项是"集成期断点"类——search writer 漏写 /
canonical pin 漏验 / mapping 漏 / i18n key 漏 / 详情页漏渲染）。Q6
sub-bullet 强制 dev agent 在新审计字段 / 新数据写入面引入时端到端追溯到
所有写入面。

**项目特定的 sub-bullet 清单（(a)-(z)）由 `harness-prompt-suffix.py implement`
从 `.claude/harness/harness-project-config.yaml` 的 `extra.fullstack_review_steps:`
list 字段动态渲染**（见本文件开头的命令；每条形如
`- (X) <file_path>（<label>）：✓ / N/A / deferred-to-FU-X.Y.Z`）。clone 到新
项目时改 yaml 即可，本文件不需动；list 为空时 Q6 段降级跳过。

适用条件：本 story 引入新审计字段 / 新 enum / 新 i18n key。纯重构 / 无新
字段 story 整体答 "(a)-(z) 全部不适用 — 本 story 无新字段"（仍显式逐行）。

dev agent 在 Dev Agent Record 段填的格式：

```markdown
#### Q6: <一句总结：本 story 引入字段 X 的全栈追溯结论>

- (a) `<file_path>`（<label>）：✓ / N/A / deferred-to-FU-X.Y.Z
- (b) `<file_path>`（<label>）：✓ / N/A / deferred-to-FU-X.Y.Z
- ...（按 prompt 注入的 fullstack_review_steps 顺序逐行）
```

#### Q6 reference examples（示例来自模板项目，仅体例参考）

> 以下两个 spec 路径 / 字段名是**模板项目** Epic 3 的产物，新项目里**不存在**
> ——不要去找这些文件，更不要在 Dev Agent Record 里引用它们。体例之外的
> 项目特定内容一律以 `harness-project-config.yaml` 的
> `extra.fullstack_review_steps` 字段（即 prompt 里注入的 (a)-(z) 清单）为准。
> 本项目积累出真实 dev story 后，可把下面示例替换为本项目自己的。

**Story 3.6 ai_model 字段全栈追溯**（模板项目 spec: `3-6-fr15a-ai-provider-model-extractor.md`）
- 7 sub-bullet 全 ✓ 覆盖 ai_model + ai_provider 字段端到端写入路径

**Story 3.8 masked_fields 字段全栈追溯**（模板项目 spec: `3-8-vision-llm-provider-interface-noop-masked-fields.md`）
- (a)-(f) ✓ 覆盖；(g) deferred-to-FU-3.8.X（详情页 masked_fields chip 渲染留 v0.2+）

dev agent 实施时参照上述**答复体例**（每行一个写入面 + ✓/N/A/deferred 判定 +
deferred 项带 FU id）组织自己的 Q6 答复；quote 的对象是体例，不是内容。

---

## 审计 hash chain 准入约束（forward-looking；模板项目 sealed pattern）

> 仅适用于存在审计 hash chain / canonical 序列化机制的项目；本项目无此机制
> 则跳过本段。

任何引入新 hash chain canonical 字段的 story 必须新加 canonical pin 测试
（模板项目命名：`canonical_pin_story_*_test.go`）固定字段集与序列化顺序；
任何字段排除决策（add-only 不进 hash chain）必须在 spec D-decisions 段
显式登记决策 + 排除路径反证。

（模板项目 Epic 3 retro §9.5 sealed pattern 之一。）
