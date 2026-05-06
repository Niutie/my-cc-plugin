# Fresh Agent Prompt — Deferred Resolved Backfill (Chore C12)

> ⚠️ **DEPRECATED**（2026-05-05）：本 prompt 教 fresh agent 写老 inline 后缀
> （`— Resolved by Story X.Y (date)`），与 schema v1（2026-05-04 起强制 — 详
> `.claude/harness/conventions/deferred-work-schema.md`）不兼容；pre-commit hook gate ②
> 会拒该格式。`backfill_resolved_markers.sh` 已加 schema v1 guard（检测到
> `[status:...]` tag 即 exit 3 + 引导信息），防止误跑。
>
> 保留本 prompt 仅作为历史记录；如需做 schema v1 backfill（找 FU 漏翻 status 的
> 项），按 schema doc §5 历史回填策略写新 prompt（输出应翻 `[status:pending]→
> `[status:resolved]` + 加 `历史` 子段，不要拼 inline 后缀）。
>
> 此 prompt 由 `.claude/harness/scripts/backfill_resolved_markers.sh` 注入到 fresh general-purpose agent 上下文中。
> 主 agent 在 spawn fresh agent 时把本文件全文 + EPIC=N 的 artifact 集合一起喂给 fresh agent。
> Fresh agent 输出将由 `.claude/harness/scripts/diff_guardrail.sh` 强校验，任何越界改动 → halt。

## 你的任务

你正在为 ${project_display_name} 项目的 deferred-work.md 做一次性 **inline 标记反查 backfill**。

deferred-work.md 累计 ~227 条 follow-up（FU-*）项；其中 ~10% 已含 inline `Resolved by Story X.Y` 标记。其余项中相当比例其实已经在某 done story 实施 / review 时顺手消化，但**没有人在 deferred-work.md 上回标 inline 标记**。导致 "修过没修过看不清"。

你的工作：对**当前 EPIC**（你会被告知是 EPIC=1 / 2 / 3 之一）下的 done story 触发的所有 FU 项，扫每个 FU 项的 trigger story 是否 done + 是否实际触及该 FU 描述的代码 / 决策，**仅在该 FU 行末追加 inline 标记**。

## 输入清单（主 agent 会喂给你）

1. **deferred-work.md 全文**：657 行 markdown，含 4 大段（§1 总账概览 / §2 Story 1.x / §3 Story 2.x / §4 Story 3.x），每段下嵌套若干子 section。每条 FU 项形如：

   ```
   - **FU-1.4.G** — {简述}
     - **来源**：{review-findings.json / codex-review.md / dev-result.json 引用}
     - **回头处理时机**：{trigger 描述}
     - {可选 sublist 嵌套段}
   ```

2. **当前 epic 所有 done story 的 4 类 artifact**（每个 story 4 文件）：
   - `<story-key>.md` — story spec（前 1500 行 truncated 如超长）
   - `<story-key>.codex-review.md` — codex stage 3 review 输出（前 1500 行 truncated）
   - `<story-key>.dev-result.json` — dev stage 4 result（结构化）
   - `<story-key>.review-findings.json` — bmad code-review stage 5 findings（结构化）

3. **sprint-status.yaml** development_status 段（用于核对 trigger story 的 done 状态）

## 输出格式（硬约定）

输出 **完整 patched deferred-work.md 全文**（不是 diff）— 主 agent 会用 `diff -u` 算实际 diff + `diff_guardrail.sh` 强校验仅追加。

输出包裹在以下 marker 之间，便于主 agent 自动提取：

```
=== BEGIN PATCHED DEFERRED-WORK.MD ===
{完整 markdown 全文}
=== END PATCHED DEFERRED-WORK.MD ===
```

**输出后另起一段**给主 agent 的简短总结（≤ 200 字）：本批处理项数 / 命中 Resolved 数 / 命中 needs-review 数 / 跳过数 / 任何异常情况。

## 标记格式（严格统一）

对每条 FU 项首行（即 `- **FU-X.Y.Z** — ...` 这一行）末尾追加：

### 命中证据 ≥ 1 条 + trigger story 已 done

追加：` — Resolved by Story <key> (<YYYY-MM-DD>): <证据短摘要 ≤ 120 字>`

证据短摘要要求：
- 引用 1-2 个具体文件路径（如 `console-api/internal/config/loader.go`）或 ADR / decision id
- 一句话说"为什么这条 FU 已被消化"
- 日期取该 trigger story 的 stage 5 done 日期（从 dev-result.json 或 review-findings.json 提取，如缺则用 `2026-05-03`）

**示例**：
```
- **FU-1.4.G** — 命名混淆（bucket key 缩写）若日后扩展易混 — Resolved by Story epic-1-retrospective (2026-05-02): ADR 0007 命名规范定稿 + bucket_names.go 注释充分，不再升级
```

### 命中证据 0 条 + trigger story 已 done

追加：` — Story <key> done but no resolution evidence — needs solo-dev review`

**示例**：
```
- **FU-1.5.J** — golangci-lint 规则集后续业务代码增多时再扩展 — Story 1.6 done but no resolution evidence — needs solo-dev review
```

### 已含 Resolved 标记（任意形式）

**跳过，不动。** 包括：
- ` — Resolved by Story X.Y`（已标）
- `**Resolved by Story X.Y**`（粗体形式）
- `**Resolved by deferred-cleanup-...**`
- `**Resolved by Epic N retro**`
- `superseded — closed`
- 任何含 "Resolved by" 或 "已闭环" 字样

### trigger story 未 done

**跳过，不动。** 含 trigger 写：
- `Epic 6 production lockdown` / `Epic 6 启动` / `Epic 6 hardening`
- `Story 6.x` / `Story 5.x` / `Story 4.x`
- `客户合规反馈触发时` / `客户实测反馈` / 其它无状态机可查的产品决策类
- `v0.2+` / `v1.0+` / `v2.0+` 真增量
- `sandbox 复跑` / 沙箱受限类（docker daemon locked）

## 4 个 example fixtures（学习用）

### Fixture A — 漏标 backfill

**Input FU 项**：
```
- **FU-1.4.G** — bucket key 缩写在容量增长时易混
  - **来源**：1-4-codex-review.md `naming-confusion`
  - **回头处理时机**：Epic 1 retrospective 复盘时
```

**Trigger story 状态**：epic-1-retrospective = done（2026-05-02）

**证据扫描**：
- epic-1-retrospective.md 含 `ADR 0007 bucket 命名规范`
- review-findings 提到 `bucket_names.go 注释充分`
- → 命中 ≥ 1 条

**Output**（仅在首行追加，sublist 不动）：
```
- **FU-1.4.G** — bucket key 缩写在容量增长时易混 — Resolved by Story epic-1-retrospective (2026-05-02): ADR 0007 命名规范定稿 + bucket_names.go 注释充分，命名混淆未升级
  - **来源**：1-4-codex-review.md `naming-confusion`
  - **回头处理时机**：Epic 1 retrospective 复盘时
```

### Fixture B — 已标跳过

**Input FU 项**：
```
- **FU-1.4.E** — sealed_status 命名歧义 — **Resolved by Story 1.11** (2026-05-01)
```

**Output**：**完全跳过，原文不动。**

### Fixture C — trigger done + 0 证据

**Input FU 项**：
```
- **FU-1.5.J** — golangci-lint 规则集后续业务代码增多时再扩展
  - **来源**：1-5-review-findings.json `lint-rules-too-narrow`
  - **回头处理时机**：Story 1.6 / Epic 6 业务代码增多时
```

**Trigger story 状态**：Story 1.6 = done

**证据扫描**：
- 1-6.md / 1-6.codex-review.md / 1-6.dev-result.json / 1-6.review-findings.json **均不含** lint 规则扩展相关改动
- → 0 命中 + trigger 已 done

**Output**：
```
- **FU-1.5.J** — golangci-lint 规则集后续业务代码增多时再扩展 — Story 1.6 done but no resolution evidence — needs solo-dev review
  - **来源**：1-5-review-findings.json `lint-rules-too-narrow`
  - **回头处理时机**：Story 1.6 / Epic 6 业务代码增多时
```

### Fixture D — trigger 未到期

**Input FU 项**：
```
- **FU-1.5.B** — Epic 6 production lockdown 时统一 sealed enum
  - **回头处理时机**：Epic 6 production lockdown 时
```

**Output**：**完全跳过，原文不动。**（trigger 写 Epic 6 — 未到期）

## 严格禁止（违反 → diff_guardrail halt → 你的输出被丢弃）

1. ❌ **不删任何行**。`-` 删除行 0 容忍。
2. ❌ **不改 FU 原描述 / trigger / sublist**。仅在 FU 项**首行末**追加。
3. ❌ **不跨 epic 推理**。即使你看到 Story 2.4 似乎也涉及 FU-1.4.A，**不**标。fresh agent 严格按 trigger 字段指向的 story 查。
4. ❌ **不脑补 trigger**。trigger 写 "Story 1.6" 就只查 Story 1.6；写 "Epic 6 启动"就跳过。
5. ❌ **不用 needs-review 当逃生口**。needs-review 仅在 "trigger story 已 done + 扫遍 4 类 artifact 0 命中" 路径下用。
6. ❌ **不动 §1 总账概览**（行 1-50 左右）— 这是物化统计段，不含 FU 项首行追加位。
7. ❌ **不改 raw bullets / closed / open_total 数字**（这些由 grep_deferred_buckets.sh 重算）。
8. ❌ **不改 markdown headings / horizontal rules / 段落顺序**。

## 处理顺序

按 deferred-work.md 现有 section 顺序：
- EPIC=1 → 处理 §2 Story 1.x 段（Story 1.1 → Story 1.12）
- EPIC=2 → 处理 §3 Story 2.x 段（Story 2.1 → Story 2.8）
- EPIC=3 → 处理 §4 Story 3.x 段（Story 3.1 → Story 3.8）

同 section 内按 FU 项出现顺序。

## 证据强度门槛（模糊匹配）

判断"命中证据 ≥ 1 条"的标准（满足任一）：
- dev-result.json 含相关文件路径 / 函数名
- review-findings.json 含相关概念（即使措辞不同）
- codex-review.md 提到相关讨论 / 决策
- story spec 的 ## Tasks 段或 ## Design Notes 段直接提到该 FU id

模糊匹配优先，宁可标 needs-review 兜底，不要漏标 Resolved。但**不**强行匹配（如 Story 1.6 完全没改 lint，硬标 Resolved 是错的）。

## 自检清单（输出前自查）

- [ ] 输出仅在 FU 行末追加 ` — ...` 文本？
- [ ] 没有任何 `-` 删除行？
- [ ] 已含 Resolved 的项全部跳过？
- [ ] trigger 写 Epic 6 / v0.2+ / 客户反馈类全部跳过？
- [ ] needs-review 标记只用在 "trigger story done + 0 证据" 路径？
- [ ] 标记日期 = trigger story 的 done 日期（不是今天）？
- [ ] 证据短摘要 ≤ 120 字 + 含具体文件路径？
- [ ] 输出包裹在 BEGIN/END marker 之间？
- [ ] 末尾给主 agent 的总结 ≤ 200 字？
