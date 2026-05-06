# 前置 deferred-work import 状态 — story md 段模板

> 由 epic-2 retro B5 (2026-05-03) 立。bmad-create-story 启动时
> activation_steps_prepend 调 `.claude/harness/scripts/grep_pending_deferred_for_story.sh`
> 自动 grep deferred-work.md 中"回头处理时机：Story X.Y" 命中行（排除已标
> "Resolved by Story" 的）+ 把结果写进新 spec dev notes 此段；spec author
> per FU 决策 Import vs Skip + 理由（与 Story 2.5 spec-deferred-cleanup
> 三处一致指令模式一致）。

## 前置 deferred-work import 状态

> 输出由 `bash .claude/harness/scripts/grep_pending_deferred_for_story.sh <epic> <story>` 生成；
> spec author 在每 FU 行后写决策（`→ Imported as Task X.Y` 或 `→ Skip: <理由>`）。

| FU code | line | trigger 摘要 | 决策 |
|---------|------|--------------|------|
| `FU-X.Y.Z` | `<deferred-work.md:LN>` | `<≤80 字符>` | `→ Imported as Task X.Y` 或 `→ Skip: <理由>` |
| ... | ... | ... | ... |

无命中时段保留为：

```markdown
## 前置 deferred-work import 状态

(none) — deferred-work.md 无 "Story <epic>.<story>" 命中行。
```

## Fallback：spec-deferred-cleanup 三处一致指令

当某 FU 无法完整 import 进当前 spec（如范围超本 story / 需要新 chore 立）：

1. 立 `_bmad-output/implementation-artifacts/spec-deferred-cleanup-YYYY-MM-DD-<topic>.md` 文件登记。
2. `sprint-status.yaml` standalone comment 行（在相关 story key 旁注释）登记。
3. `_bmad-output/implementation-artifacts/deferred-work.md` 段尾追加引用三处一致指令。

reference：Story 2.5 spec-deferred-cleanup-2026-05-02-console-web-container-build.md
（FU-1.5.M 兑现路径）。
