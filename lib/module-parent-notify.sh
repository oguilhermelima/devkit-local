#!/usr/bin/env bash

MEGABRAIN_PARENT_NOTIFY_TIMEOUT_MS="${MEGABRAIN_PARENT_NOTIFY_TIMEOUT_MS:-1000}"
MEGABRAIN_PARENT_NOTIFY_SETTLE_MS="${MEGABRAIN_PARENT_NOTIFY_SETTLE_MS:-100}"

megabrain_parent_notify_waiter_path() {
  printf '%s/waiter.json\n' "$(megabrain_dispatch_dir "$1")"
}

megabrain_parent_notify_waiter_active() {
  local dispatch_id="$1" path pid
  path="$(megabrain_parent_notify_waiter_path "$dispatch_id")" || return 1
  [ -f "$path" ] || return 1
  pid="$(jq -r '.pid // empty' "$path" 2>/dev/null || true)"
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$path"
    return 1
  fi
  return 0
}

megabrain_parent_notify_waiter_register() {
  local dispatch_id="$1" meta="$2" path tmp lock
  path="$(megabrain_parent_notify_waiter_path "$dispatch_id")" || return 1
  [ -d "$(dirname "$path")" ] || return 1
  lock="$(dirname "$path")/.waiter.lock"
  while ! mkdir "$lock" 2>/dev/null; do sleep 0.02; done
  tmp="$(mktemp "$(dirname "$path")/.waiter.XXXXXX")" || { rmdir "$lock"; return 1; }
  if ! jq -n --argjson meta "$meta" --argjson pid "$$" --arg now "$(megabrain_iso_now)" \
    '{pid: $pid, parentSessionId: $meta.parentSessionId, parentHost: $meta.parentHost, createdAt: $now}' >"$tmp"; then
    rm -f "$tmp"
    rmdir "$lock"
    return 1
  fi
  mv -f "$tmp" "$path"
  rmdir "$lock"
}

megabrain_parent_notify_waiter_unregister() {
  local dispatch_id="$1" path
  path="$(megabrain_parent_notify_waiter_path "$dispatch_id")" || return 1
  rm -f "$path"
}

megabrain_parent_notify_canonical_dir() {
  local path="$1"
  [ -n "$path" ] || return 1
  if [ -d "$path" ]; then
    (cd "$path" && pwd -P)
  else
    printf '%s\n' "$path"
  fi
}

megabrain_parent_notify_context_matches() {
  local meta="$1" dispatch_id dispatch_path owner current context session
  MEGABRAIN_PARENT_NOTIFY_STATE_REASON=state-directory-mismatch
  dispatch_id="$(printf '%s' "$meta" | jq -r '.dispatchId // empty')"
  [ -n "$dispatch_id" ] || return 1
  dispatch_path="$(megabrain_dispatch_meta_path "$dispatch_id")" || return 1
  # WHY: The dispatch path replaces the hardcoded ~/.devkit fallback and survives state renames.
  owner="$(megabrain_parent_notify_canonical_dir "$(dirname "$(dirname "$(dirname "$dispatch_path")")")")" || return 1
  current="$(megabrain_parent_notify_canonical_dir "$MEGABRAIN_STATE_DIR")" || return 1
  [ "$owner" = "$current" ] || return 1
  if [ "$(megabrain_parent_notify_channel "$meta")" = tmux ]; then
    session="$(printf '%s' "$meta" | jq -r '.parentTmuxSession // empty')"
    context="$(tmux show-environment -t "$session" MEGABRAIN_STATE_DIR 2>/dev/null | sed 's/^MEGABRAIN_STATE_DIR=//' || true)"
    [ -n "$context" ] || context="$(tmux show-environment -g MEGABRAIN_STATE_DIR 2>/dev/null | sed 's/^MEGABRAIN_STATE_DIR=//' || true)"
    if [ -z "$context" ]; then
      return 0
    fi
    context="$(megabrain_parent_notify_canonical_dir "$context")" || return 1
    # WHY: The tmux server context is authoritative because a child may override its environment.
    [ "$owner" = "$context" ] || return 1
  fi
  return 0
}

megabrain_parent_notify_pointer() {
  local dispatch_id="$1"
  # The pointer keeps message content in the durable queue and delivery path.
  printf '[megabrain] mail available for dispatch %s; run megabrain orchestrate watch %s\n' "$dispatch_id" "$dispatch_id"
}

megabrain_parent_notify_queues_input() {
  local meta="$1" session agent
  [ "$(megabrain_parent_notify_channel "$meta")" = tmux ] || { printf 'false\n'; return 0; }
  session="$(printf '%s' "$meta" | jq -r '.parentTmuxSession // empty')"
  [ -n "$session" ] || { printf 'false\n'; return 0; }
  declare -F megabrain_tmux_registry_agent_for_session >/dev/null 2>&1 || { printf 'false\n'; return 0; }
  agent="$(megabrain_tmux_registry_agent_for_session "$session" 2>/dev/null || true)"
  [ "$agent" = claude ] && printf 'true\n' || printf 'false\n'
}

megabrain_parent_notify_wake_path() {
  printf '%s/nudge.log\n' "$(megabrain_dispatch_dir "$1")"
}

megabrain_parent_notify_wake() {
  local dispatch_id="$1" pointer="$2" outcome="${3:-}" reason="${4:-}" path lock line
  path="$(megabrain_parent_notify_wake_path "$dispatch_id")" || return 1
  [ -d "$(dirname "$path")" ] || return 1
  line="$pointer"
  if [ -n "$outcome" ]; then
    reason="$(printf '%s' "$reason" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
    [ -n "$reason" ] || reason=unspecified
    line="$pointer outcome=$outcome reason=$reason"
  fi
  lock="$(dirname "$path")/.nudge.lock"
  while ! mkdir "$lock" 2>/dev/null; do sleep 0.02; done
  if ! printf '%s\n' "$line" >>"$path"; then
    rmdir "$lock"
    return 1
  fi
  rmdir "$lock"
}

megabrain_parent_notify_wait_for_wake() {
  local dispatch_id="$1" timeout="$2" path lines wake result fifo_dir fifo tail_pid
  path="$(megabrain_parent_notify_wake_path "$dispatch_id")" || return 1
  : >>"$path" || return 1
  lines="$(wc -l <"$path" | tr -d ' ')"
  # WHY: the follower must be reaped by a pid this function owns. It writes nothing
  # after the wake line, so it never takes SIGPIPE when the read side closes, and a
  # process substitution does not give back a pid that $! reports reliably here.
  fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-wake.XXXXXX")" || return 1
  fifo="$fifo_dir/wake"
  mkfifo "$fifo" || { rm -rf "$fifo_dir"; return 1; }
  tail -n +$((lines + 1)) -f "$path" >"$fifo" 2>/dev/null &
  tail_pid=$!
  # Opening read-write keeps the open from blocking on a writer that never arrives.
  if IFS= read -r -t "$timeout" wake <>"$fifo"; then
    result=0
  else
    result=1
  fi
  kill "$tail_pid" 2>/dev/null
  wait "$tail_pid" 2>/dev/null
  rm -rf "$fifo_dir"
  return "$result"
}

megabrain_parent_notify_tmux_is_idle() {
  local meta="$1" session pane first second last_line
  session="$(printf '%s' "$meta" | jq -r '.parentTmuxSession // empty')"
  pane="$(printf '%s' "$meta" | jq -r '.parentTmuxPane // empty')"
  [ -n "$session" ] && [ -n "$pane" ] || { printf 'unknown\n'; return 0; }
  megabrain_require_command tmux || { printf 'unknown\n'; return 0; }
  megabrain_tmux_session_exists "$session" || { printf 'unknown\n'; return 0; }
  tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | grep -Fx "$pane" >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  first="$(megabrain_tmux_capture_pane "$pane" -40 2>/dev/null || true)"
  sleep "$(awk "BEGIN { printf \"%.3f\", $MEGABRAIN_PARENT_NOTIFY_SETTLE_MS / 1000 }")"
  second="$(megabrain_tmux_capture_pane "$pane" -40 2>/dev/null || true)"
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

megabrain_parent_notify_tmux() {
  local meta="$1" pointer="$2" pane
  pane="$(printf '%s' "$meta" | jq -r '.parentTmuxPane // empty')"
  [ -n "$pane" ] || return 1
  megabrain_tmux_send_text "$pane" "$pointer"
}

megabrain_parent_notify_terminal_text() {
  local response="$1"
  printf '%s' "$response" | jq -r '
    if type == "string" then .
    elif type == "object" then (.text // .output // .content // .result.text // .result.output // tostring)
    else tostring
    end
  ' 2>/dev/null || true
}

megabrain_parent_notify_orca_is_idle() {
  local meta="$1" terminal_id timeout_ms
  terminal_id="$(printf '%s' "$meta" | jq -r '.parentSessionId // empty')"
  timeout_ms="$MEGABRAIN_PARENT_NOTIFY_TIMEOUT_MS"
  [ -n "$terminal_id" ] || { printf 'unknown\n'; return 0; }
  megabrain_require_command orca || { printf 'unknown\n'; return 0; }
  if orca terminal wait --terminal "$terminal_id" --for tui-idle --timeout-ms "$timeout_ms" >/dev/null 2>&1; then
    printf 'true\n'
  else
    printf 'unknown\n'
  fi
}

megabrain_parent_notify_superset_is_idle() {
  local meta="$1" workspace_id terminal_id timeout_ms attempts attempt response rendered previous=""
  workspace_id="$(printf '%s' "$meta" | jq -r '.parentWorkspaceId // empty')"
  terminal_id="$(printf '%s' "$meta" | jq -r '.parentSessionId // empty')"
  timeout_ms="$MEGABRAIN_PARENT_NOTIFY_TIMEOUT_MS"
  [ -n "$workspace_id" ] && [ -n "$terminal_id" ] || { printf 'unknown\n'; return 0; }
  megabrain_superset_available || { printf 'unknown\n'; return 0; }
  attempts=$(( (timeout_ms + MEGABRAIN_PARENT_NOTIFY_SETTLE_MS - 1) / MEGABRAIN_PARENT_NOTIFY_SETTLE_MS ))
  [ "$attempts" -gt 0 ] || attempts=1
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    response="$(megabrain_superset terminals read --workspace "$workspace_id" --terminal "$terminal_id" --json 2>/dev/null || true)"
    printf '%s' "$response" | jq -e . >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
    rendered="$(megabrain_parent_notify_terminal_text "$response")"
    if [ -n "$(printf '%s' "$rendered" | tr -d '[:space:]')" ] && [ "$rendered" = "$previous" ]; then
      printf 'true\n'
      return 0
    fi
    previous="$rendered"
    sleep "$(awk "BEGIN { printf \"%.3f\", $MEGABRAIN_PARENT_NOTIFY_SETTLE_MS / 1000 }")"
  done
  printf 'unknown\n'
}

# WHY: .runtime says how the CHILD was launched. Reaching the PARENT is a property of
# the parent, and the two are independent: a dispatch started in an IDE tab can have a
# parent sitting in a tmux pane. Deciding by the child's runtime sent such a notice to
# the host, whose terminals read answered "not active", which became liveness unknown
# and silently suppressed the pointer while the tmux coordinates sat unused in the meta.
# tmux is checked with plain tmux commands so this module keeps working where the tmux
# runtime module is not sourced.
megabrain_parent_notify_channel() {
  local meta="$1" session pane
  session="$(printf '%s' "$meta" | jq -r '.parentTmuxSession // empty')"
  pane="$(printf '%s' "$meta" | jq -r '.parentTmuxPane // empty')"
  if [ -n "$session" ] && [ -n "$pane" ] && megabrain_require_command tmux &&
    tmux has-session -t "$session" 2>/dev/null &&
    tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | grep -Fx "$pane" >/dev/null 2>&1; then
    printf 'tmux\n'
    return 0
  fi
  printf '%s\n' "$(printf '%s' "$meta" | jq -r '.parentHost // empty')"
}

megabrain_parent_is_idle() {
  local meta="$1"
  case "$(megabrain_parent_notify_channel "$meta")" in
    tmux) megabrain_parent_notify_tmux_is_idle "$meta" ;;
    orca) megabrain_parent_notify_orca_is_idle "$meta" ;;
    superset) megabrain_parent_notify_superset_is_idle "$meta" ;;
    *) printf 'unknown\n' ;;
  esac
}

megabrain_parent_notify() {
  local meta="$1" pointer="$2" host workspace_id terminal_id
  host="$(megabrain_parent_notify_channel "$meta")"
  if [ "$host" = tmux ]; then
    megabrain_parent_notify_tmux "$meta" "$pointer"
    return $?
  fi
  workspace_id="$(printf '%s' "$meta" | jq -r '.parentWorkspaceId // empty')"
  terminal_id="$(printf '%s' "$meta" | jq -r '.parentSessionId // empty')"
  case "$host" in
    orca) orca terminal send --terminal "$terminal_id" --text "$pointer" --enter --json >/dev/null ;;
    superset) megabrain_superset terminals send --workspace "$workspace_id" --terminal "$terminal_id" --text "$pointer" --json >/dev/null ;;
    *) megabrain_error "unsupported parent host: $host"; return 1 ;;
  esac
}

megabrain_parent_notify_dispatch() {
  local meta="$1" dispatch_id idle pointer queueing notify_error notify_reason notify_error_path notify_status
  MEGABRAIN_PARENT_NOTIFY_RESULT=skipped
  dispatch_id="$(printf '%s' "$meta" | jq -r '.dispatchId // empty')"
  [ -n "$dispatch_id" ] || { MEGABRAIN_PARENT_NOTIFY_RESULT=failed; return 1; }
  pointer="$(megabrain_parent_notify_pointer "$dispatch_id")"
  if ! megabrain_parent_notify_context_matches "$meta"; then
    MEGABRAIN_PARENT_NOTIFY_RESULT=suppressed
    megabrain_parent_notify_wake "$dispatch_id" "$pointer" suppressed "${MEGABRAIN_PARENT_NOTIFY_STATE_REASON:-state-directory-mismatch}" >/dev/null 2>&1 || true
    return 0
  fi
  if megabrain_parent_notify_waiter_active "$dispatch_id"; then
    MEGABRAIN_PARENT_NOTIFY_RESULT=suppressed
    megabrain_parent_notify_wake "$dispatch_id" "$pointer" suppressed active-waiter >/dev/null 2>&1 || true
    return 0
  fi
  queueing="$(megabrain_parent_notify_queues_input "$meta")"
  # Claude Code's TUI queues input while busy.
  if [ "$queueing" != true ]; then
    idle="$(megabrain_parent_is_idle "$meta")"
    case "$idle" in
      true) ;;
      false)
        MEGABRAIN_PARENT_NOTIFY_RESULT=busy
        megabrain_parent_notify_wake "$dispatch_id" "$pointer" suppressed parent-busy >/dev/null 2>&1 || true
        return 0
        ;;
      *)
        MEGABRAIN_PARENT_NOTIFY_RESULT=unknown
        megabrain_parent_notify_wake "$dispatch_id" "$pointer" suppressed parent-liveness-unknown >/dev/null 2>&1 || true
        return 0
        ;;
    esac
  fi
  if megabrain_parent_notify_waiter_active "$dispatch_id"; then
    MEGABRAIN_PARENT_NOTIFY_RESULT=suppressed
    megabrain_parent_notify_wake "$dispatch_id" "$pointer" suppressed active-waiter >/dev/null 2>&1 || true
    return 0
  fi
  notify_error_path="$(mktemp "$(megabrain_dispatch_dir "$dispatch_id")/.notify-error.XXXXXX" 2>/dev/null || true)"
  notify_status=0
  if [ -n "$notify_error_path" ]; then
    megabrain_parent_notify "$meta" "$pointer" 2>"$notify_error_path" || notify_status=$?
    notify_error="$(cat "$notify_error_path" 2>/dev/null || true)"
    rm -f "$notify_error_path"
  else
    megabrain_parent_notify "$meta" "$pointer" || notify_status=$?
    notify_error=""
  fi
  if [ "$notify_status" -eq 0 ]; then
    MEGABRAIN_PARENT_NOTIFY_RESULT=delivered
    if [ "$queueing" = true ]; then
      megabrain_parent_notify_wake "$dispatch_id" "$pointer" delivered queueing-parent >/dev/null 2>&1 || true
    else
      megabrain_parent_notify_wake "$dispatch_id" "$pointer" delivered parent-idle >/dev/null 2>&1 || true
    fi
    return 0
  fi
  MEGABRAIN_PARENT_NOTIFY_RESULT=failed
  notify_reason="$(printf '%s' "$notify_error" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
  [ -n "$notify_reason" ] || notify_reason=notify-failed
  megabrain_parent_notify_wake "$dispatch_id" "$pointer" failed "$notify_reason" >/dev/null 2>&1 || true
  return 1
}
