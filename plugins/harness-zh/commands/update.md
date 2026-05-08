---
description: 重新投递 harness-zh plugin 资产到当前项目（plugin 升级后用）。刷新 .claude/harness/ + .claude/commands/ + git hooks；不动 harness-project-config.yaml；不触发 BMad 提取。
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

## 1. Plugin 路径探测（同 init §A.0）

```bash
# 1) Claude Code env 变量
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$PLUGIN_ROOT" ] && [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT=""

# 2) 扫 plugin.json 找 name=harness-zh，优先 cache/ 版本化路径
#    **关键**：cache 下 plugin 升级历史会留下多个 <version>/ 目录（Claude Code
#    不一定立即清旧版）。find 顺序是 inode 序（macOS APFS 上随机），不带版本
#    语义；过去的 first-match-wins 实现会让 update 随机选 cache 版本，导致
#    项目副本被老版本反复覆盖（症状：脚本版本漂移、CJK regex 退化等）。
#    改成：收集所有 cache 候选（过 .orphaned_at filter） → sort -V 按 semver
#    降序 → head -1 取最高版。
if [ -z "$PLUGIN_ROOT" ]; then
    # 注：bash 3.2 (macOS 默认) 在 $(...) 里解析 case+glob 有 quirk，
    # 用 [[ == */cache/* ]] 替代 case 模式匹配，bash 3.2/4/5 均兼容
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

# 3) Fallback 任意 plugin.json 命中（marketplaces/git-clone 路径，通常单实例）
if [ -z "$PLUGIN_ROOT" ]; then
    while IFS= read -r manifest; do
        if grep -q '"name":[[:space:]]*"harness-zh"' "$manifest" 2>/dev/null; then
            cand="$(dirname "$(dirname "$manifest")")"
            [ -f "$cand/.orphaned_at" ] && continue
            PLUGIN_ROOT="$cand"
            break
        fi
    done < <(find ~/.claude/plugins -maxdepth 6 -name plugin.json 2>/dev/null)
fi

if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    echo "ERROR: 无法定位 harness-zh plugin 安装目录" >&2
    echo "       已尝试: \${CLAUDE_PLUGIN_ROOT}, ~/.claude/plugins/**/plugin.json" >&2
    exit 1
fi
echo "PLUGIN_ROOT=$PLUGIN_ROOT"
```

## 2. 项目侧目录预检 + 创建（防御 mid-update 删目录场景）

```bash
mkdir -p .claude/harness/{scripts,conventions,prompt-suffixes,prompt-templates,git-hooks}
mkdir -p .claude/commands
```

## 3. 资产投递（同 init §A.2 — cmp/backup/overwrite）

**Source → Dest 配对表**（与 init §A.2 完全一致）：

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

**单文件投递逻辑**：

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

# 子目录递归（用 find + process substitution 替代 shopt+glob — 兼容 bash 与 zsh）
for sub in scripts conventions prompt-suffixes prompt-templates git-hooks; do
    while IFS= read -r src; do
        [ -n "$src" ] && deploy "$src" ".claude/harness/$sub/$(basename "$src")"
    done < <(find "$PLUGIN_ROOT/$sub" -maxdepth 1 -type f 2>/dev/null)
done

# commands（单层 .md）
while IFS= read -r src; do
    [ -n "$src" ] && deploy "$src" ".claude/commands/$(basename "$src")"
done < <(find "$PLUGIN_ROOT/commands" -maxdepth 1 -type f -name '*.md' 2>/dev/null)
```

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
> 待用户决断：[选项 1] 修复后重跑 update（幂等）/ [选项 2] 手工 cp 缺漏文件 / [选项 3] 整轮回滚（rm 已部署文件 + 从 .bak.<ts> 恢复）
