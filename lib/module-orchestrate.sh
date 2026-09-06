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

devkit_dispatch_state_update_length() {
  local state_path="$1" last_text_length="$2" tmp
  tmp="$(mktemp "$DEVKIT_DISPATCH_DIR/.dispatch.XXXXXX")" || return 1
  if ! jq --argjson lastTextLength "$last_text_length" \
    '.lastTextLength = $lastTextLength' "$state_path" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$state_path"
}

devkit_dispatch_state_read() {
  local dispatch_id="$1" state_path state
  state_path="$(devkit_dispatch_state_path "$dispatch_id")" || return 1
  if [ ! -f "$state_path" ]; then
    devkit_error "dispatch not found: $dispatch_id"
    return 1
  fi
  state="$(<"$state_path")"
  if ! printf '%s' "$state" | jq -e '.host == "superset"' >/dev/null 2>&1; then
    if printf '%s' "$state" | jq -e '.host == "orca"' >/dev/null 2>&1; then
      devkit_error "dispatch $dispatch_id belongs to Orca; use orca orchestration check or orca-wait instead"
    else
      devkit_error "dispatch state has an unsupported host: $dispatch_id"
    fi
    return 1
  fi
  printf '%s\n' "$state"
}

devkit_superset_terminal_read() {
  local workspace_id="$1" terminal_id="$2" max_lines="${3:-}" response text
  local -a read_args
  read_args=(terminals read --workspace "$workspace_id" --terminal "$terminal_id")
  [ -n "$max_lines" ] && read_args+=(--max-lines "$max_lines")
  response="$(devkit_superset "${read_args[@]}" --json 2>/dev/null)" || {
    devkit_error "could not read Superset terminal $terminal_id"
    return 1
  }
  text="$(printf '%s' "$response" | jq -r '.text // .result.text // .output // .result.output // .terminal.text // .result.terminal.text // empty' 2>/dev/null)"
  if ! printf '%s' "$response" | jq -e '((.text // .result.text // .output // .result.output // .terminal.text // .result.terminal.text) | type) == "string"' >/dev/null 2>&1; then
    devkit_error "Superset terminal read returned no text for $terminal_id"
    return 1
  fi
  printf '%s' "$text"
}

devkit_dispatch_extract_marker() {
  local new_text="$1" line
  DEVKIT_MARKER_STATUS=""
  DEVKIT_MARKER_TEXT=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "DEVKIT_ASK: "*)
        DEVKIT_MARKER_STATUS="waiting_for_reply"
        DEVKIT_MARKER_TEXT="${line#DEVKIT_ASK: }"
        return 0
        ;;
      "DEVKIT_DONE: "*)
        DEVKIT_MARKER_STATUS="done"
        DEVKIT_MARKER_TEXT="${line#DEVKIT_DONE: }"
        return 0
        ;;
    esac
  done <<<"$new_text"
}

devkit_dispatch_report() {
  local dispatch_id="$1" status="$2" text="$3" json="$4"
  if [ "$json" = true ]; then
    jq -n --arg dispatchId "$dispatch_id" --arg status "$status" --arg text "$text" \
      '{dispatchId: $dispatchId, status: $status, text: $text}'
  else
    printf 'status: %s\n%s\n' "$status" "$text"
  fi
}

devkit_dispatch_watch() {
  local dispatch_id="${1:-}" timeout=120 poll_interval=3 json=false arg state state_path workspace_id terminal_id
  local last_text_length current_text new_text current_length start_time current_time tail_text
  [ -n "$dispatch_id" ] || { devkit_error "Usage: devkit orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --timeout) timeout="${2:-}"; shift 2 ;;
      --poll-interval) poll_interval="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help)
        printf 'Usage: devkit orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--json]\n'
        return 0
        ;;
      *) devkit_error "unknown orchestrate watch option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  [[ "$timeout" =~ ^[0-9]+$ ]] || { devkit_error "--timeout must be a non-negative number of seconds"; return "$DEVKIT_USAGE_ERROR"; }
  [[ "$poll_interval" =~ ^[0-9]+$ ]] || { devkit_error "--poll-interval must be a non-negative number of seconds"; return "$DEVKIT_USAGE_ERROR"; }
  state="$(devkit_dispatch_state_read "$dispatch_id")" || return 1
  state_path="$(devkit_dispatch_state_path "$dispatch_id")" || return 1
  workspace_id="$(printf '%s' "$state" | jq -r '.workspaceId')"
  terminal_id="$(printf '%s' "$state" | jq -r '.terminalId')"
  last_text_length="$(printf '%s' "$state" | jq -r '.lastTextLength // 0')"
  [[ "$last_text_length" =~ ^[0-9]+$ ]] || { devkit_error "dispatch state has an invalid lastTextLength: $dispatch_id"; return 1; }
  start_time="$(date +%s)"
  while true; do
    current_text="$(devkit_superset_terminal_read "$workspace_id" "$terminal_id")" || return 1
    new_text="${current_text:$last_text_length}"
    devkit_dispatch_extract_marker "$new_text"
    current_length="${#current_text}"
    devkit_dispatch_state_update_length "$state_path" "$current_length" || {
      devkit_error "could not update dispatch state: $dispatch_id"
      return 1
    }
    if [ -n "$DEVKIT_MARKER_STATUS" ]; then
      devkit_dispatch_report "$dispatch_id" "$DEVKIT_MARKER_STATUS" "$DEVKIT_MARKER_TEXT" "$json"
      return 0
    fi
    current_time="$(date +%s)"
    if [ $((current_time - start_time)) -ge "$timeout" ]; then
      tail_text="$(devkit_superset_terminal_read "$workspace_id" "$terminal_id" 20)" || return 1
      devkit_dispatch_report "$dispatch_id" timeout "$tail_text" "$json"
      return 0
    fi
    sleep "$poll_interval"
    last_text_length="$current_length"
  done
}

devkit_dispatch_reply() {
  local dispatch_id="${1:-}" answer="" json=false arg state state_path workspace_id terminal_id current_text
  [ -n "$dispatch_id" ] || { devkit_error "Usage: devkit orchestrate reply <dispatch-id> --text <answer> [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --text) answer="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help)
        printf 'Usage: devkit orchestrate reply <dispatch-id> --text <answer> [--json]\n'
        return 0
        ;;
      *) devkit_error "unknown orchestrate reply option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  [ -n "$answer" ] || { devkit_error "--text is required"; return "$DEVKIT_USAGE_ERROR"; }
  state="$(devkit_dispatch_state_read "$dispatch_id")" || return 1
  state_path="$(devkit_dispatch_state_path "$dispatch_id")" || return 1
  workspace_id="$(printf '%s' "$state" | jq -r '.workspaceId')"
  terminal_id="$(printf '%s' "$state" | jq -r '.terminalId')"
  devkit_superset terminals send --workspace "$workspace_id" --terminal "$terminal_id" --text "$answer" --json >/dev/null || return 1
  current_text="$(devkit_superset_terminal_read "$workspace_id" "$terminal_id")" || return 1
  devkit_dispatch_state_update_length "$state_path" "${#current_text}" || {
    devkit_error "could not update dispatch state: $dispatch_id"
    return 1
  }
  if [ "$json" = true ]; then
    jq -n --arg dispatchId "$dispatch_id" '{dispatchId: $dispatchId, status: "replied"}'
  else
    printf 'replied: %s\n' "$dispatch_id"
  fi
}

devkit_dispatch_close() {
  local dispatch_id="${1:-}" json=false arg state state_path workspace_id terminal_id
  [ -n "$dispatch_id" ] || { devkit_error "Usage: devkit orchestrate close <dispatch-id> [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      -h|--help)
        printf 'Usage: devkit orchestrate close <dispatch-id> [--json]\n'
        return 0
        ;;
      *) devkit_error "unknown orchestrate close option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  state="$(devkit_dispatch_state_read "$dispatch_id")" || return 1
  state_path="$(devkit_dispatch_state_path "$dispatch_id")" || return 1
  workspace_id="$(printf '%s' "$state" | jq -r '.workspaceId')"
  terminal_id="$(printf '%s' "$state" | jq -r '.terminalId')"
  devkit_superset terminals close --workspace "$workspace_id" --terminal "$terminal_id" --json >/dev/null || return 1
  rm -f "$state_path" || return 1
  if [ "$json" = true ]; then
    jq -n --arg dispatchId "$dispatch_id" '{dispatchId: $dispatchId, status: "closed"}'
  else
    printf 'closed: %s\n' "$dispatch_id"
  fi
}
