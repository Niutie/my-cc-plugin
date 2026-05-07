---
description: Harness 项目 bootstrap — 投递 plugin 资产到 .claude/harness/ + .claude/commands/ + 装 git hooks；若 BMad planning artifacts 已齐则继续从中提取 14 字段填 harness-project-config.yaml（merge 模式；--dry-run 预览；--force 覆盖二次确认）
---

# /harness-zh:init — Harness 项目 bootstrap + config 初始化

你是这个 init 的**主 orchestrator**。当用户触发 `/harness-zh:init`，按 **§A → §0 → §6** 顺序执行：先把 plugin 资产投递到用户项目（§A），再按 BMad artifacts 是否齐全（§A.5 检测）决定是否进 §0+ 跑 yaml 字段提取流程。

**触发场景**：
1. 新项目装 plugin 后**首次** init（资产未部署 + 可能无 BMad）
2. clone 到全新项目 + 已跑完 BMad（资产未部署 + 完整 BMad）
3. mid-project 启用 harness（资产部分部署 + 部分 yaml 已填 + 完整 BMad）
4. plugin 升级后（**建议改用** `/harness-zh:update` —— 只刷资产不动 yaml）

**与 `/harness-zh:run` / `/harness-zh:run-test` 共享的行为契约**：

- **代答政策**：本命令不调度 BMad/codex 子 agent，直接由主 agent 操作文件系统 + 读 BMad markdown + 写 yaml；无 prompt 后缀注入步骤。决策若不显然 → 按 `.claude/harness/answer-policy.md` 自决，不发问。
- **进度可视化**：用 TaskCreate 建任务 `Harness Init: <project_display_name>`（§A.0 启动时 in_progress；§6 完成或 §A.7 早结束时 completed）。
- **不自动 commit yaml（Q6）**：§6 报告完成后**不**调 `git add` / `git commit`；让 solo-dev review yaml 后自决。
- **资产部署幂等**：§A 用 cmp 比较内容；相同则 unchanged，不同则备份后覆盖（沿用 `install_git_hooks.sh` 模式 — 不丢用户本地修改）。
- **yaml 永不被资产投递覆盖**：`harness-project-config.yaml` 若已存在，§A.3 不动它；只在文件缺失时从 template 投放。

---

## A. Plugin Asset Deployment（首部 — 项目资产投递）

### A.0 探测 plugin 安装路径

按下列顺序尝试，命中即用，全部 miss 则 halt。Claude Code 把 plugin 装在
`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`（带版本子目录），
所以单纯 `find -name harness-zh` 只能找到版本子目录的父级，**不**包含 `commands/`
等实际文件。靠扫 `plugin.json` 的 `name` 字段定位才稳：

```bash
# 1) Claude Code 注入的 env 变量（hooks 上下文必有；commands 上下文不保证 — 试一下）
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$PLUGIN_ROOT" ] && [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT=""

# 2) 扫 ~/.claude/plugins 下所有 plugin.json，找 name="harness-zh" 的；
#    优先 cache/<marketplace>/<plugin>/<version>/（官方版本化安装路径）
#    **过滤 orphaned 副本**：Claude Code 在版本切换 / 卸载时会留下旧版本目录，
#    并放 `.orphaned_at` marker；这些目录内容是 stale 的，必须跳过
if [ -z "$PLUGIN_ROOT" ]; then
    while IFS= read -r manifest; do
        if grep -q '"name":[[:space:]]*"harness-zh"' "$manifest" 2>/dev/null; then
            candidate="$(dirname "$(dirname "$manifest")")"
            # 跳过 orphaned 缓存（Claude Code 留下的 stale 版本目录）
            [ -f "$candidate/.orphaned_at" ] && continue
            case "$candidate" in
                */cache/*) PLUGIN_ROOT="$candidate"; break;;
            esac
        fi
    done < <(find ~/.claude/plugins -maxdepth 6 -name plugin.json 2>/dev/null)
fi

# 3) Cache miss → fallback 用任意命中（如 marketplaces/<...>/plugins/<plugin>/）
if [ -z "$PLUGIN_ROOT" ]; then
    while IFS= read -r manifest; do
        if grep -q '"name":[[:space:]]*"harness-zh"' "$manifest" 2>/dev/null; then
            candidate="$(dirname "$(dirname "$manifest")")"
            [ -f "$candidate/.orphaned_at" ] && continue   # 同样过滤 orphaned
            PLUGIN_ROOT="$candidate"
            break
        fi
    done < <(find ~/.claude/plugins -maxdepth 6 -name plugin.json 2>/dev/null)
fi

# 4) 都没命中 → halt
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    cat >&2 <<EOF
ERROR: 无法定位 harness-zh plugin 安装目录
       已尝试: \${CLAUDE_PLUGIN_ROOT} env 变量，扫 ~/.claude/plugins/**/plugin.json
       请确认 plugin 已通过以下流程装载：
         /plugin marketplace add Niutie/my-cc-plugin
         /plugin install harness-zh@my-cc-plugin
EOF
    exit 1
fi
echo "PLUGIN_ROOT=$PLUGIN_ROOT"
```

把 `$PLUGIN_ROOT` 绑定到对话上下文，§A.2 之后所有 cp 用它做源路径。

### A.1 创建项目侧目标目录

```bash
mkdir -p .claude/harness/{scripts,conventions,prompt-suffixes,prompt-templates,git-hooks}
mkdir -p .claude/commands
```

### A.2 资产投递（cmp + backup + overwrite 幂等）

**Source → Dest 配对表**：

| Plugin source | Project dest |
|---|---|
| `$PLUGIN_ROOT/architecture.md` | `.claude/harness/architecture.md` |
| `$PLUGIN_ROOT/answer-policy.md` | `.claude/harness/answer-policy.md` |
| `$PLUGIN_ROOT/changelog.md` | `.claude/harness/changelog.md` |
| `$PLUGIN_ROOT/test-stage-triggers.yaml` | `.claude/harness/test-stage-triggers.yaml` |
| `$PLUGIN_ROOT/scripts/*` | `.claude/harness/scripts/` |
| `$PLUGIN_ROOT/conventions/*` | `.claude/harness/conventions/` |
| `$PLUGIN_ROOT/prompt-suffixes/*` | `.claude/harness/prompt-suffixes/` |
| `$PLUGIN_ROOT/prompt-templates/*` | `.claude/harness/prompt-templates/` |
| `$PLUGIN_ROOT/git-hooks/*` | `.claude/harness/git-hooks/` |
| `$PLUGIN_ROOT/commands/*.md` | `.claude/commands/` |

**单文件投递逻辑**（沿用 `install_git_hooks.sh` 模式）：

```bash
TS="$(date +%Y%m%d-%H%M%S)"
INSTALLED=0; UNCHANGED=0; UPDATED=0

deploy() {
    local src="$1" dst="$2"
    if [ ! -f "$dst" ]; then
        cp "$src" "$dst"
        [ -x "$src" ] && chmod +x "$dst"
        echo "installed: $dst"
        INSTALLED=$((INSTALLED + 1))
    elif cmp -s "$src" "$dst"; then
        UNCHANGED=$((UNCHANGED + 1))
    else
        cp "$dst" "$dst.bak.$TS"
        cp "$src" "$dst"
        [ -x "$src" ] && chmod +x "$dst"
        echo "updated:   $dst (backup → $(basename "$dst").bak.$TS)"
        UPDATED=$((UPDATED + 1))
    fi
}

# 顶层文件
for f in architecture.md answer-policy.md changelog.md test-stage-triggers.yaml; do
    deploy "$PLUGIN_ROOT/$f" ".claude/harness/$f"
done

# 子目录递归（用 find + process substitution 替代 shopt+glob — 兼容 bash 与 zsh，
# 且不会因空子目录在 zsh 默认 NOMATCH 下中止脚本）
for sub in scripts conventions prompt-suffixes prompt-templates git-hooks; do
    while IFS= read -r src; do
        [ -n "$src" ] && deploy "$src" ".claude/harness/$sub/$(basename "$src")"
    done < <(find "$PLUGIN_ROOT/$sub" -maxdepth 1 -type f 2>/dev/null)
done

# commands（单层，只 .md）
while IFS= read -r src; do
    [ -n "$src" ] && deploy "$src" ".claude/commands/$(basename "$src")"
done < <(find "$PLUGIN_ROOT/commands" -maxdepth 1 -type f -name '*.md' 2>/dev/null)
```

把 `$INSTALLED / $UNCHANGED / $UPDATED` 绑定上下文，§A.6 报告时引用。

### A.3 投放 yaml（仅当不存在 — 永不覆盖既有 yaml）

```bash
YAML_DST=".claude/harness/harness-project-config.yaml"
if [ ! -f "$YAML_DST" ]; then
    cp "$PLUGIN_ROOT/templates/harness-project-config.yaml.template" "$YAML_DST"
    YAML_BOOTSTRAPPED=1
else
    YAML_BOOTSTRAPPED=0
fi
```

**绝对不能**覆盖既有 yaml — 含 solo-dev 已填的项目字段（mid-project / 升级场景必须 preserve）。

### A.3.b 投放 deferred-work.md 骨架（仅当父目录存在且文件不存在）

```bash
DW_DIR="_bmad-output/implementation-artifacts"
DW_DST="$DW_DIR/deferred-work.md"
DW_BOOTSTRAPPED=0
if [ -d "$DW_DIR" ] && [ ! -f "$DW_DST" ]; then
    cp "$PLUGIN_ROOT/templates/deferred-work.md.template" "$DW_DST"
    DW_BOOTSTRAPPED=1
fi
```

`deferred-work.md` 是 schema v1 强约束文件（pre-commit gate ② 拒绝任何 4-tag
头不规范的 FU bullet）。给 dev / review agent 一个 known-good 起点，避免
它们凭印象造一份违规 placeholder（典型症状：bullet 用 `[severity:medium]`
这种非 schema v1 tag，被 gate ② 整批拒）。

**前提**：`_bmad-output/implementation-artifacts/` 必须已存在（一般由 BMad
planning 阶段产 `sprint-status.yaml` 时建出）。父目录缺失时跳过——本 init
不主动创建 BMad 输出目录。

**绝对不能**覆盖既有 `deferred-work.md`（可能含已写入的 FU）。

### A.4 装 git hooks

先检测当前目录是否在 git 工作树内：

```bash
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && echo "in_git=yes" || echo "in_git=no"
```

#### A.4.a `in_git=yes`（已在 git 仓库 — 含 parent 有 .git/ 的子目录场景）

直接跑 installer：

```bash
bash .claude/harness/scripts/install_git_hooks.sh
HOOKS_EXIT=$?
```

按退出码处理：
- `HOOKS_EXIT=0` → 进 §A.5
- `HOOKS_EXIT=1`（用户已设 `core.hooksPath`，installer 拒装避免 silent no-op）→ 把 installer 的 stderr verbatim 贴给用户作 **WARN**，**不 halt**（资产已部署，hook 装失败不阻断主流程；solo-dev 看 WARN 自决）

#### A.4.b `in_git=no`（当前目录不在任何 git 仓库内）

**用 `AskUserQuestion` 询问 solo-dev**（不要悄悄 `git init`，blast radius 不为零 — 用户可能在 scratch 目录）：

> 当前目录 `<pwd>` 不是 git 仓库 — 无法安装 pre-commit hook。是否在此目录跑 `git init` 初始化新仓库？

选项：
- **A) Yes, 初始化** → 跑 `git init`（**仅当**前一步 `in_git=no` 且 `pwd` 是项目根 — solo-dev 已通过 AskUserQuestion 显式同意）→ 然后跑 `bash .claude/harness/scripts/install_git_hooks.sh` → 按 §A.4.a 处理 exit code
- **B) No, 跳过** → emit **WARN**：「资产已部署，git pre-commit hook 跳过；solo-dev 后续如想装，手工跑 `git init && bash .claude/harness/scripts/install_git_hooks.sh`」→ 进 §A.5

#### A.4.c 边界：嵌套 repo 自动防护（若上述 A.4.b 选 Yes 但实际 `in_git=yes` 时，本分支不会进；这是 paranoia）

如果 `in_git=yes` 但用户**仍**触发了"我想 init 一个新 repo"的请求（不该走到这里），**halt** + 提示「当前已在 git 仓库 `<repo-root>` 内，再 `git init` 会建嵌套 repo（不推荐）。退出 §A.4」。

### A.5 BMad artifacts 检测 → 流程分叉

**单一权威源：调 `run_sprint_init_check_prereq.sh` helper 脚本**，根据 exit code + JSON stdout 决定流程。**不要**自己 inline 重写检测逻辑或按文件名直觉判断 —— helper 是 dual-form (单文件/sharded) 兼容的唯一可信入口。

```bash
HELPER_OUT="$(bash .claude/harness/scripts/run_sprint_init_check_prereq.sh --root "$PWD" 2>&1)"
HELPER_EXIT=$?

# Helper stdout 第一行是 JSON：{"all_present": bool, "missing_planning": [...], "missing_sprint_status": bool, "optional_missing": [...]}
HELPER_JSON="$(printf '%s\n' "$HELPER_OUT" | grep -m1 '^{')"
# Helper stderr 含人类可读引导（命令名 + 路径建议）
HELPER_GUIDANCE="$(printf '%s\n' "$HELPER_OUT" | grep -vE '^{' | grep -vE '^$')"
```

**按 HELPER_EXIT 分支**（与 helper 脚本退出码契约一致）：

| HELPER_EXIT | 含义 | 行为 |
|---|---|---|
| `0` | 3 必需产物都齐（product-brief 可能缺 → optional_missing 字段） | `BMAD_READY=1` → 走 §A.7 "BMAD ready" 分支进 §0+ |
| `2` | prd / architecture **必需** planning 缺失 | `BMAD_READY=0` → 走 §A.7 "early-exit" 分支 |
| `3` | sprint-status.yaml 缺失 | `BMAD_READY=0` → 走 §A.7 "early-exit" 分支 |
| 其他 | helper 异常（参数错误 / 内部 bug） | **halt** + 报告 exit code + HELPER_OUT verbatim |

**3 类必需产物 + 1 类可选产物的接受形式**（与 helper 脚本内逻辑一致；本表仅供 LLM 理解，**不要**用于绕过 helper 自己判断）：

| # | 概念产物 | 必需性 | 接受的形式 |
|---|---|---|---|
| 1 | prd | **必需** | 单文件 `prd.md`（默认）**或** sharded 目录 `prd/`（跑过 `/bmad-shard-doc`） |
| 2 | architecture | **必需** | 单文件 `architecture.md`（默认）**或** sharded 目录 `architecture/`（跑过 `/bmad-shard-doc`） |
| 3 | sprint-status | **必需** | `_bmad-output/implementation-artifacts/sprint-status.yaml`（路径固定） |
| 4 | product-brief | **可选**（缺则 §2 字段 1/15 用 prd.md 兜底；进 optional_missing 数组） | `product-brief*.md`（glob — 上游会带项目名后缀） |

> **重要：单文件 vs sharded 是 BMad 上游的两种合法布局**。BMad 默认产单文件 `prd.md` / `architecture.md`；用户跑 `/bmad-shard-doc` 后切到 sharded。harness-zh 对二者无偏好，二者都是一等公民。
>
> **绝对不要**自己用 `[ -f architecture/tech-stack.md ]` 这种针对单一形式的检查 —— helper 脚本已封装 dual-form 探测，调它即可。

> **BMad 命令两形式说明**：装好后大多数命令同时有 `/bmad-<name>` (skill 直射) 与 `/bmad:<name>` (workflow 别名) 两种形式，功能等价。本指南用 hyphen 形式（更直接对应 `.claude/skills/bmad-<name>/`）；若环境里 hyphen 没识别，换冒号即可。少数较新/meta 命令（`/bmad:research`、`/bmad:tech-spec`）只有冒号形式。

### A.6 资产部署统计（不论 BMad ready 与否都打印）

```
【资产部署】
  - $INSTALLED installed / $UNCHANGED unchanged / $UPDATED updated（含 backup）
  - yaml: <bootstrapped from template | preserved existing>
  - deferred-work.md: <bootstrapped from template | preserved existing | skipped — parent dir absent>
  - git hooks: <installed / unchanged | WARN: core.hooksPath ...>
```

### A.7 BMad ready 分叉（按 §A.5 的 HELPER_EXIT）

- **`HELPER_EXIT=0` (BMAD_READY=1)** → emit "BMad artifacts 齐（product-brief 可能可选缺失）→ 进入 §0 字段提取流程"。如果 helper JSON 的 `optional_missing` 非空，emit WARN 行：

  ```
  💭 可选缺失（不阻流）：
    - product-brief*.md（缺则 §2 字段 1/15 用 prd.md 兜底）
  ```

  然后进 §0。

- **`HELPER_EXIT=2` 或 `3` (BMAD_READY=0)** → emit 早结束块（下方），TaskCreate 标 `completed`，退出 0：

  ```
  ⚠️ BMad 必需 planning artifacts 未齐 — 跳过 yaml 字段提取

  【必需缺失】（来自 helper stderr 引导）
  $HELPER_GUIDANCE   ← 直接贴 helper 的引导段，不要自己重写

  【下一步】
    首次使用 BMad（项目根没 _bmad/ 目录）先装：
      npx bmad-method install                                  # 交互式：全选 5 模块（core/bmm/bmb/cis/tea）+ 选 Claude Code 集成
      # 或 npx bmad-method install --modules core,bmm,bmb,cis,tea --tools claude-code --yes
    （installer 会自动建 _bmad/ 配置 + 写 .claude/skills/bmad-*/，无需额外 init 步骤）

    然后按下列顺序跑 BMad planning workflow：
      /bmad-create-prd            → prd.md（必需）
      /bmad-create-architecture   → architecture.md（必需，默认单文件；可选 /bmad-shard-doc 切片）
      /bmad-sprint-planning       → sprint-status.yaml（必需）
      /bmad-product-brief         → product-brief-<name>.md（**可选**；不跑也能进 yaml 提取）

    （命令名也可写 /bmad:prd / /bmad:architecture / /bmad:sprint-planning / /bmad:product-brief —
      hyphen 与 colon 形式功能等价，按你环境的 skill 习惯选）

    完成后**重跑** /harness-zh:init —— 检测到 3 个必需产物齐后即进入 yaml 字段提取（product-brief 不必有）。

  yaml 当前状态：<bootstrapped from template；尚未填字段 | preserved existing；上次填的字段保留>
  ```

---

## 0. 启动前置

### 0.0 参数解析

| 参数 | 行为 | 互斥 |
|---|---|---|
| `--dry-run` | 仅 stdout 打印 diff（will-write fields），yaml 文件 0 修改 | 与 `--force` 互斥 |
| `--force` | 覆盖 yaml 既有值（含手改字段）；先列 "field: old → new" + 二次确认 prompt | 与 `--dry-run` 互斥 |
| 无参数 | 默认 merge 模式：已存在字段保留，缺失字段补全 | — |

绑定到对话上下文：
- `MODE` = `dry-run` / `force` / `merge`（默认）
- 同时给 `--dry-run` 与 `--force` → 立即 halt + stderr "互斥 flag 不能同时传"

### 0.1 TaskCreate 建任务

`TaskCreate({ subject: "Sprint Init: <project>", description: "MODE=<mode>; 14 字段从 BMad → yaml 同步" })`，立刻 `in_progress`。

---

## 1. Prerequisite 检查（MUST-EXIST gate）

调 helper：

```bash
bash .claude/harness/scripts/run_sprint_init_check_prereq.sh
```

**按退出码处理**：
- **0**：进 §2
- **2**：BMad **必需** planning artifacts 缺失。**halt**：把 helper 的 stderr verbatim 贴给用户，TaskCreate 标 `cancelled`，退出。**不**继续读 BMad / 不写 yaml。引导文本（helper 内硬编码）含具体 BMad 命令（`/bmad-create-prd` / `/bmad-create-architecture`；hyphen 形式 — colon 别名也可）。
- **3**：sprint-status.yaml 缺失。**halt**：引导跑 `/bmad-sprint-planning`（或 `/bmad:sprint-planning`），TaskCreate 标 `cancelled`，退出。
- **其它**：halt + 报告 helper exit code（参数错误 / 内部错误 — 不应发生）。

**MUST-EXIST 清单**（helper 内 — 单文件或 sharded 任一形式接受）：
1. `_bmad-output/planning-artifacts/prd.md` **或** `prd/` 目录（sharded 形式）
2. `_bmad-output/planning-artifacts/architecture.md` **或** `architecture/` 目录（sharded 形式）
3. `_bmad-output/implementation-artifacts/sprint-status.yaml`

**NICE-TO-HAVE**（缺则 WARN 不阻流；相关字段用 fallback）：
- `_bmad-output/planning-artifacts/product-brief*.md`（glob — 上游会带项目名后缀；缺则 §2 字段 1/15 用 prd.md 兜底）
- 若 architecture sharded：`architecture/i18n.md` / `architecture/nfrs.md` / `architecture/proxy*.md` / `architecture/testing-strategy.md`
- 若 architecture 单文件：上述内容作为章节嵌入 `architecture.md`，§2 提取时按章节标题 grep 即可

---

## 2. BMad artifacts 字段提取（14 字段映射表）

按下表逐字段读 BMad markdown + 用**语义检索**（Q1）提取值。**不**依赖固定锚点（如 `## Frontend`）—— BMad-generated markdown 段标题 / 段位置不严格固定（中英文 / 编号前缀 / 同义词都可能漂移）。LLM 用 Read 工具读对应文件全文 + 按"提取语义提示"找信息。

> **Source 列读法 — 单文件 / sharded 两种形式都是 BMad 合法默认布局**：
>
> - **单文件形式**（BMad 上游 `/bmad-create-architecture` 默认产出）：`architecture.md` 含 tech-stack / repo-structure / i18n / nfrs / proxy / testing-strategy 等章节；LLM 用 Read 读全文按章节标题（"Tech Stack" / "Repo Structure" / 等）grep 对应段落
> - **Sharded 形式**（用户跑过 `/bmad-shard-doc` 后切片）：`architecture/tech-stack.md` 等独立子文件；LLM 用 Read 直读对应子文件
>
> 下表"BMad source"列写法 `architecture/tech-stack.md` 或 `architecture.md §tech-stack` 表达同一信息的两种存储形式。LLM 提取时按以下顺序探测：
>
> 1. 检查 sharded 路径 `_bmad-output/planning-artifacts/architecture/<name>.md` 是否存在 → 存在则读子文件
> 2. 否则读单文件 `_bmad-output/planning-artifacts/architecture.md` 全文 → 按章节标题 grep
>
> **两种形式都是一等公民**，没有"主选"和"次选"之分。BMad 默认产单文件，sharded 是用户主动选择的次态；harness-zh 对二者无偏好。
>
> 同样地，`product-brief*.md` 是 glob 模式（BMad 上游产出文件名带项目后缀如 `product-brief-aegis.md`，是 BMad 设计如此，不是 typo）；`prd.md` / `prd/` 也按"单文件优先 → 否则读 sharded 目录"。

| # | yaml field | BMad source | 提取语义提示 | 失败 fallback |
|---|---|---|---|---|
| 1 | `project_display_name` | `product-brief*.md` 或 `prd.md` | 找产品名 / 项目代号 / 产品定位段第一句 | `'TODO: project name'` + WARN |
| 2 | `container_orchestrator` | `architecture/tech-stack.md` 或 `architecture.md §tech-stack` | 找容器编排技术（docker-compose / k8s / podman / nerdctl-compose） | `'docker-compose'` + WARN |
| 3 | `frontend_framework` | `architecture/tech-stack.md` 或 `architecture.md §tech-stack` | 找前端框架（Next.js / SvelteKit / Remix / Astro 含版本） | `'TODO: frontend framework'` + WARN |
| 4 | `backend_languages` (list) | `architecture/tech-stack.md` 或 `architecture.md §tech-stack` | 找后端语言列表（Go / Python / TypeScript / Rust 含版本） | `['TypeScript']` + WARN |
| 5 | `e2e_framework` | `architecture/tech-stack.md` 或 `architecture.md §testing-strategy` | 找端到端测试框架（Playwright / Cypress / WebdriverIO） | `'Playwright'` + WARN |
| 6 | `extra.frontend_dir` | `architecture/repo-structure.md` 或 `architecture.md §repo-structure` | 找前端代码顶层目录名 | `'frontend'` + WARN |
| 7 | `extra.e2e_test_subdir` | `architecture/repo-structure.md` 或 `testing-strategy.md` | 找 e2e 测试目录路径（相对前端目录或仓库根） | `'tests/e2e'` + WARN |
| 8 | `extra.container_count` | `architecture/tech-stack.md` 或 `deploy/` 段 | 找服务容器数量（整数） | `0` + WARN |
| 9 | `extra.i18n_locales` (list) | `architecture/i18n.md`（NICE-TO-HAVE） | 找前端国际化语种代码列表（zh-CN / en-US 等） | `['en-US']` + WARN |
| 10 | `extra.routing_pattern` | `architecture/i18n.md` 或 `architecture/tech-stack.md`（NICE-TO-HAVE） | 找路由模式描述（"Next.js i18n routing" 等） | `''` + WARN |
| 11 | `extra.proxy_addon` | `architecture/proxy*.md`（NICE-TO-HAVE） | 找代理 / 中间人插件名 | `''` + WARN |
| 12 | `extra.sandbox_constraint` | `architecture/nfrs.md` 或 PRD NFR 段（NICE-TO-HAVE） | 找资源约束 / 沙箱尺寸（"4C/8GB" 等） | `''` + WARN |
| 13 | `extra.resource_baseline` | `architecture/nfrs.md` 或 PRD NFR 段（NICE-TO-HAVE） | 找最低资源 baseline | `''` + WARN |
| 14 | `extra.backend_modules` (list) | `architecture/repo-structure.md` | 找后端服务 / 模块顶层目录列表 | `[]` + WARN |
| 15 | `extra.project_context` (multiline \| block) | `product-brief.md` 或 `prd.md` | 提取产品定位 + 关键决策原则段（开发模型 / 目标客户 / 交付形态 / 技术准则等）。每条原文一行 `- <key>：<value>` 形式，6-10 条；保留中英文。subagent 在按 answer-policy.md 自决时把这段当项目语境用 | `'项目语境未配置：clone 后请填 extra.project_context'` 多行块 + WARN |
| 16 | `extra.fullstack_review_steps` (list of {label, file_path}) | `architecture/data-model.md` 或 `architecture/component-architecture.md` 或 `architecture/repo-structure.md` | 找核心数据写入 / 序列化 / 渲染 / i18n 路径列表（按数据流"字段定义→写入→序列化→存储 mapping→hash chain canonical 验证→i18n→前端渲染"7 段；每条 `{label: 短描述, file_path: 具体文件路径或 module::symbol}`）。dev-story Q6 端到端追溯每项；新审计字段引入时按本表逐项打勾 | `[]` + WARN（list 为空时 dev-story Q6 整段降级跳过；不阻流） |

**提取协议**：
- 用 Read 工具读 BMad source 文件全文（每条 source 至多读一次，缓存到工作记忆）
- 对每个字段：在文件内容中按"提取语义提示"找信息；找到 → 记入 `EXTRACTED[<key>] = <value>`；找不到 → 记入 `WARN[<key>] = "BMad source <path> 未发现 <语义>; using fallback"`
- 提取完所有 16 字段后进 §3
- **禁止**：不写 grep/awk/sed 解析 BMad markdown（脆弱；spec Boundaries "Never"）

**字段 15-16 特殊语义**（2026-05-05 加 — L1+L2 yaml-driven 注入）：
- 字段 15（project_context）由 `harness-prompt-suffix.py` 在 prompt 注入时内联到代答政策块；缺失会导致 subagent 决策时缺项目语境（fallback 为通用决策原则）
- 字段 16（fullstack_review_steps）由 `harness-prompt-suffix.py` stage 2 渲染为 dev-story Q6 sub-bullet 注入到 dev subagent；list 为空时 Q6 整段降级跳过（不阻流）
- 这两字段 fallback 不阻 init / sprint，但实际跑 dev / review 时建议补全（subagent 决策质量与字段完整度强相关）

---

## 3. 派生字段计算（artifacts_root / path_classifiers / verification_commands）

### 3.1 artifacts_root

- yaml 已设 → 不动（merge 语义）
- yaml 未设 → 写默认 `'_bmad-output/implementation-artifacts'`

### 3.2 path_classifiers（基于 §2 提取的 frontend_dir + backend_modules + e2e_test_subdir）

按下面模板生成 list of {label, regex}。`<frontend_dir>` 等占位符按 §2 字段值代入；任一上游字段缺失 → 留 `harness-project-config.yaml` Aegis 默认 11 条 + WARN（spec I/O Matrix 表第 9 行 fallback 行为）。

**模板（条件分支按 §2 值挑选）**：

- 当 `Go` ∈ `backend_languages` 且 `backend_modules` 非空：
  - `{label: 'backend Go source', regex: '^<backend_modules[0]>/(?!.*_test\\.go$)'}`
  - `{label: 'backend Go tests',  regex: '^<backend_modules[0]>/.*_test\\.go$|^tests/integration/'}`
  - `{label: 'backend SQL/migrations', regex: '^<backend_modules[0]>/.*\\.sql$|^<backend_modules[0]>/internal/migrations/'}`
- 当 `Python` ∈ `backend_languages` 且 `backend_modules` 非空：
  - `{label: 'backend Python source', regex: '^<backend_modules[?]>/(?!.*test_.*\\.py$)'}`
  - `{label: 'backend Python tests',  regex: '^<backend_modules[?]>/.*test_.*\\.py$'}`
- 当 `Rust` ∈ `backend_languages` 且 `backend_modules` 非空：
  - `{label: 'backend Rust source', regex: '^<backend_modules[?]>/src/'}`
  - `{label: 'backend Rust tests',  regex: '^<backend_modules[?]>/tests/'}`
- 当 `frontend_dir` 非空：
  - `{label: 'frontend TS source', regex: '^<frontend_dir>/src/(?!.*\\.test\\.)'}`
  - `{label: 'frontend TS tests',  regex: '^<frontend_dir>/(tests|e2e)/'}`
  - `{label: 'frontend i18n',      regex: '^<frontend_dir>/locales/'}`
  - `{label: 'frontend config',    regex: '^<frontend_dir>/(eslint|vitest|next|package|pnpm|tsconfig)'}`
- 通用兜底：
  - `{label: 'infra/deploy', regex: '^(deploy|docker-compose|Justfile|scripts/)'}`
  - `{label: 'docs/spec',    regex: '^docs/'}`

### 3.3 verification_commands（Q5 三组合 — 多行 `|` 块）

按 `backend_languages` + `frontend_framework` 拼模板：

| backend 主语言 | frontend | verification_commands 模板 |
|---|---|---|
| Go (含版本) | TypeScript / Next.js 等 | `go vet/build/test ./<backend_modules[0]>/...\npnpm --filter <frontend_dir> typecheck/test/lint --max-warnings=0/build` |
| Python (含版本) | TypeScript / Next.js 等 | `cd <backend_modules[0]> && pytest && ruff check\npnpm --filter <frontend_dir> typecheck/test/lint --max-warnings=0/build` |
| Rust (含版本) | TypeScript / Next.js 等 | `cd <backend_modules[0]> && cargo check && cargo test\npnpm --filter <frontend_dir> typecheck/test/lint --max-warnings=0/build` |
| 其它栈 | 任意 | `# TODO: fill verification commands for your stack` + WARN |

`backend_modules` 为空 → 把 `<backend_modules[0]>` 替换为 `.` （仓库根）。`frontend_dir` 为空 → 把 `<frontend_dir>` 替换为 `frontend`。

---

## 4. yaml merge 写入

### 4.1 读当前 yaml + 解析既有字段

用 Read 读 `.claude/harness/harness-project-config.yaml` 全文，解析每个字段的当前值（保留原始行号 + 注释行）。

### 4.2 计算 diff

对 §2 + §3 算出的 17 个字段（14 BMad-sourced + 3 派生），对比 yaml 既有值：
- **既有 = 提取值** → no-op
- **既有 = 空 / 未设** → mark "to-fill"（merge 模式 + force 模式都写）
- **既有 = 非空 + 提取值 != 既有**：
  - merge 模式 → 保留既有（不动），加 stderr 提示 "field <key> 既有 '<old>' != BMad '<new>' — merge 模式保留既有"
  - force 模式 → mark "to-overwrite"
- **派生字段**：merge 同上；force 同上

### 4.3 模式分支

- **`--dry-run`**：stdout 列出 diff（"to-fill" / "to-overwrite" / "no-op"）+ 退出。**0 写入 yaml 文件**。退出码 0。
- **`--force` + 有 to-overwrite**：stdout 列出每条 "field: old → new"，**用 AskUserQuestion** 二次确认（"--force 会覆盖 yaml 既有 N 字段，确认吗？"）；用户选"是"→ 写；选"否"→ TaskCreate 标 `cancelled`，退出码 1。
- **`merge` 模式**：直接写 to-fill 字段（既有不动）。

### 4.3.5 备份 yaml（rollback 用 — F4 codex review fix 2026-05-05）

进 §4.4 写入之前，先把当前 yaml 的完整内容备份到 /tmp，以便 §4.5 / §5 失败时
**不依赖 git HEAD** 的 rollback。这避开了"用 `git checkout --` rollback 会丢
solo-dev 未提交本地编辑"的爆炸半径（用户 CLAUDE.md feedback memory：halt 时
先评估爆炸半径，别动不动整条撤回）。

```bash
BACKUP_PATH="/tmp/harness-project-config.yaml.preinit-$$"
cp .claude/harness/harness-project-config.yaml "$BACKUP_PATH"
```

把 `$BACKUP_PATH` 路径绑定到对话上下文（§4.5 / §5 rollback 时引用）。备份是
当前 worktree 内容（含 solo-dev 任何未提交编辑），与 git HEAD 解耦。

### 4.4 写入（Edit 工具，逐字段）

用 Edit 工具**逐字段替换**（保留注释 — Q2）：

```
old_string: "project_display_name: '<old>'"
new_string: "project_display_name: '<new>'"
```

对 list 字段（`backend_languages` / `i18n_locales` / `backend_modules` / `path_classifiers`）：把整个 list 块作为 `old_string` 替换为新 list 块。**保留**原 yaml 缩进 + 引号风格。

对多行 `|` 块（`verification_commands`）：替换块内行；不动 `verification_commands: |` 这行本身。

**禁止**：
- 不用 `Write` 工具整文件覆盖 — 会丢顶部 schema 文档注释（Q2 硬约束）
- 不用 sed 整文件 mutate — 多字段替换易错 + 注释脆弱

### 4.5 写入后语法 sanity

跑 `python3 .claude/harness/scripts/harness_config.py` smoke test：
- exit 0 + 输出含期望字段值 → §5 验证
- exit ≠ 0 / 输出含 `WARN [harness_config]:` → **rollback yaml from backup**（用 §4.3.5 绑定的 `$BACKUP_PATH`，**不**用 `git checkout --`）：
  ```bash
  cp "$BACKUP_PATH" .claude/harness/harness-project-config.yaml
  rm -f "$BACKUP_PATH"
  ```
  → halt + 报告失败字段（exit code 4 per spec I/O Matrix）。**为什么不用 `git checkout --`**：会把 yaml 翻成 git HEAD 状态，丢 solo-dev 未提交的本地编辑（mid-project 启用场景常见）。备份-恢复路径与 HEAD 解耦，安全。

---

## 5. 验证（simulate_clone_test.sh）

跑：

```bash
bash .claude/harness/scripts/simulate_clone_test.sh
```

**按退出码处理**：
- **0**：init 写入合法（yaml 解析正常 + helper 跑通 + 占位符在位）→ 清理备份（`rm -f "$BACKUP_PATH"`）→ 进 §6
- **非 0**：**rollback yaml from backup**（不用 `git checkout --`；同 §4.5 理由 — backup-restore 与 git HEAD 解耦，保 solo-dev 未提交本地编辑）：
  ```bash
  cp "$BACKUP_PATH" .claude/harness/harness-project-config.yaml
  rm -f "$BACKUP_PATH"
  ```
  → halt + 报告 simulate 失败步骤（exit code 5 per spec I/O Matrix）

---

## 6. 报告 + 引导（不自动 commit — Q6）

stdout 报告（按下表结构）：

```
✅ /harness-zh:init 完成

【写入字段】<N>/14 BMad 字段 + <M>/3 派生字段
  - project_display_name: '<value>'
  - container_orchestrator: '<value>'
  - ...

【保留字段（merge 模式不动）】<K>
  - field: '<existing>' (BMad 提议: '<bmad>')

【WARN】<W> 项
  - <key>: BMad source <path> 未发现 <语义>; using fallback '<default>'

【下一步】
  请 review yaml 改动后由 solo-dev 自决 commit：
    git diff .claude/harness/harness-project-config.yaml
    git add .claude/harness/harness-project-config.yaml
    git commit -m "chore: init harness config from BMad planning artifacts"
```

**`--dry-run` 模式报告**（无写入）：

```
🔍 /harness-zh:init --dry-run（0 写入）

【will-write】<N> 字段
  - field: <empty> → '<bmad-value>'

【will-overwrite (force-only)】<K> 字段（当前模式不会动；如需覆盖请加 --force）
  - field: '<existing>' → '<bmad-value>'

【no-op】<S> 字段（既有 = BMad 一致）

【WARN】<W> 项

提示：去掉 --dry-run 跑可写入 will-write 字段；加 --force 可覆盖 will-overwrite 字段（需二次确认）
```

完成后把 TaskCreate 任务标 `completed`，退出码 0。

---

## 7. 死循环 / 失控防护

下列**任一**命中立即 halt + 用户介入（与 `/harness-zh:run` §3 / `/harness-zh:run-test` §3 同款模板）：

1. helper `run_sprint_init_check_prereq.sh` 退出码非 0/2/3（参数错误 / 内部异常）
2. BMad markdown 提取语义后 `EXTRACTED[<key>]` 仍为空对**所有 14 字段** → 怀疑 BMad 产物为空文件 / 损坏 → halt + 提示用户检查 `_bmad-output/planning-artifacts/`
3. yaml 写入后 `harness_config.py` smoke test exit ≠ 0（yaml 语法破坏）→ rollback + halt
4. `simulate_clone_test.sh` exit ≠ 0 → rollback + halt
5. runtime quota 信号（`hit your limit` / `rate limit` 等）— 与 `/harness-zh:run` §3 同款配额专属模板

**Halt 模板**（与 `/harness-zh:run` 一致）：

> stage 失败：§<N> in /harness-zh:init
> 现场：[一两句话讲发生了什么]
> 违反规则：[贴 helper / harness_config / simulate_clone 的 stderr verbatim]
> yaml 当前状态：[`git diff --stat .claude/harness/harness-project-config.yaml`]
> 已采取动作：[rollback / 无变更 / 部分写入 N 字段]
> 待用户决断：是否 [选项 1] 撤回 yaml 改动 / [选项 2] 修复 BMad 产物后重跑 / [选项 3] 跳过本次 init

---

## 8. 参数（汇总）

| 参数 | 行为 |
|---|---|
| 无参数 | 默认 merge 模式 — 已存在字段不动 + 缺失字段补全；写 yaml + commit 由 solo-dev 自决 |
| `--dry-run` | 仅 stdout 列 diff，0 写入；与 `--force` 互斥 |
| `--force` | 覆盖 yaml 既有值（含手改字段）；先列 "field: old → new" + 二次确认（AskUserQuestion）；与 `--dry-run` 互斥 |

**v0.2+ 留口**（本版**不**实现）：
- `--reset-changelog`：清空 `_bmad-output/implementation-artifacts/changelog.md` 重启历史（A=a 决策当前不动）
- `--bmad-source <path>`：override 默认 `_bmad-output/planning-artifacts/` 路径（多项目共仓场景）

---

## 引用

- 关联 chore spec：`_bmad-output/implementation-artifacts/chore-harness-run-sprint-init.md`
- prereq helper：[`/scripts/run_sprint_init_check_prereq.sh`](../harness/scripts/run_sprint_init_check_prereq.sh)
- self-test：[`/scripts/run_sprint_init_test.sh`](../harness/scripts/run_sprint_init_test.sh)
- 写入目标：[`harness-project-config.yaml`](../harness/harness-project-config.yaml)
- yaml 解析 helper（写后 sanity）：[`/scripts/harness_config.py`](../harness/scripts/harness_config.py)
- 跨项目 clone 验证：[`/scripts/simulate_clone_test.sh`](../harness/scripts/simulate_clone_test.sh)
- 代答政策：[`../harness/answer-policy.md`](../harness/answer-policy.md)
- harness 通用化设计：[`../harness/architecture.md`](../harness/architecture.md) §十一
