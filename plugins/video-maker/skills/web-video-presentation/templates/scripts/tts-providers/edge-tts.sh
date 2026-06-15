# ────────────────────────────────────────────────────────────────────
# edge-tts provider — FREE, no API key. Uses Microsoft Edge's online
# TTS backend via the `edge-tts` Python CLI.
#
# Docs:    https://github.com/rany2/edge-tts
# Install: pip install edge-tts        (no account, no key, no billing)
# Voices:  edge-tts --list-voices       (hundreds, all languages)
#   zh-CN-YunxiNeural     中文 · 自然男声（中文片默认）
#   zh-CN-XiaoxiaoNeural  中文女声
#   zh-CN-YunyangNeural   中文男声 · 播音腔
#   en-US-AndrewNeural    English · natural male, warm（英文片默认）
#   en-US-GuyNeural       English male
#   en-US-AriaNeural      English female
#
# Strengths: zero cost, no key, decent quality, huge multilingual voice
# list. Best default when you don't have (or don't want to pay for) a
# MiniMax / OpenAI key. Needs network (calls Microsoft's endpoint).
#
# Voice ↔ language: edge-tts voices are language-specific. With no --voice,
# tts_synthesize auto-picks a natural MALE voice by the text's script —
# Chinese → zh-CN-YunxiNeural, English → en-US-AndrewNeural. Override per
# language when you want a different voice, e.g.:
#   PRESENTATION_TTS=edge-tts npm run synthesize-audio -- --voice=zh-CN-XiaoxiaoNeural
# ────────────────────────────────────────────────────────────────────

tts_check() {
  if ! command -v edge-tts >/dev/null; then
    echo "✗ edge-tts not found in PATH." >&2
    return 1
  fi
}

tts_install_help() {
  cat <<'EOF' >&2
To use the edge-tts provider (free, no API key):

  Install:  pip install edge-tts
            (or: pipx install edge-tts / python3 -m pip install edge-tts)
  Verify:   edge-tts --list-voices | head

It calls Microsoft Edge's online TTS service — needs network, no account.

Or pick another provider:  PRESENTATION_TTS=<name> npm run synthesize-audio
See tts-providers/README.md for the list and how to add your own.
EOF
}

tts_synthesize() {
  local text="$1"
  local out="$2"
  local voice="${3:-}"

  # No explicit --voice → pick a natural MALE voice by the text's script.
  # The film language is confirmed up front (segments are single-language),
  # so Chinese text gets a Chinese voice and everything else gets English.
  # Detect CJK by UTF-8 lead bytes 0xE3–0xE9 (covers Han U+4E00–U+9FFF plus
  # CJK punctuation / kana / Ext-A) under a byte locale — portable across
  # BSD (macOS) / GNU grep and safe under `set -u`. English typography
  # (curly quotes / em-dash, lead 0xE2) and accented Latin (lead 0xC2–0xCD)
  # stay English. A degenerate all-fullwidth-punctuation zh fragment can
  # fall through to English, but real single-language zh steps contain Han.
  if [[ -z "$voice" ]]; then
    if printf '%s' "$text" | LC_ALL=C grep -q $'[\xe3-\xe9]'; then
      voice="zh-CN-YunxiNeural"    # 中文 · 自然男声
    else
      voice="en-US-AndrewNeural"   # English · natural male (warm)
    fi
  fi

  # edge-tts writes mp3 directly with --write-media. Silence its progress
  # output; on failure it exits non-zero and the runner marks FAILED.
  edge-tts --voice "$voice" --text "$text" --write-media "$out" >/dev/null 2>&1
}
