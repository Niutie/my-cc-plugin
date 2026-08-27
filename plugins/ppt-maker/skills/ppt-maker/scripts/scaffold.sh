#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# scaffold.sh —— 建一个 ppt-maker deck 项目。
#
# 用法：
#   bash scripts/scaffold.sh <target-dir> [--theme=<id>]
#   bash scripts/scaffold.sh --list-themes
#
# 产出一个 Vite + React + TS 工作区：
#   deck.json           唯一事实源（内容 + 版式）
#   npm run dev         网页版 PPT
#   npm run export:pptx 可编辑 .pptx
#   npm run verify:geometry  校验两个渲染器坐标一致
#
# 之后换主题 = 覆盖两个文件：
#   cp themes/<id>/tokens.css  <project>/src/styles/tokens.css
#   cp themes/<id>/theme.json  <project>/src/styles/theme.json
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$SKILL_DIR/assets/scaffold-template"
THEMES_DIR="$SKILL_DIR/themes"
DEFAULT_THEME="swiss-ikb"

list_themes() {
  echo "可用主题（来自 ${THEMES_DIR}）:"
  echo
  for dir in "$THEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local meta="$dir/theme.json"
    [[ -f "$meta" ]] || continue
    local id name desc
    id=$(grep -E '"id"' "$meta" | head -n1 | sed -E 's/.*"id":[[:space:]]*"([^"]+)".*/\1/')
    name=$(grep -E '"nameZh"' "$meta" | head -n1 | sed -E 's/.*"nameZh":[[:space:]]*"([^"]+)".*/\1/')
    desc=$(grep -E '"descriptionZh"' "$meta" | head -n1 | sed -E 's/.*"descriptionZh":[[:space:]]*"([^"]+)".*/\1/')
    printf "  • %-20s %s\n      %s\n\n" "$id" "$name" "$desc"
  done
  echo "用 --theme=<id> 选定一个。默认：${DEFAULT_THEME}。"
}

TARGET=""
THEME="$DEFAULT_THEME"
SKIP_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --list-themes) list_themes; exit 0 ;;
    --theme=*)     THEME="${arg#--theme=}" ;;
    --no-install)  SKIP_INSTALL=1 ;;
    --*)           echo "✗ 未知参数: $arg" >&2; exit 1 ;;
    *)             [[ -z "$TARGET" ]] && TARGET="$arg" ;;
  esac
done

TARGET="${TARGET:-deck}"
THEME_DIR="$THEMES_DIR/$THEME"

if [[ ! -f "$THEME_DIR/tokens.css" ]]; then
  echo "✗ 找不到主题 '${THEME}'。可用：" >&2
  for dir in "$THEMES_DIR"/*/; do echo "    • $(basename "$dir")" >&2; done
  exit 1
fi

if [[ -d "$TARGET" && -n "$(ls -A "$TARGET" 2>/dev/null || true)" ]]; then
  echo "✗ 目标目录 '${TARGET}' 已存在且非空，已中止。" >&2
  exit 1
fi

command -v npm >/dev/null || { echo "✗ 需要 npm，但 PATH 里没找到。" >&2; exit 1; }

# 变量后面紧跟全角标点时必须加花括号：bash 会把多字节标点的字节
# 当成变量名的一部分，配上 set -u 就是 "unbound variable"。
echo "▸ 在 ${TARGET} 创建 deck 工作区（主题：${THEME}）"
mkdir -p "$TARGET"
# 模板本身就是一个完整可跑的项目 —— 直接拷，不走 npm create。
cp -R "$TEMPLATE"/. "$TARGET"/
rm -rf "$TARGET/node_modules" "$TARGET/dist" "$TARGET/dist-web"

cp "$THEME_DIR/tokens.css" "$TARGET/src/styles/tokens.css"
cp "$THEME_DIR/theme.json" "$TARGET/src/styles/theme.json"
echo "$THEME" > "$TARGET/.theme"

# deck.meta.theme 必须跟磁盘上的 tokens.css 是同一套，否则导出日志、
# 以及未来任何按主题分支的逻辑，都会对着一个错的名字工作。
node -e '
const fs = require("fs");
const [file, theme] = process.argv.slice(1);
const deck = JSON.parse(fs.readFileSync(file, "utf8"));
deck.meta.theme = theme;
fs.writeFileSync(file, JSON.stringify(deck, null, 2) + "\n");
' "$TARGET/deck.json" "$THEME"

if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  echo "▸ 安装依赖（要等一会）..."
  (cd "$TARGET" && npm install --no-audit --no-fund >/dev/null 2>&1)
  echo "▸ typecheck ..."
  (cd "$TARGET" && npx tsc --noEmit)
  echo "✓ typecheck 通过"
fi

cat <<EOF

✓ 完成：$TARGET

下一步：
  cd $TARGET
  npm run dev                 # 网页版 PPT（→ / ← 翻页，v 切换方案）
  npm run export:pptx         # 导出可编辑 .pptx 到 dist/deck.pptx
  npm run verify:geometry     # 校验网页与 .pptx 的坐标是否一致

改内容改版式都在 deck.json —— 它是唯一事实源，
三个渲染器（网页 / PPTX / PDF）都从它出发。
EOF
