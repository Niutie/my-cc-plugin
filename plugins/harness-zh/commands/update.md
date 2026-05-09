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
- TaskCreate 任务 `Harness Update: <project>`（§1 启动 in_progress；§5 报告 completed）
- 资产部署幂等：cmp 比较 + backup + overwrite

---

## 1. Plugin 路径探测（同 init §A.0；最小 12 行 inline bootstrap）

完整发现逻辑在 `scripts/discover_plugin_root.sh`，但 update 也可能遇上"项目侧旧脚本
被损坏"的场景，所以同样保留 inline bootstrap 自举（与 init §A.0 完全一致）：

```bash
# 1) env var 优先
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$PLUGIN_ROOT" ] && [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT=""

# 2) miss 则扫 cache（按 semver 降序选最高版；过 .orphaned_at filter；用 [[ == ]] 替代 case+glob 兼容 bash 3.2）
if [ -z "$PLUGIN_ROOT" ]; then
    PLUGIN_ROOT="$(
        find ~/.claude/plugins -maxdepth 6 -name plugin.json 2>/dev/null | while IFS= read -r manifest; do
            grep -q '"name":[[:space:]]*"harness-zh"' "$manifest" 2>/dev/null || continue
            cand="$(dirname "$(dirname "$manifest")")"
            [ -f "$cand/.orphaned_at" ] && continue
            [[ "$cand" == */cache/* ]] || continue
            printf '%s\t%s\n' "$(basename "$cand")" "$cand"
        done | sort -V -r -k1,1 | head -n 1 | cut -f2-
    )"
fi

# 3) miss → halt
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    echo "ERROR: 无法定位 harness-zh plugin 安装目录" >&2
    echo "       请先：/plugin marketplace add Niutie/my-cc-plugin && /plugin install harness-zh@my-cc-plugin" >&2
    exit 1
fi
echo "PLUGIN_ROOT=$PLUGIN_ROOT"
```

**与 init.md §A.0 的一致性**：本块与 init §A.0 / upgrade-deferred-work §3.3 同款 12 行
inline bootstrap；完整 fallback chain（含 marketplaces/ 非 cache 路径兜底）由
`$PLUGIN_ROOT/scripts/discover_plugin_root.sh` 维护单份 SoT。

## 2. 项目侧目录预检 + 创建（防御 mid-update 删目录场景）

```bash
mkdir -p .claude/harness/{scripts,conventions,prompt-suffixes,prompt-templates,git-hooks}
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
| `$PLUGIN_ROOT/prompt-templates/*` | `.claude/harness/prompt-templates/` |
| `$PLUGIN_ROOT/git-hooks/*` | `.claude/harness/git-hooks/` |
| `$PLUGIN_ROOT/templates/*` | `.claude/harness/templates/` |
| `$PLUGIN_ROOT/commands/*.md` | `.claude/commands/` |

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
3. **purged > 0 时主动告警**：在 §5 报告里单独列已删孤儿清单，请 solo-dev 二次确认
   "是否还有项目侧脚本依赖被删的文件"。

```bash
SUMMARY="$(DEPLOY_PURGE=1 bash "$PLUGIN_ROOT/scripts/deploy_assets.sh" "$PLUGIN_ROOT" "$PWD")"
echo "$SUMMARY"
# 例：deploy: installed=2 unchanged=64 updated=3 purged=2
```

**purged > 0 处理流程**：解析 stdout 的 `purged=N` 数字。N > 0 时，§5 报告必须列出
被删文件清单（`stderr` 的 `purged: ...` 行 grep 出来），并明确告诉 solo-dev：

> 这些文件在 v0.1.X 已从 plugin 中移除（参见 changelog）。如果项目自定义代码
> 还在引用它们（例如 `.claude/commands/` 或 `_bmad/customize/` 里 source 过），
> 请改引用替代品；否则可以放心。本次清理已生成 `*.bak.<TS>` 留底。

> **设计动机**：v0.1.26 删除 `extract_harness_feedback.sh` / `detect_harness_residue.sh`
> 时暴露了原版 update 只 forward-copy 不清理的缺陷 —— 老项目升级后这两个 stale 脚本
> 一直留着。0.1.27+ 用 manifest-based purge 解决（§5）。

## 4. yaml 不动（硬约束）

**绝对不**操作 `.claude/harness/harness-project-config.yaml`。该文件含 solo-dev 已填的项目配置（14 字段从 BMad 提取或手填），仅由 `/harness-zh:init` 在缺失时从 template 投放，由 solo-dev 编辑维护。

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
```

退出码处理同 init §A.4：
- 0 → 报告
- 1（`core.hooksPath` 已自定义）→ stderr WARN 给用户，不 halt

## 6. 报告

```
✅ /harness-zh:update — 资产同步完成

【部署统计】
  - $INSTALLED installed / $UNCHANGED unchanged / $UPDATED updated
  - yaml: 未触动（按设计；如需 schema 升级见下方 diff 提示）
  - git hooks: <installed / unchanged | WARN: core.hooksPath ...>

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
2. §3 单文件 cp 失败（permission / 磁盘满 / 源文件缺失）→ halt + 报告失败 src/dst + 已部署计数（partial state；solo-dev 自决继续/回滚）
3. install_git_hooks.sh exit ≠ 0 且 ≠ 1（参数错误 / 内部 bug）→ halt + 贴 stderr verbatim
4. runtime quota 信号 → 与 init / run 同款配额模板

**Halt 模板**：

> stage 失败：§<N> in /harness-zh:update
> 现场：[一两句话讲发生了什么]
> 违反规则：[stderr verbatim]
> 已部署：[$INSTALLED installed / $UPDATED updated 计数]
> 待用户决断：[选项 1] 修复后重跑 update（幂等）/ [选项 2] 手工 cp 缺漏文件 / [选项 3] 整轮回滚（rm 已部署文件 + 从 .bak.<ts> 恢复）/ [选项 4] 怀疑 plugin 缺陷 → /harness-zh:report-issue（自动收集 halt 现场 + gh CLI 直提 + 附临时绕过方案）
