---
description: 素材 → source/source.md（URL / PDF / DOCX / MD / 纯文本）
argument-hint: '<文件路径 | URL> [-o source/source.md]'
allowed-tools: Bash, Read, Write, WebFetch
---

参数：$ARGUMENTS

执行 ppt-maker 的 Phase 1。

读 `SKILL.md` 的「Phase 1」一节，用 `scripts/source-to-markdown.py` 把用户给的
素材抽成 `source/source.md`，然后自己过一遍：数字有没有丢、表格有没有塌、
图注还在不在。**每个数字保留原值和单位** —— Phase 2 的 canonical 文案包要用。

用户直接给文字或大纲时跳过本步，直接进 `/ppt-maker:plan`。

下一步：/ppt-maker:plan 做内容规划（含 canonical 文案包），停在 Checkpoint Plan。
