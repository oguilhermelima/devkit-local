#!/usr/bin/env bash

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
  # WHY: The dispatch path keeps ownership tied to the active state directory.
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
  printf 'mail: megabrain orchestrate watch %s\n' "$dispatch_id"
}

megabrain_parent_notify_pointer_many() {
  local count="$1"
  printf '%s mails: run megabrain orchestrate list\n' "$count"
}

megabrain_parent_notify_wake_path() {
  printf '%s/nudge.log\n' "$(megabrain_dispatch_dir "$1")"
}

megabrain_parent_notify_nudge_state_path() {
  printf '%s/nudge-state.json\n' "$(megabrain_dispatch_dir "$1")"
}

megabrain_parent_notify_nudge_state_lock_path() {
  printf '%s/.nudge-state.lock\n' "$(megabrain_dispatch_dir "$1")"
}

megabrain_parent_notify_delivery_contains_seq() {
  local dispatch_id="$1" message_seq="$2" deliveries_dir="" path="" status=""
  deliveries_dir="$(megabrain_dispatch_deliveries_dir "$dispatch_id")" || return 1
  for path in "$deliveries_dir"/*.json; do
    [ -f "$path" ] || continue
    status="$(jq -r '.status // empty' "$path" 2>/dev/null || true)"
    case "$status" in
      outstanding|acknowledged)
        jq -e --argjson seq "$message_seq" '(.messageSeqs // []) | index($seq) != null' "$path" >/dev/null 2>&1 &&
          return 0
        ;;
    esac
  done
  return 1
}

megabrain_parent_notify_nudge_claim() {
  local dispatch_id="$1" message_seq="$2" state_path="" lock="" state_status="" state_seq="" cursor="" tmp=""
  MEGABRAIN_PARENT_NOTIFY_NUDGE_REASON=nudge-outstanding
  state_path="$(megabrain_parent_notify_nudge_state_path "$dispatch_id")" || return 1
  lock="$(megabrain_parent_notify_nudge_state_lock_path "$dispatch_id")" || return 1
  while ! mkdir "$lock" 2>/dev/null; do sleep 0.02; done
  # WHY: the cursor is parent-side read evidence, regardless of whether watch
  # created a delivery. Keep delivery as a fallback for the watch path, where
  # the parent may have consumed mail without advancing its turn-end cursor.
  cursor="$(megabrain_dispatch_cursor_read "$dispatch_id" 2>/dev/null || true)"
  if [ -f "$state_path" ]; then
    state_status="$(jq -r '.status // empty' "$state_path" 2>/dev/null || true)"
    state_seq="$(jq -r '.messageSeq // empty' "$state_path" 2>/dev/null || true)"
    if [ "$state_status" = outstanding ]; then
      if [[ "$cursor" =~ ^[0-9]+$ && "$state_seq" =~ ^[1-9][0-9]*$ ]] && [ "$cursor" -ge "$state_seq" ]; then
        rm -f "$state_path"
      elif megabrain_parent_notify_delivery_contains_seq "$dispatch_id" "$state_seq"; then
        rm -f "$state_path"
      else
        rmdir "$lock"
        return 1
      fi
    fi
  fi
  if [[ "$cursor" =~ ^[0-9]+$ && "$message_seq" =~ ^[1-9][0-9]*$ ]] && [ "$cursor" -ge "$message_seq" ]; then
    MEGABRAIN_PARENT_NOTIFY_NUDGE_REASON=message-seen
    rmdir "$lock"
    return 1
  fi
  if megabrain_parent_notify_delivery_contains_seq "$dispatch_id" "$message_seq"; then
    MEGABRAIN_PARENT_NOTIFY_NUDGE_REASON=message-delivered
    rmdir "$lock"
    return 1
  fi
  tmp="$(mktemp "$(dirname "$state_path")/.nudge-state.XXXXXX")" || {
    rmdir "$lock"
    return 1
  }
  if ! jq -n --argjson messageSeq "$message_seq" --arg now "$(megabrain_iso_now)" \
    '{messageSeq: $messageSeq, status: "outstanding", updatedAt: $now}' >"$tmp"; then
    rm -f "$tmp"
    rmdir "$lock"
    return 1
  fi
  if ! mv -f "$tmp" "$state_path"; then
    rm -f "$tmp"
    rmdir "$lock"
    return 1
  fi
  rmdir "$lock"
  return 0
}

megabrain_parent_notify_nudge_release() {
  local dispatch_id="$1" message_seq="$2" state_path="" lock="" state_seq=""
  state_path="$(megabrain_parent_notify_nudge_state_path "$dispatch_id")" || return 1
  lock="$(megabrain_parent_notify_nudge_state_lock_path "$dispatch_id")" || return 1
  while ! mkdir "$lock" 2>/dev/null; do sleep 0.02; done
  state_seq="$(jq -r '.messageSeq // empty' "$state_path" 2>/dev/null || true)"
  [ "$state_seq" = "$message_seq" ] && rm -f "$state_path"
  rmdir "$lock"
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
  wait "$tail_pid" 2>/dev/null || true
  rm -rf "$fifo_dir"
  return "$result"
}

megabrain_parent_notify_tmux() {
  local meta="$1" pointer="$2" pane
  pane="$(printf '%s' "$meta" | jq -r '.parentTmuxPane // empty')"
  [ -n "$pane" ] || return 1
  # Parent notification records that the pointer was typed and any unsubmitted
  # draft was cleared; the durable queue remains authoritative for the child.
  megabrain_tmux_send_nudge "$pane" "$pointer"
}

# WHY: .runtime says how the CHILD was launched. Reaching the PARENT is a property of
# the parent, and the two are independent: a dispatch started in an IDE tab can have a
# parent sitting in a tmux pane. The channel therefore follows the parent's own
# coordinates when they identify a live tmux pane, regardless of the child's runtime.
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
  local meta="$1" dispatch_id pointer notify_error notify_reason notify_error_path notify_status notify_outcome message_seq=""
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
  message_seq="$(megabrain_dispatch_last_child_mail_seq "$dispatch_id" 2>/dev/null || true)"
  if [ -n "$message_seq" ] && ! megabrain_parent_notify_nudge_claim "$dispatch_id" "$message_seq"; then
    MEGABRAIN_PARENT_NOTIFY_RESULT=suppressed
    megabrain_parent_notify_wake "$dispatch_id" "$pointer" suppressed \
      "${MEGABRAIN_PARENT_NOTIFY_NUDGE_REASON:-nudge-outstanding}" >/dev/null 2>&1 || true
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
    notify_outcome=delivered
    if [ "$(megabrain_parent_notify_channel "$meta")" = tmux ]; then
      # A successful tmux transport call can mean that no keys were typed. Keep
      # the transport's measured result instead of inferring delivery from rc=0.
      notify_outcome="${MEGABRAIN_TMUX_SEND_STATUS:-unknown}"
    fi
    MEGABRAIN_PARENT_NOTIFY_RESULT="$notify_outcome"
    if [ "$notify_outcome" = not-typed ] && [ -n "$message_seq" ]; then
      megabrain_parent_notify_nudge_release "$dispatch_id" "$message_seq" >/dev/null 2>&1 || true
    fi
    megabrain_parent_notify_wake "$dispatch_id" "$pointer" "$notify_outcome" parent-notified >/dev/null 2>&1 || true
    return 0
  fi
  MEGABRAIN_PARENT_NOTIFY_RESULT=failed
  [ -z "$message_seq" ] || megabrain_parent_notify_nudge_release "$dispatch_id" "$message_seq" >/dev/null 2>&1 || true
  notify_reason="$(printf '%s' "$notify_error" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
  [ -n "$notify_reason" ] || notify_reason=notify-failed
  megabrain_parent_notify_wake "$dispatch_id" "$pointer" failed "$notify_reason" >/dev/null 2>&1 || true
  return 1
}
