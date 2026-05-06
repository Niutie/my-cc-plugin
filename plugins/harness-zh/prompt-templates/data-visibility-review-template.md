# 数据可见性收敛 review — 4 问模板

> 由 epic-2 retro B4 (2026-05-04) 立。每涉及新增 / 修改 endpoint 的 spec
> 必须在 AC 表格附近为每个 endpoint 填写下方 4 问回答。
>
> Reference pattern：Story 2.8 ops-logs 域 single-endpoint dynamic-RBAC +
> service 层 silent override —— `console-api/internal/api/ops_logs.go::registerOpsLogsList`
>
> 详见 `_bmad-output/planning-artifacts/architecture/implementation-patterns-consistency-rules.md` §RBAC 业务层数据可见性收敛 pattern。

## 数据可见性收敛 review

**Endpoint**: `<HTTP method> <path>`（如 `GET /api/v1/risk-events/{id}`）

#### (a) 此 endpoint 是否有 actor-scoped 数据可见性约束？

> **答**：<yes / no — 描述; "no" 时 b/c/d 直接答 N/A>

#### (b) service 层是否在 query 写入处主动加 `WHERE actor_id == caller`？

> **答**：<yes — 文件路径 + line; admin 旁路是否显式 if 分支?>

#### (c) 是否所有 query path（含 status filter / pagination / sort / search / aggregation）都被覆盖？

> **答**：<yes — 列举覆盖路径; 如有未覆盖列表 / 立 follow-up FU-X.Y.Z>

#### (d) framework vs business 责任划分清楚？

> **答**：<framework 决定 "能进"，service silent override 决定 "看什么"; 避免 "RBAC 中间件够了" 假设>
