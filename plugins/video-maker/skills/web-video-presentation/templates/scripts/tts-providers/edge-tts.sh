# ────────────────────────────────────────────────────────────────────
# edge-tts provider — FREE, no API key. Uses Microsoft Edge's online
# TTS backend via the `edge-tts` Python CLI.
#
# Docs:    https://github.com/rany2/edge-tts
# Install: pip install edge-tts        (no account, no key, no billing)
# Voices:  edge-tts --list-voices       (hundreds, all languages)
#   zh-CN-YunxiNeural     中文男声（默认）
#   zh-CN-XiaoxiaoNeural  中文女声
#   zh-CN-YunyangNeural   中文男声 · 播音腔
#   en-US-AriaNeural      English female
#   en-US-GuyNeural       English male
#   en-US-AndrewNeural    English male · warm
#
# Strengths: zero cost, no key, decent quality, huge multilingual voice
# list. Best default when you don't have (or don't want to pay for) a
# MiniMax / OpenAI key. Needs network (calls Microsoft's endpoint).
#
# Voice ↔ language: edge-tts voices are language-specific. For an English
# video pass an en-US voice, e.g.:
#   PRESENTATION_TTS=edge-tts npm run synthesize-audio -- --voice=en-US-AriaNeural
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
  [[ -z "$voice" ]] && voice="zh-CN-YunxiNeural"

  # edge-tts writes mp3 directly with --write-media. Silence its progress
  # output; on failure it exits non-zero and the runner marks FAILED.
  edge-tts --voice "$voice" --text "$text" --write-media "$out" >/dev/null 2>&1
}
