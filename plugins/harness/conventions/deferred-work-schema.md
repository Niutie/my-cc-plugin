# Deferred-work schema v1 — 格式契约

> Harness 自治约定。**不**改 BMad 上游 skill 文件；通过 `.claude/harness/prompt-suffixes/`
> 的 prompt 拼接告知 dev / review / chore 阶段 agent 按本契约写入
> `_bmad-output/implementation-artifacts/deferred-work.md`。
>
> **取代关系**：
> - `chore-retro-c11-deferred-grep-injection.md` 已实施部分（grep 脚本骨架）保留；
>   解析路径切到读本 schema tag，不再走 word-boundary regex 文本拼接（见 §6）
> - `chore-retro-c12-deferred-resolved-backfill.md` **取代** — fresh agent 反查工作仍
>   要做，但产出落到本 schema `status` 字段 + `历史` audit log，而非 inline 后缀字符串
> - sprint-status `retro_action_items.C11 / C12` 在本 schema 落地后 mark `superseded`

---

## §1 设计原则

1. **每条 FU 一个 markdown bullet** — 保留人类可读 + grep-friendly；不引 yaml SoT / render pipeline（按 memory `feedback_no_throwaway_mvp` — 不做 throwaway 基础设施）
2. **状态显式机器可读** — `status` 是枚举字段，不是 inline 文本后缀（`— Resolved by Story X.Y` 格式废弃）
3. **章节按"出生来源"分** — 取消独立 `## Resolved-by-Story-X.Y` / `## §X Test Harness FU items` 章节；resolved 是 FU 自身字段，test-harness 是 bucket 值
4. **§1 总账概览全 auto-generated** — 由 `grep_deferred_buckets.sh` 输出；首行 `<!-- AUTO-GENERATED — do not hand-edit -->` 警示；手编辑改的是单条 bullet 的 tag，总账数自然跟随
5. **状态变迁留 audit log** — 每次 status 翻动写一行 `历史` 子项；commit + git log 反查路径不替代文件内审计轨迹

---

## §2 单条 FU bullet 格式

### 2.1 必填头

```markdown
- **FU-X.Y.Z** `[status:<S>]` `[bucket:<B>]` `[target:<T>]` `[source:<O>]` — 一句话描述（≤120 字）
```

四个 tag **必填**，顺序固定（`status` → `bucket` → `target` → `source`）。tag 内不允许空格 / 中文逗号 / 引号。

### 2.2 可选 body 字段

```markdown
  - **修复方向**：...（≤200 字；说"做什么"，不说"为什么 defer"）
  - **触发条件**：...（≤80 字；machine-checkable — Story key / Epic gate / customer feedback / N/A）
  - **关联**：FU-A.B.C / ADR-N / spec-X.Y.codex-review.md（多项以 ` / ` 分隔；可省）
  - **历史**：（每次 status 翻动追加一行；不删历史）
    - YYYY-MM-DD `<old> → <new>` by Story X.Y / Chore <name> / fresh-agent-backfill — 短证据 ≤120 字
```

字段顺序固定。无内容字段**整行省略**（不写空 placeholder）。

### 2.3 完整示例（pending → partial → resolved）

```markdown
- **FU-1.4.E** `[status:resolved]` `[bucket:cross-story]` `[target:Story 1.11]` `[source:dev-of-1.4]` — mapping `attachment_text` 字段 + 中文 IK 分词决策
  - **修复方向**：Story 1.11 dev agent 决定字段名 `attachment_text` vs `attachments[]` + type `text` vs `text + analyzer ik_max_word` + 是否加 `.keyword` subfield
  - **触发条件**：Story 1.11 dev-story
  - **关联**：ADR-0014 / FU-1.11.B
  - **历史**：
    - 2026-05-01 `pending → resolved` by Story 1.11 — D1.11.a 选 nested 数组 + standard 分析器；`attachments[]` nested + 9 子字段；IK 推迟到 v0.2+ FU-1.11.B
```

partial 状态示例（残余路径 spawn 新 FU）：

```markdown
- **FU-4.1.C** `[status:partial]` `[bucket:cross-story]` `[target:Story 4.5]` `[source:dev-of-4.1]` — RuleEngine 配置 hot-reload + RPC 跨进程
  - **修复方向**：Story 4.5 加 fsnotify watcher + 跨 proxy 同步；RPC 跨进程路径独立
  - **触发条件**：Story 4.5 dev-story
  - **关联**：FU-4.5.D（残余 RPC 路径）
  - **历史**：
    - 2026-05-04 `pending → partial` by Story 4.5 — fsnotify watcher 落地；跨进程 RPC 推迟到 FU-4.5.D
```

needs-review 状态示例（C12 反查产物）：

```markdown
- **FU-1.10.A** `[status:needs-review]` `[bucket:sandbox]` `[target:Story 1.12]` `[source:dev-of-1.10]` — aegis-cli 7 用例 chaos test
  - **触发条件**：Story 1.12 chaos test 实施
  - **历史**：
    - 2026-05-02 `pending → needs-review` by fresh-agent-backfill — Story 1.12 done 含 chaos scaffold；无显式 verify-chain + reconcile-check 7 用例落点；solo-dev 确认是否真消化
```

---

## §3 枚举定义

### 3.1 `status`（7 值）

| 值 | 语义 | 何时翻 |
|---|---|---|
| `pending` | 未开始消化 | 初始登记 |
| `in-progress` | dev/review 进行中（trigger story 在 active sprint） | run-sprint stage 2 dev-story 创建时（可选；机器可由 sprint-status 推） |
| `partial` | 部分消化；残余路径已 spawn 新 FU 或 inline 注明 | dev/review 阶段确认部分覆盖时 |
| `resolved` | 完全消化 | dev/review/chore 阶段确认完整覆盖时 |
| `skipped` | 决策性不做（spec author 显式 Skip / 触发条件未到 / 上游工具兜底） | spec / review 阶段决策时 |
| `superseded` | 被新 FU 取代或合并入更大群（如 §1 总账类） | retro / 决策事件触发 |
| `needs-review` | trigger story done 但无证据；solo-dev 待确认 | C12-style fresh-agent 反查产出 |

**变迁路径**：

```
pending ──→ in-progress ──→ partial ──→ resolved
   │            │              │
   ├────────────┴──────────────┘
   │
   ├──→ skipped
   ├──→ superseded
   └──→ needs-review ──→ resolved / pending（solo-dev 拍板）
```

回退（如 `resolved` → `pending`）允许，但必须 `历史` 留行说明回退原因。

### 3.2 `bucket`（8 值；mutually exclusive）

| 值 | 语义 | 是否计入 §1 hard threshold |
|---|---|---|
| `epic-6` | Epic 6 production lockdown / hardening / deployment hardening | ✅（threshold 30）|
| `v0.2+` | v0.2+ 真增量 | ✅（threshold 40）|
| `v1.0+` | v1.0+ 真增量（FR68/FR69/FR70/FR77 等） | ✅（threshold 30，与 v2.0+ 合并）|
| `v2.0+` | v2.0+ 真增量 | ✅（与 v1.0+ 合并）|
| `sandbox` | sandbox-bound（docker daemon-locked 操作员复跑） | ✅（threshold 25）|
| `cross-story` | 待下游 Story 自然消化（明确指向 Story X.Y） | ❌（计 open 但不算债）|
| `test-harness` | FU-Test-* 测试 harness 流水线产物 | ❌（独立命名空间）|
| `other` | 客户反馈触发 / 历史 stale-residual / 未明确分类 | ❌（计 open 不算债）|

> v1.0+ / v2.0+ threshold 合并为 30 — 历史 §1 表已是合并口径，schema 沿用。

**`retro` bucket 已移除**（Q4 决策 2026-05-04）：

- FU-RETRO-* 命名空间**禁止进 deferred-work.md**
- 所有 retro action items 100% 归 `_bmad-output/implementation-artifacts/sprint-status.yaml.retro_action_items` 管
- 历史回填 Pass 2 时把现有 FU-RETRO-3.C2..C9 / FU-RETRO-3.C1.A..K 等条目从 deferred-work.md 移出 → 校对 sprint-status retro_action_items 已含同 id（缺则补）→ 删
- prompt-suffix 注入禁止 dev/review/retro agent 写 `FU-RETRO-*` 到 deferred-work.md（写错触发硬门）

### 3.3 `target`（自由文本，但格式约束）

合法值（机器可识别）：

- `Story X.Y`（如 `Story 1.11`）
- `Epic N`（如 `Epic 6`）
- `Epic N retro`（如 `Epic 6 retro`）
- `Epic 6 production lockdown`
- `v0.2+ first-sprint` / `v0.2+ customer-feedback` / `v1.0+ FR77` / `v2.0+ customer-feedback`
- `customer-feedback` — 客户实测触发，不绑定 phase
- `N/A` — 由其它机制兜底（yaml linter / 上游 tool / FU-RETRO-*）

> 多 target 时取**最早期**的（如"Story 2.7 / Epic 6"取 `Story 2.7`）；其它 target 写入 **修复方向** 或 **关联** 段。

### 3.4 `source`（自由文本，但格式约束）

合法值：

- `dev-of-X.Y`（Story X.Y dev-story 阶段）
- `bmad-review-of-X.Y`（bmad-code-review 阶段）
- `codex-review-of-X.Y`（codex review 阶段）
- `epic-N-retro`
- `chore-<slug>`（chore 实施阶段，如 `chore-test-harness-bootstrap`）
- `design-discussion-YYYY-MM-DD`

---

## §4 章节组织

### 4.1 文件顶层结构

```
# Deferred Work — Aegis AI Audit
（前言 2-3 行）

---

## §1 总账概览（auto-generated）
<!-- AUTO-GENERATED by .claude/harness/scripts/grep_deferred_buckets.sh — do not hand-edit -->
（脚本输出 — 桶计数表 + 各类 critical evaluation 段，由脚本 derive）

---

## Deferred from: <source-描述> (YYYY-MM-DD)
（按出生时间倒序或正序均可；保持 grep -nE '^## Deferred from:' 可索引）

- **FU-X.Y.Z** `[status:...]` ... — ...
  - **修复方向**：...
  - ...

- **FU-X.Y.W** `[status:...]` ... — ...
  ...

---
（下一个出生章节）
```

### 4.2 章节命名规则

- 标准格式：`## Deferred from: <source 描述> (YYYY-MM-DD)` —— 描述与各 FU 内 `source` 字段语义一致（DRY 容忍冗余，方便人类阅读）
- 同一来源多次产出（如 dev + bmad-review of same story）允许多个章节，分别按时间区分
- **废弃**：`## Resolved-by-Story-X.Y` 独立章节（resolved 是 FU 字段；FU 仍留在出生章节）
- **废弃**：`## §X — Test Harness FU items` 顶级章节（用 `bucket:test-harness` 区分）
- **禁止**：FU-RETRO-* 命名空间（retro 项 100% 归 `sprint-status.yaml.retro_action_items`，详 §3.2）

### 4.3 §1 总账概览段

由 `grep_deferred_buckets.sh` 全自动生成。包含：

1. 桶计数表（Epic 6 / v0.2+ / v1.0+ / sandbox / cross-story / retro / test-harness / other / closed / open total）
2. threshold breach 状态指示
3. 各类 critical evaluation 段（仅 breach 时由脚本插入 stub；详细 rationale 由人类编辑后的"段尾追加"模式）

**脚本边界**：`<!-- AUTO-GENERATED -->` 与 `<!-- /AUTO-GENERATED -->` 之间是脚本管辖区；外面的人类追加（如 §1.1 / §1.2 critical evaluation 详述）由人类编辑，每次脚本 rerun 不动。

---

## §5 历史回填策略（commit-2 阶段执行）

第二个 commit 的工作。本 schema 文档落地后才执行：

1. **Pass 1（机器自动，~80%）** — Python 脚本扫现有 1002 行：
   - inline `— Resolved by Story X.Y (date): ...` → 提取 → `status:resolved` + 历史子项
   - inline `— Partial resolution by Story X.Y (date): ...` → `status:partial` + 历史子项
   - inline `Story X.Y done but no resolution evidence — needs solo-dev review` → `status:needs-review`
   - 无 inline 标记 → `status:pending`
   - bucket 推断：从"回头处理时机"文本 + §1 总账"Story X.Y add" 桶映射表 cross-reference
   - target / source 推断：从章节标题 + 文本"回头处理时机：Story X.Y" 提取
2. **Pass 2（手工兜底，~20%）** — 边缘 case：
   - FU-RETRO-* / FU-Test-* / FU-A1.REAL-ACTUATION 顶级章节迁回出生章节
   - bucket 歧义条目（"Story 2.7 / Epic 6"二选一）
   - 跨 epic 联动（如 FU-1.4.A / 1.5.A / 1.12.B 共群引用）拍板主 FU + 其余 superseded
3. **Pass 3（验证）** — 跑新 schema 工具链产生新 §1 总账段；与历史 §1（手工版）数字 cross-check；偏差 ≤ 5% PASS

历史回填 commit 单独成 commit；commit message：
`chore(deferred-work): backfill schema-v1 tags across N FU items + auto-generated §1 总账`

---

## §6 工具链对接（commit-1 阶段顺势完成；本文档不规定实现细节）

`grep_deferred_buckets.sh` / `grep_pending_deferred_for_story.sh` / `grep_deferred_status.sh` 三个
脚本切到读 schema tag。简化：

- pending grep：`grep -E '^- \*\*FU-' deferred-work.md | grep '\[status:pending\]'`
- target grep：`... | grep '\[target:Story X.Y\]'`
- bucket 计数：`... | awk -F'[' '{ for(i=1;i<=NF;i++) if($i ~ /^bucket:/) print $i }' | sort | uniq -c`

不再需要：word boundary regex (`\bStory[[:space:]]+${EPIC}[\.\-]${SEQ}\b`) / `Resolved by` / `Partial resolution by` 文本剔除 / `--diff-filter` 兜底等。

---

## §7 dev / review / chore 阶段的写入约束（prompt-suffix 注入）

`.claude/harness/prompt-suffixes/` 三份 suffix 增加约束段（具体注入文案在 prompt-suffix 文件，非本文档）：

- **bmad-create-story-suffix**：spec author 引入新 FU 时按本 schema 头格式写入
- **bmad-dev-story-suffix**：dev agent 翻 status / 加 partial / spawn 新 FU 时按 §3 状态变迁路径走，必加 `历史` 行
- **bmad-retrospective-suffix**：retro 阶段做 superseded / 大群合并时按 schema 翻 status

---

## §8 schema v1 → 未来 v2 的演进锚

- **v1 在 markdown bullet + tag 模式上 cap** —— 不再演进到 yaml SoT（throwaway risk）
- **触发 v2 的条件**：
  - bullet 总数 > 1000（当前 280）→ 物理拆 `deferred-work/` 目录 + per-FU 文件
  - tag 字段超 6 个 → 引入 frontmatter 块替代 bullet 头部 tag
  - 工具链 awk-only 路径不够（如需要 cross-reference / 联表）→ 引入 yq + yaml SoT
- 上述任一触发前，schema 锁 v1
