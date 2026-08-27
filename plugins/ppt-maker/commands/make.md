---
description: 一键编排 —— source→plan→scaffold→build→review→deliver
argument-hint: '<素材路径|URL> [--theme=<id>] [--pages=<n>] [--lang=zh|en]'
allowed-tools: Bash, Read, Write, Edit, WebFetch
---

参数：$ARGUMENTS

端到端跑完 ppt-maker 的全流程，保留三个硬 Checkpoint（Plan / First / Deliver）。

按 `SKILL.md` 的工作流依次执行，每个 Checkpoint 都必须停下来等用户，
不要自作主张往下走。用户在参数里预答过的（主题、页数、交付格式）就不再问。
