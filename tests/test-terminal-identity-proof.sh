#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-terminal-proof.XXXXXX")"
session_name="megabrain-terminal-proof-$$"
scenario="${TEST_SCENARIO:-all}"
child_pane=""
wrong_pane=""
empty_pane=""

cleanup() {
  tmux kill-session -t "$session_name" >/dev/null 2>&1 || true
  rm -rf "$state_dir"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

export MEGABRAIN_STATE_DIR="$state_dir/state"
unset TMUX TMUX_PANE SUPERSET_TERMINAL_ID ORCA_TERMINAL_HANDLE

source "$root/lib/common.sh"
source "$root/lib/module-tmux-runtime.sh"
source "$root/lib/module-context.sh"
source "$root/lib/module-orchestrate.sh"

create_dispatch() {
  local dispatch_id="$1" pane="$2"
  megabrain_dispatch_meta_write "$dispatch_id" parent-terminal tmux tmux workspace terminal \
    "$root" main codex label running gpt-5 true codex "$session_name" "$pane" tmux tmux >/dev/null
}

terminal_status() {
  local dispatch_id="$1"
  local meta
  meta="$(megabrain_dispatch_meta_read "$dispatch_id")"
  megabrain_dispatch_terminal_status "$meta"
  printf '%s\n' "$MEGABRAIN_TERMINAL_STATUS"
}

start_child_with_marker() {
  local pane="$1" dispatch_id="$2" pane_pid="" child_pid="" attempt
  pane_pid="$(tmux display-message -p -t "$pane" '#{pane_pid}')"
  tmux send-keys -t "$pane" -l \
    "export MEGABRAIN_DISPATCH_ID=$dispatch_id; (exec -a MEGABRAIN_DISPATCH_ID=$dispatch_id sleep 60)"
  tmux send-keys -t "$pane" Enter
  for ((attempt = 1; attempt <= 100; attempt++)); do
    child_pid="$(pgrep -P "$pane_pid" 2>/dev/null | head -n 1 || true)"
    [ -n "$child_pid" ] && return 0
    sleep 0.05
  done
  fail "timed out waiting for child process in pane $pane"
}

start_empty_child() {
  local pane="$1" pane_pid="" child_pid="" attempt
  pane_pid="$(tmux display-message -p -t "$pane" '#{pane_pid}')"
  tmux send-keys -t "$pane" -l '(sleep 60)'
  tmux send-keys -t "$pane" Enter
  for ((attempt = 1; attempt <= 100; attempt++)); do
    child_pid="$(pgrep -P "$pane_pid" 2>/dev/null | head -n 1 || true)"
    [ -n "$child_pid" ] && return 0
    sleep 0.05
  done
  fail "timed out waiting for child process in pane $pane"
}

tmux new-session -d -s "$session_name" bash
child_pane="$(tmux split-window -d -P -F '#{pane_id}' -t "$session_name" bash)"
wrong_pane="$(tmux split-window -d -P -F '#{pane_id}' -t "$session_name" bash)"
empty_pane="$(tmux split-window -d -P -F '#{pane_id}' -t "$session_name" bash)"

if [ "$scenario" = all ] || [ "$scenario" = child ]; then
  create_dispatch child-dispatch "$child_pane"
  start_child_with_marker "$child_pane" child-dispatch
  assert_equal "$(terminal_status child-dispatch)" proven
  printf 'a shell pane proves identity from its child agent process\n'
fi

if [ "$scenario" = all ] || [ "$scenario" = different ]; then
  create_dispatch wrong-dispatch "$wrong_pane"
  start_child_with_marker "$wrong_pane" another-dispatch
  assert_equal "$(terminal_status wrong-dispatch)" unknown
  printf 'a child carrying another dispatch id does not prove identity\n'
fi

if [ "$scenario" = all ] || [ "$scenario" = absent ]; then
  create_dispatch empty-dispatch "$empty_pane"
  start_empty_child "$empty_pane"
  assert_equal "$(terminal_status empty-dispatch)" unknown
  printf 'a process tree without the dispatch id remains unproven\n'
fi

printf 'ok: terminal identity proof follows the pane process tree\n'
