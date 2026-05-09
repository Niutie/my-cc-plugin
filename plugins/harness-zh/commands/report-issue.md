---
description: 自动收集 plugin 版本 / 当前 sprint+story 状态 / halt 现场等上下文，用 gh CLI 直接给 Niutie/my-cc-plugin 提 GitHub issue。halt 时提完会附一个临时绕过方案。
argument-hint: '[--type bug|feature|halt|other] [--story KEY] [--epic N] [--halt-stage N] [--halt-command run|run-test|init|update|upgrade-deferred-work]'
allowed-tools: Bash, Read, Write, AskUserQuestion
---

# /harness-zh:report-issue — 一键给 plugin 作者提 GitHub issue

你是这个命令的**主 orchestrator**。当用户触发 `/harness-zh:report-issue`，自动收集当前项目的 plugin/sprint/halt 上下文，让用户拍板"提交还是取消"，确认后用 `gh` CLI 直提 issue 到 `Niutie/my-cc-plugin`。

**触发场景**：

1. **halt 时**：`/harness-zh:run` / `run-test` / `init` 等任一命令进入 §3 halt 模板"待用户决断"页面，用户怀疑这是 plugin 缺陷而非项目侧问题 — 选项 6 引导跑本命令
2. **阶段收尾随手**：sprint / 单 story 跑完后用户回想到刚才哪一段不顺手 — 主动跑本命令
3. **ad-hoc 反馈**：用户日常使用时发现任何 plugin 行为/文档/脚本问题，随时跑

**与已弃用的 `upstream-feedback.md` 通道的关系**：v0.1.26 起 plugin 不再维护 `upstream-feedback.md` 流程（`extract_harness_feedback.sh` / `detect_harness_residue.sh` / `templates/upstream-feedback.md.template` 已删；retro skill 不再分流到该文件）。所有给 plugin 作者的反馈一律走本命令，自动收集上下文 + 一步直提，比手工复制粘贴 markdown 提 issue 损耗低。

**共享行为契约**（与 init / update 一致）：
- 代答政策：不调度子 agent；决策按 `.claude/harness/answer-policy.md` 自决
- TaskCreate 任务 `Harness Report Issue: <one-line desc>`（§1 启动 in_progress；§5 报告 completed）
- 不动任何 git 状态（不 commit / 不 push / 不切 branch）；只读取信息

---

## 1. 解析输入参数 + 兜底向用户问

参数从 `$ARGUMENTS` 解析。**所有参数都可省略** — 缺什么用 `AskUserQuestion` 兜底。

支持的 flag（顺序不固定）：

| Flag | 取值 | 说明 |
|---|---|---|
| `--type` | `bug` / `feature` / `halt` / `other` | issue 类型（label） |
| `--story` | story KEY，如 `1-3-login-flow` | 当前 story 上下文 |
| `--epic` | epic 编号 | 当前 epic 上下文 |
| `--halt-command` | `run` / `run-test` / `init` / `update` / `upgrade-deferred-work` / `other` | halt 来自哪个命令 |
| `--halt-stage` | 阶段编号（如 `2` / `5` / `T3` / `A.3.d`） | halt 在哪个 stage |
| `--halt-reason` | 一句话现场摘要 | halt 触发条件 / 报错关键句 |

如 `$ARGUMENTS` 含 `--halt` 但无 `--type`，自动设 `--type halt`。

**Halt 场景 fast-path**：当主 agent 自己刚刚走完 §3 halt 模板（其上下文里有 `LOOP_SCOPE` / `TARGET_KEY` / `TARGET_EPIC` / 当前 stage / halt REASON），**直接复用**这些值预填，不再问用户；只追问 `--type`（默认 `halt`）+ `--description`（halt 现场摘要）。

**ad-hoc 场景**：

- `--type` 缺 → `AskUserQuestion`，single-select，header `Issue type`：
  - `bug` — plugin 行为有 bug / 不符预期
  - `feature` — 新功能 / 改进建议
  - `halt` — halt 后定位是 plugin 问题
  - `other` — 其他（文档 / 教学缺口 / 提问）
- `--description` 总是要问（一句话），无默认。`AskUserQuestion` 提供"Other"自由输入即可达到 free-text 效果。
- 如果 `--type=halt` 且 `--halt-stage` / `--halt-command` 缺，逐个问。

---

## 2. 调采集脚本拼 issue body

```bash
TYPE="${TYPE:?}"
DESC="${DESC:?}"
ARGS=( --type "$TYPE" --description "$DESC" )
[ -n "${STORY:-}" ]         && ARGS+=( --story "$STORY" )
[ -n "${EPIC:-}" ]          && ARGS+=( --epic "$EPIC" )
[ -n "${HALT_CMD:-}" ]      && ARGS+=( --halt-command "$HALT_CMD" )
[ -n "${HALT_STAGE:-}" ]    && ARGS+=( --halt-stage "$HALT_STAGE" )
[ -n "${HALT_REASON:-}" ]   && ARGS+=( --halt-reason "$HALT_REASON" )

BODY_FILE="$(mktemp -t harness-issue-XXXXXX.md)"
bash .claude/harness/scripts/collect_issue_context.sh "${ARGS[@]}" > "$BODY_FILE"
```

脚本退出码总是 0（best-effort）；只有 `--type` / `--description` 缺才退出 2，那时主 agent 的参数兜底逻辑就有 bug，halt + 报告。

把 `$BODY_FILE` 完整内容**显示给用户**让其 review（直接 `cat $BODY_FILE` 输出到对话流即可；不要省略）。

---

## 3. Title + label

按 type 拼：

| TYPE | Title 形式 | gh label |
|---|---|---|
| `bug` | `[bug] <DESC>` | `bug` |
| `feature` | `[feature] <DESC>` | `enhancement` |
| `halt` | `[halt][${HALT_CMD:-?} stage ${HALT_STAGE:-?}] <DESC>` | `bug,halt-recovery` |
| `other` | `[other] <DESC>` | `question` |

Title 长度截断到 ≤ 100 字符（`gh` 接受更长但 GitHub UI 不友好）：

```bash
TITLE="$(printf '%s' "$TITLE" | awk 'length>100 {print substr($0,1,97) "..."} length<=100 {print}')"
```

---

## 4. 用户确认 + 提交

`AskUserQuestion`（**单选**，header `Submit issue`）：

> **A) Submit now（推荐）** — 跑 `gh issue create`，把 issue 直接提交到 `Niutie/my-cc-plugin`
>
> **B) Edit body first** — 主 agent 暂停；用户手工编辑 `$BODY_FILE`（emit 路径），编辑完再说"continue"主 agent 续提交
>
> **C) Cancel** — 不提，删 `$BODY_FILE`，emit "已取消"

**A) 路径执行**：

```bash
# Preflight: gh CLI 装了？已 auth？
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI 未安装" >&2
    echo "  macOS: brew install gh" >&2
    echo "  其他: https://cli.github.com/manual/installation" >&2
    echo "装好后跑 'gh auth login' 再重试 /harness-zh:report-issue" >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh CLI 未登录" >&2
    echo "  跑 'gh auth login' 完成 OAuth 后重试" >&2
    exit 1
fi

# 提交
ISSUE_URL="$(gh issue create \
    --repo Niutie/my-cc-plugin \
    --title "$TITLE" \
    --body-file "$BODY_FILE" \
    --label "$LABEL" 2>&1)"
GH_EXIT=$?

if [ $GH_EXIT -eq 0 ]; then
    echo "✅ Issue 提交成功"
    echo "   $ISSUE_URL"
else
    echo "❌ gh issue create 失败 (exit $GH_EXIT)"
    echo "   stderr verbatim:"
    echo "   $ISSUE_URL"
    echo ""
    echo "Body 文件保留以便手工提交：$BODY_FILE"
    echo "或：cat $BODY_FILE | pbcopy && open https://github.com/Niutie/my-cc-plugin/issues/new"
    exit 1
fi
```

`gh` 拿不到 label（label 不存在）时它会 ignore label 但 issue 仍提交；不需要主 agent 介入。

**B) Edit 路径**：emit 一行说明：

> Body 已写到：`$BODY_FILE`
>
> 编辑完成后跟我说 "继续提交" / "submit" / "ok"，我会重新走第 4 步 A 路径（不再问 type / description，直接提交编辑后的 body 文件）。

主 agent 等待用户下一条消息含 "submit" / "继续" / "ok" / "go" 关键词，才走 A 路径；其他指令视为新任务，本流程结束。

**C) Cancel 路径**：

```bash
rm -f "$BODY_FILE"
echo "ℹ️ 已取消；未提交 issue。"
```

---

## 5. Halt 场景：附临时绕过方案

仅当 `TYPE=halt`：提交成功后，主 agent **必须**额外输出一段「临时绕过方案」让用户继续推进项目，而不是被这条 halt 卡死等 plugin 修复。模板：

> 🩹 **临时绕过方案**（提完 issue 后，可让你继续推进项目，不必等 plugin 修复）：
>
> 现场：`/harness-zh:<HALT_CMD>` stage `<HALT_STAGE>` 在 `<DESC>` 处 halt。
>
> 建议绕过路径（**任选**，按你的风险偏好）：
>
> 1. **手工跳过**：[根据 halt 现场，主 agent 给一条具体的跳过指令；如 `python3 .claude/harness/scripts/sprint-status.py set <KEY> done` 把当前 story 翻 done 后直接跑下一条]
> 2. **绕开 gate**：[如果 halt 是某个 check_*.sh 阻断，主 agent 给具体的 sed 命令暂时把对应规则注释掉，并在 issue 里粘 sed diff 让作者看到]
> 3. **回滚到上一 commit**：`git reset --hard harness/<KEY>/start`（彻底撤回该 story；选项 1 / 2 都不可行时保命用）
> 4. **等修复**：subscribe issue 通知，issue close 后跑 `/plugin marketplace update my-cc-plugin && /harness-zh:update` 拉新版重试
>
> ⚠️ 1 / 2 都是**临时绕过**，不是修复。建议在原 halt 现场附近加 TODO 注释指向这条 issue（`# TODO(plugin-issue: <URL>)`），plugin 修好后顺手清理。

**主 agent 的责任**：根据 halt 现场（手里有 `HALT_CMD` / `HALT_STAGE` / `HALT_REASON` / 子 agent 报错原文），给出**具体可跑**的 shell / git 指令，而不是上面占位文本。如果现场信息不足（缺 stage / 缺 reason），只给保底的"3. 回滚"+"4. 等修复"两条，emit 一行说明"halt 现场信息不全 — 建议详细的绕过方案需要看 issue 里的 halt context 后由 plugin 作者建议"。

---

## 6. TaskCreate 收尾 + 报告

把 §0 创建的 TaskCreate 任务标 `completed`，emit 一行总结：

```
✅ /harness-zh:report-issue 完成
   - Type: $TYPE
   - Issue: $ISSUE_URL
   - 上下文：harness-zh $PLUGIN_VERSION / $GIT_BRANCH @ $GIT_HEAD / story $STORY (可缺)
   <halt 时多一行>
   - 临时绕过：见上文 §5
```

退出码 0。

---

## 7. 死循环 / 失控防护

下列任一命中立即 halt + 用户介入（与 init §A.4 / run §3 防护表精神一致）：

1. §1 用户取消（"Cancel" 选项）→ emit "已取消"，**正常退出**（非 halt；用户主动行为）
2. §1 / §2 `collect_issue_context.sh` exit ≠ 0 且 ≠ 2（参数 bug / 内部错）→ halt + 贴 stderr verbatim
3. §4 A 路径 `gh` 未装 / 未登录 → 不 halt（已在脚本内 emit 引导文字）；exit 1 给主 agent 知道，主 agent emit 一行"装好 gh 后重跑 /harness-zh:report-issue"，正常退出
4. §4 A 路径 `gh issue create` exit ≠ 0（rate limit / repo 权限问题 / 网络问题）→ 不 halt；emit 失败原因 + body 文件路径 + 手工 fallback 指令（已在脚本内）；正常退出
5. runtime quota 信号 → 与 init / run 同款配额模板（emit halt 模板请求用户授权重启）

**Halt 模板**（仅 §7-2 / 7-5 适用）：

> stage 失败：§<N> in /harness-zh:report-issue
> 现场：[一两句话讲发生了什么]
> 违反规则：[stderr verbatim]
> 待用户决断：[选项 1] 修复后重跑 / [选项 2] 手工 cat $BODY_FILE 复制粘贴提到 https://github.com/Niutie/my-cc-plugin/issues/new
