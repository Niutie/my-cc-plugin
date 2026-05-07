# harness-zh changelog

每次对 harness-zh plugin 的改动在这里追加一条记录。**新条目放最上面**。每条包含：

- 版本号 + 日期 + commit hash 段
- 改动范围（plugin 文件 / 段）
- 改动动机
- 后续注意事项 / 待办

> **历史接续说明**：harness 在 plugin 化之前作为 `.claude/harness/` 资产维护在 Aegis AI Audit 项目内（commits before plugin extraction）；plugin 提取前的 runtime 演化历史完整保留在该项目的 git history。本 changelog 仅记录 plugin 化之后的改动。

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
