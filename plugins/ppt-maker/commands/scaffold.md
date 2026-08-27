---
description: 建工作区 + 做首屏三页，停在 Checkpoint First
argument-hint: '--theme=<主题id> [目标目录，默认 ./deck]'
allowed-tools: Bash, Read, Write, Edit
---

参数：$ARGUMENTS

执行 ppt-maker 的 Phase 3。

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/scripts/scaffold.sh ./deck --theme=<用户选的 id>
```

然后**只做三页**：封面 + 一页数据页 + 一页结构页。主题不够用、容量不够、
图表选错都会在这三页暴露，此时改成本最低。

做完跑 `npm run check`，再按 SKILL.md「视觉自检」截图，停在
**Checkpoint First** 让用户看真页面。

下一步：/ppt-maker:build 铺完其余页面。
