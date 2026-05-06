# Self-review (5-question gate) — story md 段模板

> 由 epic-2 retro B2 (2026-05-03) 立。dev agent 在 implementation 完成后
> 必须把此模板粘贴到 story spec `## Dev Agent Record` 段下，并对每问独立
> 答复（不允许一字答 yes/no；"不适用" 必须写 `N/A — <理由>`）。
>
> 5 问内容**逐字**沿用 Epic 1 retro §6 A3 + Epic 2 retro §6 B2，保证
> cross-retro 字面追溯。

## Dev Agent Record

<!-- 其它 dev agent record 段（implementation summary / changes / files modified 等）保留 -->

### Self-review (5-question gate)

#### 1. 可观测性反向验证

> spec mech-verify 命令当攻击者跑能否绕过？

**答**：<具体反向验证路径 / 命中真 metric counter 而非自由文本 log>

#### 2. 状态机边界

> 当前 story 引入的状态机，每两状态间 crash / restart / cancel / timeout / retry 如何降级？

**答**：<状态机图（PENDING → BATCHED → SEALED 等）+ 每条 transition 的 crash safe 路径>

#### 3. 错误吞掉清单

> `_ = err` / `if err != nil { log.Warn; continue }` 路径有无 silent data loss / silent success？

**答**：<grep `_ = err|log.Warn` 命中点 + 每点合理性 / propagate 决策>

#### 4. 资源泄漏

> channel / file / connection / cgroup 资源，崩溃 / 取消 / 超时 / 关闭顺序有无 race？

**答**：<资源生命周期 + go test -race 结果 + cleanup ordering>

#### 5. 可移植性 / 默认值陷阱

> 关键 cfg flag 默认值是否安全？

**答**：<默认值清单 + worst-case 假设 + image bomb / OOM safe path>
