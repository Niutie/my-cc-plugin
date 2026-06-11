#!/usr/bin/env bash
# release_check — pre-tag / pre-publish gate for the harness-zh marketplace.
#
# 校验五件 things：
#   (1) 版本一致性（四处）：plugin.json（SoT）=== marketplace.json 里 harness-zh 的
#       version === README.md 版本表（顶部 plugin 表 + Versioning 表首行）===
#       changelog.md 头条 `## vX.Y.Z` 版本号。前两处防 0.1.16 / 0.1.26 那种漂移再发生
#       （详 changelog v0.1.26 codex review）；后两处是 review 2026-06-10 finding #42 —
#       changelog 头条是 collect_issue_context.sh 运行时取版本号的事实来源，README 表
#       历史上漂移过 0.1.17-0.1.25 连续 9 个版本。
#   (2) commands/*.md frontmatter 必须能被 PyYAML 解析（防 report-issue.md 类 unquoted
#       flow-sequence 错误：argument-hint: [a] [b] 直接报 'expected <block end>'）。
#   (3) run.md 不得回流『主 agent 手工 set 兜底』指令性协议（review finding #70 —
#       现协议 2026-05-04 起 sync 责任全在 harness-commit.py，主 agent 不再调 set；
#       否定句『不再/不要 … set 兜底』属协议说明，放行）。
#   (4) upgrade-deferred-work.md 的 inline heredoc fallback 模板必须与
#       templates/deferred-work.md.template 逐字节一致（review finding #67 — 该一致性
#       是 md 文件自述的不变量，此前仅靠注释自律，已实际漂移过一次）。
#   (5) scripts/ 下带 shebang 的文件必须有可执行位（regression R2 2026-06-10 —
#       harness-commit.py / harness-state.py 工作区 100755→100644 丢位，index 仍
#       755，git add 后会把 644 写进 index 破坏部署侧调用）。sourceable lib
#       （只被 source / import、从不直接执行）走显式豁免名单。
#
# 不需要外部依赖：jq / python3 即可（python3 配合 PyYAML；缺 PyYAML 时 fall back 到
# 仅做 frontmatter 是否 well-fenced 的最低检查 + WARN）。
#
# 用法：
#   bash plugins/harness-zh/scripts/release_check.sh                       # 自动定位 marketplace
#   MARKETPLACE_JSON=...json PLUGIN_JSON=...json bash release_check.sh     # override
#
# 退出码：
#   0  — 全过
#   2  — 版本不一致（四处任一）
#   3  — 至少一个 commands/*.md frontmatter 无法解析
#   4  — run.md 出现指令性『主 agent set 兜底』回流
#   5  — upgrade-deferred-work.md heredoc 与 deferred-work.md.template 漂移
#   6  — scripts/ 下带 shebang 的非豁免文件缺可执行位
#   1  — 内部错误（找不到 marketplace.json / plugin.json / README / changelog / template）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ → plugins/harness-zh/ → plugins/ → repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MARKETPLACE_JSON="${MARKETPLACE_JSON:-$REPO_ROOT/.claude-plugin/marketplace.json}"
PLUGIN_JSON="${PLUGIN_JSON:-$PLUGIN_DIR/.claude-plugin/plugin.json}"
COMMANDS_DIR="${COMMANDS_DIR:-$PLUGIN_DIR/commands}"
README_MD="${README_MD:-$REPO_ROOT/README.md}"
CHANGELOG_MD="${CHANGELOG_MD:-$PLUGIN_DIR/changelog.md}"
DW_TEMPLATE="${DW_TEMPLATE:-$PLUGIN_DIR/templates/deferred-work.md.template}"

# Minimal precondition checks — all input files MUST exist; fail loud otherwise.
for _f in "$MARKETPLACE_JSON" "$PLUGIN_JSON" "$README_MD" "$CHANGELOG_MD" "$DW_TEMPLATE"; do
    if [ ! -f "$_f" ]; then
        echo "ERROR [release_check]: required file not found: $_f" >&2
        exit 1
    fi
done

# ============================================================================
# Gate 1: version equality
# ============================================================================

echo "==> Gate 1: version equality (plugin.json / marketplace.json / README / changelog)"

# Extract harness-zh entry from marketplace.json (handles single + multi-plugin
# marketplace; matches by name "harness-zh"). Uses python3+json (universally
# available; jq optional).
MK_VER="$(python3 - "$MARKETPLACE_JSON" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
plugins = data.get("plugins") or []
hit = next((p for p in plugins if p.get("name") == "harness-zh"), None)
if not hit:
    print("__MISSING__")
else:
    print(hit.get("version", "__NO_VERSION__"))
PYEOF
)"

PG_VER="$(python3 - "$PLUGIN_JSON" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
print(data.get("version", "__NO_VERSION__"))
PYEOF
)"

if [ "$MK_VER" = "__MISSING__" ]; then
    echo "  ✗ marketplace.json has no plugin entry named 'harness-zh'" >&2
    exit 2
fi
if [ "$MK_VER" = "__NO_VERSION__" ] || [ "$PG_VER" = "__NO_VERSION__" ]; then
    echo "  ✗ at least one of marketplace.json / plugin.json has no 'version' field" >&2
    exit 2
fi
if [ "$MK_VER" != "$PG_VER" ]; then
    cat >&2 <<EOF
  ✗ version mismatch:
      marketplace.json (harness-zh): $MK_VER
      plugin.json:                   $PG_VER
    These MUST be equal. Update marketplace.json to match plugin.json (plugin.json is the SoT).
EOF
    exit 2
fi
echo "  ✓ marketplace.json and plugin.json both at $PG_VER"

# --- README version table (top plugin table row + Versioning table first data
#     row) + changelog head entry — review 2026-06-10 finding #42. The
#     changelog head is what collect_issue_context.sh reports as the deployed
#     plugin version at runtime, so drift here pollutes issue triage.
README_VERS="$(python3 - "$README_MD" <<'PYEOF'
import re, sys
top = table = "__MISSING__"
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        if top == "__MISSING__":
            m = re.match(r"^\|\s*\*\*harness-zh\*\*\s*\|\s*(\d+\.\d+\.\d+)\s*\|", line)
            if m:
                top = m.group(1)
                continue
        if table == "__MISSING__":
            m = re.match(r"^\|\s*(\d+\.\d+\.\d+)\s*\|", line)
            if m:
                table = m.group(1)
        if top != "__MISSING__" and table != "__MISSING__":
            break
print(top)
print(table)
PYEOF
)"
RM_TOP_VER="$(printf '%s\n' "$README_VERS" | sed -n 1p)"
RM_TABLE_VER="$(printf '%s\n' "$README_VERS" | sed -n 2p)"

CL_VER="$(python3 - "$CHANGELOG_MD" <<'PYEOF'
import re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        m = re.match(r"^## v(\d+\.\d+\.\d+)\b", line)
        if m:
            print(m.group(1))
            break
    else:
        print("__MISSING__")
PYEOF
)"

V_FAIL=0
for pair in "README top plugin table:$RM_TOP_VER" \
            "README Versioning table first row:$RM_TABLE_VER" \
            "changelog.md head entry:$CL_VER"; do
    label="${pair%:*}"
    ver="${pair##*:}"
    if [ "$ver" = "__MISSING__" ]; then
        echo "  ✗ $label: version not found (expected $PG_VER)" >&2
        V_FAIL=1
    elif [ "$ver" != "$PG_VER" ]; then
        echo "  ✗ $label: $ver != plugin.json $PG_VER" >&2
        V_FAIL=1
    else
        echo "  ✓ $label: $ver"
    fi
done
if [ "$V_FAIL" -ne 0 ]; then
    echo "  ✗ version drift — update README.md / changelog.md to match plugin.json (the SoT)" >&2
    exit 2
fi

# ============================================================================
# Gate 2: commands/*.md frontmatter is parseable YAML
# ============================================================================

echo "==> Gate 2: commands/*.md frontmatter parses as YAML"

if [ ! -d "$COMMANDS_DIR" ]; then
    echo "  ✗ commands directory not found at $COMMANDS_DIR" >&2
    exit 1
fi

FAIL_COUNT="$(python3 - "$COMMANDS_DIR" <<'PYEOF'
import re, sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("WARN [release_check]: PyYAML not installed; only checking frontmatter fence presence", file=sys.stderr)
    yaml = None

commands_dir = Path(sys.argv[1])
fail = 0
for md in sorted(commands_dir.glob("*.md")):
    with md.open(encoding="utf-8") as f:
        content = f.read()
    m = re.match(r"^---\n(.*?)\n---\n", content, re.DOTALL)
    if not m:
        print(f"  ✗ {md.name}: missing or malformed frontmatter fence", file=sys.stderr)
        fail += 1
        continue
    if yaml is None:
        print(f"  ~ {md.name}: fence OK (PyYAML missing — full parse skipped)", file=sys.stderr)
        continue
    try:
        fm = yaml.safe_load(m.group(1))
        if not isinstance(fm, dict):
            print(f"  ✗ {md.name}: frontmatter is not a mapping (got {type(fm).__name__})", file=sys.stderr)
            fail += 1
            continue
        if "description" not in fm:
            print(f"  ✗ {md.name}: missing required 'description' field", file=sys.stderr)
            fail += 1
            continue
        print(f"  ✓ {md.name}: OK", file=sys.stderr)
    except yaml.YAMLError as e:
        print(f"  ✗ {md.name}: YAML parse error → {e}", file=sys.stderr)
        fail += 1

print(fail)
PYEOF
)"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "==> FAIL: $FAIL_COUNT command(s) have unparseable frontmatter" >&2
    exit 3
fi

# ============================================================================
# Gate 3: run.md must not re-introduce the instructive "main agent runs
#         `sprint-status.py set` as fallback" protocol (review finding #70)
# ============================================================================
#
# 现协议（2026-05-04，chore-harness-epic-4 T1）：sprint-status 推进责任全在
# harness-commit.py 的 auto-sync，主 agent 只读不写。run.md 里允许出现的是
# **否定句**（『不再手工跑兜底 set』『不要手工 set』——协议说明），不允许出现
# 指令句（『主 agent 调 set 兜底』『主 agent 兜底 set review』）。
# 机检口径：同一行内同时出现独立词 `set` 与『兜底』、且该行不含『不再』/『不要』
# → 视为指令性回流。0.1.38 收口时上述否定句全部含『不再』/『不要』，已实测放行。

echo "==> Gate 3: run.md has no instructive 'main agent set-fallback' protocol"

RUN_MD="$COMMANDS_DIR/run.md"
if [ ! -f "$RUN_MD" ]; then
    echo "  ✗ run.md not found at $RUN_MD" >&2
    exit 1
fi

SET_FALLBACK_HITS="$(grep -nE '(^|[^A-Za-z_])set([^A-Za-z_]|$)' "$RUN_MD" | grep '兜底' | grep -vE '不再|不要' || true)"
if [ -n "$SET_FALLBACK_HITS" ]; then
    {
        echo "  ✗ run.md re-introduces instructive 'set 兜底' wording (finding #70):"
        printf '%s\n' "$SET_FALLBACK_HITS" | sed 's/^/      /'
        echo "    现协议主 agent 不再调 sprint-status.py set；若为协议说明请用否定句（含『不再』/『不要』）。"
    } >&2
    exit 4
fi
echo "  ✓ no instructive set-fallback wording (negation-form mentions allowed)"

# ============================================================================
# Gate 4: upgrade-deferred-work.md inline heredoc === deferred-work.md.template
# ============================================================================
#
# upgrade-deferred-work.md 自述不变量：『Inline 模板内容与 plugin
# templates/deferred-work.md.template 保持一致』。此前仅靠注释自律，已实际
# 漂移过一次（review finding #67）。此 gate 提取 <<'TPL' heredoc 正文与
# template 文件做逐字节比对。

echo "==> Gate 4: upgrade-deferred-work.md heredoc matches deferred-work.md.template"

UPGRADE_MD="$COMMANDS_DIR/upgrade-deferred-work.md"
if [ ! -f "$UPGRADE_MD" ]; then
    echo "  ✗ upgrade-deferred-work.md not found at $UPGRADE_MD" >&2
    exit 1
fi

HEREDOC_DIFF="$(python3 - "$UPGRADE_MD" "$DW_TEMPLATE" <<'PYEOF'
import difflib, re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    md = f.read()
m = re.search(r"<<'TPL'\n(.*?\n)TPL\n", md, re.DOTALL)
if not m:
    print("__NO_HEREDOC__")
    sys.exit(0)
with open(sys.argv[2], encoding="utf-8") as f:
    tpl = f.read()
if m.group(1) == tpl:
    sys.exit(0)
sys.stdout.writelines(difflib.unified_diff(
    m.group(1).splitlines(keepends=True), tpl.splitlines(keepends=True),
    fromfile="upgrade-deferred-work.md <<'TPL' heredoc",
    tofile="templates/deferred-work.md.template"))
PYEOF
)"
if [ "$HEREDOC_DIFF" = "__NO_HEREDOC__" ]; then
    echo "  ✗ no <<'TPL' heredoc found in upgrade-deferred-work.md (extraction pattern broken?)" >&2
    exit 5
fi
if [ -n "$HEREDOC_DIFF" ]; then
    {
        echo "  ✗ inline heredoc has drifted from templates/deferred-work.md.template (finding #67):"
        printf '%s\n' "$HEREDOC_DIFF" | sed 's/^/      /'
        echo "    两者必须逐字节一致 — 改 template 时同步改 upgrade-deferred-work.md 步骤 5 heredoc。"
    } >&2
    exit 5
fi
echo "  ✓ heredoc and template are byte-identical"

# ============================================================================
# Gate 5: scripts/ shebang files carry the executable bit (regression R2
#         2026-06-10 — harness-commit.py / harness-state.py 100755→100644)
# ============================================================================
#
# 判定口径：scripts/ 下首两字节为 `#!` 的文件必须 `[ -x ]`（直接看文件系统位 —
# R2 的回归形态正是 index 仍 755 而工作区丢位，所以必须查盘上实际位，不能只
# 对照 git ls-files mode）。sourceable lib（只被 `source`/`import`、index 记录
# 即为 100644、从不直接执行）走显式豁免名单；新增 lib 触发红灯时要么 chmod +x
# 要么有意识地加进名单。

echo "==> Gate 5: scripts/ shebang files carry the executable bit"

SCRIPTS_DIR="${SCRIPTS_DIR:-$SCRIPT_DIR}"
if [ ! -d "$SCRIPTS_DIR" ]; then
    echo "  ✗ scripts directory not found at $SCRIPTS_DIR" >&2
    exit 1
fi

# Sourceable/importable libs — never executed directly, tracked as 100644 by
# design. Keep this list minimal and individually justified:
#   deferred_work_schema_lib.sh — `source`d shared schema primitives
#   prompt_template_lib.sh      — `source`d shared template renderer
#   harness_config.py           — `import harness_config` module, no CLI entry
X_EXEMPT="deferred_work_schema_lib.sh prompt_template_lib.sh harness_config.py"

is_x_exempt() {
    local name="$1" e
    for e in $X_EXEMPT; do
        [ "$e" = "$name" ] && return 0
    done
    return 1
}

X_FAIL=0
for f in "$SCRIPTS_DIR"/*; do
    [ -f "$f" ] || continue
    # bash 3.2 兼容：head -c 2 取首两字节判 shebang
    if [ "$(head -c 2 "$f" 2>/dev/null)" != "#!" ]; then
        continue
    fi
    name="$(basename "$f")"
    if is_x_exempt "$name"; then
        continue
    fi
    if [ ! -x "$f" ]; then
        echo "  ✗ $name: has shebang but missing executable bit (chmod +x it; R2 regression)" >&2
        X_FAIL=$((X_FAIL + 1))
    fi
done
if [ "$X_FAIL" -gt 0 ]; then
    echo "  ✗ $X_FAIL script(s) lost the executable bit — git add would bake 100644 into the index" >&2
    exit 6
fi
echo "  ✓ all shebang scripts executable (exempt sourceable libs: $X_EXEMPT)"

echo "==> All gates passed"
exit 0
