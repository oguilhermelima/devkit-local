#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/devkit-close-safety.XXXXXX")"
socket_name="devkitclose-$$"
session_name="devkit-close-parent-$$"
dedicated_session_name="devkit-close-dedicated-$$"
parent_pane=""
parent_tmux=""
close_log="$state_dir/host-close.log"

cleanup() {
  local rc=$?
  tmux -L "$socket_name" kill-server >/dev/null 2>&1 || true
  rm -rf "$state_dir"
  return "$rc"
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir"

source "$root/lib/common.sh"
source "$root/lib/module-tmux-runtime.sh"
source "$root/lib/module-orchestrate.sh"

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

assert_failure_contains() {
  local expected="$1" output
  shift
  if output="$("$@" 2>&1)"; then
    fail "expected command to fail: $*"
  fi
  printf '%s\n' "$output"
  assert_contains "$output" "$expected"
}

tmux_cmd() {
  tmux -L "$socket_name" "$@"
}

orca() {
  if [ "${1:-}" = terminal ] && [ "${2:-}" = close ]; then
    printf 'close:%s\n' "${4:-}" >>"$close_log"
    printf '{"ok":true}\n'
    return 0
  fi
  return 1
}

create_meta() {
  local dispatch_id="$1" tmux_session="$2" tmux_pane="$3" parent_session="$4" parent_pane="$5"
  devkit_dispatch_meta_write "$dispatch_id" parent-terminal orca orca workspace-test "$dispatch_id-terminal" \
    "$root" fix/close-never-kills-caller codex label running gpt-5 true codex \
    "$tmux_session" "$tmux_pane" tmux tmux "$parent_session" "$parent_pane" workspace-test >/dev/null
}

assert_pane_alive() {
  tmux_cmd display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1 || fail "pane is not alive: $1"
}

assert_session_alive() {
  tmux_cmd has-session -t "$1" >/dev/null 2>&1 || fail "session is not alive: $1"
}

tmux_cmd new-session -d -s "$session_name" bash
parent_pane="$(tmux_cmd display-message -p -t "$session_name" '#{pane_id}')"
parent_tmux="$(tmux_cmd display-message -p -t "$parent_pane" '#{socket_path},#{pid},#{session_id}')"
export TMUX="$parent_tmux" TMUX_PANE="$parent_pane" ORCA_TERMINAL_HANDLE=parent-terminal
unset SUPERSET_TERMINAL_ID

create_meta self-close "$session_name" "$parent_pane" "$session_name" "$parent_pane"
assert_failure_contains 'refusing to close dispatch self-close' devkit_dispatch_close self-close --json
assert_pane_alive "$parent_pane"
assert_session_alive "$session_name"
printf 'caller pane is protected from normal close\n'

create_meta force-self-close "$session_name" "$parent_pane" "$session_name" "$parent_pane"
devkit_dispatch_meta_update_terminal_state force-self-close retained
assert_failure_contains 'refusing to close dispatch force-self-close' devkit_dispatch_close force-self-close --force-release --json
assert_pane_alive "$parent_pane"
assert_session_alive "$session_name"
printf 'caller pane protection cannot be bypassed by force-release\n'

shared_pane="$(tmux_cmd split-window -v -t "$parent_pane" -P -F '#{pane_id}' bash)"
create_meta shared-child "$session_name" "$shared_pane" "$session_name" "$parent_pane"
before_panes="$(tmux_cmd list-panes -t "$session_name" | wc -l | tr -d ' ')"
devkit_dispatch_close shared-child --json >/dev/null
after_panes="$(tmux_cmd list-panes -t "$session_name" | wc -l | tr -d ' ')"
assert_equal "$before_panes" 2
assert_equal "$after_panes" 1
assert_pane_alive "$parent_pane"
assert_session_alive "$session_name"
[ ! -s "$close_log" ] || fail 'shared close attempted to close the host terminal'
assert_equal "$(jq -r '.state' "$state_dir/dispatches/shared-child/meta.json")" closed
printf 'shared-session child close removes only the child pane\n'

tmux_cmd new-session -d -s "$dedicated_session_name" bash
dedicated_pane="$(tmux_cmd display-message -p -t "$dedicated_session_name" '#{pane_id}')"
create_meta dedicated-child "$dedicated_session_name" "$dedicated_pane" "$session_name" "$parent_pane"
devkit_dispatch_close dedicated-child --json >/dev/null
if tmux_cmd has-session -t "$dedicated_session_name" >/dev/null 2>&1; then
  fail 'dedicated dispatch session is still alive'
fi
assert_pane_alive "$parent_pane"
assert_session_alive "$session_name"
assert_contains "$(cat "$close_log")" 'close:dedicated-child-terminal'
assert_equal "$(jq -r '.state' "$state_dir/dispatches/dedicated-child/meta.json")" closed
printf 'dedicated-session child close still closes its host terminal\n'

printf 'ok: close self-protection and shared-session safety\n'
