# super-harness changelog

## 0.1.0 — 2026-11-02

首个版本。

- `/super-harness:init`：检查前置条件，投递 `superh.py` 和 prompt 到 `.claude/super-harness/`，分析 depends_on 覆盖情况。
- `/super-harness:run`：调度循环。按 depends_on、`deps_overrides` 和 epic 屏障挑出就绪的 story；每条开一个 worktree，用后台 `claude -p` 跑 harness-zh 的 B0-B3；按完成顺序 rebase + ff 合回 sprint 分支，再串行执行 build-sync、run-test 和 epic retro。
- `/super-harness:board`：看板，先列需要人处理的 lane。
- 合流自动消解 `sprint-status.yaml`、`epic-N-context.md`（取 sprint 分支版本）和 `deferred-work.md`（union）的冲突；用 `rebase --update-refs` 搬迁 `harness/<KEY>/*` tag；ff 之前在 lane 里重跑 build-verify。
- 代码冲突交给合流冲突子 agent（`prompts/merge-fix.md`），每路最多派一次；人工解决冲突并 `git add` 后，tick 会把这一路送回合流。
- 合流可中断重跑：起点 `onto` 在动 tag 和 ff 之前落盘，start tag 只在真的 rebase 过时移动，已经 ff 但没记下的 lane 只补记状态。
- prepare 和 launch 可中断：prepare 中途中断的 lane 由 tick 送回 prepare，先安全回滚再重做；launch 在启动 worker 前中断的 lane 可以直接重新 launch。
- 收口可中断：新增只读的 `superh.py postmerge <KEY>`，按 done tag、harness-state、测试产物和 `--step tested` 检查点给出下一步（sync / tag / test / finish），已完成的步骤不会重做，已有的 marker 不会重写。收口在 sync 步骤里被打断时，`start-run` 识别出脏文件都属于该 lane 的收口产物，报 `MAIN_CLEAN=resumable` 放行续作，其他脏文件仍然 halt。
- 不修改共享的 `.git/info/exclude`。补进 lane 的路径没被 `.gitignore` 忽略时，prepare 失败并给出要加的行；新增只读的 `superh.py doctor`，init 用它预检。
- `superh_test.sh`：80 项断言，用假 claude 跑通全链路，已接入 CI。
