# Harness 代答政策

`/super-harness:run-inline` / `/super-harness:run` 编排的所有 BMad / Codex 子 agent 在被调用时，必须按本政策自决，**不要发问**。

本文件只含跨项目通用的**流程决策原则**。项目特定决策语境（产品定位 / 目标客户 /
交付形态 / 关键决策原则等）由 `harness-prompt-suffix.py` 在 prompt 注入时从
`.claude/harness/harness-project-config.yaml` 的 `extra.project_context:` 字段
内联到代答政策块中——subagent 在 prompt 中直接收到，无需 Read 第二个文件。

## 决策原则

1. **不发问**。如果你的工作流在任何步骤想询问用户、要求确认、或在多选项中等待挑选，按 prompt 注入的项目语境 + 下面的 fallback 规则自决并继续。
2. **优先选「能让流水线继续往前走」的选项**。歧义大时偏向"够用就好"，把雕琢留给后续 story。
3. **决定写进交付物**。把你做出的每个非显然选择 + 理由记录在你最终交付的产物里（story 文件 / review 文件 / retrospective 文件）。审计要靠这些产物事后追溯，不能靠 prose 报告。
4. **登记 follow-up，不要 halt**。如果某个歧义会影响后续 story 的正确性，把它登记成 follow-up note，但不要因此 halt——主 agent 才有 halt 的特权。

## 适用范围

任何主 agent 用 `Agent` / `SendMessage` 调用的子 agent，prompt 末尾出现"按 `.claude/harness/answer-policy.md` 自决"字样时，本政策生效。子 agent 应当先 Read 这份文件，按上面的决策原则 + 同一 prompt 中由 `harness-prompt-suffix.py` 注入的项目语境段处理后续工作流。

## 必须人工确认的事

下面几类不按推荐项代答。子 agent 遇到时把它写成 follow-up 交回，不要自己做；主 agent、lane worker、调度者遇到时停下来问用户（lane worker 回报 `blocked`）。除此之外的拍板题都有推荐项可选，按上面的原则选，记下来，继续往下走，不因为等人确认而停。

1. 对外发布：push 到远端、发版、发包、部署，对外提 issue / PR、发评论或消息。
2. 破坏性操作：删除或覆盖数据、不可逆的数据迁移、改写已经推送的历史、删除分支或 tag、丢掉别人的改动。
3. 硬闸门的口径：改变质量闸门（G0 之类的验收门槛、覆盖率、性能基线）的阈值或计数方式，或者改变验收标准怎样判定通过。
4. 钱、凭据和许可：会产生费用的操作、新增或轮换凭据、引入许可证有限制的依赖。

判断不了是否属于这几类时，按属于处理。

## 代答记录

`/super-harness:run` 下，lane worker 按推荐项回答 intent gap 后，每个决定都会进入调度者的收件箱（`superh.py decisions`），调度者自己按推荐项做的决定也用 `superh.py decide` 记进去。用户空下来时在看板「待你确认」一栏批量确认，或者推翻其中一条：没合入的那一路会退回到这个决定之前，按用户的答复重跑。
