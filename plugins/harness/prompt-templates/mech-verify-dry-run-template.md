# Mech-verify dry-run results — story md 段模板

> 由 epic-2 retro B3 (2026-05-03) 立。spec author 在 spec 末 Tasks 段之后
> 必须含此段 + 每命令标 tag。
>
> 详 protocol：`_bmad-output/implementation-artifacts/mech-verify-dry-run-protocol.md`
>
> 4 项验证维度（每命令必标）：grep 真命中 / file existence check 路径 /
> 退出码语义 / 命令依赖可达。

## Mech-verify dry-run results

dry-run executed locally on `<YYYY-MM-DD>` by solo-dev（如 sandbox-skipped 则待后续本地复跑兜底）。

| Command | Tag | Output excerpt | Notes |
|---------|-----|----------------|-------|
| `grep -nE '<pattern>' <file>` | `[local-verified]` | `<1-2 行片段>` | 4 项验证维度命中 |
| `docker exec <container> <cmd>` | `[sandbox-skipped]` | — | docker daemon 不可达；待操作员本地复跑 |
| `curl -sf <url> \| jq <expr>` | `[FAIL]` | `<error 输出>` | endpoint 行为不一致；按 protocol Q2 修法（代码先行 / 修 spec 文字） |

Tag enum：
- `[local-verified]` — solo-dev 本地复跑通过
- `[sandbox-skipped]` — sandbox 无 daemon / network；待操作员本地复跑兜底
- `[FAIL]` — 命令输出与 spec 描述不一致；按 protocol Q2 修复路径
