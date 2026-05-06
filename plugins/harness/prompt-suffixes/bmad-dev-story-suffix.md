# bmad-dev-story prompt suffix（项目层）

> 由 epic-3 retro C2 (2026-05-04) 立。CLAUDE.md 严禁动 `.claude/skills/bmad-*/`
> 上游 SKILL —— 本文件作为项目层 prompt 拼接路径（C11 范式）。bmad-dev-story
> skill 启动时主 agent 在 user prompt 内 inject 引用本文件，让"复制粘贴 pattern"
> 沉淀到 SKILL 级标准 checklists。
>
> 加载机制：调 bmad-dev-story 前主 agent 在 user prompt 内 inject:
> > 参考 `.claude/harness/prompt-suffixes/bmad-dev-story-suffix.md` 的 Standard checklists
> > 段填写 Dev Agent Record 各 self-review 子段。
>
> 历史：
> - 2026-05-04 C2: 5-question self-review gate / Mech-verify dry-run / Dev
>   Agent Record 标准 checklists 抽出到本文件。
> - 2026-05-04 C3: 增 Q6 — 全栈贯通 review 7 sub-bullet。
> - 2026-05-04 deferred-work-schema-v1: dev agent 翻 status / 加 partial /
>   spawn 新 FU 时按 schema v1（详 §"deferred-work schema v1 写入约束"）。

---

## deferred-work schema v1 写入约束

dev agent 在 implementation 过程中需更新
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

dev 实施过程发现新 deferred 项必须按 4-tag 头 + 字段格式登记：

```markdown
- **FU-X.Y.Z** `[status:pending]` `[bucket:<B>]` `[target:<T>]` `[source:dev-of-X.Y]` — 一句话描述
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

dev agent 在 implementation 完成后必须在 story spec `## Dev Agent Record` 段
下填写以下 self-review 子段，每子段格式严格遵守。

### Self-review (5-question gate)

dev agent 必须在 stage handover 前显式回答以下 5 问（每条独立答；不允许一字答 yes/no）。

source-of-truth：`_bmad-output/implementation-artifacts/dev-story-self-review-gate.md`

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

source-of-truth：`_bmad-output/implementation-artifacts/mech-verify-dry-run-protocol.md`

| Command | Tag | Output excerpt | Notes |
|---------|-----|----------------|-------|
| `<command-1>` | `[local-verified]` / `[sandbox-skipped]` / `[FAIL]` | `<1-2 行输出片段>` | `<Q2 修复路径或备注>` |
| ... | ... | ... | ... |

**4 项验证维度**（每命令必标）：
1. **grep 真命中**：命令针对当前文件状态多行结构 / 命名差异都覆盖。
2. **file existence check 路径正确**：避免"架构文档双源"footgun（D20 在 architecture-validation-results.md 而非 core-architectural-decisions.md）。
3. **退出码语义一致**：exit 0 / 1 / 2 与 spec 描述对齐。
4. **命令依赖可达**：docker exec 容器名 / sqlc schema 文件可达。

---

### Q6 — 全栈贯通 review (forward-looking from Epic 4)

由 Epic 3 retro C3 (2026-05-04) 立。Epic 3 codex high finding 14 项中 ≥ 6
项是"集成期断点"类（OpenSearch writer 漏写 / canonical pin 漏验 / mapping
漏 / i18n key 漏 / 详情页漏渲染）—— Q6 sub-bullet 强制 dev agent 在新
审计字段引入时端到端追溯到所有写入面。

**项目特定的 sub-bullet 清单（(a)-(z)）由 `harness-prompt-suffix.py` stage 2
从 `.claude/harness/harness-project-config.yaml` 的 `extra.fullstack_review_steps:`
list 字段动态渲染**，已自动注入到本 dev subagent prompt 中（每条形如
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

#### Q6 reference examples

参考 Epic 3 真 dev story Dev Agent Record 答复模式：

**Story 3.6 ai_model 字段全栈追溯**（spec: `_bmad-output/implementation-artifacts/3-6-fr15a-ai-provider-model-extractor.md`）
- 7 sub-bullet 全 ✓ 覆盖 ai_model + ai_provider 字段端到端写入路径

**Story 3.8 masked_fields 字段全栈追溯**（spec: `_bmad-output/implementation-artifacts/3-8-vision-llm-provider-interface-noop-masked-fields.md`）
- (a)-(f) ✓ 覆盖；(g) deferred-to-FU-3.8.X（详情页 masked_fields chip 渲染留 v0.2+）

dev agent 实施时直接 quote 上述 reference example 段以建立"答复体例"。

---

## 审计 hash chain 准入约束（forward-looking）

任何引入新 hash chain canonical 字段的 story 必须新加 `canonical_pin_story_*_test.go`
固定字段集与序列化顺序；任何字段排除决策（add-only 不进 hash chain）必须在
spec D-decisions 段显式登记决策 + 排除路径反证。

（Epic 3 retro §9.5 sealed pattern 之一。）
