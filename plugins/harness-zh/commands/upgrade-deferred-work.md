---
description: 复测 deferred-work.md schema v1 conformance；按现状给 solo-dev 三档选择（advisory 共存 / archive+greenfield / 手工 backfill 指南）。半路接入项目时由 init §A.3.c 自动唤起；solo-dev 也可事后手工跑本命令切换 mode。
---

# /harness-zh:upgrade-deferred-work — deferred-work schema 复测 + 模式切换

你是这个 upgrade 的**主 orchestrator**。当用户触发 `/harness-zh:upgrade-deferred-work`，
跑一次 detector，然后按 `init §A.3.c` 同款三档交互让 solo-dev 决定如何处理历史 legacy
条目。

**触发场景**：
1. solo-dev 在 init 时选了 advisory，后来手工 backfill 了一部分历史条目，想复测 + 切回 strict
2. solo-dev 跳过了 init 的检测（pristine 时不询问），后来项目里手工导入了 legacy 数据想升级
3. plugin 版本升级带来更准的 detector，想重测一次现状

**与 `/harness-zh:init §A.3.c` 的差异**：
- init §A.3.c 仅在 `DW_BOOTSTRAPPED=0` 且文件 pre-existed 时进；本命令**总是**进
- 本命令不投放 plugin 资产 / 不装 hooks / 不跑 BMad 提取 — 只做 deferred-work 复测 + mode 切换
- 本命令对 `pristine` / `v1_clean` 也输出报告（init 只 silent OK）— 让 solo-dev 看到实数

---

## 1. 前置探测

### 1.1 yaml 在场

```bash
YAML_DST=".claude/harness/harness-project-config.yaml"
if [ ! -f "$YAML_DST" ]; then
    cat <<'EOF'
ERROR: .claude/harness/harness-project-config.yaml 不存在
       本命令需要 yaml 来读 / 写 deferred_work_mode 字段。
       先跑 /harness-zh:init 投放 yaml + 资产再来。
EOF
    exit 1
fi
```

### 1.2 detector 脚本在场

```bash
DETECT="bash .claude/harness/scripts/detect_deferred_work_schema.sh"
if [ ! -x ".claude/harness/scripts/detect_deferred_work_schema.sh" ]; then
    cat <<'EOF'
ERROR: .claude/harness/scripts/detect_deferred_work_schema.sh 不存在或不可执行
       本命令是 plugin v0.1.13+ 引入的，旧 init / update 部署的项目可能无此脚本。
       先跑 /harness-zh:update 刷新 plugin 资产再来。
EOF
    exit 1
fi
```

---

## 2. 跑 detector + 解析 JSON

```bash
DETECT_JSON="$($DETECT 2>/dev/null)"
DETECT_EXIT=$?
```

按 exit code 处理：

| DETECT_EXIT | 含义 | 行为 |
|---|---|---|
| `0` | 成功，JSON 含 classification | 进 §3 分类分支 |
| `2` | deferred-work.md 不存在 | emit 提示 + 跑 `/harness-zh:init`（init §A.3.b 会 bootstrap）→ 退出 |
| 其他 | detector 异常 | emit JSON + stderr verbatim + halt（怀疑 plugin 缺陷可跑 `/harness-zh:report-issue` 直提 issue） |

从 JSON 提取（用 `python3 -c` 或 `jq`，按项目 toolchain 选）：

```bash
CLASSIFICATION="$(printf '%s' "$DETECT_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("classification",""))')"
FU_TOTAL="$(printf '%s' "$DETECT_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("fu_total",0))')"
FU_V1="$(printf '%s' "$DETECT_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("fu_v1",0))')"
FU_LEGACY_HEAD="$(printf '%s' "$DETECT_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("fu_legacy_head",0))')"
FU_LEGACY_INLINE="$(printf '%s' "$DETECT_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("fu_legacy_inline_resolved",0))')"
FU_RETRO_NS="$(printf '%s' "$DETECT_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("fu_retro_namespace",0))')"
V1_PCT="$(printf '%s' "$DETECT_JSON" | python3 -c 'import sys,json; print(round(json.load(sys.stdin).get("v1_pct",0)*100,1))')"
```

读当前 mode：

```bash
CURRENT_MODE="$(grep -E '^deferred_work_mode:' "$YAML_DST" | head -1 | sed -E "s/^deferred_work_mode:[[:space:]]+//;s/^['\"]//;s/['\"]$//")"
[ -z "$CURRENT_MODE" ] && CURRENT_MODE="strict"  # 缺字段视为 strict（plugin 升级前装的旧 yaml）
```

---

## 3. 按 classification 分支

### 3.1 `pristine`（fu_total = 0）

emit：

```
ℹ️ deferred-work.md 当前为空（无 FU 条目；schema v1 ready）
   - 当前 mode: ${CURRENT_MODE}
   - 无需操作。第一条 FU 由 dev / review / chore agent 按 schema v1 自动写入。
```

**例外**：如果 `CURRENT_MODE=advisory` 但文件已 pristine，提示用户可切回 strict：

> 当前 mode 是 `advisory`，但 deferred-work.md 已无 FU 条目（pristine）。是否切回 `strict`？

`AskUserQuestion`（**单选**，header `Mode flip`）：
- **A) Yes, 切到 strict** — sed 改 yaml 字段为 `'strict'`，emit OK
- **B) No, 保持 advisory** — emit "保持 advisory；下次有历史数据时不会被新逻辑误读"

### 3.2 `v1_clean`（fu_v1 / fu_total ≥ 0.95）

emit：

```
✅ deferred-work.md schema v1 conformant
   - 总 FU: ${FU_TOTAL}（v1 已标 ${FU_V1} / ${V1_PCT}%）
   - legacy 残余 4-tag 缺失: ${FU_LEGACY_HEAD}
   - 当前 mode: ${CURRENT_MODE}
```

如果 `CURRENT_MODE=advisory` → 提示切回 strict（同 3.1 例外路径，AskUserQuestion 二选一）。
如果 `CURRENT_MODE=strict` → emit "无需操作"，退出。

### 3.3 `mixed` / `legacy` — 三档交互

emit 现状报告（同 init §A.3.c.i）：

```
⚠️ deferred-work.md schema v1 不一致
   - 总 FU: ${FU_TOTAL}
   - schema v1 4-tag 已标: ${FU_V1}（${V1_PCT}%）
   - legacy 4-tag 缺失: ${FU_LEGACY_HEAD}
   - legacy inline `Resolved by Story` 后缀: ${FU_LEGACY_INLINE}
   - FU-RETRO-* 命名空间（schema v1 §3.2 禁止）: ${FU_RETRO_NS}
   - 当前 mode: ${CURRENT_MODE}
```

`AskUserQuestion`（**单选**，header `DW migration`）— 同 init §A.3.c.i 三档：

> **A) Advisory 共存（推荐）** — 设 `deferred_work_mode: advisory`；§1 总账按 v1 子集解读
>
> **B) Archive + greenfield** — `mv deferred-work.md deferred-work.legacy-pre-schema-v1.md`，重新投放空白模板
>
> **C) Backfill 指南（手工）** — 不改文件，emit schema §5 backfill 指南

执行（与 init §A.3.c.i 完全同款；为避免内容漂移，**直接调用 init 的实现路径**：复用其
sed yaml-update 片段 + archive 片段 + 指南文本块）：

#### 3.3.A）Advisory

```bash
if grep -qE "^deferred_work_mode:" "$YAML_DST"; then
    sed -i.bak -E "s/^deferred_work_mode:.*$/deferred_work_mode: 'advisory'/" "$YAML_DST"
    rm -f "$YAML_DST.bak"
else
    printf '\n# %s\ndeferred_work_mode: %s\n' \
        "Added by /harness-zh:upgrade-deferred-work on $(date +%Y-%m-%d)" \
        "'advisory'" >> "$YAML_DST"
fi
```

emit OK：

```
✅ deferred_work_mode: ${CURRENT_MODE} → advisory
   - §1 总账 / grep 工具按 v1-tagged 子集口径输出
   - 新增 FU 仍受 pre-commit gate ② 强制
   - 想升级到 strict：先 backfill 历史条目，再重跑本命令
```

#### 3.3.B）Archive + greenfield

**安全顺序**：先解析模板源（plugin 路径探测 / fallback inline），**确认源可用后**再做归档
`mv`；任何步骤失败必须**回滚**已 `mv` 的归档文件，避免主账本永久缺失。

```bash
DW_DIR="_bmad-output/implementation-artifacts"
DW_DST="$DW_DIR/deferred-work.md"

# 步骤 1: 解析 plugin templates/ 路径（同 /harness-zh:update §1 探测逻辑）
# cache 下多版本时按 semver 降序取最高版（避免 inode-order first-match-wins 的随机选版 bug）
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$PLUGIN_ROOT" ] && [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT=""
if [ -z "$PLUGIN_ROOT" ]; then
    # bash 3.2 (macOS 默认) 在 $(...) 里 case+glob 有 quirk，用 [[ == ]] 替代
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

# 步骤 2: 决定 source mode（plugin-template 优先；探测失败 → inline-fallback）
TEMPLATE_PATH=""
if [ -n "$PLUGIN_ROOT" ] && [ -f "$PLUGIN_ROOT/templates/deferred-work.md.template" ]; then
    TEMPLATE_PATH="$PLUGIN_ROOT/templates/deferred-work.md.template"
    SOURCE_MODE="plugin-template"
else
    SOURCE_MODE="inline-fallback"
fi

# 步骤 3: 算归档路径（防 collision）
ARCHIVE_PATH="$DW_DIR/deferred-work.legacy-pre-schema-v1.md"
if [ -f "$ARCHIVE_PATH" ]; then
    ARCHIVE_PATH="$DW_DIR/deferred-work.legacy-pre-schema-v1.$(date +%Y%m%d-%H%M%S).md"
fi

# 步骤 4: mv 归档；步骤 5: 写入新模板，**失败必须 rollback** mv
mv "$DW_DST" "$ARCHIVE_PATH"

WRITE_OK=0
if [ "$SOURCE_MODE" = "plugin-template" ]; then
    if cp "$TEMPLATE_PATH" "$DW_DST"; then
        WRITE_OK=1
    fi
else
    if cat > "$DW_DST" <<'TPL'
# Deferred Work

跨 story 延后项总账。每条 FU 必须使用 schema v1 4-tag 头：
`[status:...] [bucket:...] [target:...] [source:...]`。

完整契约见 `.claude/harness/conventions/deferred-work-schema.md`。
工具链：`bash .claude/harness/scripts/grep_deferred_buckets.sh` 看总账。

---

## §1 总账概览（auto-generated）
<!-- AUTO-GENERATED by .claude/harness/scripts/grep_deferred_buckets.sh — do not hand-edit -->
（脚本首次跑后插入桶计数表 + critical evaluation 段）
<!-- /AUTO-GENERATED -->

---

（暂无延后项 — 第一条 FU 由 dev / review / chore agent 按 schema v1 写入。）
TPL
    then
        WRITE_OK=1
    fi
fi

if [ "$WRITE_OK" != "1" ]; then
    # Rollback: 把刚 mv 走的 legacy 文件搬回来
    mv "$ARCHIVE_PATH" "$DW_DST"
    cat <<'ERREOF' >&2
ERROR: greenfield 写入新 deferred-work.md 失败 — 已回滚归档操作。
       PLUGIN_ROOT='${PLUGIN_ROOT}'  TEMPLATE_PATH='${TEMPLATE_PATH}'  SOURCE_MODE='${SOURCE_MODE}'
       检查文件系统权限 / 磁盘空间 / plugin 路径，再重跑 /harness-zh:upgrade-deferred-work。
ERREOF
    exit 1
fi

# 步骤 6: 同步 mode → strict（greenfield 后新文件 100% v1）
if grep -qE "^deferred_work_mode:" "$YAML_DST"; then
    sed -i.bak -E "s/^deferred_work_mode:.*$/deferred_work_mode: 'strict'/" "$YAML_DST"
    rm -f "$YAML_DST.bak"
fi
```

emit OK：

```
✅ deferred-work.md greenfield（schema v1 空白模板；source: ${SOURCE_MODE}）
   - 历史归档: ${ARCHIVE_PATH}
   - deferred_work_mode: ${CURRENT_MODE} → strict
```

> **设计原则**：先确认 source 可用 + 算好归档路径，再做不可逆的 `mv`。`cp` / `cat` 失败
> 自动 rollback `mv`，确保 `deferred-work.md` 任意时刻**恒存在**（避免主账本缺失窗口）。
> 早期实现先 mv 再 cp 且未定义 PLUGIN_ROOT，会留下"归档已走、新文件未生"的不可逆状态
> （codex review 0.1.14 指出；0.1.16 修）。

> **Plugin 路径探测失败**：上面 `SOURCE_MODE=inline-fallback` 路径已 cover；仍要警示 — 
> 如发现实际生产里频繁走 fallback，说明 plugin 安装位置非标准，需要修探测逻辑而非依赖 fallback。
> Inline 模板内容与 `plugin templates/deferred-work.md.template` 保持一致；future 模板演进
> 需同步更新步骤 5 的 heredoc。

#### 3.3.C）Backfill 手工指南

不改文件、不改 mode。emit 指南块（同 init §A.3.c.i 选 C）：

```
ℹ️ 维持现状。Backfill 路径（手工）：
   1. 阅读 .claude/harness/conventions/deferred-work-schema.md §5
   2. Pass 1（机器辅助 ~80%）：用 LLM 单批改写历史段
   3. Pass 2（人工兜底 ~20%）：FU-RETRO-* 移至 sprint-status.yaml.retro_action_items；
      bucket 歧义 / 跨 epic 联动手工拍板
   4. Pass 3（验证）：bash .claude/harness/scripts/grep_deferred_buckets.sh
   5. 完成后重跑 /harness-zh:upgrade-deferred-work 复测；通过则切 strict

   当前 mode 保持 ${CURRENT_MODE}（用户未选切换）。
```

---

## 4. 收尾

emit 一行总结：

```
✅ /harness-zh:upgrade-deferred-work 完成
   - classification: ${CLASSIFICATION}
   - mode: ${OLD_MODE} → ${NEW_MODE}（或保持 ${CURRENT_MODE}）
```

**不**触发 commit；mode 切换 / archive 操作产生的改动留给 solo-dev 自决（一般紧跟一次手工
`git add` + commit；commit message 建议 `chore(harness): switch deferred_work_mode to <mode>`
或 `chore(harness): archive legacy deferred-work.md + greenfield schema v1`）。
