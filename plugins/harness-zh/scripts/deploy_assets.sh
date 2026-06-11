#!/usr/bin/env bash
# deploy_assets — copy harness-zh plugin assets into a project's .claude/ tree.
#
# Single source of truth for the asset-deployment logic that init.md and
# update.md previously duplicated (~50 lines × 2). Idempotent: cmp + backup +
# overwrite per file.
#
# Manifest-based purge (v0.1.27):
#   Every successful deploy writes `.claude/harness/.deploy-manifest.txt` —
#   a sorted list of paths the plugin owns at this version. On the next run
#   with DEPLOY_PURGE=1, we read the OLD manifest, diff vs the NEW deploy
#   set, and purge only files that USED TO BE in the manifest but no longer
#   are. Files never in any plugin manifest (user-authored personal commands,
#   other plugins' files, etc.) are NEVER touched. All purged files are first
#   backed up to `<file>.bak.<TS>` before rm.
#
#   This replaces the v0.1.26-prototype "blanket diff against entire .claude/"
#   approach (codex-review 2026-05-09 [high]: would delete user-owned files).
#
# Usage:
#   bash $PLUGIN_ROOT/scripts/deploy_assets.sh $PLUGIN_ROOT [DEST_ROOT]
#
# Args:
#   $1  PLUGIN_ROOT (required) — source dir, typically `bash discover_plugin_root.sh`
#   $2  DEST_ROOT (optional, default $PWD) — project root; assets land at
#         <DEST_ROOT>/.claude/harness/   (architecture, scripts, conventions, ...)
#         <DEST_ROOT>/.claude/commands/  (*.md slash-commands)
#
# Optional env:
#   DEPLOY_PURGE=1     — see commands/update.md §3.5. Removes files that were
#                        in the previous manifest but not in this one (with
#                        backup). Default off so init.md does NOT purge.
#   DEPLOY_QUIET=1     — suppress per-file status lines; only print summary
#
# Output (stderr): per-file status (`installed:` / `updated:` / `purged:`).
#                  Final summary line on stdout:
#                    deploy: installed=N unchanged=M updated=K purged=P [FAILED=F]
#
# Exit codes:
#   0 — deployed successfully (purge non-fatal even if some delete fails)
#   1 — invalid args
#   2 — at least one required asset failed to deploy

set -euo pipefail

PLUGIN_ROOT="${1:-}"
DEST_ROOT="${2:-$PWD}"
QUIET="${DEPLOY_QUIET:-0}"

if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    echo "ERROR [deploy_assets]: PLUGIN_ROOT missing or not a directory: '$PLUGIN_ROOT'" >&2
    echo "  usage: bash deploy_assets.sh <PLUGIN_ROOT> [DEST_ROOT]" >&2
    exit 1
fi

if [ ! -d "$DEST_ROOT" ]; then
    echo "ERROR [deploy_assets]: DEST_ROOT not a directory: '$DEST_ROOT'" >&2
    exit 1
fi

cd "$DEST_ROOT"

# Required top-level files — missing source = packaging bug = hard fail.
# Listed once, used for both deploy + manifest building.
#
# review #30：prompt-templates/ 自分发清单移除（4 个模板是运行时死资产，内容
# 停留在 pre-schema-v1 + 含下游项目专属引用）。老项目已部署的
# .claude/harness/prompt-templates/* 由下方 manifest purge 对账自动清掉：
# 它们在 OLD manifest 里、不在新部署集里 → DEPLOY_PURGE=1 时成为 purge
# candidates（备份后删除）。
REQUIRED_TOP_FILES=(architecture.md answer-policy.md changelog.md test-stage-triggers.yaml)
SUBDIRS=(scripts conventions prompt-suffixes git-hooks templates)

# Ensure target dirs exist
mkdir -p .claude/harness/scripts \
         .claude/harness/conventions \
         .claude/harness/prompt-suffixes \
         .claude/harness/git-hooks \
         .claude/harness/templates \
         .claude/commands

TS="$(date +%Y%m%d-%H%M%S)"
INSTALLED=0
UNCHANGED=0
UPDATED=0
FAILED=0

# Track every successfully reached `dst` (regardless of installed/unchanged/updated)
# for the new manifest. A file that fails to deploy is NOT added — its absence
# from the new manifest will (on next run with PURGE=1) cause the OLD entry to
# be flagged as purge candidate, which is wrong only if FAILED > 0; we guard
# against that by refusing to write a manifest when FAILED > 0.
DEPLOYED_TMP="$(mktemp -t harness_deployed.XXXXXX)"
# review #55/#87②：所有临时文件都进 EXIT trap（中途 set -e 退出 / 被 kill 时
# 不泄漏）。后三个变量在用到时才赋值，先初始化为空串兼 set -u；trap 里用
# ${var:+...} 跳过未赋值项，避免给 rm 传空操作数。
NEW_MANIFEST=""
OLD_MANIFEST_SORTED=""
MANIFEST_TMP=""
trap 'rm -f "$DEPLOYED_TMP" ${NEW_MANIFEST:+"$NEW_MANIFEST"} ${OLD_MANIFEST_SORTED:+"$OLD_MANIFEST_SORTED"} ${MANIFEST_TMP:+"$MANIFEST_TMP"}' EXIT

_log() {
    [ "$QUIET" = "1" ] && return 0
    echo "$1" >&2
}

deploy() {
    local src="$1" dst="$2"
    if [ ! -f "$src" ]; then
        echo "ERROR [deploy_assets]: source missing — $src" >&2
        FAILED=$((FAILED + 1))
        return 0
    fi
    if [ ! -f "$dst" ]; then
        if cp "$src" "$dst" 2>/dev/null; then
            [ -x "$src" ] && chmod +x "$dst"
            _log "installed: $dst"
            INSTALLED=$((INSTALLED + 1))
            echo "$dst" >> "$DEPLOYED_TMP"
        else
            echo "ERROR [deploy_assets]: failed to install $src → $dst" >&2
            FAILED=$((FAILED + 1))
        fi
    elif cmp -s "$src" "$dst"; then
        UNCHANGED=$((UNCHANGED + 1))
        echo "$dst" >> "$DEPLOYED_TMP"
    else
        if cp "$dst" "$dst.bak.$TS" 2>/dev/null && cp "$src" "$dst" 2>/dev/null; then
            [ -x "$src" ] && chmod +x "$dst"
            _log "updated:   $dst (backup → $(basename "$dst").bak.$TS)"
            UPDATED=$((UPDATED + 1))
            echo "$dst" >> "$DEPLOYED_TMP"
        else
            echo "ERROR [deploy_assets]: failed to update $src → $dst" >&2
            FAILED=$((FAILED + 1))
        fi
    fi
}

# Top-level required files. NO `[ -f ... ] &&` guard — `deploy()` handles
# missing-source by incrementing FAILED. A packaging bug (architecture.md
# absent in plugin source) MUST surface as exit 2, not silent skip.
for f in "${REQUIRED_TOP_FILES[@]}"; do
    deploy "$PLUGIN_ROOT/$f" ".claude/harness/$f"
done

# Subdirs (single-level, files only). Use `find` + process substitution to stay
# bash-3.2 / zsh compatible without shopt + glob.
# review #57：排除隐藏文件（.DS_Store 等 macOS 开发机垃圾）+ 备份/编辑器临时
# 文件 + *.pyc（__pycache__/ 目录本身在 depth 2，-maxdepth 1 -type f 天然不进），
# 避免投递进用户项目并记入 manifest（下个版本又触发一轮 purge+backup 噪音）。
# 排除清单与 install_git_hooks.sh 的同动机 case 分支对齐。
for sub in "${SUBDIRS[@]}"; do
    [ -d "$PLUGIN_ROOT/$sub" ] || continue
    while IFS= read -r src; do
        [ -n "$src" ] && deploy "$src" ".claude/harness/$sub/$(basename "$src")"
    done < <(find "$PLUGIN_ROOT/$sub" -maxdepth 1 -type f \
                  ! -name '.*' ! -name '*.bak.*' ! -name '*.backup' \
                  ! -name '*.orig' ! -name '*~' ! -name '*.pyc' 2>/dev/null)
done

# commands/ → .claude/commands/  (single-level, *.md only; ! -name '.*' 防隐藏 md)
while IFS= read -r src; do
    [ -n "$src" ] && deploy "$src" ".claude/commands/$(basename "$src")"
done < <(find "$PLUGIN_ROOT/commands" -maxdepth 1 -type f -name '*.md' ! -name '.*' 2>/dev/null)

# ============================================================================
# Manifest-based purge
# ============================================================================
#
# Behavior matrix:
#   PURGE off → just write new manifest; never delete anything.
#   PURGE on, no old manifest → first time PURGE meets a project that pre-dates
#     manifests. We can't tell what was "ours" before. Skip purge with a notice;
#     write new manifest so next run works.
#   PURGE on, FAILED > 0 → deploy partially broken. Don't trust the new manifest
#     to be complete; skip purge and don't overwrite the old manifest. User should
#     re-run after fixing the underlying issue.
#   PURGE on, both manifests good → diff old - new = purge candidates. Each one
#     is backed up to .bak.<TS> before rm.

MANIFEST_PATH=".claude/harness/.deploy-manifest.txt"
PURGED=0
PURGE_FAILED=0

NEW_MANIFEST="$(mktemp -t harness_new_manifest.XXXXXX)"
sort -u "$DEPLOYED_TMP" > "$NEW_MANIFEST"

if [ "${DEPLOY_PURGE:-0}" = "1" ]; then
    if [ "$FAILED" -gt 0 ]; then
        _log "purge: SKIPPED (deploy had failures; would corrupt manifest)"
    elif [ ! -f "$MANIFEST_PATH" ]; then
        _log "purge: SKIPPED (no prior manifest at $MANIFEST_PATH; project pre-dates manifest tracking — future runs will purge correctly)"
    elif [ ! -s "$NEW_MANIFEST" ]; then
        _log "purge: SKIPPED (new manifest empty — refusing to purge against empty truth)"
    else
        OLD_MANIFEST_SORTED="$(mktemp -t harness_old_manifest.XXXXXX)"
        sort -u "$MANIFEST_PATH" > "$OLD_MANIFEST_SORTED"
        # review #87①：backup/rm 瞬态失败（权限/磁盘满）的 candidate 累积在此，
        # 循环结束后回写进 NEW_MANIFEST——否则新 manifest 一覆盖，失败文件从此
        # 不在任何 manifest 里，"skip" 变成 "forever-skip" 的永久遗孤。
        # 注意：被路径校验拒绝的条目（absolute / .. / out-of-scope / symlink）
        # **不**回写——那些是疑似篡改条目，回写会让它们永驻 manifest。
        PURGE_RETRY=""
        # Files in OLD but not in NEW = purge candidates (plugin removed them)
        # Use comm -23 (line-1-only) for clarity vs grep -Fxvf (works but less obvious).
        #
        # Path validation (codex-review 2026-05-09 high #1, defense-in-depth):
        # The manifest file lives in .claude/harness/.deploy-manifest.txt, which
        # is committable and could in theory be tampered with (malicious fork,
        # corrupted state, future code bug writing wrong relative root). Each
        # candidate path MUST satisfy ALL of:
        #   - relative (NOT starting with /)
        #   - no `..` segment (no traversal)
        #   - prefixed with .claude/harness/ or .claude/commands/ (allowlist)
        #   - is a regular file (NOT symlink — refuse to follow)
        # Rejected entries log to stderr and are skipped — main deploy is not
        # aborted (safer to skip purge than to abort an otherwise-successful update).
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            # Reject absolute paths
            case "$candidate" in
                /*)
                    echo "WARN [deploy_assets]: refusing absolute path in manifest (skipped): $candidate" >&2
                    PURGE_FAILED=$((PURGE_FAILED + 1))
                    continue
                    ;;
            esac
            # Reject .. traversal (any segment equal to .. — also catches embedded /../, leading ../, trailing /..)
            case "/$candidate/" in
                */../*)
                    echo "WARN [deploy_assets]: refusing path with '..' traversal (skipped): $candidate" >&2
                    PURGE_FAILED=$((PURGE_FAILED + 1))
                    continue
                    ;;
            esac
            # Allowlist: must be inside .claude/harness/ or .claude/commands/
            case "$candidate" in
                .claude/harness/*|.claude/commands/*) ;;
                *)
                    echo "WARN [deploy_assets]: refusing out-of-scope path (skipped): $candidate" >&2
                    PURGE_FAILED=$((PURGE_FAILED + 1))
                    continue
                    ;;
            esac
            # Refuse symlinks — don't follow + delete what they point to
            if [ -L "$candidate" ]; then
                echo "WARN [deploy_assets]: refusing symlink (skipped): $candidate" >&2
                PURGE_FAILED=$((PURGE_FAILED + 1))
                continue
            fi
            if [ ! -f "$candidate" ]; then
                # Already gone (user deleted manually since last update). Just drop from manifest.
                continue
            fi
            if cp "$candidate" "$candidate.bak.$TS" 2>/dev/null; then
                if rm -f "$candidate" 2>/dev/null; then
                    _log "purged:    $candidate (backup → $(basename "$candidate").bak.$TS)"
                    PURGED=$((PURGED + 1))
                else
                    echo "WARN [deploy_assets]: failed to remove $candidate (backup written; rm denied) — kept in manifest for retry next run" >&2
                    PURGE_FAILED=$((PURGE_FAILED + 1))
                    PURGE_RETRY="${PURGE_RETRY}${candidate}
"
                fi
            else
                echo "WARN [deploy_assets]: failed to back up $candidate before purge — skipping; kept in manifest for retry next run" >&2
                PURGE_FAILED=$((PURGE_FAILED + 1))
                PURGE_RETRY="${PURGE_RETRY}${candidate}
"
            fi
        done < <(comm -23 "$OLD_MANIFEST_SORTED" "$NEW_MANIFEST")
        rm -f "$OLD_MANIFEST_SORTED"
        OLD_MANIFEST_SORTED=""
        # purge 瞬态失败的 candidate 回写新 manifest（循环已结束，NEW_MANIFEST
        # 不再被 comm 并发读取），下次 DEPLOY_PURGE=1 自动重试。
        if [ -n "$PURGE_RETRY" ]; then
            printf '%s' "$PURGE_RETRY" >> "$NEW_MANIFEST"
            sort -u "$NEW_MANIFEST" -o "$NEW_MANIFEST"
        fi
    fi
fi

# Write new manifest unless deploy failed (in which case we keep the old one
# as the still-valid record of "what we own").
# review #55③：原子落盘——同目录 tmp + mv -f（此前 cp 截断写，中途被杀会留下
# 半截 manifest）。tmp 在 MANIFEST_PATH 同目录保证同文件系统 rename 原子性。
if [ "$FAILED" -gt 0 ]; then
    _log "manifest: NOT updated (deploy had $FAILED failure(s); old manifest preserved)"
else
    MANIFEST_TMP="$MANIFEST_PATH.tmp.$$"
    cp "$NEW_MANIFEST" "$MANIFEST_TMP"
    mv -f "$MANIFEST_TMP" "$MANIFEST_PATH"
    MANIFEST_TMP=""
fi
rm -f "$NEW_MANIFEST"
NEW_MANIFEST=""

if [ "$FAILED" -gt 0 ]; then
    echo "deploy: installed=$INSTALLED unchanged=$UNCHANGED updated=$UPDATED purged=$PURGED FAILED=$FAILED"
    exit 2
fi
if [ "$PURGE_FAILED" -gt 0 ]; then
    echo "deploy: installed=$INSTALLED unchanged=$UNCHANGED updated=$UPDATED purged=$PURGED purge_failed=$PURGE_FAILED"
else
    echo "deploy: installed=$INSTALLED unchanged=$UNCHANGED updated=$UPDATED purged=$PURGED"
fi
