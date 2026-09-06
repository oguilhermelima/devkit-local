#!/usr/bin/env bash

DEVKIT_SUPERSET_PROTOCOL="When you need the coordinator's input mid-task, print a line starting with 'DEVKIT_ASK: ' followed by your question, nothing else on that line, then stop and wait — do not guess or proceed past that point until you see a reply appear as your next input. When you have finished all requested work, print a line starting with 'DEVKIT_DONE: ' followed by a short outcome summary, then stop."
DEVKIT_LAST_DISPATCH=""

devkit_dispatch_state_path() {
  local dispatch_id="$1"
  case "$dispatch_id" in
    ""|*[!A-Za-z0-9._-]*)
      devkit_error "invalid dispatch id: $dispatch_id"
      return 1
      ;;
  esac
  printf '%s/%s.json\n' "$DEVKIT_DISPATCH_DIR" "$dispatch_id"
}

devkit_dispatch_state_write() {
  local dispatch_id="$1" workspace_id="$2" terminal_id="$3" last_text_length="$4"
  local state_path tmp
  state_path="$(devkit_dispatch_state_path "$dispatch_id")" || return 1
  mkdir -p "$DEVKIT_DISPATCH_DIR" || return 1
  tmp="$(mktemp "$DEVKIT_DISPATCH_DIR/.dispatch.XXXXXX")" || return 1
  if ! jq -n \
    --arg host superset \
    --arg workspaceId "$workspace_id" \
    --arg terminalId "$terminal_id" \
    --argjson lastTextLength "$last_text_length" \
    --arg createdAt "$(devkit_iso_now)" \
    '{host: $host, workspaceId: $workspaceId, terminalId: $terminalId, lastTextLength: $lastTextLength, createdAt: $createdAt}' \
    >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$state_path"
}
