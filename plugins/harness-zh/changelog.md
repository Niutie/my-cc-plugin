# harness-zh changelog

每次对 harness-zh plugin 的改动在这里追加一条记录。**新条目放最上面**。每条包含：

- 版本号 + 日期 + commit hash 段
- 改动范围（plugin 文件 / 段）
- 改动动机
- 后续注意事项 / 待办

> **历史接续说明**：harness 在 plugin 化之前作为 `.claude/harness/` 资产维护在 Aegis AI Audit 项目内（commits before plugin extraction）；plugin 提取前的 runtime 演化历史完整保留在该项目的 git history。本 changelog 仅记录 plugin 化之后的改动。

---

## v0.1.33 — 2026-05-29 — `/harness-zh:run` 启动前置自动兑现 retro DEV items（fixes #3）

### 触发

GitHub issue #3（用户仓库 epic 5，story `5-1-安全事件-crud-启停-筛选`，stage 1 halt）：

```
pre-commit hook BLOCKING: epic-4-retro 10 条 dev 类 pending action items
(D7/D8/D9/D10/D11/D14/D15/D16/D18/D20) 未兑现
```

新 epic 4-6 story 的 stage ① 创建 `<KEY>.md` 命中 pre-commit gate ① 触发模式
`[4-6]-*.md`。若上个 epic retro 落地的 `category: dev` action items 还没兑现，
commit 被 hook 拦——但**此时 stage ① subagent 的 token 已经烧掉**。用户要求：
`/harness-zh:run` 启动时自动检测这些 dev 项并**先兑现**，避免「spawn stage-1 →
干活 → commit 被拦 → halt」的 token 浪费。

### 改动范围

- `plugins/harness-zh/scripts/grep_pending_dev_retro_items.sh`（NEW）：纯
  enumerator —— 扫 `retro_action_items` 块，机器可读列出所有 `category: dev` 且
  status ∈ {pending, in-progress} 的项（gate ① 同口径），每项附 epic/code/status/
  chore_spec。复用 `check_retro_action_items.sh` 的 awk 状态机 + 新增 chore_spec
  捕获。stdout 契约：`ITEM<TAB>epic<TAB>code<TAB>status<TAB>spec` 行 + `_PENDING_DEV_`
  / `_WITH_SPEC_` / `_NO_SPEC_` 三行汇总。恒 exit 0（除文件缺失 exit 2）；块缺失 /
  重复 header 走 WARN + 0 项（gate 自会拦，enumerator 不重复报错）。
- `plugins/harness-zh/scripts/harness-commit.py`：新增 `retro-fulfill` commit
  stage —— 把一条 dev retro item 的 chore_spec 实现成项目代码后收口 commit。允许
  路径 = 项目代码 + `sprint-status.yaml`（主 agent Edit 翻 status → done）+
  `deferred-work.md` + `chore-retro-c{epic}-*.md`（chore_retro 通道豁免，与 stage
  6-5 同）。位参 `key` = retro item 的 `<CODE>`（非 story key）；commit_msg =
  `chore(retro-c{epic}-{key}): fulfill retro dev item`。`_sync_sprint_status_for_stage`
  对本 stage no-op（retro_action_items 无 setter，由主 agent Edit 落地）。同步把
  `retro-fulfill` 加进「需 `--epic`」stage 列表。
- `plugins/harness-zh/commands/run.md`：
  - 新增 §0.A.0「retro DEV items 兑现前置 gate」——在 §0.A 末尾、进 §1 之前，先判
    本轮第一条 story key 是否命中 `^[4-6]-`；命中则跑 enumerator 检测 → 对每个有
    chore_spec 的 dev 项 spawn fresh subagent 实现 → Edit 翻 status → `retro-fulfill`
    收口 commit → 全清后进 §1。缺 spec 项不臆造，列给用户走 `process_retro_residue.sh`
    补 spec 或 `--no-verify` 留痕。
  - §0.5 路径预期产出表加 `retro-fulfill` 行；「项目代码」允许 stage 列表加
    `retro-fulfill`。
- `plugins/harness-zh/scripts/grep_pending_dev_retro_items_test.sh`（NEW）：9 用例
  覆盖 dev/harness/done/NOCAT 分流、with/no-spec 分桶、块缺失 / 重复 header /
  文件缺失边界、+ 与 `check_retro_action_items.sh` dev 计数一致性回归锚。
- `plugins/harness-zh/scripts/retro_fulfill_stage_test.sh`（NEW）：3 用例（源码树
  直跑 `--dry-run`）覆盖 happy path（3 路径 staged + commit_msg）、缺 `--epic` halt、
  cross-story 隔离 halt。

### 后续注意事项

- **范围**：本前置只覆盖**启动那一刻**的 gate ① 阻塞。`all` 模式跑到 epic 边界
  时上个 epic 的 stage ⑥ retro 会**新 seed** dev 项，下个 epic stage ① 仍可能被
  拦——属 mid-run epic 切换，沿用既有 stage 6.5 → 手工兑现路径，未纳入本前置（避免
  在主循环里插 dev-loop 的复杂度 + 失控风险）。后续如需可把 §0.A.0 抽成 §1 stage ①
  前可复用的子例程。
- gate ① 触发模式 `[4-6]-*.md` 是单字符 epic（4/5/6）；epic 7+ / epic 53 这类
  `^[4-6]-` 不命中的 epic，gate ① 本就不触发，§0.A.0 也据此跳过——与 hook 行为
  对齐。这是 harness 围绕 1-6 epic 项目设计的既有限制，本版未扩。
- `retro-fulfill` 一次只兑现一条（per-item commit），chore_retro 通道允许任意
  `chore-retro-c{epic}-*.md`（非严格限定当前 CODE），与 stage 6-5 批处理一致；真正
  的隔离靠 cross-story gate（foreign `<other-key>.md` 仍 halt）。

## v0.1.32 — 2026-05-28 — BLACKLIST `**/*credentials*` 收窄 + artifacts allow-list（fixes #2）

### 触发

GitHub issue #2（用户 caller 仓库 epic 53 跑 `/harness-zh:run` stage 1 halt）：

```
BLACKLIST=_bmad-output/implementation-artifacts/53-1-db-migration-credentials-表-agents-owner-user-id.md (**/*credentials*)
```

epic 53 主题就是「凭证管理」，4 条 backlog story 名字都含 `credentials` 子串
（`53-1-db-migration-credentials-表-...` / `53-3-agent-凭证迁移-...-credentials` /
`53-5-bff-credentials-crud-...`）→ stage 1 spec md / stage 2 源码改动 / stage 3
codex-review.md / stage 5 review-findings.json 每个阶段 commit 都被同一模式
误伤，epic 53 完全跑不通自动化。issue 由用户自己写得非常细致：root cause +
方案 A/B/C + reproduction + workaround 全列了，本版按其推荐的 A+B 组合修。

### 改动范围

- `plugins/harness-zh/scripts/harness-commit.py`：
  - **B（pattern 收窄）**: `BLACKLIST_PATTERNS` 删 `**/*credentials*`，替换为
    精确命名集合 12 条：`**/credentials`、`**/credentials.{json,yaml,yml,ini,txt}`、
    `**/*-credentials`、`**/*-credentials.{json,yaml,yml,ini}`、`**/*.credentials`。
    业务命名中段含 `credentials` 子串（如 `credentials_service.go` /
    `V53_create_credentials_table.sql` / `*-credentials-table.md`）不再误判。
  - **A（artifacts allow-list 防御层 2）**: `matches_blacklist()` 入口加守卫
    — `_bmad-output/implementation-artifacts/` 路径下后缀 md/json/yaml/yml 的
    文件直接 return None（豁免 blacklist 扫描）。未来新增宽松 pattern 也不会
    误伤 BMad 工程产物。allow-list 只覆盖 4 个 plugin 已识别的 artifact 后缀
    （与 `ARTIFACT_RE` 对齐），不过度豁免 — `.pem` / `.key` 等真凭证后缀即使
    放进 artifacts 目录也仍被原规则拦。
- `plugins/harness-zh/scripts/orchestration_observations_test.sh` 新增 T1.f13
  fixture：22 个用例覆盖 (a) issue 现场 spec/json/yaml PASS / (b) 业务源码命名
  PASS / (c) 真凭证文件 BLOCK / (d) allow-list 后缀过滤（.pem under artifacts/
  仍 BLOCK）。

### 后续注意事项

- `**/*secret*` 没列在原 BLACKLIST_PATTERNS，但同类风险存在（项目里出现 secret
  字串的合法业务命名）。本版只修了 issue 报的 credentials，secret 类未来如需
  添加 pattern，应直接走精确格式（不要再用 `*secret*` 宽 glob）。
- glob_match 的 `**` 实现存在一个**独立 bug**：fullmatch 模式下 `**/foo` 不
  匹配顶层 `foo`（顶层 `aws-credentials.json` / `.env` 当前不被拦）。本版没
  fix 它（scope creep），但留作 known limitation；用户的真凭证一般落在子目录
  （`~/.aws/credentials`、`config/credentials.yaml`），顶层文件被遗漏的实际
  风险低。后续如需修可考虑把 `**/` 前缀展开为 `(.*/)?` 而非 `.*`。
- T1.f13 覆盖 22 用例（8 PASS + 11 BLOCK + 3 边界）；retro parser fixture
  T1.f6-f12 + 本 fixture 合计 T1 共 13 条。

---

## v0.1.31 — 2026-05-28 — retro action items parser 兜底放宽 + follow-through 过滤（fixes #1）

### 触发

GitHub issue #1（用户用 `/harness-zh:report-issue` 自动提）：epic-3 retro stage 6
commit halt，第 3 个连续 epic 同样 root cause。诊断过程：

1. issue 描述说 `### 3.1`/`### 4.1`/`### 5.1` numeric headers 是禁止形态 —— 这是
   `/harness-zh:report-issue` 自动收集的**概述偏差**（取了 §三 What-went-well 的
   `### 3.1` 之类 H3 当成 Action Items 的 H3）。
2. 真实 retro `_bmad-output/.../epic-3-retro-2026-05-27.md` 实际格式：
   - §六 "Epic 2 retro Action items follow-through" —— prev-epic recap section
     （title 含 "Action items"，被旧 section detection 抢先命中，但其下表格行
     `AI-N.M (注释)` 带括号注释 → 旧 Form 2 正则 `AI-(\d+)\.(\d+)\s*\|` 不匹配）
   - §八 "Action items（行动项 — owner 统一为 solo-dev）" —— 真正的 epic 3 新增
     17 条 + §8.5 团队约定 4 条 bullets，被 section detection 跳过未 scan
3. 即使 section detection 命中 §八，§8.1-§8.4 表格用 `| AI-1.Y2 |`/`| **AI-1.X
   (二次升级)** |`/`| AI-4.X1 (升级) |` 字母后缀 sub-id + bold/paren wrap，
   旧 Form 2 正则全 0 命中 → fail-loud halt。

3 个连续 epic 都触发是因为 BMad retrospective skill 在 prompt-suffix 引导下
稳定输出这套"差不多但不全合规"的格式，老 fail-loud 哲学没让 skill 转向，每次
都靠用户手工救场。

### 改动范围

- `plugins/harness-zh/scripts/harness-commit.py` `_parse_retro_action_items`：
  - **section detection 改"取最后一个 canonical"**：增加 follow-through /
    follow up / carryover 关键字过滤，跳过 prev-epic recap section；剩余
    candidate 取 last（BMad retro 把新增 action items 放文末）。
  - **Form 2 正则放宽接受 4 种 col 1 变体**：原 `AI-(\d+)\.(\d+)` 改为
    `AI-(\d+)\.([A-Za-z]\w*|\d+)` 接受 letter+digits sub-id；前置 `\**\s*` +
    后置 `(?:\([^)\n]*\))?\s*\**` 兼容 bold wrap + 括号注释。
  - **Form 3 正则放宽接受 whole-bold 形态**：除原 `**A1** title` 外接受
    `**A1 — title**` / `**A1（title）**：rest` 4 种变体；inner/outer title 都
    剥分隔符 + 取非空者作为最终 title。
  - **Form 2/3 改为共存合并**：原"Form 2 命中即 return"改为"Form 2 + Form 3
    都跑、按 code 去重合并"。处理混合 retro 布局（§8.1-§8.4 表格 + §8.5
    bullets）的实际场景。
  - WARN 文案保留 `Form 2 (markdown table` / `Form 3 (bold inline` 老前缀
    （兼容老 fixture grep 断言）+ 追加新格式说明。
- `plugins/harness-zh/prompt-suffixes/bmad-retrospective-suffix.md` §"4. 兜底
  匹配（Form 2/3）"：补 4 种 col 1 变体 + 4 种 whole-bold 变体清单；标记
  v0.1.31 实测说明（"BMad skill 连续 3 轮稳定此格式 → 兜底已扩"）；记录
  follow-through filter + §"团队约定"跨 epic A 系列的 known limitation。
- `plugins/harness-zh/scripts/orchestration_observations_test.sh` 新增 3 条
  fixture（T1.f10 follow-through 过滤 / T1.f11 Form 2 4 变体接受 / T1.f12
  hybrid Form 2 + Form 3 合并 seed）。

### 后续注意事项

- BMad retrospective skill 的输出格式实际更接近"markdown 表格 + bullets 混合"
  而非 prompt-suffix §"Form 1 H3" canonical。retro skill 是否未来真按 Form 1
  写仍未知；v0.1.31 兜底已扩 + WARN 提示 + prompt-suffix 文档实测说明，先观察
  epic-4 / 5 retro 的实际输出。如 BMad skill 仍稳定用 Form 2/3 → 考虑把"H3
  canonical"哲学下调，把当前 Form 2 markdown 表格升为 canonical。
- §"团队约定"跨 epic A 系列（`A7`-`A10` 在 epic-3 retro，但 letter=C）当前
  作为 known limitation；如未来 retro skill 真切到 letter-strict 编码，可去
  WARN。
- T1.f10-f12 三新 fixture 增加 ~150 行测试代码，覆盖 issue #1 根因 + 兜底放宽
  + section detection 多场景；retro action items parser 现总测试覆盖度 7 条。

---

## v0.1.30 — 2026-05-27 — plugin-discovery pipeline 加 `command grep`（修复敌对 shell wrapper 环境）

### 触发

0.1.29 push 完后，用户在 Linux dev env 重跑 `/harness-zh:update`，cache 里明明有 0.1.29 plugin.json，inline bootstrap 还是 halt：

```
ERROR: 无法定位 harness-zh plugin 安装目录
```

诊断过程（另一台机器的 agent 用 `set -x` 拆出来的）：

1. `find ~/.claude/plugins/cache` 单独跑 → 4 个 manifest 全输出（codex + harness-zh 0.1.27/0.1.28/0.1.29）✓
2. 但 `find ... | while IFS= read -r manifest; do ...; done` 循环里 read 只跑了 **1 次** ✗
3. ground-truth `grep -c '"name":[[:space:]]*"harness-zh"' <manifest>` 单跑能命中 ✓ → grep 本身没坏
4. 把 `grep` trace 出来看到：`exec -a ugrep ${_cc_bin} -G ... "$@"` —— Claude Code 在那台机器上注入了 `grep` shell function wrapper

wrapper 内部逻辑（精简版）：

```bash
grep() {
    if [[ $BASHPID != $$ ]]; then
        # 已在 subshell → 省一次 fork，直接 exec 替换当前进程
        exec -a ugrep "$_cc_bin" -G ... "$@"
    else
        # 主 shell → 包一层 subshell 避免污染
        ( exec -a ugrep "$_cc_bin" -G ... "$@" )
    fi
}
```

`find | while read` 的右侧本身就是 subshell（`BASHPID != $$`），循环体里调 grep 命中第二条分支 → grep **把 while 循环所在的 subshell 进程整个 exec 替换掉了** → grep 跑完那个 subshell 就没了 → read 直接 EOF → 循环只迭代一次。

后续 `</dev/null` redirect、`< <(process-sub)` 等都救不回来，因为问题在**进程被替换**，不在数据流被偷。

### 改

**5 个 critical-path 位置 grep → command grep**（`command` 内建绕过 function lookup → 直接调真 grep 二进制）：

| 文件 | 行数 | 上下文 |
|---|---|---|
| `commands/init.md` | §A.0 2a + 2b | inline bootstrap cache + marketplaces 扫描 |
| `commands/update.md` | §1 2a + 2b | 同上 |
| `commands/upgrade-deferred-work.md` | 步骤 1 2a + 2b | 同上 |
| `scripts/discover_plugin_root.sh` | step 2 + step 3 | helper 单份 SoT |
| `scripts/collect_issue_context.sh` | line 87 + 88 | PLUGIN_VERSION 兜底扫描（issue 提单上下文收集） |

每处加注释解释 wrapper-exec 隐患 + 为什么 `command` 救场。

**未改的 `while` loops**（已扫一遍）：harness 其它 7 个 while-read 循环（`deploy_assets.sh` / `eval_test_stage_triggers.sh` / `process_retro_residue.sh` / `lint_deferred_work.sh` / `grep_prev_retro_action_items.sh` / `backfill_resolved_markers.sh` / `check_codex_availability.sh`）全部用 process-substitution `< <(...)` 喂数据，while 跑在主 shell 里，wrapper 走安全分支，**不**需要加 `command`。

### 注意事项 / 后续

- **未来新增 `find | while ... do ... grep ... done` 模式时**：必须用 `command grep`。如果改成 `while ... done < <(find ...)` process-substitution 形式也安全，但 critical-path 选择 `command grep` 不改循环结构，diff 最小。
- 没有 blanket 把所有 grep 都换 `command grep` —— 99% 的 grep 调用不在 hostile subshell 上下文里，加 `command` 是噪音。只针对 5 处真有 hazard 的关键路径。
- **wrapper 本身**：是 Claude Code 在某些 Linux dev env 上注入的（具体 trigger 条件未深查；可能是某个 shell init 钩子）。本插件不去碰它，只防御自己被坑。
- **v0.1.28 / v0.1.29 squash 考虑**：0.1.28 的硬依赖修 + 0.1.29 的 2-tier bootstrap 修 + 本版的 wrapper 修，三轮都是为了让 fresh dev env 能装上 plugin。三个 commit 都已 push，回头不 squash；版本号留作 history trail。

---

## v0.1.29 — 2026-05-27 — inline bootstrap 2-tier 化（修复 fresh dev env 上探测失败）

### 触发

用户在另一台 fresh dev env 上跑 `/harness-zh:update` 报错：

```
ERROR: 无法定位 harness-zh plugin 安装目录
```

诊断：fresh install 时 Claude Code 直接从 `~/.claude/plugins/marketplaces/<name>/plugins/<plugin>/` 路径服务 plugin，**不**复制到 `~/.claude/plugins/cache/`。但 init/update/upgrade-deferred-work 三处的 inline bootstrap 都硬卡 `[[ "$cand" == */cache/* ]] || continue`，把 marketplaces 命中给跳过 → 全 miss → halt。

`scripts/discover_plugin_root.sh` 自己 step 3 有 marketplaces fallback（注释里也写了"完整 fallback chain 由 helper 维护单份 SoT"），但 inline bootstrap 只是 helper 的简化版，丢了这层兜底。

### 改

**三处 inline bootstrap 全部改成 2-tier**（init.md §A.0 / update.md §1 / upgrade-deferred-work.md 步骤 1）：

```bash
# 2a) cache 扫描（首选 — 按 semver 降序选最高版）
find ~/.claude/plugins/cache -maxdepth 5 -name plugin.json ...
# 2b) marketplaces 兜底（fresh install / cache 未 populated）
find ~/.claude/plugins/marketplaces -maxdepth 6 -name plugin.json ...
```

关键改动：
- 移除 `[[ "$cand" == */cache/* ]] || continue` 硬过滤
- `find` 根路径从 `~/.claude/plugins` 改成具体的 `~/.claude/plugins/cache` 或 `~/.claude/plugins/marketplaces`（更明确，少一次 path filter）
- cache 仍优先（多版本时按 semver 选最新）；只有 cache 完全 miss 才走 marketplaces
- marketplaces 找到第一个命中即 `break`（fresh install 只有一份）

**`discover_plugin_root.sh` 不动** — 它的 step 3 已经有 marketplaces fallback。本次改动只对齐 inline bootstrap 与 helper 的语义。

**周边教学文本同步更新**：init.md §A.0 / update.md §1 注释从"最小 12 行 inline bootstrap"改成"2-tier inline bootstrap"。

### 注意事项 / 后续

- **用户升级路径**：先 `/plugin marketplace update my-cc-plugin` 拉新 commits，再 `/plugin update harness-zh@my-cc-plugin` 把 0.1.29 进 cache（这一步用 Claude Code 内置命令，不走我们的 bootstrap，所以 0.1.27/0.1.28 用户也能正常升级）。新版进入 cache 后 `/harness-zh:update` 就用新 bootstrap 跑。
- 0.1.28 等于本次 v0.1.29 改动**之前**的最后一版；marketplaces fallback 缺失导致 0.1.28 在 fresh env 上不可用，没人能用 /harness-zh:update 升上来 — 这是个 squash candidate，但 0.1.28 既已 push（commit `7b7ceee`），保留版本号防 cache/marketplace listing 漂移。
- 未来若 inline bootstrap 还要改：先想想是不是该把逻辑挪进 `discover_plugin_root.sh`，让 inline 部分只保留"能不能找到 helper 自己"的最小自举。

---

## v0.1.28 — 2026-05-27 — codex 改回可选依赖（解锁 codex 未装时的安装失败）

### 触发

用户反馈：`/plugin install harness-zh@my-cc-plugin` 报错 `Dependency "codex@openai-codex" is not installed`，要求用户先单独装 codex 才能装 harness。但 harness 自己已经有完整的 codex graceful-skip 通道（v0.1.27 引入 stage 3+4 pre-flight skip + `<KEY>.codex-skipped.json` marker + `/harness-zh:codex-catchup` 补跑），硬依赖与"codex 是可选增强"的设计意图直接冲突。

### 改

**`plugin.json` 摘掉硬依赖**

- 删除 `dependencies` 段（之前是 `[{ "name": "codex", "marketplace": "openai-codex", "version": "*" }]`）
- 影响：harness-zh 单独 `/plugin install` 不再报错；用户可以先用 harness，想要 stage 3+4 对抗式 review 再单独装 codex
- runtime 行为不变：`/harness-zh:run` stage 3 pre-flight 仍调 `check_codex_availability.sh`，不可用就走 skip + marker 路径

**`/harness-zh:init` 加 codex availability advisory（§A.4.d）**

- §A.4 之后、§A.5（BMad detection）之前插入一段 advisory 探测：调 `scripts/check_codex_availability.sh`，结果绑定到 `$CODEX_RESULT`
- §A.6 deployment summary 多一行 `codex (optional): <status>`：
  - `available — stage 3+4 will run normally`
  - `not installed — stage 3+4 will skip; install with /plugin marketplace add openai/codex-plugin-cc && /plugin install codex@openai-codex; then /harness-zh:codex-catchup`
- 探测**不阻 init**（codex 是 optional），只是首次装 harness 时让 solo-dev 一眼知道当前 codex 状态

**README + 顶层 versioning table 更新**

- README `### Prerequisites > #### 2. codex plugin` 标题加 `(optional — v0.1.28+)` + 改述（不再说"hard dependency blocks install"，改说"install works without it；skip+marker+catchup 路径处理 codex 缺席场景"）
- 顶层 versioning table 加 0.1.28 行；表格版本号 0.1.27 → 0.1.28

### 注意事项 / 后续

- marketplace.json + plugin.json 版本必须保持一致（v0.1.27 引入的 `release_check.sh` gate 会捕获 drift）
- 用户半路 init 现有项目 → §A.4.d advisory 也会跑（不止首次 install 场景）；想跳过可以未来加 `--skip-codex-probe` flag，但本版不实现
- `/harness-zh:codex-catchup` 命令、`check_codex_availability.sh` 脚本、`codex-skipped.json` marker 协议均**不变**

---

## v0.1.27 — 2026-05-09 — 工程化加固（codex 多轮 review 驱动）+ codex skip / catchup

### 触发

`/codex:adversarial-review` 在 v0.1.26 提交后跑了三轮，逐轮揭出工程化层面的问题：

- **Round 1 critical**：marketplace.json 版本（0.1.16）与 plugin.json（0.1.26）漂移；`/harness-zh:report-issue` 命令的 `argument-hint` frontmatter 是非法 YAML（两个相邻 flow sequence），命令可能根本装不上
- **Round 2 high**：`/harness-zh:update` 的 purge 实现是"对账整个 .claude/ 树"，会误删用户自定义 `.claude/commands/*.md` 与 personal helper 脚本（数据丢失风险）；CI 用 `KNOWN_STALE` 把多个测试静默 SKIP，新做的 schema 修改可能 silent 回归
- **新功能需求**：codex-in-cc 不可用（未装 / 配额耗尽 / 未登录）时，原协议是 halt + 等用户。改成显式跳过 stage 3+4 + 留 marker + `/harness-zh:codex-catchup` 后置补跑

### 改

**释放门禁**

- 新增 `scripts/release_check.sh`：两道闸门 — (1) marketplace.json 与 plugin.json 版本必须相等 (2) 6 个 `commands/*.md` frontmatter 必须能被 PyYAML 解析。任一失败 exit ≠ 0
- `commands/report-issue.md:3` 的 `argument-hint` 加单引号修复 YAML 解析失败
- `commands/init.md / run.md / run-test.md / update.md / upgrade-deferred-work.md / report-issue.md` 全部加 `allowed-tools` frontmatter；`update.md` / `upgrade-deferred-work.md` 补 `argument-hint`

**Manifest-based purge**（替换 v0.1.26 prototype 的 blanket diff 实现）

- `scripts/deploy_assets.sh` 每次部署后写 `.claude/harness/.deploy-manifest.txt`（本插件本次部署的文件清单）
- `DEPLOY_PURGE=1` 模式只 purge "出现在旧 manifest 但不在新 manifest" 的文件，每个删之前先备份到 `<file>.bak.<TS>`
- **从未进过 manifest 的文件永不动**：用户自定义命令 / 其他 plugin 文件 / personal helpers 都安全
- 安全网：deploy 有 FAILED → purge 整体跳过 + manifest 不被覆盖；新 manifest 为空 → 拒绝 purge；半路接入（旧项目无 manifest）→ 首次 PURGE 跳过 + 留 manifest 给以后用
- `deploy_assets.sh` 必需顶层文件（`architecture.md` / `answer-policy.md` / `changelog.md` / `test-stage-triggers.yaml`）missing 时不再静默跳过 — 通过 `deploy()` 内部的 FAILED++ 路径触发 exit 2

**Codex skip + catchup**（新功能）

- 新增 `scripts/check_codex_availability.sh`：cheap path probe，不调用 codex（不烧 quota），输出 JSON `{available, reason, binary_path, remediation}`
- 新增 `commands/codex-catchup.md`（`/harness-zh:codex-catchup`）：扫描 `_bmad-output/implementation-artifacts/*.codex-skipped.json` marker → 对每条 KEY 重跑 stage 3 + stage 4 → 归档为 `*.codex-skipped.resolved.json`
- `commands/run.md` 阶段 ③ 拆三段：
  - §③.0 pre-flight 探测（调 `check_codex_availability.sh`）
  - §③.1 skip 路径（不可用 → 写 `<KEY>.codex-skipped.json` + 显式 halt 模板风格通知 + 跳到 stage 5；触发条件 = pre-flight 命中 OR in-flight 关键词命中：`hit your limit` / `rate limit` / `usage limit` / `quota` / `not logged in` / `unauthorized` / `please log in` / `auth required`）
  - §③.2 主体（codex 可用时正常 spawn）
- `commands/run.md` 阶段 ④.0 pre-flight：检查 `<KEY>.codex-skipped.json` 是否存在；存在则 stage 4 整段跳过

**dedup + 工程清理**

- 抽 `scripts/discover_plugin_root.sh` + `scripts/deploy_assets.sh`：init / update / upgrade-deferred-work 三命令各自的 ~50 行复制粘贴块缩到 12 行 inline bootstrap + 调用共享脚本
- `scripts/harness_config.py` 加 `--get <field>` / `--config-path` CLI 模式；`read_harness_config.sh:read_harness_config_field` / `eval_test_stage_triggers.sh:read_project_field` / `check_test_harness_env.sh` 三处 inline awk parser shell-out 到 Python（保留 awk fallback 防 python3 缺失）
- 同时修 `_strip_yaml_scalar` 对 `'val' # comment` 形式的语义错误（v0.1.26 之前缺这一支处理）
- 抽 `scripts/deferred_work_schema_lib.sh`：`git-hooks/pre-commit` gate ② 与 `scripts/lint_deferred_work.sh` 共用同一份 schema regex SoT
- `harness-commit.py` + `harness-state.py` 全部 `open()` 加 `encoding="utf-8"`（CJK locale 安全）
- `harness-state.py:120` cwd 相对路径调用 → `Path(__file__).resolve().parent / "sprint-status.py"`

**测试 + CI**

- 新增 `scripts/retro_category_round_trip_test.sh`：5 fixture 集成测试，覆盖 retro_action_items category 字段的 writer→reader round-trip（防 writer 漏 `category:` 字段静默退化为 NOCAT WARN）
- 新增 `scripts/run_all_tests.sh`：中央 test runner，区分 PASS / FAIL / `KNOWN_STALE` SKIP
- 新增 `.github/workflows/ci.yml`：双 job
  - `source-tests` 跑 release_check + run_all_tests（10 个 source-tree 测试）
  - `bootstrap-tests` 用 mktemp + `deploy_assets.sh` + `install_git_hooks.sh` + 真 `_bmad-output/` seed 构造下游项目 fixture，跑 4 个 env-dependent 测试（`pre_commit_deferred_schema_test.sh` / `harness_commit_isolation_test.sh` / `simulate_clone_test.sh` / `run_retro_self_audit_test.sh`）
- bootstrap 这一道**当场抓到**了我自己 v0.1.27 改动里的一个 regression：pre-commit 的 `${VAR:-default}` fallback 因 default 含 `[0-9]{4}` 中的 `}` 被 bash 截断，regex 变成 `[0-9]{4--}` → legacy-inline-resolved fixture 静默 PASS（应 BLOCK）。不上 CI bootstrap 永远抓不到。改成显式 `if/else` 写法

**其它**

- 6 处 `bash` 脚本加 `set -o pipefail`；`read_harness_config.sh` 加 `set -o pipefail` 头
- 4 处 broken cross-reference（`run.md` / `run-test.md`）
- `plugin.json` 加 `"license": "UNLICENSED"`
- README 加 `(0.1.17–0.1.25 internal-only)` 跳号注解
- `pre_commit_deferred_schema_test.sh:16` worktree 兼容（`git rev-parse --git-path hooks/pre-commit`）

### 后续

- v0.2 候选：split harness-commit.py / harness-state.py god-object（1920 LOC / 870 LOC）
- 字段数三方对齐（architecture.md `16 字段` vs README `14 fields` vs template 注释头 `11 + 3 = 14`，实际数 19）
- README 加 troubleshooting / uninstall section

---

## v0.1.26 — 2026-05-09 — 新增 `/harness-zh:report-issue` 一键提 issue 通道；退役 `upstream-feedback.md`（Q4 第二次 supersession）

### 触发

solo-dev 反馈：v0.1.14 引入的 `upstream-feedback.md` 中转通道实际反馈到达率低 — 用户 review 文件 → 复制粘贴到 GitHub issue 创建页 → 手填 title / 标 label，5+ 步手工损耗，多数项目积累几条后就不提了。同时 plugin 缺乏"用户在使用过程中遇到 plugin 缺陷时一键反馈"的入口；halt 时只能在选项 1-5 里给出"撤回 / 续作 / 调查 / 重启 / 等修复"，没有"提 issue 让作者去修"这一档。

### 改

**新增直通管道：**

- `commands/report-issue.md` — 新 slash command `/harness-zh:report-issue`：
  - 解析 `--type bug|feature|halt|other` / `--story` / `--epic` / `--halt-stage` / `--halt-command` / `--halt-reason` 等 flag（缺什么用 `AskUserQuestion` 兜底）
  - 调 `collect_issue_context.sh` 拼好 issue body 给用户 review
  - `AskUserQuestion` 三档：Submit / Edit body first / Cancel
  - Submit 时 `gh auth status` preflight + `gh issue create --repo Niutie/my-cc-plugin --title "..." --body-file ... --label ...`
  - **halt 场景特殊行为**：提交成功后必须输出一段「临时绕过方案」（基于手里的 halt 现场给具体的 git / shell 指令），让用户不必等 plugin 修复就能继续推进项目
  - 失败兜底：gh 未装 / 未登录 / 提交失败时 emit 引导文字 + 手工 fallback（`pbcopy` + `open https://github.com/Niutie/my-cc-plugin/issues/new`）
- `scripts/collect_issue_context.sh` — best-effort 上下文采集器：
  - plugin 版本（先读 `.claude/harness/changelog.md` 顶部，缺则扫 `~/.claude/plugins/**/plugin.json` 取最高 semver）
  - 环境（OS / shell / `CLAUDE_PLUGIN_ROOT` 注入状态）
  - git 状态（branch / HEAD / dirty 行数 / 近 10 个 harness-asset commits / 近 5 个项目 commits）
  - sprint 状态（`sprint-status.py count` + `next`）
  - story 状态（如指定 `--story` 则 `harness-state.py $KEY`）
  - halt block（仅 `--halt-stage` 时拼）
  - `harness-project-config.yaml` fingerprint（仅 project_name / project_language / deferred_work_mode 三字段；privacy-conscious — 不抽路径或 org 字段）
  - 全程 best-effort，缺哪个采哪个；`yaml` / `git` / `python3` 任一缺失也能退化产出 markdown

**halt 模板植入：**

- `commands/run.md` §3 末尾的 canonical halt 模板新增**选项 6**："怀疑这是 plugin 缺陷？跑 /harness-zh:report-issue ..." — 与原有选项 0-5 并列
- `commands/run-test.md` / `commands/init.md` / `commands/update.md` / `commands/upgrade-deferred-work.md` 各自的短 halt 模板都加同一档新选项
- `commands/run.md` §2 主循环出口的"🎉 完成"报告后加一行 mild hint：跑下来如有不顺手 → 跑 `/harness-zh:report-issue`

**Q4 第二次 supersession — 退役 `upstream-feedback.md` 通道：**

- 删 `scripts/extract_harness_feedback.sh`（迁移工具，353 行）
- 删 `scripts/detect_harness_residue.sh`（残余检测器，155 行）
- 删 `templates/upstream-feedback.md.template`
- `prompt-suffixes/bmad-retrospective-suffix.md` 重写「retro action items 写入分流」段：
  - retro skill 不再分流；`category: dev` 与 `category: harness` 都写 `sprint-status.yaml.retro_action_items`
  - `category` 字段仅决定 pre-commit gate 行为：dev 阻 commit / harness 仅 stderr WARN + hint 跑 `/harness-zh:report-issue`
- `commands/init.md` §A.3.d 重写为**纯 advisory**：仅检测 sprint-status.yaml 内是否还有 v0.1.25 残余的 `category: harness` 条目；有则 emit hint 引导跑 `/harness-zh:report-issue`，**不**自动改 yaml、**不**调任何脚本。`HR_RESULT` 字段仍在 §A.6 报告中露出。
- `scripts/check_retro_action_items.sh` 对 `pending_harness > 0` 的 WARN 文本改为 hint `/harness-zh:report-issue`（不再 hint 已删的 `extract_harness_feedback.sh`）；`migrated-upstream` status enum 保留兼容（v0.1.14-0.1.25 残余视同 done，不阻不 WARN）
- `architecture.md` 〇.3 命令分工表加一行 `/harness-zh:report-issue`；§六 Q4 加 v0.1.26 supersession note；scripts 树状图 [Harness upstream-feedback 流] 一节改为 [Plugin issue 直通管道]

### 后续注意事项

- 用户首次跑 `/harness-zh:report-issue` 前需保证 `gh` CLI 已装 + `gh auth login` 完成；`gh-cli` 不像 BMad / codex 是硬依赖（plugin.json `dependencies` 不申明），保持轻量
- v0.1.14-0.1.25 期间项目侧落到磁盘的 `.claude/harness/upstream-feedback.md` 文件**不**主动删（用户私有数据；plugin 资产投递的 cmp/backup 路径里不包含此文件，`/harness-zh:update` 不会动）。用户可自行决定 archive / 删除 / 把里面剩余条目用 `/harness-zh:report-issue` 提为 issue 后再清理
- `migrated-upstream` 仍是合法 status enum 用于历史兼容；将来某个版本（v0.2+）可考虑硬移除 + 配套 migration 工具

---

## v0.1.17 – v0.1.25 — _未公开发布_

internal iteration only — squash-merged into v0.1.26 before marketplace publish；未单独打 marketplace tag、未单独投递 plugin store。版本号跳跃仅是内部迭代记账痕迹。

---

## v0.1.16 — 2026-05-07 — 修 codex adversarial review 在 v0.1.13 / v0.1.14 上发现的 3 处 control-flow / 一致性缺陷

### 触发

solo-dev 跑 `/codex:adversarial-review` 审 0.1.13 + 0.1.14 + 0.1.15 三个未 push commit。verdict = `needs-attention`，3 处缺陷可复现：

1. **[high] detector exit code 被吞** — `extract_harness_feedback.sh` 用 `$(... 2>/dev/null || true)` 包 detector 后再读 `$?`，`|| true` 让退出码恒为 0。`sprint-status.yaml` 缺失或 `retro_action_items` 块缺失时本应触发 `exit 2/3` 的路径被静默跳过，假报"已干净"。
2. **[high] upgrade-deferred-work B 档先 mv 后 cp 且 PLUGIN_ROOT 未定义** — `/harness-zh:upgrade-deferred-work` 选 B（archive+greenfield）时，文档先 `mv deferred-work.md` 到归档，再 `cp "$PLUGIN_ROOT/templates/..."` 回填新模板。但该文档未定义 `PLUGIN_ROOT` 探测逻辑（注释说"复用 update §1"但没原样列出），LLM 照搬时会因 `PLUGIN_ROOT` 空字符串导致 `cp` 失败 → 主账本 `deferred-work.md` 永久缺失。
3. **[medium] 迁移非事务化，部分失败会双追加** — `extract_harness_feedback.sh --apply` 先写 `upstream-feedback.md`，再改 `sprint-status.yaml`。若第二步失败，下次重跑 detector 仍认为同条目 unmigrated → 重复追加 UF。

### 修

**Fix #1**：`scripts/extract_harness_feedback.sh` detector 调用改用 `set +e` / `set -e` 块包，显式捕获真退出码。新增 `[ "$DETECT_EXIT" -ne 0 ]` 兜底分支处理意外退出码。fixture 测试覆盖 exit 0/2/3 三条路径。

**Fix #2**：`commands/upgrade-deferred-work.md` 选 B 改为安全六步：
1. 解析 `PLUGIN_ROOT`（同 update §1 探测：env var → cache/* → 任意 plugin.json）
2. 决定 `SOURCE_MODE`（plugin-template 优先；探测失败 → inline-fallback）
3. 算归档路径（防 collision；已存在则加时间戳后缀）
4. `mv deferred-work.md → archive`（不可逆动作）
5. 写新模板（cp 或 cat heredoc），**失败必 rollback** mv
6. 同步 `deferred_work_mode → strict`

inline fallback 模板内容直接写在步骤 5 heredoc 内（不再依赖文档别处的"参考"段；删除冗余尾注）。

**Fix #3**：`scripts/extract_harness_feedback.sh --apply` 重写为原子 + 幂等：
- 在 memory 里算好新 UF + 新 SS 内容，再走 `os.replace()` 原子写入（write `.tmp` + fsync + replace）
- 写入顺序：UF 先 / SS 后（SS-mutation 是 ack；crash 在中间不会 data loss，只可能 retry 后 dedup）
- 新增 `(epic, code)` dedup：扫现有 UF 文件中 `## From: <epic>` 段下的 `- **<code>**` bullet，已在的条目跳过 UF 追加（仍 mutate SS 翻状态）
- 异常路径清理 .tmp 残文件 + 提示用户 retry 安全

fixture 测试模拟 partial-failure（写完 UF 后回滚 SS）+ retry，验证：UF 不重复（grep -c 仍为 1）+ SS 重新翻 migrated-upstream。

### 后续注意事项

- Atomic write 在跨文件系统场景（如 `/tmp` 归档 vs 项目根 SS）会退化为 `EXDEV` — 当前实现 `.tmp` sibling 在同 fs 下，假设 SS / UF 同卷。如未来支持跨卷需改成"copy + rename"+"原 path unlink on success"。
- Fix #2 文档化的探测逻辑较长（~20 行 bash）— 后续如新增"投放空模板"路径（不止 deferred-work.md，可能 upstream-feedback.md 也需 greenfield 模式），考虑抽出 `scripts/locate_plugin_template.sh` 共享脚本。
- Codex review verdict `needs-attention` 已闭环；本 commit 后建议再跑一次 review 确认 fix 落地。

---

## v0.1.15 — 2026-05-07 — 命令 frontmatter `argument-hint` 字段：autocomplete 提示参数

### 触发

solo-dev 注意到其它 plugin（如 codex 的 `/codex:adversarial-review`）在 slash command autocomplete 菜单上显示参数提示（`[--wait|--background] [--base <ref>] ...`），harness-zh 的 5 条命令都没显示。Claude Code slash command frontmatter 支持 `argument-hint` 字段（man-page 风格 — 方括号可选 / 竖线互斥 / 尖括号占位符），加上即可。

### 修

| 命令 | argument-hint |
|---|---|
| `/harness-zh:run` | `[--story [<key>] \| --epic [<num>] \| --continue \| --dry-run]` |
| `/harness-zh:run-test` | `--story <key>` |
| `/harness-zh:init` | `[--dry-run \| --force \| --merge]` |
| `/harness-zh:update` | (无参数；省略 hint) |
| `/harness-zh:upgrade-deferred-work` | (无参数；省略 hint) |

仅改 frontmatter，不动命令正文 / 任何运行逻辑。

### 后续注意事项

无。后续新增命令记得带 `argument-hint`（无参数时省略字段，不写空字符串以免 autocomplete 显示空方框）。

---

## v0.1.14 — 2026-05-07 — retro action items category:harness 与 sprint-status 解耦 → upstream-feedback.md

### 触发

epic retro 产出的 action items 已经按 `category` 字段分流（`dev` / `harness`），`check_retro_action_items.sh` (pre-commit gate ①) 也按 category 做行为分流（dev 阻 commit，harness 仅 WARN）。但**物理位置**还都在 `_bmad-output/implementation-artifacts/sprint-status.yaml.retro_action_items`。从 plugin 用户视角：

- sprint-status.yaml 是**项目侧 artifact**（用户的项目 git 历史里），里面躺着 plugin 维护方的债（`category: harness` 那些）
- 用户感觉项目背着 plugin 自己的待办，污染 retro 视图
- harness 类条目对项目用户没有 actionable 意义（用户不可能也不该改 plugin 源码），但 `check_retro_action_items.sh` 还会反复 WARN 提示它们 pending

需要把 harness 类彻底搬出 sprint-status，落到一个独立的、专给 plugin 用户用来汇总后提 GitHub issue 的文件。

### 修

**新增 `templates/upstream-feedback.md.template`** — markdown 文件，header 含用户工作流（review → 复制提 issue → 翻 status 留 audit）+ schema 说明（每条目格式 + 5-值 status enum）。

**新增 `scripts/detect_harness_residue.sh`** — bash + python3 内联，扫 sprint-status.yaml.retro_action_items 块，找未迁移（即 status != `migrated-upstream`）的 `category: harness` 条目。stdout 单行 JSON `{count, items[]}`，含每条的 epic / code / status / inline comment（description）/ chore_spec。exit 0 健康 / 2 sprint-status 缺 / 3 retro 块缺。

**新增 `scripts/extract_harness_feedback.sh`** — 迁移工具，`--dry-run`（默认）print 预览，`--apply`：
1. bootstrap upstream-feedback.md（不存在时从 plugin templates/ 投放，fallback 内嵌 minimal header）
2. 备份 sprint-status.yaml → `.bak.<timestamp>`
3. 把 harness 条目按 epic 分组追加到 upstream-feedback.md
4. python state-machine 重写 sprint-status.yaml：把被迁条目的 `<CODE>: <status>` 行的 status 翻 `migrated-upstream`（**不**删行，保留 audit；用户可手工清掉 commented block）

**`scripts/check_retro_action_items.sh` enum 扩展** — `migrated-upstream` 加入合法 status enum；不再触发 unknown-status WARN。

**`prompt-suffixes/bmad-retrospective-suffix.md` 新增 §"retro action items 写入分流"** — 强制 retro skill 区分 `category: dev`（写 sprint-status，行为同前）vs `category: harness`（**禁止**写 sprint-status，**改写** upstream-feedback.md）。包含写入 schema、文件 bootstrap 路径、历史数据兼容指引。

**`commands/init.md` 扩展 §A.3.d** — sprint-status.yaml 存在时跑 detect_harness_residue.sh，按 count 分支：
- `count = 0` 或 sprint-status 缺 / retro 块缺 → silent / skip
- `count > 0` → emit 现状 + dry-run 预览 + AskUserQuestion 二选一：
  - **A) Migrate 现在**（推荐）— 跑 `extract_harness_feedback.sh --apply`
  - **B) 跳过** — 提示后续手工跑

§A.6 部署统计新增 `harness-residue: $HR_RESULT` 行。

### 后续注意事项

- 迁移行为是**保留式**（status 翻 `migrated-upstream`，不删行）。用户如果想完全清理 sprint-status，需手工删除 `migrated-upstream` 状态的整段（每段 4 行：CODE: status / category / chore_spec / 空行间隔）。后续可补一个 `--purge` 模式但目前不做（保留 = 安全）。
- 没改 `sprint-status.py` 渲染逻辑 — 不知道它是否会显式列 `migrated-upstream` 状态条目；如发现噪音再补 filter。
- 项目侧的"未迁残余"WARN 路径：`check_retro_action_items.sh` 看到 pending+harness 时仍 WARN（提示"快跑 extract"）；solo-dev 选择 init §A.3.d 跳过的话每次 commit 都会看到这条 WARN，是预期行为（提醒未完事）。
- 提 issue 路径目前是手工（用户 review upstream-feedback.md 后复制粘贴）。后续可补一个 `/harness-zh:export-feedback` 命令一键打包成可提 issue 的 markdown 段，但 MVP 不做。

---

## v0.1.13 — 2026-05-07 — 半路接入项目时 deferred-work.md schema 检测 + 三档迁移

### 触发

`/harness-zh:init` 假定 deferred-work.md 要么不存在（bootstrap 空模板）、要么 100% schema v1 conformant。半路接入既有项目（项目里已有大段 legacy deferred-work.md — 无 4-tag 头 / 含 inline `Resolved by Story X.Y` 后缀 / 含 `FU-RETRO-*` 命名空间）时这两个假设都不成立。具体伤害：

- pre-commit gate ② 只扫新增行，历史 legacy 条目本身**不**阻 commit — 但 dev / review / spec-author agent 在 deferred-work.md 上下文里 mimic 周围 legacy 格式写新条目时会被 gate 拒
- `grep_deferred_buckets.sh` / `grep_deferred_status.sh` / `grep_pending_deferred_for_story.sh` 三脚本只识 v1 4-tag 行，对 legacy 条目盲；§1 总账数据失真；dev agent 漏 cross-story trigger surface

不能强制要求半路接入用户先还历史债（违背"装插件就能用"的接入意图），也不能默默忽略（数据失真会复利累积）。

### 修

**新增 `scripts/detect_deferred_work_schema.sh`** — bash 入口 + python3 内联，扫 deferred-work.md 算四类计数（FU 总数 / v1 4-tag 已标 / legacy 4-tag 缺失 / legacy inline 后缀 / FU-RETRO-* 命名空间）+ v1_pct，分类成 4 档：`pristine`（无 FU）/ `v1_clean`（≥95% v1）/ `mixed`（部分 v1）/ `legacy`（0% v1）。stdout 单行 JSON，exit 0 健康路径 / 2 文件缺失。

**`templates/harness-project-config.yaml.template` 新增字段** — 顶层 `deferred_work_mode: 'strict'`（默认）；可切 `'advisory'` 表示与历史 legacy 条目共存，§1 总账按 v1-tagged 子集口径解读。pre-commit gate ② 行为不受 mode 影响（永远只校验新增行）。

**`commands/init.md` 扩展 §A.3.c** — 仅当 `DW_BOOTSTRAPPED=0`（文件 pre-existed）时进，跑 detector，按 classification 分支：
- `pristine` / `v1_clean` → silent OK，不询问
- `mixed` / `legacy` → emit 现状报告 + AskUserQuestion 三选一：
  - **A) Advisory 共存**（推荐）— 历史不动，sed yaml 设 `deferred_work_mode: 'advisory'`
  - **B) Archive + greenfield** — `mv deferred-work.md deferred-work.legacy-pre-schema-v1.md`，从 plugin 模板重新 bootstrap；mode 保持 strict
  - **C) Backfill 手工指南** — 不改文件，emit schema §5 backfill 路径；solo-dev 自己用 LLM 单批改写后重测
- `§A.6` 部署统计新增 `deferred_work_mode: ${DW_MODE_RESULT}` 行

**新增 `commands/upgrade-deferred-work.md`** — 事后入口，跑同款 detector + 三档交互。供 solo-dev 在 init 时选 advisory、后来想切回 strict、或事后手工 backfill 完想复测的场景；对 `pristine` / `v1_clean` + `mode=advisory` 自动提示切回 strict（mode 漂回路径）。

### 后续注意事项

- 本 commit **未**实现机器自动 Pass 1 backfill（schema §5 描述的 ~80% regex 抽取转换）。Backfill 仍是手工 LLM 单批 + 人工 Pass 2 兜底路径。后续 v0.2+ 可补一个 `scripts/backfill_deferred_pass1.py` 把 schema §5 Pass 1 逻辑落地，`/harness-zh:upgrade-deferred-work` 选项 C 升级为半自动。
- `grep_deferred_buckets.sh` / `grep_deferred_status.sh` / `grep_pending_deferred_for_story.sh` 当前**不**感知 mode；跑 advisory 模式时三脚本仍按 v1 子集输出，无 WARN 提示"还有 K 条 legacy 条目未计入"。这是 known gap；solo-dev 自己在脑里把"§1 总账"理解为子集就够，正式补 WARN 是 v0.2+ 的小品改。
- detector 的 `v1_pct >= 0.95` 阈值是经验值（容忍 5% 单条遗漏），如发现真实项目里 1-2 条 typo 反复触发交互可调到 0.9。

---

## v0.1.12 — 2026-05-07 — harness-commit.py / harness-state.py CJK 路径 quotepath + utf-8 decode-safe（i18n 续修）

### 触发

solo-dev 在 `~/HaiAn MCTS` 升级到 v0.1.11（CJK story key regex 修好）后跑 `/harness-zh:run`，stage 1 commit 仍 halt：

```
STATUS=halt
REASON=non-artifact path in stage 1 which forbids project code
FORBIDDEN="_bmad-output/implementation-artifacts/1-1-\345\220\216\347\253\257\345\267\245\347\250\213\350\204\232\346\211\213\346\236\266\344\270\216\345\205\254\345\205\261\345\237\272\347\241\200\350\256\276\346\226\275.md"
```

### 根因

两个独立 i18n bug，叠加发作：

1. **`git status --porcelain` / `git diff --stat` / `git ls-files` 默认 quotepath=true** — 输出对非 ASCII 路径做 C-style octal 转义并加双引号包裹（`"_bmad-output/.../1-1-\345\220..."`）。harness-commit.py 的 `classify()` 把这种带引号 + 转义的 path 拿去匹配 `<KEY>.md` artifact pattern，全数 miss，故 stage 1 把 story md 误判为"项目代码"（黑名单）→ halt。harness-state.py 三处 `git status --porcelain` + 一处 `git diff --stat` 同样路径数据全部受污染，影响 `compute_state` 的 worktree_clean / 落地清单分组 / resume prompt artifact 计数。

2. **`subprocess.run(..., text=True)` 默认 utf-8 strict 解码** — `git diff --cached --stat` 把长文件名按列宽截断展示（`...3-2-用户管理-rbac... | 12 +-`），可能在 CJK 多字节序列中段切断。strict 解码遇到孤立首字节抛 `UnicodeDecodeError`，stage 1 在 sanity-check 段崩。

CJK story key 项目（v0.1.11 修好后才暴露，因为之前 sprint-status.py 直接过滤掉看不到 story）必踩；ASCII 项目（如 Aegis）从未遇到。

### 修

集中到 `run()` helper（`harness-commit.py:1234` + `harness-state.py:79`），双 fix 一并注入：

```python
def run(cmd):
    if cmd and cmd[0] == "git" and (len(cmd) < 3 or cmd[1] != "-c" or not cmd[2].startswith("core.quotepath")):
        cmd = ["git", "-c", "core.quotepath=false"] + list(cmd[1:])
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace", check=False)
```

- (a) 幂等检测后 `-c core.quotepath=false` 注入；所有 git 子调用统吃（status / diff / ls-files / log / rev-parse 全部）
- (b) `errors="replace"` 让 stat 截断的半个 UTF-8 字节降级成 U+FFFD 替换符，不阻流；stat 输出本就是人类摘要，replacement char 无害

`git-hooks/pre-commit` 同时加 `GIT="git -c core.quotepath=false"` 别名，gate ① / ② 防御性挂上（当前 trigger 都是 ASCII 不直接出问题，但任何未来 CJK 命名的 retro 文件 `4-X-中文复盘.md` 会立即踩坑——零成本补丁）。

附带 ship `templates/deferred-work.md.template` + init §A.3.b 投放——`_bmad-output/implementation-artifacts/` 父目录存在但 `deferred-work.md` 不存在时从 template cp 一份。消除 main agent 凭印象造非 schema-v1 placeholder 被 gate ② 拒的整类问题（典型症状：用 `[severity:medium]` 这种废弃 tag）。

### 验证

`run()` helper 单测：注入 git 子调用 + 不重复注入已设的 `-c core.quotepath=...` + 不动 non-git 命令；`errors='replace'` 实际下沉到 subprocess kwargs。

```
PASS: quotepath injection works for git, idempotent, skips non-git
PASS: run() now passes errors=replace + quotepath
```

CJK 路径 stage 1 实跑（在 HaiAn MCTS 项目 hotfix 版上验证过）：commit 通过、artifact 正确分类、stat 截断不再崩。

### 注意

- 这是 v0.1.11 i18n 修复的续集——sprint-status 解 CJK key 后，下游 git path I/O 是第二层雷。已审计 plugin 内全部 `subprocess.run(["git", ...])` 调用（harness-commit.py / harness-state.py 各一处 helper 集中托底；harness_config.py、sprint-status.py 等其他脚本不直接 shell out 到 git，无关）。短期内应该排完了。
- `git-hooks/pre-commit` 的 `GIT="git -c ..."` 是 bash 字符串展开模式，不是 array — 当前所有调用都是裸的 `$GIT diff ...` 形式，无 quoting 边界问题；如未来加更复杂 hook gate 用到含空格参数，记得切 array `GIT=(git -c core.quotepath=false)` + `"${GIT[@]}"`。
- 升级后请检查项目侧 `.claude/harness/scripts/` 是否有手工 hotfix（`.claude/` 通常 gitignored）；`/harness-zh:update` 会备份成 `.bak.<TS>` 再覆盖，diff 确认 plugin 新版语义覆盖了 hotfix 之后再清 .bak。

Bump 0.1.11 → 0.1.12。

---

## v0.1.11 — 2026-05-07 — sprint-status.py CJK story key 解析（i18n 真 bug 修复）

### 触发

solo-dev 在 `~/HaiAn MCTS` 跑 `/harness-zh:run --epic 1`，启动时 `python3 sprint-status.py count` 返回 `0/0`、`next` 退出 1，但 `_bmad-output/implementation-artifacts/sprint-status.yaml` 实际有 80+ 条 backlog story。

### 根因

`sprint-status.py:61` 的 `STORY_KEY_RE` 正则 `^\s+([A-Za-z0-9_\-]+):\s*(\S+)\s*(?:#.*)?$` 写死 ASCII 字符集，但 BMad 中文模式（用户配置 `communication_language: Chinese / document_output_language: Chinese`）产出的 story key 全是 CJK 短语：

```yaml
development_status:
  epic-1: backlog
  1-1-后端工程脚手架与公共基础设施: backlog        ← 不匹配 ASCII regex
  1-2-前端工程脚手架-主题-token-与全局布局: backlog ← 同上
  ...
```

整个 80+ 条 story 被静默过滤，count→0/0 / next→exit1 / epic-of/find-by-status 等所有 sprint-status.py 命令链路全失效。

`harness-state.py` 通过 `python3 sprint-status.py status <key>` shell out 读状态，连带受影响。`harness-commit.py` 等其他脚本用 `re.escape(key)` 处理 key，无 ASCII 假设，未受影响。

### 修

`scripts/sprint-status.py:61` 把 `[A-Za-z0-9_\-]+` 替换成 `[^\s:#]+`（接受任何非空白/非冒号/非注释起点字符 — yaml 语法本就禁止 unquoted mapping key 含这三类，CJK / accents / 任何 Unicode 自动通过）：

```python
STORY_KEY_RE = re.compile(r"^\s+([^\s:#]+):\s*(\S+)\s*(?:#.*)?$")
```

加注释解释为什么用否定字符类（yaml 语法约束 + i18n 友好）。整个 regex 仍只在 `development_status:` 块内匹配（`_iter_dev_status` 的 `in_block` 状态机不变），不会误吃 yaml 其他段（如 `retro_action_items.<code>.status`）。

### 验证

复制修过的脚本到 HaiAn MCTS 项目侧 `.claude/harness/scripts/sprint-status.py`，重跑：

| 命令 | 修前 | 修后 |
|---|---|---|
| `count` | `0/0`（全过滤） | `62/62` ✓ |
| `next` | exit 1 | `1-1-后端工程脚手架与公共基础设施` exit 0 ✓ |
| `epic-of <CJK key>` | `key 不是合法 story key` | `1` ✓ |

### 注意

这是 harness 第一个 i18n 真 bug。原 Aegis 项目用英文 story key（`5-9-forensic-evidence-destroy-workflow-dual-control` 这种），从未踩过这个坑。BMad 中文产出场景属于 plugin 化后扩大用户群带来的覆盖面变化，未来类似 ASCII 假设需逐个排雷（已审计 harness-commit.py / harness-state.py 无此问题；其他 .sh / .py 脚本的 regex 多数针对 chore filename / action item code 等 design-by-letter 场景，非 user-data，无需修）。

Bump 0.1.10 → 0.1.11。

---

## v0.1.10 — 2026-05-06 — Orphaned cache 过滤 + §A.5 单一权威源化（修 LLM hallucinate "需要 split form"）

### 触发

solo-dev 在 `~/HaiAn MCTS`（prd.md ✓ + architecture.md 单文件 ✓ + sprint-status.yaml ✓）跑 v0.1.9 `/harness-zh:init`，**直接跑 helper 脚本** `bash run_sprint_init_check_prereq.sh` 输出 `all_present: true exit 0`，但 LLM **没真跑 helper**，自己按 §A.5 inline bash 字面意义 + §A.7 文案历史模式 hallucinate "需要 split 成 architecture/tech-stack.md + repo-structure.md"，错误进 BMAD_READY=0 早结束。

同时报告中提到：§A.0 plugin 路径探测命中了 orphaned 0.1.2 缓存目录（带 `.orphaned_at` marker），LLM 从 stale 副本部署了 0.1.2 内容 — 需要手动切到 0.1.9 活跃路径。

### 根因

1. **§A.0 探测漏洞**：`find` + `plugin.json` 扫描没有过滤 Claude Code 在版本切换时留下的 `.orphaned_at` 标记目录，"命中即用"会拿到 stale 内容
2. **§A.5 双源结构**：表格 + inline bash 同时存在，LLM 倾向于按"自己理解"判断而不实际执行 bash → 字面读了"3 必需 + 1 可选"但 hallucinate 出"sharded form 是真正的 well-known"

### 修

#### §A.0 加 orphaned 过滤

`commands/init.md` §A.0 plugin 路径探测两处（cache 优先 + fallback）都加 `[ -f "$candidate/.orphaned_at" ] && continue`，跳过 stale 副本。Cache 目录可能同时存在多个版本（如 0.1.0 + 0.1.2 + 0.1.7 + 0.1.9），其中只有最新一个无 marker；探测器现在自动跳过历史版本。

#### §A.5 重构为"helper 是单一权威源"

之前 §A.5 既有"接受形式"表格又有 inline bash detection — LLM 容易"演奏"bash（按语义分析而不实际跑）。改成：

- §A.5 顶部明确 **"调 helper 脚本，按 exit code + JSON 决定流程"**
- 删 inline bash detection（不再是"参考实现"，避免 LLM 误用）
- 表格降级为"供理解的 reference"，明确 **"绝对不要用此表自己重写检测，调 helper 即可"**
- 加 HELPER_EXIT → BMAD_READY 映射表（0/2/3/其他）
- §A.7 早结束文案改成 `$HELPER_GUIDANCE`（直接贴 helper 的 stderr 引导段），不再重写

### 注意

- helper 脚本 `run_sprint_init_check_prereq.sh` 本身从 v0.1.8 起就 dual-form 正确；v0.1.10 是把 init.md §A.5 / §A.7 也对齐到"helper 唯一权威"模型，避免 LLM 绕过 helper 自己 hallucinate
- HaiAn MCTS 实测 helper 输出：`{"all_present": true, "missing_planning": [], "missing_sprint_status": false, "optional_missing": ["product-brief*.md (可选 — 缺则字段 1/15 从 prd.md 兜底)"]}` exit 0 — 应该进 §0+ 字段提取（product-brief 缺仅 WARN）

---

## v0.1.9 — 2026-05-06 — 跨整个 plugin tree 全量审计 dual-form (sharded / 单文件) 兼容性

### 触发

solo-dev 提醒"prd / ux-design / architecture 都存在分片和不分片，都兼容了吗"。v0.1.3-v0.1.8 已修 §A.5 detection + §2 字段表 + helper script，但全量审计发现还有几处遗漏。

### 全量审计结果

| 文件 | 引用 BMad sharded 路径？ | 修法 |
|---|---|---|
| `commands/init.md` §A.5 | ✓ 已 dual-form（v0.1.3-v0.1.8） | — |
| `commands/init.md` §2 字段表 | ✓ 已 dual-form（前 6 行；后续行 LLM 按表前置说明 fallback） | — |
| `scripts/run_sprint_init_check_prereq.sh` | ✓ 已 dual-form（v0.1.8） | — |
| `architecture.md` §十一 (plugin 设计文档) | ✗ MUST-EXIST 表 + 字段 mapping 表都写 sharded 形式为唯一 | **修：表格扩成 dual-form；加 ux-design / epics 未引用的说明段** |
| `scripts/run_retro_self_audit.sh` | ✗ 6 处 hardcode sharded 子文件路径（A5/A8/B4/B9/C2/C6） | **修：加 `find_bmad_doc` helper + 6 处替换** |
| `scripts/run_sprint_init_test.sh` | ✗ test fixture 用 sharded + assert product-brief MUST-EXIST | 暂留（脚本是 self-test，用户不跑；下版本统一更新） |
| `prompt-templates/data-visibility-review-template.md` | ⚠️ 引用 sharded 子文件 | 暂留（template 是项目特定，clone 时 solo-dev 自决） |

### ux-design 和 epics

`grep -r 'ux-design\|epics'` 在 plugin 任何运行时文件（commands/scripts/prompt-suffixes/templates）**均无命中**。harness-zh 当前不读 ux-design / epics 任何形式（信息从 sprint-status.yaml + prd.md + architecture.md 间接获取）。所以"兼容 vs 不兼容"对 ux-design / epics 无意义。

将来若加 hard ref（比如 story creation 注入 UX 上下文），需同步在 §A.5 加可选检测 + §2 加字段映射 + 用 `find_bmad_doc` 风格 helper。本版只在 architecture.md §十一 加说明段记录这个决策。

### 修

| 位置 | 改动 |
|---|---|
| `architecture.md` §十一 prereq gate 表 | 4 行 hardcoded MUST-EXIST → 4 行概念产物（必需/可选 + 单文件/sharded 接受形式） |
| `architecture.md` §十一 14 字段 mapping 表 | source 列加"或 architecture.md §section"形式作单文件 channel；加表头说明 |
| `architecture.md` §十一 加说明段 | ux-design / epics 当前未引用；如未来加引用需走同样的 dual-form pattern |
| `scripts/run_retro_self_audit.sh` | 加 `find_bmad_doc` helper（顶部，sharded → 单文件 fallback 的通用解析器）；6 处 check 函数（check_A5 / A8 / B4 / B9 / C2 / C6）替换 hardcode 路径为 helper 调用 |

### 注意

- `find_bmad_doc` 单文件回退是近似（grep 跨整个父文件而非仅章节），但 retro audit grep 模式都很特异（"NFR52 baseline" / "RBAC 业务层数据可见性收敛 pattern" 等），跨章节假阳性风险低
- `run_retro_self_audit.sh` 头部 banner 已标 PROJECT-SPECIFIC（A1..C12 是 Aegis 实际 retro action items），新项目本就要重写 check 函数体；本版只是把"如果你保留这套 scaffolding 但项目用单文件 BMad"场景从 silent 失效升级为正确兼容

---

## v0.1.8 — 2026-05-06 — product-brief 降级可选 + 单文件 architecture.md 表述清晰化

### 触发

solo-dev 在 `~/HaiAn MCTS`（已跑过 BMad，有 prd.md + architecture.md 单文件 + sprint-status.yaml）跑 `/harness-zh:init`，被错报"BMad 未齐"早结束：

1. **product-brief.md 误判**：项目没跑过 `/bmad-product-brief`（BMad 上游 product-brief 本就是可选环节），但我把它列为 MUST-EXIST hard fail，导致 BMAD_READY=0
2. **architecture.md 单文件 LLM 误读**：spec 里写"单文件或 sharded 都接受"，但 LLM 仍报告"需要 split form" —— spec 表述偏 sharded 形式作为"主选"，单文件作为"fallback"，措辞误导

### 修

#### product-brief 降级为可选

`commands/init.md` §A.5 + `scripts/run_sprint_init_check_prereq.sh`：

- product-brief 从 MUST-EXIST 移到 NICE-TO-HAVE 类别
- 缺失只进 `OPTIONAL_MISSING` 数组（WARN 不 fail），不影响 BMAD_READY
- helper JSON 输出加 `optional_missing` 字段
- §A.7 早结束文案分两段：【必需缺失】（阻流）+【可选缺失】（仅信息）
- §2 字段 1（project_display_name）已有"product-brief.md 或 prd.md"双源，缺 product-brief 自然 fallback 到 prd.md 提取项目名

#### 单文件 vs sharded 表述对等

`commands/init.md` §A.5 表 + §2 字段表前置说明：

- 明确写 "**单文件 / sharded 是 BMad 上游的两种合法布局**"（不是"主选/次选"）
- §2 表前置说明加粗 "**两种形式都是一等公民，没有'主选'和'次选'之分**"
- 单文件读取协议：用 Read 读全文按章节标题（"Tech Stack" / "Repo Structure" / "NFRs" / "i18n" / "Proxy" / "Testing Strategy"）grep 段落
- BMad 默认产单文件（不跑 `/bmad-shard-doc` 就一直是单文件） — 这是 majority case，要求 split 等于强迫用户额外动作

### 注意

升到 v0.1.8 后跑 init 在 `~/HaiAn MCTS` 应该能进 §0+ 字段提取（3 必需都齐：prd ✓ architecture ✓ sprint-status ✓；product-brief 缺会 WARN 但不阻）。

---

## v0.1.7 — 2026-05-06 — §A.4 git hook 安装加非 git 仓库自适应（AskUserQuestion 半自动 init）

### 触发

solo-dev 在 `~/plugin-test`（非 git 目录）跑 `/harness-zh:init`，§A.4 install_git_hooks.sh 退出 128 (fatal: not a git repository)，被 LLM 智能降级为 WARN 通过。但 solo-dev 反馈"是不是也需要自动帮忙 init 一下"。

### 设计权衡

`git init` 完全无脑自动有 4 类 case 需要处理：

| 场景 | 自动 init 是否安全 |
|---|---|
| 已在 git 仓库（含 parent 有 .git/ 的子目录） | N/A — 不该 init |
| 干净空目录 / 全新项目 | ✓ 合理 |
| solo-dev 错进了 scratch 目录 | ✗ 不该悄悄 init |
| 嵌套 — parent 已是 git 仓库 | ✗ 嵌套 repo 是 anti-pattern |

直接 silent auto-init blast radius 不为零（场景 3、4），不能这么做。

### 修

`commands/init.md` §A.4 重构成 3 个分支：

- **§A.4.a** `git rev-parse --is-inside-work-tree` 退出 0（已在 git 工作树）→ 直接装 hook（与 v0.1.6 行为相同）
- **§A.4.b** 退出非 0（不在任何 git 仓库内）→ 用 `AskUserQuestion` 询问 solo-dev：
  - 选 Yes → `git init` + 装 hook
  - 选 No → WARN 跳过，提示"手工 git init 后跑 install_git_hooks.sh"
- **§A.4.c** paranoia 防护：嵌套 repo 触发不该出现的状态时 halt

### 注意

- `git rev-parse --is-inside-work-tree` 检测同时覆盖 "当前目录是 repo 根" + "当前目录是 repo 子目录"；不需要单独 check parent
- AskUserQuestion 是 LLM 调用的 tool，markdown command 直接 instruct LLM 调用即可（不需要 interactive shell）
- 选 No 时退出码 0（成功），仅 WARN — 与现有"hook 装失败不阻断主流程"原则一致

---

## v0.1.6 — 2026-05-06 — BMad 安装文档基于实测更新（5 模块 + 66 skills + 4 输出目录）

### 触发

solo-dev 在 `~/HaiAn MCTS` 跑了一遍 `npx bmad-method install` 把实际交互流程贴回来。对照之前的 README + helper 文案，发现几处不准：

1. **模块数从 4 改 5** — agent 调研漏了 `BMad Core` 模块（v6.6.0），它跟 BMM 是分开的两个模块（`_bmad/core/config.yaml` + `_bmad/bmm/config.yaml`）。`--modules bmm,bmb,tea,cis` 漏 core，应该是 `core,bmm,bmb,cis,tea`。
2. **Skills 数从"~30"改"~66"** — 实测 `claude-code configured: 66 skills → .claude/skills`。
3. **输出目录有 4 个**（不是 2 个） — installer 实际创建：
   - `_bmad-output/planning-artifacts/`
   - `_bmad-output/implementation-artifacts/`
   - `_bmad-output/test-artifacts/`（TEA 模块产物落点 — 之前没提）
   - `docs/`（project knowledge）
4. **legacy 提醒** — installer 检测旧 `~/.codex/prompts/bmad-*.md` 并打印 `rm -rf` 清理命令；README 加一段说明。
5. **模块版本号** — README 里加版本快照（BMM v6.6.0 / BMB v1.7.0 / CIS v0.2.0（早期）/ TEA v1.15.1）。
6. **non-interactive 安装命令** — `--directory` + `--yes` flag 加上才能跑 CI 模式。

### 修

| 位置 | 改动 |
|---|---|
| `README.md` BMad 段模块表 | 4 → 5 模块；加 BMad Core 行（v6.6.0）；CIS 标早期版本 v0.2 |
| `README.md` install 段 | 重写：重点放在**交互式安装的提示与默认回答对照表**（用户实测的 8 个交互 prompt 逐条列出推荐回答）；非交互式版降级为附加的"一键脚本"（CI 用）|
| `README.md` 删 legacy 清理段 | 老版 BMad 残留是 BMad installer 自己提示用户清理的事，与 harness-zh 无关，删 |
| `commands/init.md` §A.7 早结束文案 | install 命令同步：`npx bmad-method install` 主推；非交互一键脚本作 alt |
| `scripts/run_sprint_init_check_prereq.sh` stderr footer | 同上 |

### 注意

- 交互安装时**必须选 Claude Code 作为 integration**，否则 skills 不会写到 `.claude/skills/`，harness-zh 后续 `/bmad-*` 命令调度会失败
- CIS v0.2.0 是 early 版本（README 标"early"），ABI 可能未稳定；harness-zh 当前不依赖 CIS 命令（主要 brainstorming / 设计思维类，非 sprint loop 必需），降级为 Recommended 而非 Required

---

## v0.1.5 — 2026-05-06 — 删除多余的 `/bmad:workflow-init` 引导

### 触发

solo-dev 质疑 v0.1.3 / v0.1.4 文案里 "首次装完 BMad 还要跑 `/bmad:workflow-init` 来初始化 `_bmad/` 配置目录"这句话的必要性。

### 根因

v0.1.3 调研时 agent 看到 `/bmad:workflow-init` 命令描述写"executing Workflow Init command to initialize BMAD Method in the current project"，**字面**理解为"装完后首次必跑"。但实际核实（Aegis 项目侧 `_bmad/bmm/config.yaml` 头部注释 "Generated by BMAD installer / Version: 6.6.0 / Date: ..."）：

- `_bmad/` 配置目录是 **`npx bmad-method install` 自己生成的**（installer 内部脚本写）
- Aegis 没单独跑过 `/bmad:workflow-init`，BMad 命令照常工作
- `/bmad:workflow-init` 这个命令大概是给"项目已有 BMad skills 但缺 `_bmad/` 配置"的特殊场景用（如 clone 了别人项目但没 install 过），**不是**标准流程必要步骤

### 修

| 位置 | 改动 |
|---|---|
| `commands/init.md` §A.7 早结束文案 | 删 `/bmad:workflow-init` 行；改成"installer 会自动建 _bmad/ 配置目录，无需额外 init 步骤" |
| `scripts/run_sprint_init_check_prereq.sh` stderr footer | 同上 |
| `README.md` BMad install 段 | 删 workflow-init 子节；明确 installer 自动建配置 |

### 注意

如果 solo-dev 实际遇到 "BMad not initialized" 类错误（罕见 — 通常只在 clone/copy 项目但没 install 时），手动跑 `/bmad:workflow-init` 仍是有效兜底；但**不是**标准首次流程。

---

## v0.1.4 — 2026-05-06 — BMad 命令名改回 hyphen 形式（修 v0.1.3 过激改动）

### 触发

solo-dev 反馈 v0.1.3 把所有 BMad 命令改成 colon 形式（`/bmad:prd` 等）"好像不对" —— 实际 hyphen 形式（`/bmad-create-prd`）和 colon 形式（`/bmad:prd`）在用户环境**都存在且都可用**，他**通常用 hyphen**。

### 根因

v0.1.3 调研时 agent 报告 "上游用纯冒号"，但只看了 BMad 上游 README 的 docs 描述，没核实**实际装到本地后的命令注册**。两形式同时存在的实情：

- **hyphen 形式**（`/bmad-<name>`）= 直接对应 `.claude/skills/bmad-<name>/` 的 skill 名（`npx bmad-method install --tools claude-code` 写的就是这种）
- **colon 形式**（`/bmad:<name>`）= BMad workflow 别名 / namespace 命令；多数 PM 命令同时注册两种
- 部分命令名形式不同（`/bmad-create-prd` vs `/bmad:prd`、`/bmad-create-architecture` vs `/bmad:architecture` —— hyphen 带 "create-" 前缀，colon 没有）
- 较新 / meta 命令（`/bmad:workflow-init`、`/bmad:research`、`/bmad:tech-spec`、`/bmad:brainstorm`、`/bmad:create-workflow` 等）**仅** colon 形式

### 修

| 位置 | 改动 |
|---|---|
| `commands/init.md` §A.5 表格"来源命令"列 | colon → hyphen + 加两形式等价说明段 |
| `commands/init.md` §A.5 detection 块的 MISSING_LABELS hint | colon → hyphen |
| `commands/init.md` §A.7 早结束文案 | 4 个 PM 命令改 hyphen + 加 "命令名也可写 /bmad:xxx" 说明；保留 `/bmad:workflow-init` 标注"只有冒号形式" |
| `commands/init.md` §1 描述 | 同步 |
| `scripts/run_sprint_init_check_prereq.sh` MISSING_GUIDANCE 数组 | colon → hyphen；末尾 stderr 加两形式等价注脚 |
| `README.md` BMad 段命令清单 | colon → hyphen + 一行说明 colon 别名也可 |

### 注意

§A.5 表格"来源命令"列示例（修后）：
- product-brief → `/bmad-product-brief`
- prd → `/bmad-create-prd`（注意 hyphen 形式带 "create-" 前缀）
- architecture → `/bmad-create-architecture`（同上）
- sprint-planning → `/bmad-sprint-planning`

未来若 solo-dev 改习惯 colon 形式，重跑一次本档全局 sed 即可。

---

## v0.1.3 — 2026-05-06 — 对齐 BMad-METHOD 上游（命令名 + 路径）

### 触发

`/harness-zh:init` 早结束文案里硬编码了：

- `/bmad-product-brief`（连字符 — 旧命令命名约定）
- `_bmad-output/planning-artifacts/architecture/tech-stack.md` + `repo-structure.md`（sharded 路径）
- 跑 BMad install 没指引

但 BMad-METHOD 上游（github.com/bmad-code-org/BMAD-METHOD）当前实际：

- 命令统一冒号形式：`/bmad:product-brief` / `/bmad:prd` / `/bmad:architecture` 等
- architecture 默认产**单文件** `architecture.md`（含 tech-stack / repo-structure / nfrs / i18n / proxy 等章节）；只有跑过 `/bmad:shard-doc` 才切片到 subdir
- product-brief 文件名带项目后缀（`product-brief-{project_name}.md`）
- 5 模块：BMM / BMB / TEA / CIS / BMGD，前 4 个 harness-zh 都用得上，BMGD（game dev）不需要
- 装法：`npx bmad-method install --modules bmm,bmb,tea,cis --tools claude-code` + `/bmad:workflow-init`

### 修

| 位置 | 改动 |
|---|---|
| `commands/init.md` §A.5 | 检测改"4 类概念产物，单文件或 sharded 任一形式接受"；MISSING 列表精简到产物级别（不逐文件） |
| `commands/init.md` §A.7 早结束文案 | `/bmad-` → `/bmad:`；产物路径用单文件名（默认形式）；加 `npx bmad-method install` + `/bmad:workflow-init` 引导 |
| `commands/init.md` §1 描述 + MUST-EXIST 文本清单 | 同步上述变化 |
| `commands/init.md` §2 字段提取表 | 加前置说明（"sharded 路径优先 → fallback 读单文件章节"）；前 6 行 source 列加"或 architecture.md §section"备选 |
| `scripts/run_sprint_init_check_prereq.sh` | PLANNING_CHECKS 数组 → 4 个内联 if-else 块（支持 glob / 单文件 OR sharded 目录）；GUIDANCE 命令名全冒号；末尾加"首次使用 BMad" install + workflow-init 提示 |
| `README.md` BMad prereq 段 | 增加 5 模块对照表（BMGD 标 "Skip"）；改 install 命令为 `npx bmad-method install --modules bmm,bmb,tea,cis --tools claude-code`；增加 `/bmad:workflow-init` 首次步骤 |

### 注意

§2 字段提取表只更新了前 6 行的 source 列（加 "或 architecture.md §section" 备选）；后 10 行（i18n / nfrs / proxy / project_context / fullstack_review_steps）仍按 sharded 路径写但 LLM 在 §2 跑提取时会按表前的"sharded 优先 → fallback 单文件章节"自适应，不阻流。

---

## v0.1.2 — 2026-05-06 — 跨 marketplace 依赖语法修复

### 触发场景

solo-dev 跑 `/plugin install harness-zh@my-cc-plugin` 报错：

> Plugin "harness-zh@my-cc-plugin" is already installed — 1 dependency still unresolved: codex@my-cc-plugin.

### 根因

`plugin.json` 的 `dependencies` 用了 `{name: "codex", version: "*"}` 简写。Claude Code 默认把 `{name: "codex"}` 解析为 `codex@<当前 marketplace>` —— 即 `codex@my-cc-plugin`。但 codex 实际在 `openai-codex` marketplace，my-cc-plugin 里没有 codex plugin，所以 dep 永远 unresolved。

### 修法

**plugin.json** 用对象格式显式指定 marketplace：

```json
"dependencies": [
  { "name": "codex", "marketplace": "openai-codex", "version": "*" }
]
```

**marketplace.json** 加白名单（跨 marketplace 依赖默认禁，必须根 marketplace 显式 opt-in）：

```json
"allowCrossMarketplaceDependenciesOn": ["openai-codex"]
```

### 注意

用户装 harness-zh 前必须已 `claude plugin marketplace add openai/codex-plugin-cc`（让 Claude Code 知道 openai-codex marketplace 存在）。README 已列为前置；此处用 plugin.json 硬声明做兜底（自动检查 / 报错引导）。

---

## v0.1.1 — 2026-05-06 — PLUGIN_ROOT 探测修复（首次装载暴露的 bug）

1 commit（`38c799b`）：

- **`38c799b`** — `/harness-zh:init` §A.0 + `/harness-zh:update` §1 的 fallback 探测改用 `plugin.json` 扫描，替代失效的 `find -name harness-zh`

### 触发场景

solo-dev 首次在 `~/plugin-test` 跑 `/plugin install harness-zh@my-cc-plugin` 后，未跑 `/harness-zh:init`（先误以为 install 会自动部署）。但更深一层 bug：即便跑 init，§A.0 的 `find ~/.claude -type d -name harness-zh` fallback 在 Claude Code **实际**的安装布局下找到的是版本子目录的**父级**（`~/.claude/plugins/cache/my-cc-plugin/harness-zh/`），里面没 commands/ scripts/ 等 — 实际文件在 `harness-zh/0.1.0/` 下。

### 修法

两遍扫 `plugin.json`：
1. 第一遍优先 `cache/<marketplace>/<plugin>/<version>/`（官方版本化安装路径）
2. 第二遍 fallback 到任意命中（含 `marketplaces/<...>/plugins/<plugin>/` git-clone 副本）

匹配条件：plugin.json 内含 `"name": "harness-zh"`。

### 验证

在 zhenhua 实际安装路径上跑通 — 解析到 `/Users/zhenhuazhu/.claude/plugins/cache/my-cc-plugin/harness-zh/0.1.0`，含 commands/ 和 41 个 scripts。

---

## v0.1.0 — 2026-05-06 — 初始 plugin 提取

5 commits（commit `65148b1` → `2f782ae`）：

- **`65148b1`** — 把 Aegis 项目的 `.claude/harness/` + `.claude/commands/` 全量 copy 到 `my-cc-plugin/plugins/harness/`，加 `marketplace.json` + `plugin.json`（v0.1.0 scaffolding）
- **`0d82f82`** — 重命名 plugin 命名空间 `harness` → `harness-zh`（避通用名冲突）；commands 文件 reshuffle：
  - `run-sprint.md` → `run.md` (`/harness-zh:run`)
  - `run-test-sprint.md` → `run-test.md` (`/harness-zh:run-test`)
  - `run-sprint-init.md` → `init.md` (`/harness-zh:init`)
- **`6fd3a4e`** — `/harness-zh:init` 头部加 §A Plugin Asset Deployment 段：
  - §A.0 探测 `${CLAUDE_PLUGIN_ROOT}` / `find ~/.claude` fallback
  - §A.1-§A.2 mkdir + cmp/backup/overwrite 资产部署
  - §A.3 仅当不存在时投放 `harness-project-config.yaml`
  - §A.4 跑 `install_git_hooks.sh`
  - §A.5 BMad artifacts 检测 → 决定是否进 §0+ 字段提取
  - 新增 `/harness-zh:update` 命令（仅刷资产，不动 yaml，不跑 BMad 提取）
- **`1662600`** — `harness-project-config.yaml.template` 全清空（让 init merge 模式能填）+ 修漏掉的 `.yaml.template` sed（前一次重命名 find 过滤只匹配 `.yaml`）
- **`2f782ae`** — `/init` §A.2 + `/update` §3 用 `find` + process substitution 替代 `shopt -s nullglob` + glob（兼容 zsh — 不会因空子目录在默认 NOMATCH 下中止脚本）

### 设计要点

- **Plugin 是 asset deployer，不是 runtime container**：runtime 仍用 `.claude/harness/` project-resident 路径，因为：
  - git pre-commit hooks 在 git 上下文跑（非 Claude Code），`${CLAUDE_PLUGIN_ROOT}` 不可用
  - markdown commands 的 bash 块（per Anthropic docs）不保证注入 `${CLAUDE_PLUGIN_ROOT}`
  - 强行用 plugin-internal 路径会撞这两道墙
- **Asset deployment 幂等**：cmp 比较内容；相同 unchanged，不同 backup → overwrite（沿用 `install_git_hooks.sh` 模式）
- **yaml 永不被资产投递覆盖**：保 solo-dev 已填的 14 字段配置；只在缺失时从 template 投放
- **BMad ready 分叉**：init §A.5 检测 `_bmad-output/planning-artifacts/{product-brief,prd,architecture/{tech-stack,repo-structure}}.md` + `_bmad-output/implementation-artifacts/sprint-status.yaml` 都齐 → 进 §0+ 字段提取；缺则早结束 + 引导用户跑 BMad workflow

### 已知约束 / 待验证

- **依赖 `codex` plugin**（plugin.json 已声明）；缺则 Claude Code 装 harness-zh 时 halt
- **依赖 BMad workflow toolset**（**未声明 plugin dep**，因为 BMad 在多数环境是项目 `.claude/skills/bmad-*` 形式而非 plugin）；README 列为前置要求
- **未做真实 Claude Code 装载测试**：`/plugin marketplace add` + `/plugin install` + `/harness-zh:init` 端到端验证待 solo-dev 在干净项目跑
- **smoke-tested**：§A 部署逻辑在 zsh 临时目录跑通三轮（fresh / 幂等 / drift 恢复），含空子目录边界场景
