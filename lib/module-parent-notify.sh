#!/usr/bin/env bash

DEVKIT_PARENT_NOTIFY_TIMEOUT_MS="${DEVKIT_PARENT_NOTIFY_TIMEOUT_MS:-1000}"
DEVKIT_PARENT_NOTIFY_SETTLE_MS="${DEVKIT_PARENT_NOTIFY_SETTLE_MS:-100}"

devkit_parent_notify_waiter_path() {
  printf '%s/waiter.json\n' "$(devkit_dispatch_dir "$1")"
}

devkit_parent_notify_waiter_active() {
  local dispatch_id="$1" path pid
  path="$(devkit_parent_notify_waiter_path "$dispatch_id")" || return 1
  [ -f "$path" ] || return 1
  pid="$(jq -r '.pid // empty' "$path" 2>/dev/null || true)"
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$path"
    return 1
  fi
  return 0
}

devkit_parent_notify_waiter_register() {
  local dispatch_id="$1" meta="$2" path tmp lock
  path="$(devkit_parent_notify_waiter_path "$dispatch_id")" || return 1
  [ -d "$(dirname "$path")" ] || return 1
  lock="$(dirname "$path")/.waiter.lock"
  while ! mkdir "$lock" 2>/dev/null; do sleep 0.02; done
  tmp="$(mktemp "$(dirname "$path")/.waiter.XXXXXX")" || { rmdir "$lock"; return 1; }
  if ! jq -n --argjson meta "$meta" --argjson pid "$$" --arg now "$(devkit_iso_now)" \
    '{pid: $pid, parentSessionId: $meta.parentSessionId, parentHost: $meta.parentHost, createdAt: $now}' >"$tmp"; then
    rm -f "$tmp"
    rmdir "$lock"
    return 1
  fi
  mv -f "$tmp" "$path"
  rmdir "$lock"
}

devkit_parent_notify_waiter_unregister() {
  local dispatch_id="$1" path
  path="$(devkit_parent_notify_waiter_path "$dispatch_id")" || return 1
  rm -f "$path"
}

devkit_parent_notify_pointer() {
  local dispatch_id="$1"
  # The pointer keeps message content in the durable queue and delivery path.
  printf '[devkit] mail available for dispatch %s; run devkit orchestrate watch %s\n' "$dispatch_id" "$dispatch_id"
}

devkit_parent_notify_wake_path() {
  printf '%s/nudge.log\n' "$(devkit_dispatch_dir "$1")"
}

devkit_parent_notify_wake() {
  local dispatch_id="$1" pointer="$2" path lock
  path="$(devkit_parent_notify_wake_path "$dispatch_id")" || return 1
  [ -d "$(dirname "$path")" ] || return 1
  lock="$(dirname "$path")/.nudge.lock"
  while ! mkdir "$lock" 2>/dev/null; do sleep 0.02; done
  if ! printf '%s\n' "$pointer" >>"$path"; then
    rmdir "$lock"
    return 1
  fi
  rmdir "$lock"
}

devkit_parent_notify_wait_for_wake() {
  local dispatch_id="$1" timeout="$2" path lines wake result
  path="$(devkit_parent_notify_wake_path "$dispatch_id")" || return 1
  : >>"$path" || return 1
  lines="$(wc -l <"$path" | tr -d ' ')"
  if IFS= read -r -t "$timeout" wake < <(tail -n +$((lines + 1)) -f "$path"); then
    result=0
  else
    result=1
  fi
  return "$result"
}

devkit_parent_notify_tmux_is_idle() {
  local meta="$1" session pane first second last_line
  session="$(printf '%s' "$meta" | jq -r '.parentTmuxSession // empty')"
  pane="$(printf '%s' "$meta" | jq -r '.parentTmuxPane // empty')"
  [ -n "$session" ] && [ -n "$pane" ] || { printf 'unknown\n'; return 0; }
  devkit_require_command tmux || { printf 'unknown\n'; return 0; }
  devkit_tmux_session_exists "$session" || { printf 'unknown\n'; return 0; }
  tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | grep -Fx "$pane" >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  first="$(devkit_tmux_capture_pane "$pane" -40 2>/dev/null || true)"
  sleep "$(awk "BEGIN { printf \"%.3f\", $DEVKIT_PARENT_NOTIFY_SETTLE_MS / 1000 }")"
  second="$(devkit_tmux_capture_pane "$pane" -40 2>/dev/null || true)"
  [ "$first" = "$second" ] || { printf 'unknown\n'; return 0; }
  last_line="$(printf '%s\n' "$second" | tail -n 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$last_line" in
    *Working*|*Thinking*|*Running*|*'esc to interrupt'*|*'ctrl-c to interrupt'*) printf 'false\n' ;;
    '⏵⏵ bypass permissions on · 1 shell · ← for agents') printf 'true\n' ;;
    # Unknown is not idle because a failed liveness check must never type into the parent.
    *'›'|*'❯'|*'$'|*'%'|*'#') printf 'true\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

devkit_parent_notify_tmux() {
  local meta="$1" pointer="$2" pane
  pane="$(printf '%s' "$meta" | jq -r '.parentTmuxPane // empty')"
  [ -n "$pane" ] || return 1
  tmux send-keys -t "$pane" -l "$pointer" || return 1
  tmux send-keys -t "$pane" Enter
}

devkit_parent_notify_terminal_text() {
  local response="$1"
  printf '%s' "$response" | jq -r '
    if type == "string" then .
    elif type == "object" then (.text // .output // .content // .result.text // .result.output // tostring)
    else tostring
    end
  ' 2>/dev/null || true
}

devkit_parent_notify_orca_is_idle() {
  local meta="$1" terminal_id timeout_ms
  terminal_id="$(printf '%s' "$meta" | jq -r '.parentSessionId // empty')"
  timeout_ms="$DEVKIT_PARENT_NOTIFY_TIMEOUT_MS"
  [ -n "$terminal_id" ] || { printf 'unknown\n'; return 0; }
  devkit_require_command orca || { printf 'unknown\n'; return 0; }
  if orca terminal wait --terminal "$terminal_id" --for tui-idle --timeout-ms "$timeout_ms" >/dev/null 2>&1; then
    printf 'true\n'
  else
    printf 'unknown\n'
  fi
}

devkit_parent_notify_superset_is_idle() {
  local meta="$1" workspace_id terminal_id timeout_ms attempts attempt response rendered previous=""
  workspace_id="$(printf '%s' "$meta" | jq -r '.parentWorkspaceId // empty')"
  terminal_id="$(printf '%s' "$meta" | jq -r '.parentSessionId // empty')"
  timeout_ms="$DEVKIT_PARENT_NOTIFY_TIMEOUT_MS"
  [ -n "$workspace_id" ] && [ -n "$terminal_id" ] || { printf 'unknown\n'; return 0; }
  devkit_superset_available || { printf 'unknown\n'; return 0; }
  attempts=$(( (timeout_ms + DEVKIT_PARENT_NOTIFY_SETTLE_MS - 1) / DEVKIT_PARENT_NOTIFY_SETTLE_MS ))
  [ "$attempts" -gt 0 ] || attempts=1
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    response="$(devkit_superset terminals read --workspace "$workspace_id" --terminal "$terminal_id" --json 2>/dev/null || true)"
    printf '%s' "$response" | jq -e . >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
    rendered="$(devkit_parent_notify_terminal_text "$response")"
    if [ -n "$(printf '%s' "$rendered" | tr -d '[:space:]')" ] && [ "$rendered" = "$previous" ]; then
      printf 'true\n'
      return 0
    fi
    previous="$rendered"
    sleep "$(awk "BEGIN { printf \"%.3f\", $DEVKIT_PARENT_NOTIFY_SETTLE_MS / 1000 }")"
  done
  printf 'unknown\n'
}

devkit_parent_is_idle() {
  local meta="$1" runtime host
  runtime="$(printf '%s' "$meta" | jq -r '.runtime // "host"')"
  if [ "$runtime" = tmux ]; then
    devkit_parent_notify_tmux_is_idle "$meta"
    return 0
  fi
  host="$(printf '%s' "$meta" | jq -r '.parentHost // empty')"
  case "$host" in
    orca) devkit_parent_notify_orca_is_idle "$meta" ;;
    superset) devkit_parent_notify_superset_is_idle "$meta" ;;
    *) printf 'unknown\n' ;;
  esac
}

devkit_parent_notify() {
  local meta="$1" pointer="$2" runtime host workspace_id terminal_id
  runtime="$(printf '%s' "$meta" | jq -r '.runtime // "host"')"
  if [ "$runtime" = tmux ]; then
    devkit_parent_notify_tmux "$meta" "$pointer"
    return $?
  fi
  host="$(printf '%s' "$meta" | jq -r '.parentHost // empty')"
  workspace_id="$(printf '%s' "$meta" | jq -r '.parentWorkspaceId // empty')"
  terminal_id="$(printf '%s' "$meta" | jq -r '.parentSessionId // empty')"
  case "$host" in
    orca) orca terminal send --terminal "$terminal_id" --text "$pointer" --enter --json >/dev/null ;;
    superset) devkit_superset terminals send --workspace "$workspace_id" --terminal "$terminal_id" --text "$pointer" --json >/dev/null ;;
    *) devkit_error "unsupported parent host: $host"; return 1 ;;
  esac
}

devkit_parent_notify_dispatch() {
  local meta="$1" dispatch_id idle pointer
  DEVKIT_PARENT_NOTIFY_RESULT=skipped
  dispatch_id="$(printf '%s' "$meta" | jq -r '.dispatchId // empty')"
  [ -n "$dispatch_id" ] || { DEVKIT_PARENT_NOTIFY_RESULT=failed; return 1; }
  pointer="$(devkit_parent_notify_pointer "$dispatch_id")"
  devkit_parent_notify_wake "$dispatch_id" "$pointer" >/dev/null 2>&1 || true
  if devkit_parent_notify_waiter_active "$dispatch_id"; then
    DEVKIT_PARENT_NOTIFY_RESULT=suppressed
    return 0
  fi
  idle="$(devkit_parent_is_idle "$meta")"
  case "$idle" in
    true) ;;
    false) DEVKIT_PARENT_NOTIFY_RESULT=busy; return 0 ;;
    *) DEVKIT_PARENT_NOTIFY_RESULT=unknown; return 0 ;;
  esac
  if devkit_parent_notify_waiter_active "$dispatch_id"; then
    DEVKIT_PARENT_NOTIFY_RESULT=suppressed
    return 0
  fi
  if devkit_parent_notify "$meta" "$pointer"; then
    DEVKIT_PARENT_NOTIFY_RESULT=delivered
    return 0
  fi
  DEVKIT_PARENT_NOTIFY_RESULT=failed
  return 1
}
