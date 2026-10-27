# bmad-build-auto 规划契约（项目层）

> BMad 6.11 起 `bmad-create-story` / `bmad-dev-story` 合并进 `bmad-build` /
> `bmad-build-auto`。harness-zh 0.2.0 起每条 story 由一次 `bmad-build-auto`
> 跑完「规划 → 实现 → 多层 review → commit」。本文件是旧
> `bmad-create-story-suffix.md` 的继任：上游 SKILL 不改，harness 的项目约束
> 通过本文件在**规划阶段**（bmad-build-auto step-02 写 spec 时）注入。
>
> **加载机制**：`run.md` §1 B1 的 dispatch prompt 要求跑 bmad-build-auto 的
> subagent 在 step-02 写 spec 之前 Read 本文件。实现子 agent 看不到 dispatch
> prompt（bmad-build-auto 规定 spec 是实现子 agent 的唯一事实来源），所以凡是
> 要让实现子 agent 遵守的东西，都必须落进 spec 本身或 spec frontmatter
> `context:` 挂载的文件里。
>
> 历史：
> - 2026-05-04 C2 / C7 / deferred-work-schema-v1：create-story 时代的长度 lint、
>   继承段、FU 写入约束。
> - 2026-05-08 cross-story-artifacts、2026-06-12 planning-artifacts（issue #9）。
> - 2026-10-27 v0.2.0：改写为 bmad-build-auto 规划契约。spec 长度 lint 与
>   D-decisions extract 退役（bmad-build-auto 自带 900–1600 token 范围标准和
>   `oversized` warning）。

---

## 1. spec 文件名

spec 的 slug 用 **story key 原文**，即 `spec_file` =
`{implementation_artifacts}/spec-<KEY>.md`。key 含中文也照抄，不要缩写、改写、
翻译。harness 按 `spec-<epic>-<seq>` 编号前缀找 spec，所以就算 slug 偏了也能
认出来，但前缀（epic 与 story 编号）必须正确。（bmad-build-auto 在同名非 draft
spec 已存在时会自己追加 `-2`，harness 认得这种后缀。）

## 2. frontmatter `context:` 必须挂实现清单

spec frontmatter 的 `context:` 列表里**必须**有这一项：

```yaml
context:
  - '{project-root}/.claude/harness/prompt-suffixes/bmad-build-implement-suffix.md'
```

这是实现子 agent 拿到 harness 实现清单（deferred-work 写入格式、self-review、
Q6 全栈追溯）的唯一渠道。其它 context 项照常按 bmad-build-auto 的规则添加。

## 3. Deferred-work 注入项的处理（C11）

dispatch prompt 头部可能有一段 `## Deferred-work 待消化提示（auto-injected by C11）`，
列出 `deferred-work.md` 里 target 指向本 story、仍 pending 的 FU 条目。规划时
逐条判断：

- 在本 story 自然范围内、顺手能解决的：在 `## Tasks & Acceptance` 里写成正常
  task，并**另加一条 task**：「`{implementation_artifacts}/deferred-work.md` —
  把 FU-x.y.z 的 `[status:pending]` 翻成 `[status:resolved]` 并加 `历史` 行」。
  这样实现子 agent 才知道要改 ledger。
- 会让范围膨胀的：不纳入，不需要写理由。
- 注入段为空：跳过本节。

不要因为注入项把 story 扩成多目标（会触发 bmad-build-auto 的
`multiple-goals` warning）。

**新的延后项不要直接写进 deferred-work.md。** bmad-build-auto 在 review 时会把
`defer` 结论写进 spec frontmatter 的 `deferred:` 列表，harness 的 build-sync
会把它们导入 ledger（`FU-<X.Y>.B<n>`，source `build-auto-of-<X.Y>`）。

## 4. cross-story artifacts 声明

spec 的 Tasks 要求改**不属于本 story** 的 `{implementation_artifacts}/*.md`
（其它 story 的 spec、`epic-N-retro-*.md`、`chore-retro-c<epic>-*.md` 等）时，
在 frontmatter 声明：

```yaml
cross_story_artifacts:
  - epic-1-retro-2026-05-07.md
  - spec-1-7-proxy-fork-addon-framework-unix-socket.md
```

约束：bare basename（不含 `/` `..`），`.md` 结尾，不要列本 story 自己的文件。
默认已放行、不需要声明的：本 story 的 spec（`spec-<epic>-<seq>-*.md`）、`<KEY>.*`、`epic-<N>-context.md`、
`deferred-work.md`、`sprint-status.yaml`。

没声明就改了别的 story 的文件，build-verify 会报 `CROSS_STORY=` halt（commit
已经发生，要由 solo-dev 决定怎么撤）。

## 5. planning-artifacts 回写声明（issue #9）

spec 的 Tasks 明确要求回写 `_bmad-output/planning-artifacts/` 下的规划文档
（典型：forward-only remediation 把修正后的 AC 写回 `epics.md`）时，在
frontmatter 用完整 repo 相对路径声明：

```yaml
planning_artifacts:
  - _bmad-output/planning-artifacts/epics.md
```

约束：只限 `planning-artifacts/` 子树，`.md` 结尾，禁 `..` 和绝对路径；只声明
Tasks 真正要求回写的文件。其它兄弟子树（brainstorming/ research/）不在豁免内。

## 6. Epic 第一个 story 的继承段（C7）

story key 形如 `X-1-*` 且 X > 1 时，spec 在 `</intent-contract>` 之后、
`## Code Map` 之前加一个 H2：

```markdown
## 继承自前序 Epic patterns

- (a) **<前序 epic 沉淀的实现 pattern>** — 沿用 Epic {X-1} Story {X-1}.<n> 的 <pattern 描述>。
- (b) ...
- (e) **与 Epic {X-1} retro action items 状态对齐** — 已查 sprint-status.yaml 的 retro_action_items / action_items；状态 = <...>。
```

至少 5 条 `- ` 子项，必须出现 `Epic {X-1} Story` 字样；epic ≥ 5 时还要引用
`sealed-patterns-epic-{X-1}.md` 或同一行写 retro 文件名 + `§9.5`。只引用本项目
真实存在的 story，不要编造。写完 spec 后自检：

```bash
bash .claude/harness/scripts/check_inheritance_block.sh <spec-path>
```

exit 1 → 按缺项补全后重跑；exit 0 → 继续。

## 7. Verification 段

`## Verification` 的 Commands 至少包含 dispatch prompt 里「项目级验证命令」列出
的命令（来自 `harness-project-config.yaml`）。环境里跑不了的（缺 mvn / docker
等），在 `## Auto Run Result` 的 verification 记录里写明跳过原因，**不要**另写
`<KEY>.*-skipped.json` 之类的 marker 文件。

## 8. 编排措辞

spec Tasks 里涉及 ledger / 跨 story 文件 / 规划文档的修改，一律写成实现子 agent
的 task（带文件路径），不要写「主 agent 在编排中……」。harness 主 agent 在 build
期间不改任何文件。
