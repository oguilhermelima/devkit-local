#!/usr/bin/env bash

DEVKIT_CHAIN_AGENTS='codex claude agy'
DEVKIT_CHAIN_WINDOWS='5h weekly'

devkit_chain_seed() {
  cat <<'EOF'
{
  "chains": {
    "claude": {
      "when": {"parentAgent": "claude"},
      "steps": [
        {"agent": "codex", "model": "gpt-5.6-luna", "effort": "high", "until": {"usedPercent": 95, "window": "5h"}},
        {"agent": "agy", "model": "gemini-2.5-pro", "effort": "high"}
      ]
    },
    "codex": {
      "when": {"parentAgent": "codex"},
      "steps": [
        {"agent": "claude", "model": "claude-sonnet-4-5", "effort": "high"},
        {"agent": "agy", "model": "gemini-2.5-pro", "effort": "high"}
      ]
    },
    "agy": {
      "when": {"parentAgent": "agy"},
      "steps": [
        {"agent": "codex", "model": "gpt-5.6-luna", "effort": "high", "until": {"usedPercent": 95, "window": "5h"}},
        {"agent": "claude", "model": "claude-sonnet-4-5", "effort": "high"}
      ]
    }
  },
  "defaultSteps": []
}
EOF
}

devkit_chain_init() {
  local tmp
  mkdir -p "$DEVKIT_STATE_DIR" || return 1
  if [ ! -f "$DEVKIT_CHAIN_FILE" ]; then
    tmp="$(mktemp "$DEVKIT_STATE_DIR/chains.XXXXXX")" || return 1
    if ! devkit_chain_seed >"$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    mv -f "$tmp" "$DEVKIT_CHAIN_FILE"
  elif ! jq empty "$DEVKIT_CHAIN_FILE" >/dev/null 2>&1; then
    devkit_error "chain file is not valid JSON: $DEVKIT_CHAIN_FILE"
    return 1
  fi
}

devkit_chain_read() {
  devkit_chain_init || return 1
  cat "$DEVKIT_CHAIN_FILE"
}
