# 合流冲突处理：story `{{KEY}}`

super-harness 正在把 story `{{KEY}}` 的分支 rebase 到 sprint 分支最新提交上，遇到了代码冲突。账本类文件（`sprint-status.yaml`、`deferred-work.md`、`epic-N-context.md`）脚本已经自动处理过，剩下的需要你解决。

| 项 | 值 |
|---|---|
| lane worktree（rebase 进行中） | `{{WORKTREE}}` |
| 冲突文件 | {{CONFLICT_FILES}} |
| 本 story spec | `{{SPEC}}`（可能为空，用 `ls _bmad-output/implementation-artifacts/spec-*` 找） |

你的 Bash 工作目录不是 lane worktree。每条命令都写成 `cd {{WORKTREE}} && ...`，或者用 `git -C {{WORKTREE}}`。不要改主 worktree 里的任何文件。

## 步骤

1. 弄清两边各自想做什么：
   - `git -C {{WORKTREE}} status`、`git -C {{WORKTREE}} diff`：冲突现场。
   - `git -C {{WORKTREE}} show REBASE_HEAD`：本 story 正在重放的这个提交。
   - `git -C {{WORKTREE}} log --oneline -5 HEAD -- <文件>`：sprint 分支上最近改过这个文件的提交，提交信息里通常带着另一条 story 的 key；需要时读那条 story 的 spec。
2. 逐个文件解决冲突，保留两边的意图。两边都在加东西时一般都要保留；两边改同一段逻辑时，以 sprint 分支（已经合入、已经测过的代码）为基础，把本 story 的改动重新叠上去。
3. 每解决一个文件：`git -C {{WORKTREE}} add -- <文件>`。全部解决后：
   ```bash
   cd {{WORKTREE}} && GIT_EDITOR=true git -c core.hooksPath=/dev/null rebase --continue
   ```
   如果后面的提交又冲突，重复 1 到 3，直到 rebase 结束（`git -C {{WORKTREE}} status` 不再显示 rebase in progress）。
4. rebase 结束后在 lane worktree 里跑项目的验证命令：
   ```bash
   cd {{WORKTREE}} && python3 -c 'import sys; sys.path.insert(0, ".claude/harness/scripts"); import harness_config as h; print(h.get_verification_commands())'
   ```
   按输出执行。验证失败而且原因出在你的合并上，就修好，用一个新提交记录（`fix({{KEY}}): resolve merge with <另一条 story key>`），提交前确认只改了合并相关的文件。

## 禁止

- `git rebase --abort`、`git rebase --skip`、`git reset`、`git checkout <分支>`、删除或移动 tag。
- 为了让冲突消失而直接整份取某一边（`--ours` / `--theirs`），除非你确认另一边的改动已经被这一边完整包含。
- 改动与冲突无关的文件。

## 遇到这些情况就停下

- 两边的需求本身互相矛盾，需要产品层面的取舍。
- 冲突牵涉的范围大到需要重新设计。

停下时不要继续 rebase，保持现场。

## 返回

用中文列出：每个冲突文件怎么解决的（各一行），验证命令的结果，最后附上 `git -C {{WORKTREE}} status` 的完整输出。如果停下了，第一行写 `NEEDS_PERSON: <原因>`。
