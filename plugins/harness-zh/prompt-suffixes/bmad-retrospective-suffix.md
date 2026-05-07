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
