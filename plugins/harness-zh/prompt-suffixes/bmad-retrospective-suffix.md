# bmad-retrospective prompt suffix（项目层）

> 由 epic-3 retro C9 (2026-05-04) 立。CLAUDE.md 严禁动 `.claude/skills/bmad-*/`
> 上游 SKILL —— 本文件作为项目层 prompt 拼接路径，retro skill 启动时主 agent
> 在 user prompt 内 inject 引用本文件。

---

## Pre-retro: 跑 self-audit 脚本

retro skill 进入 Step 3 "Cross-reference with current epic execution" 之前
建议运行：

```bash
bash .claude/harness/scripts/run_retro_self_audit.sh <prev_epic_num>
```

或 Justfile：

```bash
just retro-audit <prev_epic_num>
```

参数 `<prev_epic_num>` = 上一 epic 编号（如 Epic 4 retro 启动时跑 `... 3`，
扫 epic-1 + epic-2 + epic-3 全表）。

输出 markdown 表格 4 列（id / 描述 / 自动判定 status / evidence），solo-dev
把表格 paste 到 retro 文档 §2 cross-reference 草稿基础 + 增补 evidence /
调整 status / 写跨 epic 兑现度评估。

**hint 不阻断**：脚本失败（如新 epic 脚本 case 还没写完）不阻 retro 继续；
solo-dev 可手工填 §2 表格。每加新 epic action items 时同步更新脚本规则
（在 `.claude/harness/scripts/run_retro_self_audit.sh` 加 `check_DN()` function）。

---

## §2 cross-reference 表格使用约定

脚本输出的 4 列 status 自动判定 = `done / partial / pending / unknown`：
- `done` — grep 命中 + file-exist 通过
- `partial` — 部分命中 / via spec-pattern 但 SKILL 未集成
- `pending` — 无命中 / 文件缺失
- `unknown` — 无法机械判定（如 trigger 未到期；deferred 类）

solo-dev 在 paste 后必须为每行：
1. 复核 evidence 真实性（脚本是 grep 兜底，不替代人工判断）
2. 增补 commit hash / 实施日期 / 跨 epic 影响评估
3. 必要时手工调整 status（如脚本判 done 但实际 partial）

---

## Action items markdown 格式契约（**覆盖上游 BMad SKILL §8 默认范式**）

> **背景**：上游 BMad retro skill (`bmm-skills/4-implementation/bmad-retrospective/SKILL.md`)
> §8 默认输出 `**Process Improvements:**\n\n1. {{action_item}}\n   Owner: ...` —
> bold category label + numbered list，**不出 H3 heading**。harness
> `_parse_retro_action_items` 与 stage ⑥.5 `process_retro_residue.sh` 都依赖
> H3 + letter-prefix code 才能 seed `retro_action_items.epic-N-retro` 块。
> 若 retro markdown 不按本契约写，stage 6 commit 会 **fail-loud halt**
> （REASON 含 "schema drift"），不再静默推迟到 ⑥.5 才暴露。

### 1. code 命名规则

- **letter** = epic 编号映射（1→A、2→B、...、26→Z），由 `_epic_letter()` 给定
- **code** 形式 2 选 1：
  - `<letter><digits>` — 如 `A1`、`A2`、`A23`（推荐，简单）
  - `<letter>-<kebab>` — 如 `A-route-authz`、`A-test-coverage`（kebab **必小写**起头）

### 2. 合规 markdown 格式（**仅这一种是 Form 1 / 一等公民**）

```markdown
## 五、Action items（行动项）

### A1 — 流程改进：xxx 必须 yyy
<可选 evidence / rationale 段落>

### A2 — 技术债：补 zzz 单测
<...>

### A-route-authz — 路由鉴权重构
<...>
```

格式细节：`### ` + 一个空格 + code + 可选 ` — title`（em-dash `—` / en-dash `–` /
hyphen `-` 任一；title 可省）。section heading 必须 `## ` 且 title 含
"action item"（英）或"行动项"（中）。

### 3. 禁止形态（会被 fail-loud halt）

下述形态**全部**会让 Form 1 0 命中、走兜底（Form 2/3 命中 → stderr WARN；
全部 0 命中 → halt）：

- ❌ 数字 sub-heading：`### 5.1 流程改进类 action items`
- ❌ markdown 表格行：`| AI-1.1 | <action> | solo-dev | <when> | <criteria> |`
- ❌ bold inline bullet：`- **A1** 不再 X / **A2** 必须 Y`
- ❌ 编号列表：`1. action item 1\n   Owner: ...`（BMad SKILL §8 默认范式）

### 4. 兜底匹配（Form 2/3）— 仅 backward-compat，**不应**依赖

为兼容旧 retro md 与 BMad 默认衍生形态，harness 对下面两种形态做兜底匹配，
但兜底命中后会在 stderr 打 WARN，提示**后续 retro 必须按 Form 1 写**：

- **Form 2 — markdown 表格行**：`| AI-N.M | title | ... |` →
  normalize 成 code `<letter>-N-M`（如 epic 1 / `AI-2.3` → `A-2-3`）
- **Form 3 — bold inline**：`**A1** title` 或 `**A1/A2/A3** shared-title` →
  按 `/` 分裂为多个 code，共享同一 title

不要依赖兜底：
- 兜底 normalize 后的 code（`A-1-1`）与 retro md 内显式引用（`AI-1.1`）对不齐，
  cross-reference 会断
- 兜底匹配范围窄（如 Form 2 仅认第一列 `AI-N.M`，不认 `Action 1.1` 等其他列模式）
- 兜底版本可能在后续 plugin 版本去除

### 5. retro skill 起草 action items 时的写作流程

retro skill 进入 SKILL §8 "Synthesize Action Items" 时，**忽略上游模板的
`**Process Improvements:**\n\n1. {{action_item}}` 输出范式**，按本契约 Form 1
直接生成 H3 heading。对应 §五（中文）/ §6 Action Items（英文）section 内：

1. 先按 `category` 分类（process / tech-debt / test / doc / 自我约束 ...）
2. 每条 action 起一个 `### A<N> — <一句话>` H3 heading
3. heading 下面写：
   - `**Owner**: solo-dev`
   - `**Category**: <process|tech-debt|test|doc|self-discipline|...>`
   - `**Success criteria**: <how we'll know it's done>`
   - 可选 evidence / rationale 段落
4. 编号 N 全 epic 内连续递增（不要按 sub-section 重置编号；`A1..A23` 而非
   `A1.1..A1.4 / A2.1..A2.3`）

### 6. category 字段（与 §"retro action items 写入分流"配合）

每条 action item 必须在 markdown 内显式声明 `**Category**: dev` 或
`**Category**: harness`。category 决定后续 yaml 写入路径（见下一节）：
`dev` → `sprint-status.yaml`；`harness` → `.claude/harness/upstream-feedback.md`。

---

## retro action items 写入分流（category: dev → sprint-status；harness → upstream-feedback.md）

retro 阶段产出 action items 时**必须**按 `category` 字段分流到不同文件：

### category: dev — 项目自身改动

写入 `_bmad-output/implementation-artifacts/sprint-status.yaml.retro_action_items.epic-N-retro` 块：

```yaml
retro_action_items:
  epic-N-retro:
    <CODE>: <status>          # 一句话描述（inline comment）
      category: dev
      chore_spec: '<filename>'   # optional
```

行为同前：`pending` / `in-progress` 项被 pre-commit gate ① 阻 epic spec 创建。

### category: harness — plugin 维护方的债（不进 sprint-status）

**禁止**写入 sprint-status.yaml.retro_action_items；**改写**到 `.claude/harness/upstream-feedback.md`：

```markdown
## From: epic-N-retro (YYYY-MM-DD)

- **<CODE>** `[status:pending]` — <一句话描述>
  - 上下文：<rationale 摘要；retro 文档 evidence>
  - 关联：plugin repo chore-spec 建议 `<filename>`（可选；指 plugin 仓库内的 chore spec 名）
```

**为什么分流**：plugin 用户视角下 `category: harness` 是上游 plugin 维护方的改进建议（非项目本身的债）。混在 sprint-status.yaml 里会让用户感觉项目背着 plugin 的债，污染项目 artifact。upstream-feedback.md 让用户事后复制粘贴提交到 plugin GitHub issue（https://github.com/Niutie/my-cc-plugin/issues）。

**文件不存在时**：retro agent 在写第一条 harness 类条目时调 `bash .claude/harness/scripts/extract_harness_feedback.sh --apply`（即使 sprint-status 内 0 条 harness 条目也会触发 bootstrap 路径）；或由 `/harness-zh:init` §A.3.d 的迁移流程提前 bootstrap。

**历史数据**：旧 retro 产出的 `category: harness` 条目可能仍躺在 sprint-status.yaml.retro_action_items；solo-dev 跑 `/harness-zh:init` 时会被检测到并提示迁移，或事后手工跑 `bash .claude/harness/scripts/extract_harness_feedback.sh --apply`。

### check_retro_action_items.sh 分流契约（参考）

- `category: dev` + status pending/in-progress → 阻 commit
- `category: harness` + status pending/in-progress → stderr WARN（**不应**还存在 — 应已迁；WARN 即提示"快跑 extract_harness_feedback.sh"）
- status `migrated-upstream` → 视同 done（已迁出 sprint-status；不阻、不 WARN）

---

## deferred-work schema v1 写入约束

retro skill 在做 superseded / 大群合并 / status 翻动时**必须**按 schema v1
格式（权威：`.claude/harness/conventions/deferred-work-schema.md`）：

- 翻 `status` 字段不再用 inline `— Resolved by Story X.Y` 后缀；状态变迁记入
  `历史` audit log 子段
- 大群合并（多个 FU 合并为大群锚）：被合并 FU 翻 `[status:superseded]`，
  历史子段记 `superseded by FU-X.Y.Z` + `关联` 字段交叉指
- **retro action items 严禁写入 `_bmad-output/implementation-artifacts/deferred-work.md`** —— retro action items（FU-RETRO-* 命名空间）100% 归
  `sprint-status.yaml.retro_action_items` 块；retro 段如发现 deferred-work.md 含
  `FU-RETRO-*` 条目应在 retro action items 中立 chore 移除

跑 §1 总账 freshness check：

```bash
bash .claude/harness/scripts/grep_deferred_buckets.sh --emit-section1
```

retro 写作时拿 emit 输出与 deferred-work.md §1 AUTO-GENERATED 块对比；如不一致
（dev 期间漏 regen），retro 顺手 regen + commit。
