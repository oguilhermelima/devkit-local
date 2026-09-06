#!/usr/bin/env bash

DEVKIT_SUPERSET_PROTOCOL="This is a managed devkit dispatch. If you need coordinator input, run devkit ask \"your question\" and stop until the coordinator replies. When the requested work is complete, run devkit done \"short outcome summary\". Do not print protocol markers and do not continue past an unanswered question."
DEVKIT_LAST_DISPATCH=""

devkit_dispatch_default_label() {
  local user_name host_name timestamp
  user_name="${USER:-$(id -un 2>/dev/null || true)}"
  host_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
  timestamp="$(devkit_iso_now)"
  if [ -n "$user_name" ] && [ -n "$host_name" ]; then
    printf '%s@%s %s\n' "$user_name" "$host_name" "$timestamp"
  elif [ -n "$timestamp" ]; then
    printf 'devkit-dispatch-%s\n' "$timestamp"
  else
    printf 'devkit-dispatch\n'
  fi
}

devkit_dispatch_dir() {
  local dispatch_id="$1"
  case "$dispatch_id" in
    ""|*[!A-Za-z0-9._-]*)
      devkit_error "invalid dispatch id: $dispatch_id"
      return 1
      ;;
  esac
  printf '%s/%s\n' "$DEVKIT_DISPATCH_DIR" "$dispatch_id"
}

devkit_dispatch_meta_path() { printf '%s/meta.json\n' "$(devkit_dispatch_dir "$1")"; }
devkit_dispatch_messages_dir() { printf '%s/messages\n' "$(devkit_dispatch_dir "$1")"; }
devkit_dispatch_cursor_path() { printf '%s/cursor.json\n' "$(devkit_dispatch_dir "$1")"; }

devkit_dispatch_meta_write() {
  local dispatch_id="$1" parent_session="$2" parent_host="$3" child_host="$4"
  local workspace_id="$5" terminal_id="$6" worktree_path="$7" branch="$8"
  local agent="$9" label="${10}" state="${11}" dispatch_dir tmp
  dispatch_dir="$(devkit_dispatch_dir "$dispatch_id")" || return 1
  mkdir -p "$dispatch_dir/messages" || return 1
  devkit_dispatch_cursor_write "$dispatch_id" 0 || return 1
  tmp="$(mktemp "$dispatch_dir/.meta.XXXXXX")" || return 1
  if ! jq -n \
    --arg dispatchId "$dispatch_id" --arg parentSessionId "$parent_session" \
    --arg parentHost "$parent_host" --arg childHost "$child_host" \
    --arg workspaceId "$workspace_id" --arg terminalId "$terminal_id" \
    --arg worktreePath "$worktree_path" --arg branch "$branch" \
    --arg agent "$agent" --arg label "$label" --arg state "$state" \
    --arg now "$(devkit_iso_now)" \
    '{dispatchId: $dispatchId, parentSessionId: $parentSessionId, parentHost: $parentHost, childHost: $childHost, workspaceId: $workspaceId, terminalId: $terminalId, worktreePath: $worktreePath, branch: $branch, agent: $agent, label: $label, state: $state, createdAt: $now, updatedAt: $now}' \
    >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$(devkit_dispatch_meta_path "$dispatch_id")"
  printf '%s\n' "$dispatch_id"
}

devkit_dispatch_meta_read() {
  local dispatch_id="$1" path
  path="$(devkit_dispatch_meta_path "$dispatch_id")" || return 1
  if [ ! -f "$path" ]; then
    devkit_error "dispatch not found: $dispatch_id"
    return 1
  fi
  jq -e . "$path" >/dev/null 2>&1 || { devkit_error "dispatch metadata is not valid JSON: $dispatch_id"; return 1; }
  cat "$path"
}

devkit_dispatch_meta_update_state() {
  local dispatch_id="$1" state="$2" path tmp
  path="$(devkit_dispatch_meta_path "$dispatch_id")" || return 1
  tmp="$(mktemp "$(devkit_dispatch_dir "$dispatch_id")/.meta.XXXXXX")" || return 1
  if ! jq --arg state "$state" --arg now "$(devkit_iso_now)" '.state = $state | .updatedAt = $now' "$path" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path"
}

devkit_dispatch_cursor_read() {
  local dispatch_id="$1" path value
  path="$(devkit_dispatch_cursor_path "$dispatch_id")" || return 1
  if [ ! -f "$path" ]; then
    printf '{"lastReadSeq":0}\n' >"$path" || return 1
  fi
  value="$(jq -r '.lastReadSeq // 0' "$path" 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+$ ]] || { devkit_error "dispatch cursor is invalid: $dispatch_id"; return 1; }
  printf '%s\n' "$value"
}

devkit_dispatch_cursor_write() {
  local dispatch_id="$1" seq="$2" path tmp
  path="$(devkit_dispatch_cursor_path "$dispatch_id")" || return 1
  tmp="$(mktemp "$(devkit_dispatch_dir "$dispatch_id")/.cursor.XXXXXX")" || return 1
  jq -n --argjson seq "$seq" '{lastReadSeq: $seq}' >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

devkit_dispatch_message_append() {
  local dispatch_id="$1" from="$2" type="$3" text="$4" session_id="$5"
  local messages_dir lock path tmp seq file_name
  messages_dir="$(devkit_dispatch_messages_dir "$dispatch_id")" || return 1
  lock="$messages_dir/.lock"
  while ! mkdir "$lock" 2>/dev/null; do sleep 0.02; done
  seq="$(find "$messages_dir" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | sed 's|.*/||; s|-.*||' | sort -n | tail -n 1)"
  [ -n "$seq" ] || seq=0
  seq=$((seq + 1))
  file_name="$(printf '%04d-%s-%s.json' "$seq" "$from" "$type")"
  path="$messages_dir/$file_name"
  tmp="$(mktemp "$messages_dir/.message.XXXXXX")" || { rmdir "$lock"; return 1; }
  if ! jq -n --argjson seq "$seq" --arg from "$from" --arg type "$type" --arg text "$text" \
    --arg createdAt "$(devkit_iso_now)" --arg sessionId "$session_id" \
    '{seq: $seq, from: $from, type: $type, text: $text, createdAt: $createdAt, sessionId: $sessionId}' >"$tmp"; then
    rm -f "$tmp"
    rmdir "$lock"
    return 1
  fi
  mv -f "$tmp" "$path"
  rmdir "$lock"
  DEVKIT_LAST_MESSAGE_SEQ="$seq"
  printf '%s\n' "$seq"
}

devkit_dispatch_require_session() {
  devkit_session_id >/dev/null
  if [ -z "${DEVKIT_SESSION_ID:-}" ]; then
    devkit_error "this command requires a managed terminal identity; run it inside an Orca or Superset terminal"
    return 1
  fi
}

devkit_dispatch_require_parent() {
  local dispatch_id="$1" meta expected_id expected_host
  devkit_dispatch_require_session || return 1
  meta="$(devkit_dispatch_meta_read "$dispatch_id")" || return 1
  expected_id="$(printf '%s' "$meta" | jq -r '.parentSessionId // empty')"
  expected_host="$(printf '%s' "$meta" | jq -r '.parentHost // empty')"
  if [ "$DEVKIT_SESSION_ID" != "$expected_id" ] || [ "$DEVKIT_SESSION_HOST" != "$expected_host" ]; then
    devkit_error "dispatch $dispatch_id is owned by $expected_host/$expected_id, not $DEVKIT_SESSION_HOST/$DEVKIT_SESSION_ID"
    return 1
  fi
  printf '%s\n' "$meta"
}

devkit_dispatch_find_child() {
  local meta_path meta dispatch_id
  DEVKIT_FOUND_DISPATCH=""
  devkit_dispatch_require_session || return 1
  for meta_path in "$DEVKIT_DISPATCH_DIR"/*/meta.json; do
    [ -f "$meta_path" ] || continue
    meta="$(cat "$meta_path")"
    if printf '%s' "$meta" | jq -e --arg id "$DEVKIT_SESSION_ID" --arg host "$DEVKIT_SESSION_HOST" \
      '.terminalId == $id and .childHost == $host' >/dev/null 2>&1; then
      dispatch_id="$(printf '%s' "$meta" | jq -r '.dispatchId')"
      if [ -n "$DEVKIT_FOUND_DISPATCH" ]; then
        devkit_error "terminal identity matches multiple dispatches"
        return 1
      fi
      DEVKIT_FOUND_DISPATCH="$dispatch_id"
    fi
  done
  [ -n "$DEVKIT_FOUND_DISPATCH" ] || { devkit_error "no managed dispatch belongs to $DEVKIT_SESSION_HOST/$DEVKIT_SESSION_ID"; return 1; }
}

devkit_dispatch_native_send() {
  local meta="$1" text="$2" host workspace_id terminal_id
  host="$(printf '%s' "$meta" | jq -r '.childHost')"
  workspace_id="$(printf '%s' "$meta" | jq -r '.workspaceId // empty')"
  terminal_id="$(printf '%s' "$meta" | jq -r '.terminalId')"
  case "$host" in
    superset) devkit_superset terminals send --workspace "$workspace_id" --terminal "$terminal_id" --text "$text" --json >/dev/null ;;
    orca) orca terminal send --terminal "$terminal_id" --text "$text" --enter --json >/dev/null ;;
    *) devkit_error "unsupported child host: $host"; return 1 ;;
  esac
}

devkit_dispatch_native_close() {
  local meta="$1" host workspace_id terminal_id
  host="$(printf '%s' "$meta" | jq -r '.childHost')"
  workspace_id="$(printf '%s' "$meta" | jq -r '.workspaceId // empty')"
  terminal_id="$(printf '%s' "$meta" | jq -r '.terminalId')"
  case "$host" in
    superset) devkit_superset terminals close --workspace "$workspace_id" --terminal "$terminal_id" --json >/dev/null ;;
    orca) orca terminal close --terminal "$terminal_id" --json >/dev/null ;;
    *) devkit_error "unsupported child host: $host"; return 1 ;;
  esac
}

devkit_dispatch_report() {
  local dispatch_id="$1" status="$2" text="$3" json="$4"
  if [ "$json" = true ]; then
    jq -n --arg dispatchId "$dispatch_id" --arg status "$status" --arg text "$text" '{dispatchId: $dispatchId, status: $status, text: $text}'
  else
    printf 'status: %s\n%s\n' "$status" "$text"
  fi
}

devkit_dispatch_watch() {
  local dispatch_id="${1:-}" timeout=120 poll_interval=3 json=false arg meta cursor start_time now path
  local seq from type text reported=false
  [ -n "$dispatch_id" ] || { devkit_error "Usage: devkit orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --timeout) timeout="${2:-}"; shift 2 ;;
      --poll-interval) poll_interval="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--json]\n'; return 0 ;;
      *) devkit_error "unknown orchestrate watch option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  [[ "$timeout" =~ ^[0-9]+$ ]] || { devkit_error "--timeout must be a non-negative number of seconds"; return "$DEVKIT_USAGE_ERROR"; }
  [[ "$poll_interval" =~ ^[0-9]+$ ]] || { devkit_error "--poll-interval must be a non-negative number of seconds"; return "$DEVKIT_USAGE_ERROR"; }
  meta="$(devkit_dispatch_meta_read "$dispatch_id")" || return 1
  cursor="$(devkit_dispatch_cursor_read "$dispatch_id")" || return 1
  start_time="$(date +%s)"
  while true; do
    for path in "$(devkit_dispatch_messages_dir "$dispatch_id")"/*.json; do
      [ -f "$path" ] || continue
      seq="$(jq -r '.seq // 0' "$path" 2>/dev/null || true)"
      [[ "$seq" =~ ^[0-9]+$ ]] || continue
      [ "$seq" -gt "$cursor" ] || continue
      from="$(jq -r '.from // empty' "$path")"
      type="$(jq -r '.type // empty' "$path")"
      [ "$from" = child ] || continue
      case "$type" in
        ask) text="$(jq -r '.text // empty' "$path")"; devkit_dispatch_cursor_write "$dispatch_id" "$seq" || return 1; devkit_dispatch_report "$dispatch_id" waiting_for_reply "$text" "$json"; reported=true ;;
        done) text="$(jq -r '.text // empty' "$path")"; devkit_dispatch_cursor_write "$dispatch_id" "$seq" || return 1; devkit_dispatch_report "$dispatch_id" done "$text" "$json"; reported=true ;;
      esac
      [ "$reported" = true ] && return 0
    done
    now="$(date +%s)"
    if [ $((now - start_time)) -ge "$timeout" ]; then
      devkit_dispatch_report "$dispatch_id" timeout "" "$json"
      return 0
    fi
    sleep "$poll_interval"
  done
}

devkit_dispatch_reply() {
  local dispatch_id="${1:-}" answer="" json=false arg meta state
  [ -n "$dispatch_id" ] || { devkit_error "Usage: devkit orchestrate reply <dispatch-id> --text <answer> [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --text) answer="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit orchestrate reply <dispatch-id> --text <answer> [--json]\n'; return 0 ;;
      *) devkit_error "unknown orchestrate reply option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  [ -n "$answer" ] || { devkit_error "--text is required"; return "$DEVKIT_USAGE_ERROR"; }
  meta="$(devkit_dispatch_require_parent "$dispatch_id")" || return 1
  state="$(printf '%s' "$meta" | jq -r '.state // empty')"
  [ "$state" = waiting_for_reply ] || { devkit_error "dispatch $dispatch_id is not waiting_for_reply (state: $state)"; return 1; }
  devkit_dispatch_native_send "$meta" "$answer" || { devkit_error "could not deliver reply to dispatch $dispatch_id"; return 1; }
  devkit_dispatch_message_append "$dispatch_id" parent reply "$answer" "$DEVKIT_SESSION_ID" >/dev/null || return 1
  devkit_dispatch_meta_update_state "$dispatch_id" running || return 1
  if [ "$json" = true ]; then
    jq -n --arg dispatchId "$dispatch_id" '{dispatchId: $dispatchId, status: "replied"}'
  else
    printf 'replied: %s\n' "$dispatch_id"
  fi
}

devkit_dispatch_close() {
  local dispatch_id="${1:-}" json=false arg meta
  [ -n "$dispatch_id" ] || { devkit_error "Usage: devkit orchestrate close <dispatch-id> [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit orchestrate close <dispatch-id> [--json]\n'; return 0 ;;
      *) devkit_error "unknown orchestrate close option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  meta="$(devkit_dispatch_require_parent "$dispatch_id")" || return 1
  devkit_dispatch_native_close "$meta" || { devkit_error "could not close dispatch $dispatch_id"; return 1; }
  devkit_dispatch_meta_update_state "$dispatch_id" closed || return 1
  if [ "$json" = true ]; then
    if [ "$(printf '%s' "$meta" | jq -r '.childHost')" = superset ]; then
      jq -n --arg dispatchId "$dispatch_id" '{dispatchId: $dispatchId, status: "closed", message: "Superset leaves the pane visible as Desconectado until the human dismisses it with the pane X."}'
    else
      jq -n --arg dispatchId "$dispatch_id" '{dispatchId: $dispatchId, status: "closed"}'
    fi
  else
    printf 'closed: %s\n' "$dispatch_id"
    if [ "$(printf '%s' "$meta" | jq -r '.childHost')" = superset ]; then
      printf 'Superset leaves the pane visible as Desconectado until the human dismisses it with the pane X.\n'
    fi
  fi
}

devkit_dispatch_child_message() {
  local type="$1" text="$2" dispatch_id
  case "$type" in
    ask|done) ;;
    *) devkit_error "unsupported child message type: $type"; return "$DEVKIT_USAGE_ERROR" ;;
  esac
  devkit_dispatch_find_child || return 1
  dispatch_id="$DEVKIT_FOUND_DISPATCH"
  devkit_dispatch_message_append "$dispatch_id" child "$type" "$text" "$DEVKIT_SESSION_ID" >/dev/null || return 1
  if [ "$type" = ask ]; then
    devkit_dispatch_meta_update_state "$dispatch_id" waiting_for_reply || return 1
  else
    devkit_dispatch_meta_update_state "$dispatch_id" done || return 1
  fi
  printf '%s sent: %s\n' "$type" "$dispatch_id"
}

command_ask() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || { devkit_error 'Usage: devkit ask "question"'; return "$DEVKIT_USAGE_ERROR"; }
  devkit_dispatch_child_message ask "$1"
}

command_done() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || { devkit_error 'Usage: devkit done "summary"'; return "$DEVKIT_USAGE_ERROR"; }
  devkit_dispatch_child_message done "$1"
}
