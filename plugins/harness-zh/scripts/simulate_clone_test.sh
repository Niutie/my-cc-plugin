#!/usr/bin/env bash
# Simulate harness clone to a fresh project root — physical "通用化" verification
#
# Strategy（chore-harness-layout-consolidation 升级版）：
#   1. mktemp -d 临时目录
#   2. cp 完整 harness：CLAUDE.md + .claude/ 全（含 commands/skills/harness/） +
#      _bmad/{customize,custom}/（BMad-loaded customization 加载点）
#   3. 在临时目录写最小 harness-project-config.yaml
#   4. assert 新布局 4 个 harness/ 子目录全存在
#   5. assert 0 残留旧路径（_bmad/scripts/ / _bmad/customizations/ / _bmad/templates/ /
#      _bmad/git-hooks/ / .claude/scripts/ / .claude/harness-architecture.md / .claude/answer-policy.md）
#   6. 跑 eval_test_stage_triggers.sh + assert JSON 合理
#   7. 跑 install_git_hooks.sh + assert hook 装上（worktree 兼容）
#   8. assert harness 元文档零 Aegis 硬编码（grep "Aegis AI Audit" 命中 0）
#   9. assert ${project_display_name} 占位符存在
#  10. cleanup
#
# 退出码：0 = 全过；非 0 = 某步骤失败（stderr 含细节）

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

TMPDIR="$(mktemp -d -t harness_clone_test.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "==> simulate clone to: $TMPDIR"

# ---- step 1: 拷贝完整 harness（含 .claude/ 全 + BMad customization 加载点） ----
cp "$REPO_ROOT/CLAUDE.md" "$TMPDIR/CLAUDE.md"
cp -R "$REPO_ROOT/.claude" "$TMPDIR/.claude"
mkdir -p "$TMPDIR/_bmad"
cp -R "$REPO_ROOT/_bmad/customize" "$TMPDIR/_bmad/customize"
cp -R "$REPO_ROOT/_bmad/custom"    "$TMPDIR/_bmad/custom"
mkdir -p "$TMPDIR/_bmad-output/implementation-artifacts/test_artifacts"

# ---- step 2: 写最小 harness-project-config.yaml（覆盖原项目 config） ----
cat > "$TMPDIR/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Test Project'
container_orchestrator: 'docker-compose'
frontend_framework: 'Next.js'
backend_languages:
  - 'TypeScript'
e2e_framework: 'Playwright'

extra:
  frontend_dir: 'frontend'
  e2e_test_subdir: 'tests/e2e'
  container_count: 3
YAML

# ---- step 3: assert 4 个 harness 子目录全存在 ----
echo ""
echo "==> assert 新布局 4 个 harness 子目录"
for d in scripts prompt-suffixes prompt-templates git-hooks; do
    if [ -d "$TMPDIR/.claude/harness/$d" ]; then
        echo "    ✓ .claude/harness/$d/ 存在"
    else
        echo "FAIL: .claude/harness/$d/ 不存在 — 物理布局不完整" >&2
        exit 1
    fi
done

# ---- step 4: assert 0 残留旧路径 ----
echo ""
echo "==> assert 0 残留旧路径"
LEFTOVER=0
# 排除 changelog.md（历史叙事 frozen，不动）+ implementation-artifacts/chore-*.md（27+ 历史 spec frozen）
LEFTOVER_HITS="$(grep -rnE '_bmad/(scripts|customizations|templates|git-hooks)|\.claude/scripts|\.claude/(harness-architecture|harness-changelog|answer-policy)\.md' \
    "$TMPDIR/CLAUDE.md" \
    "$TMPDIR/.claude/commands" \
    "$TMPDIR/.claude/harness/architecture.md" \
    "$TMPDIR/.claude/harness/answer-policy.md" \
    "$TMPDIR/.claude/harness/scripts" \
    "$TMPDIR/.claude/harness/prompt-suffixes" \
    "$TMPDIR/.claude/harness/prompt-templates" \
    "$TMPDIR/.claude/harness/git-hooks" \
    "$TMPDIR/_bmad/customize" \
    2>/dev/null \
    | grep -v "_bmad/scripts/resolve_" \
    | grep -v "/simulate_clone_test\.sh:" \
    || true)"

if [ -n "$LEFTOVER_HITS" ]; then
    echo "FAIL: 残留旧路径引用 — chore-harness-layout-consolidation 半搬不全" >&2
    echo "$LEFTOVER_HITS" | head -10 >&2
    LEFTOVER=$(printf '%s' "$LEFTOVER_HITS" | wc -l | tr -d ' ')
    echo "  共 $LEFTOVER 处残留" >&2
    exit 2
fi
echo "    ✓ 0 处残留旧路径"

# ---- step 5: 临时 spec.md（无 NFR / trace 关键词 — 走 baseline path） ----
SPEC="$TMPDIR/_bmad-output/implementation-artifacts/sample-story.md"
echo "# Sample story for simulate clone test" > "$SPEC"

# ---- step 6: 跑 eval 脚本，断言 JSON ----
echo ""
echo "==> eval_test_stage_triggers.sh"
cd "$TMPDIR"
EVAL_OUT="$(bash .claude/harness/scripts/eval_test_stage_triggers.sh sample-story \
    _bmad-output/implementation-artifacts/sample-story.md 2>/dev/null)"
echo "    eval JSON: $EVAL_OUT"

if ! printf '%s' "$EVAL_OUT" | grep -q '"reason": "real_eval"'; then
    echo "FAIL: eval did not return real_eval reason — got: $EVAL_OUT" >&2
    exit 3
fi
if ! printf '%s' "$EVAL_OUT" | grep -qE '"t3":[[:space:]]*true'; then
    echo "FAIL: eval JSON missing t3=true (per_story triggers) — got: $EVAL_OUT" >&2
    exit 4
fi
if ! printf '%s' "$EVAL_OUT" | grep -qE '"t4":[[:space:]]*true'; then
    echo "FAIL: eval JSON missing t4=true — got: $EVAL_OUT" >&2
    exit 5
fi
if ! printf '%s' "$EVAL_OUT" | grep -qE '"teach":[[:space:]]*false'; then
    echo "FAIL: eval JSON teach should be false (manual_only) — got: $EVAL_OUT" >&2
    exit 6
fi
echo "    ✓ eval JSON 合理（real_eval / t3=true / t4=true / teach=false）"

# ---- step 7: 跑 install_git_hooks（在 git 仓库 init 后） ----
echo ""
echo "==> install_git_hooks.sh"
git init -q "$TMPDIR" >/dev/null 2>&1 || true
if bash "$TMPDIR/.claude/harness/scripts/install_git_hooks.sh" >/dev/null 2>&1; then
    if [ -x "$TMPDIR/.git/hooks/pre-commit" ]; then
        echo "    ✓ install_git_hooks.sh 装上 pre-commit hook"
    else
        echo "FAIL: install_git_hooks 跑通但 .git/hooks/pre-commit 缺失" >&2
        exit 7
    fi
else
    echo "FAIL: install_git_hooks.sh 退出非 0（新布局应能跑）" >&2
    exit 8
fi

# ---- step 8: grep harness 元文档 + fresh agent prompt 模板无 Aegis 硬编码 ----
# (2026-05-05 扩展：加 *_prompt.md fresh agent 模板 — 这些是真发到 fresh agent 的
# prompt，clone 后必须按 ${project_display_name} 占位符替换，否则 fresh agent 会
# 以为还在原项目里。)
echo ""
echo "==> grep harness 元文档 + prompt 模板 'Aegis AI Audit'（期望 0 命中）"
GREP_HITS=0
PROMPT_TEMPLATES="$(ls "$TMPDIR/.claude/harness/scripts/"*_prompt.md 2>/dev/null | sed "s|^$TMPDIR/||" || true)"
for f in CLAUDE.md .claude/harness/architecture.md \
         .claude/commands/run.md .claude/commands/run-test.md \
         $PROMPT_TEMPLATES; do
    if [ -f "$TMPDIR/$f" ]; then
        hits="$(grep -c "Aegis AI Audit" "$TMPDIR/$f" 2>/dev/null)"
        hits="${hits:-0}"
        if [ "$hits" -gt 0 ]; then
            echo "    ✗ $f 命中 $hits 次 'Aegis AI Audit'"
            GREP_HITS=$((GREP_HITS + hits))
        else
            echo "    ✓ $f 已 placeholder 化"
        fi
    fi
done

if [ "$GREP_HITS" -gt 0 ]; then
    echo "FAIL: 共 $GREP_HITS 处 'Aegis AI Audit' 残留 — chore 改造不完整" >&2
    exit 9
fi

# ---- step 9: 验证 ${project_display_name} 占位符存在 ----
echo ""
echo "==> assert \${project_display_name} 占位符存在"
if grep -q '${project_display_name}' "$TMPDIR/.claude/harness/architecture.md" 2>/dev/null; then
    echo "    ✓ .claude/harness/architecture.md 含 \${project_display_name} 占位符"
else
    echo "FAIL: .claude/harness/architecture.md 未发现 \${project_display_name} 占位符（仍 hardcoded）" >&2
    exit 10
fi

# ---- step 10: 自定义 artifacts_root fixture（path-externalization 验证） ----
# 在已有 TMPDIR 上 mutate config + create docs/specs/ + sprint-status.py 跑通
echo ""
echo "==> custom artifacts_root fixture (artifacts_root: docs/specs)"
cat > "$TMPDIR/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Custom Project'
container_orchestrator: 'docker-compose'
frontend_framework: 'Next.js'
backend_languages:
  - 'TypeScript'
e2e_framework: 'Playwright'

artifacts_root: 'docs/specs'

extra:
  frontend_dir: 'frontend'
  e2e_test_subdir: 'tests/e2e'
YAML

# 建 docs/specs/sprint-status.yaml fixture
mkdir -p "$TMPDIR/docs/specs"
cat > "$TMPDIR/docs/specs/sprint-status.yaml" <<'YAML'
development_status:
  9-1-fixture-story: done
retro_action_items: {}
YAML

# 跑 sprint-status.py — 应读 docs/specs/sprint-status.yaml
cd "$TMPDIR"
CUSTOM_OUT="$(python3 .claude/harness/scripts/sprint-status.py status 9-1-fixture-story 2>&1)"
if [ "$CUSTOM_OUT" = "done" ]; then
    echo "    ✓ sprint-status.py 读 docs/specs/sprint-status.yaml + 输出 done"
else
    echo "FAIL: custom artifacts_root 未生效；sprint-status.py 输出：$CUSTOM_OUT" >&2
    exit 11
fi

# 反向验证：bash helper 也读了新值
CUSTOM_SH="$(bash -c "source $TMPDIR/.claude/harness/scripts/read_harness_config.sh 2>&1; echo \"\$HARNESS_ARTIFACTS_ROOT\"")"
if printf '%s' "$CUSTOM_SH" | grep -q "docs/specs"; then
    echo "    ✓ read_harness_config.sh HARNESS_ARTIFACTS_ROOT contains 'docs/specs'"
else
    echo "FAIL: bash helper 未读到 docs/specs；output: $CUSTOM_SH" >&2
    exit 12
fi

# ---- summary ----
echo ""
echo "================================"
echo " simulate_clone_test: ALL CHECKS PASSED"
echo "================================"
echo " temp dir (cleaned on exit): $TMPDIR"
exit 0
