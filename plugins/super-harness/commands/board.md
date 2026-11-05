---
description: 查看 super-harness 各路 lane 的状态：先列需要人处理的（受阻、失败、合流冲突），再列进行中的，最后是 story 就绪情况
argument-hint: '[--plan]'
allowed-tools: Bash
---

# /super-harness:board

1. 执行 `python3 .claude/harness/scripts/superh.py board`，输出原样给用户。
2. 带 `--plan` 参数，或者用户问到某条 story 为什么还没开始时，再执行 `python3 .claude/harness/scripts/superh.py plan`，输出同样原样给用户。
3. 有「需要你处理」的条目时，在后面附上这段说明：

```
每一条下面的「接手」一行是针对它的处理办法。常用操作：
接手某一路：         cd <worktree> && claude --resume <session>
修完让 worker 续作： python3 .claude/harness/scripts/superh.py retry <KEY>
合流冲突手工解决后： git add 解决好的文件，重新执行 /super-harness:run（会从 rebase 现场继续）
合流挂起（held）的： 按「接手」一行修好后，python3 .claude/harness/scripts/superh.py integrate <KEY>
放弃某一路：         python3 .claude/harness/scripts/superh.py abandon <KEY> --yes
有 /super-harness:run 会话还在调度时，上面会改状态的命令会报 STATUS=locked：
在那个会话里让它执行，或者等它结束调度再执行。
```

只读，不要执行 retry、abandon 或任何会改状态的命令。
