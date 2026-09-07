#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/devkit-notify-delivery.XXXXXX")"
socket_name="devkitnotify-$$"
parent_session="devkit-notify-parent-$$"
unknown_session="devkit-notify-unknown-$$"
failed_session="devkit-notify-failed-$$"
dedicated_session="devkit-notify-dedicated-$$"
parent_pane=""
parent_tmux=""

cleanup() {
  local rc=$?
  tmux -L "$socket_name" kill-server >/dev/null 2>&1 || true
  rm -rf "$state_dir"
  return "$rc"
}
trap cleanup EXIT

export DEVKIT_STATE_DIR="$state_dir"
export DEVKIT_PARENT_NOTIFY_SETTLE_MS=10
export ORCA_TERMINAL_HANDLE=parent-terminal
unset SUPERSET_TERMINAL_ID

source "$root/lib/common.sh"
source "$root/lib/module-tmux-runtime.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-parent-notify.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected '$1' to contain '$2'" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected '$1' not to contain '$2'" ;;
    *) ;;
  esac
}

tmux_cmd() {
  tmux -L "$socket_name" "$@"
}

create_meta() {
  local dispatch_id="$1" session="$2" pane="$3" parent_session_arg parent_pane_arg
  parent_session_arg="${4:-$session}"
  parent_pane_arg="${5:-$pane}"
  devkit_dispatch_meta_write "$dispatch_id" parent-terminal orca orca "" "$dispatch_id-terminal" \
    "$root" main codex label running gpt-5 true codex "$session" "$pane" tmux tmux \
    "$parent_session_arg" "$parent_pane_arg" "" >/dev/null
}

register_parent() {
  local session="$1" agent="$2"
  mkdir -p "$state_dir/sessions"
  jq -n --arg session "$session" --arg agent "$agent" --arg pane "$parent_pane" \
    '{tmuxSession: $session, agent: $agent, workingDirectory: "/tmp", tmuxPane: $pane, role: "main"}' \
    >"$state_dir/sessions/$session.json"
}

tmux_cmd new-session -d -s "$parent_session" "printf '%s' 'Working · esc to interrupt'; sleep 5"
parent_pane="$(tmux_cmd display-message -p -t "$parent_session" '#{pane_id}')"
parent_tmux="$(tmux_cmd display-message -p -t "$parent_pane" '#{socket_path},#{pid},#{session_id}')"
export TMUX="$parent_tmux" TMUX_PANE="$parent_pane"
register_parent "$parent_session" claude
create_meta queueing-parent "$parent_session" "$parent_pane"
queueing_meta="$(devkit_dispatch_meta_read queueing-parent)"
assert_equal "$(devkit_parent_notify_tmux_is_idle "$queueing_meta")" false
devkit_parent_notify_dispatch "$queueing_meta"
assert_equal "$DEVKIT_PARENT_NOTIFY_RESULT" delivered
queueing_capture="$(tmux_cmd capture-pane -p -t "$parent_pane" -S -20)"
assert_contains "$queueing_capture" '[devkit] mail available for dispatch queueing-parent'
assert_contains "$(cat "$state_dir/dispatches/queueing-parent/nudge.log")" 'outcome=delivered reason=queueing-parent'
assert_equal "$(wc -l <"$state_dir/dispatches/queueing-parent/nudge.log" | tr -d ' ')" 1
printf 'queueing parent receives a notice while busy\n'

tmux_cmd new-session -d -s "$unknown_session" "printf '%s' 'Working · esc to interrupt'; sleep 5"
unknown_pane="$(tmux_cmd display-message -p -t "$unknown_session" '#{pane_id}')"
create_meta unrecognised-parent "$unknown_session" "$unknown_pane"
unknown_meta="$(devkit_dispatch_meta_read unrecognised-parent)"
unknown_before="$(tmux_cmd capture-pane -p -t "$unknown_pane" -S -20)"
devkit_parent_notify_dispatch "$unknown_meta"
unknown_after="$(tmux_cmd capture-pane -p -t "$unknown_pane" -S -20)"
assert_equal "$DEVKIT_PARENT_NOTIFY_RESULT" busy
assert_equal "$unknown_before" "$unknown_after"
assert_contains "$(cat "$state_dir/dispatches/unrecognised-parent/nudge.log")" 'outcome=suppressed reason=parent-busy'
assert_equal "$(wc -l <"$state_dir/dispatches/unrecognised-parent/nudge.log" | tr -d ' ')" 1
printf 'unrecognised busy parent remains suppressed\n'

tmux_cmd new-session -d -s "$failed_session" "printf '%s' 'Working · esc to interrupt'; sleep 5"
failed_pane="$(tmux_cmd display-message -p -t "$failed_session" '#{pane_id}')"
register_parent "$failed_session" claude
create_meta failed-notice "$failed_session" "$failed_pane"
failed_meta="$(devkit_dispatch_meta_read failed-notice)"
devkit_parent_notify() {
  printf 'simulated send failure\n' >&2
  return 1
}
devkit_parent_notify_dispatch "$failed_meta" || true
assert_equal "$DEVKIT_PARENT_NOTIFY_RESULT" failed
failed_log="$(cat "$state_dir/dispatches/failed-notice/nudge.log")"
assert_contains "$failed_log" 'outcome=failed reason=simulated send failure'
assert_equal "$(printf '%s\n' "$failed_log" | wc -l | tr -d ' ')" 1
printf 'notify log records delivered, suppressed, and failed outcomes\n'

devkit_parent_notify_dispatch() {
  return 1
}
export ORCA_TERMINAL_HANDLE=child-terminal
unset TMUX TMUX_PANE
devkit_dispatch_meta_write queue-safety parent-terminal orca orca "" child-terminal "$root" main codex label running gpt-5 true codex "" "" host ide >/dev/null
if ! child_output="$(devkit_dispatch_child_message ask 'queue survives notify failure')"; then
  fail 'child message failed when notify failed'
fi
assert_contains "$child_output" 'ask sent: queue-safety'
queue_message="$(find "$state_dir/dispatches/queue-safety/messages" -name '*.json' -print -quit)"
assert_equal "$(jq -r '.text' "$queue_message")" 'queue survives notify failure'
printf 'queue remains the source of truth when notify fails\n'

export ORCA_TERMINAL_HANDLE=parent-terminal
tmux_cmd split-window -v -t "$parent_pane" -P -F '#{pane_id}' bash >/dev/null
shared_pane="$(tmux_cmd list-panes -t "$parent_session" -F '#{pane_id}' | tail -n 1)"
create_meta shared-close "$parent_session" "$shared_pane"
shared_close="$(devkit_dispatch_close shared-close --json)"
assert_equal "$(printf '%s' "$shared_close" | jq -r '.message')" \
  'tmux pane removed; the shared tmux session and host terminal tab were kept.'
printf 'shared close reports that session and host tab were kept\n'

tmux_cmd new-session -d -s "$dedicated_session" bash
dedicated_pane="$(tmux_cmd display-message -p -t "$dedicated_session" '#{pane_id}')"
create_meta exclusive-close "$dedicated_session" "$dedicated_pane" "$parent_session" "$parent_pane"
orca() {
  if [ "${1:-}" = terminal ] && [ "${2:-}" = close ]; then
    printf '{"ok":true}\n'
    return 0
  fi
  return 1
}
exclusive_close="$(devkit_dispatch_close exclusive-close --json)"
assert_equal "$(printf '%s' "$exclusive_close" | jq -r '.message')" \
  'last tmux pane removed; the exclusive tmux session and host terminal tab were closed.'
printf 'exclusive close reports that session and host tab were closed\n'

printf 'ok: notice delivery, outcome logging, queue safety, and close reporting\n'
