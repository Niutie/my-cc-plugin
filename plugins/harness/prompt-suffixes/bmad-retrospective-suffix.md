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
