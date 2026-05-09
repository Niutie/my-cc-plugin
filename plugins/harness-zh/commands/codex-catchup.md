---
description: 补跑 /harness-zh:run 时因 codex-in-cc 不可用（未装 / 配额耗尽 / 未登录）被自动跳过的 stage 3+4。扫描 *.codex-skipped.json marker → 重跑 codex 对抗式 review + dev fix → 归档 marker。
argument-hint: '[--story <KEY> | --all] [--dry-run]'
allowed-tools: Bash, Read, Edit, Write, Task, AskUserQuestion
---

# /harness-zh:codex-catchup — 补跑被跳过的 codex review + fix

你是这个 catchup 的**主 orchestrator**。当用户触发 `/harness-zh:codex-catchup`，扫描所有
被 `/harness-zh:run` 标记为"codex-skipped"的 story，对每条重跑 stage 3 + stage 4。

**触发场景**：

1. 之前跑 `/harness-zh:run` 时 codex 配额耗尽 / plugin 没装 / 未登录 → stage 3+4 被自动跳过
   （留下 `<KEY>.codex-skipped.json` marker）。codex 恢复后用本命令补上漏跑的 QA 关
2. 用户事后想给某条 story 单独跑一次 codex 对抗审查（即使原跑没跳过）—— `--story <KEY>` + `--force`
   （v0.2 留扩展，本版只支持已 skip 的 story）

**与 /harness-zh:run 的关系**：

- **不动 stage 1/2/5/6**。catchup 只补 stage 3+4。已经过 stage 5（done）的 story 也能 catchup —
  catchup 产生的 fix commit 直接落在 done 之后，作为后期 QA。
- **codex 仍不可用时拒绝运行**：本命令开头会跑 `check_codex_availability.sh` 探测；不可用直接
  halt，告诉用户什么时候可以再试。绝不静默重跳过。

**共享行为契约**（与 init / update / run 一致）：

- 代答政策：subagent prompt 末尾必须含 `harness-prompt-suffix.py 3` 与 `4` 输出
- TaskCreate 任务 `Codex Catchup: <count> stories`（§1 启动 in_progress；§5 完成 completed）
- Commit：每条 story 跑 `harness-commit.py 3 <KEY>` 与 `4 <KEY>`，与 /harness-zh:run 同 stage 命名空间
- 不允许 `git add -A`；不动 sprint-status 的 dev_status 字段（catchup 不改 review/done state）

---

## 1. 解析输入

参数从 `$ARGUMENTS` 解析：

| flag | 说明 |
|---|---|
| `--story <KEY>` | 仅 catchup 一条 story（必须有对应 marker；否则告知 + halt） |
| `--all` | catchup 所有 marker（默认；与 `--story` 互斥） |
| `--dry-run` | 仅扫描 + 列清单，不真跑 catchup |

无参时默认 `--all`。

## 2. 前置探测：codex 必须可用

```bash
CODEX_PROBE_JSON="$(bash .claude/harness/scripts/check_codex_availability.sh)"
CODEX_AVAILABLE="$(printf '%s' "$CODEX_PROBE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["available"])')"
```

若 `CODEX_AVAILABLE != True` → **halt + 引导**（不归档 marker，不写 commit）：

```
┌──────────────────────────────────────────────────────────────────┐
│ ⚠️  codex-in-cc 仍不可用 — catchup 无法继续                       │
│                                                                  │
│   reason       : <从 JSON.reason 读>                             │
│   remediation  : <从 JSON.remediation 读>                        │
│                                                                  │
│ 待 codex 恢复后再跑 /harness-zh:codex-catchup                    │
│ marker 文件保持原样，不会丢失。                                  │
└──────────────────────────────────────────────────────────────────┘
```

进入 §3。

## 3. 扫描 marker

```bash
shopt -s nullglob 2>/dev/null || true
markers=( _bmad-output/implementation-artifacts/*.codex-skipped.json )
```

如果 0 个 marker：友好告知 + 退出（无事可做）。

```
✓ 没有 codex-skipped marker — 当前没有需要补跑的 story。
```

否则按 marker 文件名提取 KEY（即 basename 去掉 `.codex-skipped.json`），构造 catchup 任务清单。

`--story <KEY>` 模式：仅保留 KEY 匹配的 marker；找不到 → halt 告知。

`--dry-run` 模式：列清单 + 退出，不真跑：

```
将 catchup 以下 story（dry-run，未执行）：
  - <KEY-1>  reason=quota_exhausted  skipped_at=2026-05-09T12:34:56
  - <KEY-2>  reason=not_installed    skipped_at=2026-05-09T13:00:00
共 N 条。去掉 --dry-run 真跑。
```

## 4. 主循环：对每条 KEY 跑 stage 3 → stage 4

用 `TaskCreate` 建一个总任务 `Codex Catchup: N stories`。每条 story 内部循环：

### 4.1 读 marker
读 `<KEY>.codex-skipped.json` 拿 reason / skipped_at / stage2_base_sha 等上下文。

### 4.2 验证前置
- `<KEY>.md` 存在（stage 1 已跑）
- 当前 git HEAD 不是 dirty worktree（如 dirty → halt 告知用户先 commit/stash）

### 4.3 调度 stage 3 codex review subagent
**完全复用 `/harness-zh:run §1 阶段 ③` 的 prompt 模板**（不要在本文件复粘，把要点写在主
agent 操作清单里，让主 agent 引用 run.md §1 ③ 的同款 prompt）：

- 解析 `<CODEX_COMPANION_PATH>`（同 run.md 阶段 ③ 解析逻辑）
- 解析 `<STAGE2_BASE>` ← marker JSON 里的 `stage2_base_sha` 字段；缺失则 fallback 到
  `harness-state.py <KEY>` 取 stage2_base_sha
- spawn general-purpose subagent，prompt = run.md §1 ③ 同款两步指令 + `harness-prompt-suffix.py 3`
- 等返回，验收 `<KEY>.codex-review.md` 存在 + 含 `base: <STAGE2_BASE>` 行

**in-flight 配额/auth 检测**：subagent 返回文本若含 `hit your limit` / `rate limit` /
`usage limit` / `quota` / `not logged in` / `unauthorized` → halt + §6 重新 marker 模板
（保留原 marker 不归档，因为 catchup 自身被打断）。

### 4.4 commit stage 3
`python3 .claude/harness/scripts/harness-commit.py 3 <KEY>`，按 §−1.d 退出码处理。

### 4.5 调度 stage 4 dev fix subagent
同 `/harness-zh:run §1 阶段 ④`：

- spawn fresh general-purpose subagent
- prompt = `harness-state.py <KEY> --resume-prompt --stage 4` 输出 + run.md §1 ④ 同款指令 +
  `harness-prompt-suffix.py 4`
- 等返回，验收 `<KEY>.md` 的 `### Codex Review Handling (Stage 3)` 段每条 finding 都有处理记录

### 4.6 commit stage 4
`python3 .claude/harness/scripts/harness-commit.py 4 <KEY>`。

### 4.7 归档 marker
catchup 成功后**不删** marker（保留审计轨迹），重命名：

```bash
mv "_bmad-output/implementation-artifacts/<KEY>.codex-skipped.json" \
   "_bmad-output/implementation-artifacts/<KEY>.codex-skipped.resolved.json"
```

并在 resolved 文件里追加（用 jq 或 Python）：
```json
{
  "resolved_at": "<ISO 8601 timestamp>",
  "resolved_by": "/harness-zh:codex-catchup"
}
```

把"已 catchup 完成 <KEY>"通报用户。

## 5. 完成报告

主 agent 用一条简短消息告诉用户：

```
✓ Codex catchup 完成
   resolved : <count> 条
   skipped  : <count> 条（如有 halt 中途退出）
   resolved 标记文件已归档为 *.codex-skipped.resolved.json（git 可见 — 留作审计）。
```

把 TaskCreate 任务标 completed。

## 6. Halt 模板（中途配额/auth 再次耗尽）

如果 catchup 跑到第 K 条时 codex 又耗尽（已成功 K-1 条），那 K-1 条已归档。第 K 条 halt：

```
┌──────────────────────────────────────────────────────────────────┐
│ ⚠️  Catchup 中途 codex 再次失败 — 已完成前 N 条                  │
│                                                                  │
│   故障 story  : <KEY>                                            │
│   故障 stage  : 3 / 4                                            │
│   故障 reason : quota_exhausted / auth_failed                    │
│                                                                  │
│ 已 resolve 的 N 条 marker 已归档（不会重跑）。                   │
│ 失败的 <KEY> marker 保持原样。                                   │
│                                                                  │
│ 待 codex 恢复后再跑：                                            │
│   /harness-zh:codex-catchup                                      │
│ 仅未归档的 marker 会被重新处理。                                 │
└──────────────────────────────────────────────────────────────────┘
```

## 7. 设计动机

**为什么 catchup 走单独命令而不是 /harness-zh:run 的子分支**？

- 主循环 `/harness-zh:run` 状态机只负责"主线流水线"——遇到 codex 缺失就显式跳过 + 留 marker。
  分担"补跑"职责到独立命令避免主循环逻辑膨胀。
- catchup 触发时机不可预测（codex 何时恢复用户决定），强行把它绑到 run 上反而约束用户。
- catchup 失败不影响主线进度（marker 保留即可下次重试），主流程的 halt 模板更聚焦在主线问题。

**为什么 marker 用文件而不是 sprint-status.yaml 字段**？

- 简单 — 单文件 = 单 story 状态，glob 即可发现，归档时只挪一个文件
- 不污染 sprint-status 状态机（dev_status 仍是 review / done 等正常值；codex-skip 是
  正交关注点）
- audit trail 直接落在 _bmad-output/implementation-artifacts/，与 story md / dev-result.json
  在同一目录，git 历史里好检索

**为什么 resolved marker 不删**？

- 保留审计轨迹 → 未来回顾"哪些 story 是 catchup 后才补的 codex review"有据可查
- `*.resolved.json` 不会被本命令再次扫描（§3 glob 只匹配 `.codex-skipped.json`）
- 用户可以手工 git rm 清理，但**不强制**
