---
description: 重新投递 harness-zh plugin 资产到当前项目（plugin 升级后用）。刷新 .claude/harness/ + .claude/commands/ + git hooks；不动 harness-project-config.yaml；不触发 BMad 提取。
argument-hint: ''
allowed-tools: Bash, Read, Edit, Write, AskUserQuestion
---

# /harness-zh:update — 资产重新投递

你是这个 update 的**主 orchestrator**。当用户触发 `/harness-zh:update`，把 plugin 当前版本的资产重新投递到用户项目，覆盖既有差异（备份后覆盖），但**绝不**动 `.claude/harness/harness-project-config.yaml`，也**不**重跑 BMad 字段提取。

**触发场景**：
1. solo-dev 跑 `/plugin marketplace update my-cc-plugin` 升级 plugin 后，资产在 plugin 安装目录已更新，但项目侧 `.claude/harness/` 副本还是旧的 — 用本命令同步过去
2. 项目侧资产被意外删 / 改坏，想重置回 plugin 当前版本（不动 yaml）

**与 `/harness-zh:init` 的差异**：

| 行为 | init | update |
|---|---|---|
| 部署资产到 `.claude/harness/` + `.claude/commands/` | ✓ | ✓ |
| 投放 yaml（仅当不存在） | ✓ | ✗（绝不创建/覆盖 yaml） |
| 装 git hooks | ✓ | ✓ |
| BMad artifacts 检测 + 字段提取 | 检测齐 → 跑 §1-§6 | ✗（永不跑） |
| 适用阶段 | 首次 bootstrap / mid-project 启用 | plugin 升级后刷新 |

**共享行为契约**（与 init 一致）：
- 代答政策：不调度子 agent；决策按 `.claude/harness/answer-policy.md` 自决
- TaskCreate 任务 `Harness Update: <project>`（§1 启动 in_progress；§6 报告 completed）
- 资产部署幂等：cmp 比较 + backup + overwrite

---

## 1. Plugin 路径探测（同 init §A.0；最小 12 行 inline bootstrap）

完整发现逻辑在 `scripts/discover_plugin_root.sh`，但 update 也可能遇上"项目侧旧脚本
被损坏"的场景，所以同样保留 inline bootstrap 自举（与 init §A.0 完全一致；
v0.1.29 起 2-tier：cache 优先 + marketplaces 兜底）：

```bash
# 1) env var 优先
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$PLUGIN_ROOT" ] && [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT=""

# 2a) cache 扫描（首选 — 按 semver 降序选最高版；过 .orphaned_at filter）
# 注：循环里**必须**用 `command grep`（绕开 function wrapper）— v0.1.30 修复，
# 详细说明见 init.md §A.0 同款注释。
if [ -z "$PLUGIN_ROOT" ]; then
    PLUGIN_ROOT="$(
        find ~/.claude/plugins/cache -maxdepth 5 -name plugin.json 2>/dev/null | while IFS= read -r manifest; do
            command grep -q '"name":[[:space:]]*"harness-zh"' "$manifest" 2>/dev/null || continue
            cand="$(dirname "$(dirname "$manifest")")"
            [ -f "$cand/.orphaned_at" ] && continue
            printf '%s\t%s\n' "$(basename "$cand")" "$cand"
        done | sort -V -r -k1,1 | head -n 1 | cut -f2-
    )"
fi

# 2b) marketplaces 兜底（fresh install / cache 未 populated — Claude Code 可能直接从 marketplaces 跑 plugin）
if [ -z "$PLUGIN_ROOT" ]; then
    PLUGIN_ROOT="$(
        find ~/.claude/plugins/marketplaces -maxdepth 6 -name plugin.json 2>/dev/null | while IFS= read -r manifest; do
            command grep -q '"name":[[:space:]]*"harness-zh"' "$manifest" 2>/dev/null || continue
            cand="$(dirname "$(dirname "$manifest")")"
            [ -f "$cand/.orphaned_at" ] && continue
            echo "$cand"
            break
        done
    )"
fi

# 3) miss → halt
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    echo "ERROR: 无法定位 harness-zh plugin 安装目录" >&2
    echo "       请先：/plugin marketplace add https://github.com/Niutie/my-cc-plugin.git && /plugin install harness-zh@my-cc-plugin" >&2
    exit 1
fi
echo "PLUGIN_ROOT=$PLUGIN_ROOT"
```

**与 init.md §A.0 的一致性**：本块与 init §A.0 / upgrade-deferred-work §3.3 同款 2-tier
inline bootstrap；完整 fallback chain（marketplaces/ 路径自动收）由
`$PLUGIN_ROOT/scripts/discover_plugin_root.sh` 维护单份 SoT。

## 2. 项目侧目录预检 + 创建（防御 mid-update 删目录场景）

```bash
mkdir -p .claude/harness/{scripts,conventions,prompt-suffixes,git-hooks}
mkdir -p .claude/commands
```

## 3. 资产投递 + 孤儿清理（共用 deploy_assets.sh；DEPLOY_PURGE=1）

**Source → Dest 配对表**（与 init §A.2 完全一致；由 `deploy_assets.sh` 内部维护，
本表仅人工 reference）：

| Plugin source | Project dest |
|---|---|
| `$PLUGIN_ROOT/architecture.md` | `.claude/harness/architecture.md` |
| `$PLUGIN_ROOT/answer-policy.md` | `.claude/harness/answer-policy.md` |
| `$PLUGIN_ROOT/changelog.md` | `.claude/harness/changelog.md` |
| `$PLUGIN_ROOT/test-stage-triggers.yaml` | `.claude/harness/test-stage-triggers.yaml` |
| `$PLUGIN_ROOT/scripts/*` | `.claude/harness/scripts/` |
| `$PLUGIN_ROOT/conventions/*` | `.claude/harness/conventions/` |
| `$PLUGIN_ROOT/prompt-suffixes/*` | `.claude/harness/prompt-suffixes/` |
| `$PLUGIN_ROOT/git-hooks/*` | `.claude/harness/git-hooks/` |
| `$PLUGIN_ROOT/templates/*` | `.claude/harness/templates/` |
| `$PLUGIN_ROOT/commands/*.md` | `.claude/commands/` |

（`prompt-templates/` 已停止分发 — 4 个模板停留在 pre-schema-v1 语义且无任何运行时引用；
老项目残留副本会被本节 manifest purge 自动清理 + 列入 §6 purged 清单。）

**update 调 deploy_assets.sh 的三大不同点**（vs init）：

1. **DEPLOY_PURGE=1**：基于 manifest 对账删除"上一次 plugin 部署过、本次不再部署"
   的文件（v0.1.27+ 重写；codex-review 2026-05-09 high）。
   - 实现：deploy_assets.sh 每次成功部署后写 `.claude/harness/.deploy-manifest.txt`
     列出本次拥有的文件清单。下次 PURGE=1 时读旧 manifest，对比新 manifest，**只有
     "出现在旧 manifest 但不在新 manifest"** 的文件才是 purge 候选。
   - **never-touched 守恒**：用户自定义命令（`.claude/commands/my-foo.md`）/ 其他
     plugin 文件 / personal helpers — 这些**从未进入过本 plugin 的 manifest**，
     永远不会被 purge。
   - 所有 purge 候选先备份到 `<file>.bak.<TS>` 再 `rm -f`；备份失败则跳过，不强删。
   - 安全网：deploy 有任何 FAILED → purge 整体跳过 + manifest 不被覆盖（避免被半成品
     manifest 污染）。新 manifest 为空时同样跳过 purge（拒绝对空真值做对账）。
   - 半路接入：`.claude/harness/.deploy-manifest.txt` 不存在 → 首次 PURGE 跳过 +
     提示 "future runs will purge correctly"。这一次只写 manifest，不删任何东西。
   - init 首跑也写 manifest（不开 PURGE），让以后 update 能正常对账。
2. **更详细的 stdout**（不设 DEPLOY_QUIET）：让 solo-dev 看到逐条 installed/updated/purged
   日志，便于即时审视。
3. **purged > 0 时主动告警**：在 §6 报告里单独列已删孤儿清单，请 solo-dev 二次确认
   "是否还有项目侧脚本依赖被删的文件"。

```bash
SUMMARY="$(DEPLOY_PURGE=1 bash "$PLUGIN_ROOT/scripts/deploy_assets.sh" "$PLUGIN_ROOT" "$PWD")"
DEPLOY_EXIT=$?
echo "DEPLOY_EXIT=$DEPLOY_EXIT"
echo "$SUMMARY"
# 例：deploy: installed=2 unchanged=64 updated=3 purged=2
```

`DEPLOY_EXIT ≠ 0` 或 summary 含 `FAILED=` → **halt**（§7.2）：报告已部署计数 + stderr verbatim。

**purged > 0 处理流程**：解析 stdout 的 `purged=N` 数字。N > 0 时，§6 报告必须列出
被删文件清单（`stderr` 的 `purged: ...` 行 grep 出来），并明确告诉 solo-dev：

> 这些文件在 v0.1.X 已从 plugin 中移除（参见 changelog）。如果项目自定义代码
> 还在引用它们（例如 `.claude/commands/` 或 `_bmad/customize/` 里 source 过），
> 请改引用替代品；否则可以放心。本次清理已生成 `*.bak.<TS>` 留底。

> **设计动机**：v0.1.26 删除 `extract_harness_feedback.sh` / `detect_harness_residue.sh`
> 时暴露了原版 update 只 forward-copy 不清理的缺陷 —— 老项目升级后这两个 stale 脚本
> 一直留着。0.1.27+ 用 manifest-based purge 解决（本节 purge + §6 报告二次确认）。

## 4. yaml 不动（硬约束）

**绝对不**操作 `.claude/harness/harness-project-config.yaml`。该文件含 solo-dev 已填的项目配置（16 字段从 BMad 提取或手填），仅由 `/harness-zh:init` 在缺失时从 template 投放，由 solo-dev 编辑维护。

如 plugin 升级后 template 新增字段（schema 演进），diff 提示 solo-dev 手工补：

```bash
diff .claude/harness/harness-project-config.yaml \
     "$PLUGIN_ROOT/templates/harness-project-config.yaml.template"
```

但**不**自动 patch yaml — 字段语义 / 默认值需 solo-dev 拍板。

## 5. git hooks 重装

```bash
bash .claude/harness/scripts/install_git_hooks.sh
HOOKS_EXIT=$?
echo "HOOKS_EXIT=$HOOKS_EXIT"
```

退出码处理（installer 退出码语义：`0` 成功；`3` = hooksPath 良性拒装；其他非 0 = 真实安装失败）：
- 0 → 进 §6 报告
- 3（`core.hooksPath` 已自定义，installer 拒装避免 silent no-op — 良性）→ stderr WARN 给用户，不 halt
- 其他非 0（含 1 — hook 源目录缺失 / cp、chmod 权限失败等真实安装失败）→ **halt**（§7.3）+ 贴 stderr verbatim — update 的触发场景 2 正是"项目侧资产被删/改坏"，hook 重装失败必须响亮失败而非伪装成 hooksPath WARN

## 6. 报告

```
✅ /harness-zh:update — 资产同步完成

【部署统计】
  - $INSTALLED installed / $UNCHANGED unchanged / $UPDATED updated / $PURGED purged
  - yaml: 未触动（按设计；如需 schema 升级见下方 diff 提示）
  - git hooks: <installed / unchanged | WARN: core.hooksPath ...（exit 3 良性拒装）>

【purged 清单】（仅 $PURGED > 0 时输出本块；数据来自 §3 deploy stderr 的 `purged:` 行）
  - <被删文件路径 1>（备份：<路径 1>.bak.<TS>）
  - <被删文件路径 2>（备份：...）
  ⚠️ 请二次确认：项目侧脚本 / `.claude/commands/` 自定义命令 / `_bmad/customize/` 是否
     还引用上述文件；如有，改引用替代品（参见 changelog 对应版本条目）；确认无误后
     可删 `.bak.<TS>` 备份。

【下一步建议】
  ① 查看被覆盖前的备份：ls .claude/harness/**/*.bak.<ts>（可放心删，确认无误后）
  ② 检查 yaml schema 是否有新字段：
       diff .claude/harness/harness-project-config.yaml \
            "$PLUGIN_ROOT/templates/harness-project-config.yaml.template"
  ③ 若 BMad artifacts 完整且想刷新 yaml，重跑 /harness-zh:init（**不会**覆盖既有非空字段，但会补齐空字段）
```

把 TaskCreate 任务标 `completed`，退出码 0。

---

## 7. 死循环 / 失控防护

下列任一命中立即 halt + 用户介入：

1. §1 plugin 路径探测两路 fallback 全 miss → halt + 报错（同 §1 ERROR 块）
2. §3 deploy_assets.sh `DEPLOY_EXIT ≠ 0` 或 summary 含 `FAILED=`（单文件 cp 失败：permission / 磁盘满 / 源文件缺失）→ halt + 报告失败 src/dst + 已部署计数（partial state；solo-dev 自决继续/回滚）
3. install_git_hooks.sh exit ≠ 0 且 ≠ 3（真实安装失败：hook 源目录缺失 / cp、chmod 权限失败 / 参数错误 / 内部 bug；exit 3 = hooksPath 良性拒装仅 WARN）→ halt + 贴 stderr verbatim
4. runtime quota 信号 → 与 init / run 同款配额模板

**Halt 模板**：

> stage 失败：§<N> in /harness-zh:update
> 现场：[一两句话讲发生了什么]
> 违反规则：[stderr verbatim]
> 已部署：[$INSTALLED installed / $UPDATED updated 计数]
> 待用户决断：[选项 1] 修复后重跑 update（幂等）/ [选项 2] 手工 cp 缺漏文件 / [选项 3] 整轮回滚（rm 已部署文件 + 从 .bak.<ts> 恢复）/ [选项 4] 怀疑 plugin 缺陷 → /harness-zh:report-issue（自动收集 halt 现场 + gh CLI 直提 + 附临时绕过方案）
