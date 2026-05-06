# bmad-create-story prompt suffix（项目层）

> 由 epic-3 retro C2 (2026-05-04) 立。CLAUDE.md 严禁动 `.claude/skills/bmad-*/`
> 上游 SKILL —— 本文件作为项目层 prompt 拼接路径。bmad-create-story skill 启动时
> 主 agent 在 user prompt 内 inject 引用本文件。
>
> 历史：
> - 2026-05-04 C2: spec 长度 hard 上限 800 + D-decisions extract 提议
>   finalize 子项。
> - 2026-05-04 C7: Epic 第一个 story 继承段约束（X-1-* 且 X > 1）。
> - 2026-05-04 deferred-work-schema-v1: spec 引入新 FU bullet 时按 schema v1
>   格式（详 §"deferred-work schema v1 写入约束"）。

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

## Finalize sub-steps

spec 创建 finalize 阶段，主 agent 必须按顺序运行以下脚本：

### 1. spec 长度 lint

```bash
bash .claude/harness/scripts/check_spec_length.sh <spec-path>
```

- 退出码 0 → 通过（≤ 500 行）
- 退出码 2 → warn（500 < N ≤ 800；spec 头部强制写超 soft 上限说明）
- 退出码 1 → 阻断（> 800 行 + 无 frontmatter `large_spec_justification` 字段）
  - 旁路：在 spec frontmatter 加 `large_spec_justification: <≥ 1 句话理由>` 字段后重跑

### 2. D-decisions extract 提议

```bash
bash .claude/harness/scripts/extract_d_decisions.sh <spec-path>
```

- 静默通过（< 5 D-decisions）
- 打印 extract 提议（≥ 5 D-decisions）；solo-dev 确认后手工迁移到
  `_bmad-output/planning-artifacts/architecture/decisions/d-{epic}-{story}.md`，
  主 spec 仅留 标题 + 一行摘要 + 链接

### 3. Epic 第一个 story 继承段约束（X-1-*, X > 1）

```bash
bash .claude/harness/scripts/check_inheritance_block.sh <spec-path>
```

仅在 story id 匹配 `^X-1-` 且 X > 1 时触发；其它 story id 跳过。

---

## Epic 第一个 story 继承段约束（C7）

由 epic-3 retro C7 (2026-05-04) 立。每个新 epic 的第一个 story（如 4-1-*,
5-1-*, 6-1-*）必须在 spec 头部 frontmatter 之后、`## Intent` 段之前含
`## 继承自前序 Epic patterns` H2 段，含 5 个 sub-bullet：

```markdown
## 继承自前序 Epic patterns

- (a) **5-question self-review gate** — 沿用 Epic 3 Story 3.4 spec 中的 self-review 5 问 pattern（详 dev-story-self-review-gate.md）。
- (b) **Mech-verify dry-run** — 沿用 Epic 3 Story 3.6 spec 中的 mech-verify dry-run 段 + 4 项验证 tag pattern（详 mech-verify-dry-run-protocol.md）。
- (c) **DI / 测试矩阵 / canonical pin / mapping upgrade helper** — 沿用 Epic 3 Story 3.8 spec 中的 DI 注入 + 测试矩阵 pattern（详 architecture/implementation-patterns-consistency-rules.md）。
- (d) **plugin-ready 注册** — 沿用 Epic 3 Story 3.6 / 3.8 ProviderResolver / VisionProvider 注册 pattern（D18 / D19 plugin framework 一致）。
- (e) **与 Epic {X-1} retro action items 状态对齐** — 已查 sprint-status.yaml retro_action_items.epic-{X-1}-retro 块；状态 = <done / pending 列表>；本 spec Tasks 引用 / 解决相关项。
```

每 sub-bullet 必须 quote 至少 1 个具体先行 story 路径（如 `沿用 Epic 3 Story 3.4 spec 中的 self-review 5 问 pattern`）。
脚本 `check_inheritance_block.sh` grep `^## 继承自前序 Epic patterns$` 锚 + 5 行
sub-bullet 行 + 含 `Epic {X-1} Story` 引用；缺失 → exit 1 阻断。

### Epic 4 Story 4.1 占位示例

```markdown
## 继承自前序 Epic patterns

- (a) **5-question self-review gate** — 沿用 Epic 3 Story 3.4 spec self-review 5 问 pattern（hostile review 视角 / silent failure / 状态机边界 / 资源泄漏 / 默认值陷阱）。
- (b) **Mech-verify dry-run** — 沿用 Epic 3 Story 3.6 mech-verify dry-run 段 + 4 项 tag（grep 真命中 / file-exist / 退出码语义 / dependencies 可达）。
- (c) **DI / 测试矩阵 / canonical pin** — 沿用 Epic 3 Story 3.8 spec DI 注入 + canonical_pin_story_3_8_test.go pattern；新 risk_tag enum 需新加 canonical pin 测试。
- (d) **plugin-ready 注册** — 沿用 Epic 3 Story 3.6 ProviderResolver registry pattern；DetectionRule 注册同款 plugin framework（D18）。
- (e) **与 Epic 3 retro action items 状态对齐** — 已查 retro_action_items.epic-3-retro：C1 done / C2-C9 pending 待本 epic 入口 chore 兑现；本 spec 不直接修复 C7 已立 chore（外置）。
```
