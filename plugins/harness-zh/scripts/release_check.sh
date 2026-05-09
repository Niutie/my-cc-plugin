#!/usr/bin/env bash
# release_check — pre-tag / pre-publish gate for the harness-zh marketplace.
#
# 校验两件 things：
#   (1) 版本一致性：marketplace.json 里 harness-zh 的 version === plugin.json 的 version。
#       这条专门防 0.1.16 / 0.1.26 那种漂移再发生（详 changelog v0.1.26 codex review）。
#   (2) commands/*.md frontmatter 必须能被 PyYAML 解析（防 report-issue.md 类 unquoted
#       flow-sequence 错误：argument-hint: [a] [b] 直接报 'expected <block end>'）。
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
#   2  — 版本不一致
#   3  — 至少一个 commands/*.md frontmatter 无法解析
#   1  — 内部错误（找不到 marketplace.json / plugin.json）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ → plugins/harness-zh/ → plugins/ → repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MARKETPLACE_JSON="${MARKETPLACE_JSON:-$REPO_ROOT/.claude-plugin/marketplace.json}"
PLUGIN_JSON="${PLUGIN_JSON:-$PLUGIN_DIR/.claude-plugin/plugin.json}"
COMMANDS_DIR="${COMMANDS_DIR:-$PLUGIN_DIR/commands}"

# Minimal precondition checks — both files MUST exist; fail loud otherwise.
if [ ! -f "$MARKETPLACE_JSON" ]; then
    echo "ERROR [release_check]: marketplace.json not found at $MARKETPLACE_JSON" >&2
    exit 1
fi
if [ ! -f "$PLUGIN_JSON" ]; then
    echo "ERROR [release_check]: plugin.json not found at $PLUGIN_JSON" >&2
    exit 1
fi

# ============================================================================
# Gate 1: version equality
# ============================================================================

echo "==> Gate 1: version equality"

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

echo "==> All gates passed"
exit 0
