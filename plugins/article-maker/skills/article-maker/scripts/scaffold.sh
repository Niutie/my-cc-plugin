#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# scaffold.sh —— 一键创建一个 Article Maker 工作区。
#
# 用法：
#   bash scripts/scaffold.sh <target-dir> [--theme=<id>] [--no-cover] [--accent=<hex>]
#   bash scripts/scaffold.sh --list-themes
#
# 例子：
#   bash <path-to-article-maker>/scripts/scaffold.sh ./my-article --theme=tufte
#   bash <path-to-article-maker>/scripts/scaffold.sh ./brief --theme=press --no-cover
#   bash <path-to-article-maker>/scripts/scaffold.sh ./course --theme=vignelli --accent="#2b3f9e"
#   bash <path-to-article-maker>/scripts/scaffold.sh --list-themes
#
# --no-cover：禁用文章封面（默认开 · 屏幕 3:4 / PDF 独占首页）。详见 references/cover.md。
#
# --accent=<hex>：把所选主题的强调色（accent + info）换成该色，强浅色用 color-mix 自动派生，
#   写进 article/theme-overrides.css（risk / warn 警示红保持不变）。培训模版与 video-maker
#   training-center 视频对齐 royal 蓝：--theme=vignelli --accent="#2b3f9e"。不传则用主题原始强调色。
#
# 工作区从 npm 安装**最新发布版的 reacticle**（package.json 里 reacticle: "latest"，
# 每次 fresh scaffold 都会取当下最新）。无需本地 reacticle 仓库。
#
# 跑完后看 SKILL.md「Phase 4 First Spread」+ references/component-policy.md /
# raw-policy.md / 选定主题 theme-profiles/<id>.md。
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$SKILL_DIR/assets/scaffold-template"
PROFILES="$SKILL_DIR/theme-profiles/index.json"
DEFAULT_THEME="tufte"

list_themes() {
  echo "可用主题（来自 ${PROFILES}）:"
  echo
  # 没有 jq，用 grep + sed 提字段
  grep -E '"id"|"label"|"mood"' "$PROFILES" | sed -E \
    -e 's/.*"id":[[:space:]]*"([^"]+)".*/  • \1/' \
    -e 's/.*"label":[[:space:]]*"([^"]+)".*/      \1/' \
    -e 's/.*"mood":[[:space:]]*"([^"]+)".*/      \1/'
  echo
  echo "用 --theme=<id> 选定一个。默认：${DEFAULT_THEME}。"
}

# 校验主题 id 是否在 theme-profiles/index.json 里
theme_exists() {
  grep -Eq "\"id\"[[:space:]]*:[[:space:]]*\"$1\"" "$PROFILES"
}

# ── 解析参数 ──
TARGET=""
THEME="$DEFAULT_THEME"
COVER=1
ACCENT=""
for arg in "$@"; do
  case "$arg" in
    --list-themes) list_themes; exit 0 ;;
    --theme=*) THEME="${arg#--theme=}" ;;
    --no-cover) COVER=0 ;;
    --cover) COVER=1 ;;
    --accent=*) ACCENT="${arg#--accent=}" ;;
    --*) echo "✗ 未知参数: $arg" >&2; exit 1 ;;
    *) [[ -z "$TARGET" ]] && TARGET="$arg" ;;
  esac
done

TARGET="${TARGET:-my-article}"

# ── 校验 / 归一化强调色 ──
if [[ -n "$ACCENT" ]]; then
  [[ "$ACCENT" != \#* ]] && ACCENT="#$ACCENT"
  if ! [[ "$ACCENT" =~ ^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$ ]]; then
    echo "✗ --accent 需要 3 / 6 位十六进制颜色（如 #2b3f9e 或 2b3f9e），收到 '$ACCENT'。" >&2
    exit 1
  fi
fi

# ── 校验主题 ──
if ! theme_exists "$THEME"; then
  echo "✗ 未知主题 '$THEME'。可用主题：" >&2
  echo >&2
  list_themes >&2
  exit 1
fi

# ── 目标目录检查 ──
if [[ -d "$TARGET" && -n "$(ls -A "$TARGET" 2>/dev/null || true)" ]]; then
  echo "✗ 目标目录 '$TARGET' 已存在且非空，已中止。" >&2
  exit 1
fi
if ! command -v npm >/dev/null; then
  echo "✗ 需要 npm，但在 PATH 里没找到。" >&2
  exit 1
fi

echo "▸ 在 $TARGET 创建 Article Maker 工作区"
echo "▸ 主题：$THEME"
echo "▸ 封面：$([[ "$COVER" == "1" ]] && echo "开（屏幕 3:4 / PDF 独占首页，详见 references/cover.md）" || echo "关")"
[[ -n "$ACCENT" ]] && echo "▸ 强调色覆盖：${ACCENT}（写入 article/theme-overrides.css，risk / warn 警示红保持不变）"
echo "▸ reacticle：从 npm 安装最新发布版"

mkdir -p "$TARGET"
# 复制工程模板
cp "$TEMPLATE/package.json"        "$TARGET/package.json"
cp "$TEMPLATE/vite.config.ts"      "$TARGET/vite.config.ts"
cp "$TEMPLATE/tsconfig.json"       "$TARGET/tsconfig.json"
cp "$TEMPLATE/tsconfig.node.json"  "$TARGET/tsconfig.node.json"
cp "$TEMPLATE/index.html"          "$TARGET/index.html"

# 工作记忆目录 + 文章源目录
mkdir -p "$TARGET/source" "$TARGET/plan" "$TARGET/review" \
         "$TARGET/article/sections" "$TARGET/article/raw-blocks" "$TARGET/article/assets"
cp "$TEMPLATE/article/main.tsx"             "$TARGET/article/main.tsx"
cp "$TEMPLATE/article/Article.tsx"          "$TARGET/article/Article.tsx"
cp "$TEMPLATE/article/theme-overrides.css"  "$TARGET/article/theme-overrides.css"
# 一节一文件：assembler + 第一个 section 组件（多 Agent 并行的代码锚点）
cp "$TEMPLATE/article/sections/01-opening.tsx" "$TARGET/article/sections/01-opening.tsx"

# 封面：默认开。--no-cover 时跳过 Cover.tsx 并从 main.tsx 剥掉 __COVER_*__ 段。
if [[ "$COVER" == "1" ]]; then
  cp "$TEMPLATE/article/Cover.tsx" "$TARGET/article/Cover.tsx"
fi

# 留住空目录（git 友好）
touch "$TARGET/article/raw-blocks/.gitkeep" "$TARGET/article/assets/.gitkeep"

# ── 注入主题 id（用 perl 避免转义问题）──
# main.tsx: <ThemeProvider theme="__THEME__">
# Article.tsx: colophon "· __THEME__ theme"
export RA_THEME="$THEME"
perl -pi -e 's/__THEME__/$ENV{RA_THEME}/g' "$TARGET/article/main.tsx"
perl -pi -e 's/__THEME__/$ENV{RA_THEME}/g' "$TARGET/article/Article.tsx"

# ── 封面开关：处理 main.tsx 里 __COVER_*__ 标记包裹的区段 ──
# COVER=1 → 去掉两行 __COVER_*_BEGIN__ / __COVER_*_END__ 标记（保留中间的 import 和 <Cover/>）
# COVER=0 → 连标记带中间内容一起剥掉（封面不参与构建）
if [[ "$COVER" == "1" ]]; then
  # 删除标记行本身，保留 Cover 引入与渲染
  perl -i -ne 'print unless /__COVER_(IMPORT|RENDER)_(BEGIN|END)__/' "$TARGET/article/main.tsx"
else
  # 把 BEGIN..END 之间（含两端标记行）整段删掉
  perl -i -0pe 's{[^\n]*__COVER_IMPORT_BEGIN__.*?__COVER_IMPORT_END__[^\n]*\n}{}gs' "$TARGET/article/main.tsx"
  perl -i -0pe 's{[^\n]*__COVER_RENDER_BEGIN__.*?__COVER_RENDER_END__[^\n]*\n}{}gs' "$TARGET/article/main.tsx"
fi

# ── 强调色覆盖：写进 article/theme-overrides.css（accent + info；强浅色用 color-mix 派生）──
if [[ -n "$ACCENT" ]]; then
  cat > "$TARGET/article/theme-overrides.css" <<CSS
/* 项目级主题 token 覆盖 —— 在 reacticle/styles.css 之后加载。
 * 由 scaffold.sh --accent=$ACCENT 生成：把 "$THEME" 主题的强调色（accent + info）换成该色，
 * 强 / 浅变体用 color-mix 自动派生；risk / warn 等警示色保持主题原样（红 = 正确警示信号）。
 * 想改回主题原始强调色：清空本文件或删掉下面这段。 */
[data-theme="$THEME"] {
  --ra-color-accent:          $ACCENT;
  --ra-color-accent-strong:   color-mix(in srgb, $ACCENT 82%, #000);
  --ra-color-accent-soft:     color-mix(in srgb, $ACCENT 10%, #fff);
  --ra-color-accent-contrast: #fff;
  --ra-color-info:            $ACCENT;
  --ra-color-info-soft:       color-mix(in srgb, $ACCENT 10%, #fff);
}
CSS
fi

# 标记起步主题
echo "$THEME" > "$TARGET/.theme"

cd "$TARGET"
echo "▸ 安装依赖（含 reacticle 最新版，可能要等一会）..."
npm install >/dev/null 2>&1
# 确保拿到当下最新（即使将来模板带了 lockfile 也强制刷新到最新）
npm install reacticle@latest >/dev/null 2>&1

INSTALLED_REACTICLE="$(node -e "console.log(JSON.parse(require('fs').readFileSync('node_modules/reacticle/package.json','utf8')).version)" 2>/dev/null || echo '?')"
echo "▸ reacticle 版本：$INSTALLED_REACTICLE"

echo "▸ 跑一次 typecheck 确认接线 OK ..."
if npx tsc --noEmit; then
  echo "✓ typecheck 通过"
else
  echo "⚠ typecheck 有问题（见上），dev / build 仍可能正常 —— 请人工确认。" >&2
fi

cat <<EOF

✓ 完成。工作区：${TARGET}（主题 ${THEME}，见 .theme；reacticle ${INSTALLED_REACTICLE}）

下一步：
  1. cd $TARGET
  2. npm run dev      # 预览（Phase 4 先写首屏 + 第一个 Section）
  3. 首屏（Hero/Lead）写进 article/Article.tsx（assembler）；
     第一个 Section 写进 article/sections/01-opening.tsx
     —— 铁律：一个 Section 一个文件，坚决不要写进 Article.tsx（多 Agent 并行前提）。
  4. $([[ "$COVER" == "1" ]] && echo "封面：替换 article/Cover.tsx 里的 <CoverPlaceholder />，按文章 + 主题做定制（读 references/cover.md）。" || echo "封面：已关闭。如需打开，重新跑 scaffold 时去掉 --no-cover，或手动复制 Cover.tsx 模板。")
  5. 把决策落盘到 source/ plan/ review/（Skill 的长期记忆）

构建交付（Phase 8）：
  • npm run build     # 类型检查 + 单页 HTML → dist/index.html（CSS+JS 内联）
  • npm run html      # 复用 build，再复制为交付物 article/article.html

切主题：改 article/main.tsx 的 <ThemeProvider theme="..."> 一个字（可用 id 见 theme-profiles/index.json，跑 --list-themes 查看）。
改强调色：编辑 article/theme-overrides.css（或重跑 scaffold 带 --accent=<hex>）。
升级组件库：npm install reacticle@latest

写作必读（路径在 Skill 仓库内）：
  • $SKILL_DIR/references/component-policy.md
  • $SKILL_DIR/references/raw-policy.md
  • $SKILL_DIR/theme-profiles/$THEME.md
EOF
