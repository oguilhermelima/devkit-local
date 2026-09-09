#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-panes.XXXXXX")"
# Resolved, because /var is a symlink to /private/var on macOS and the guard below
# compares this against the path tmux reports.
state_dir="$(cd -P "$state_dir" && pwd -P)"
# Short on purpose: TMUX_TMPDIR sits under a long mktemp path and the socket path has
# to stay inside the 104-byte Unix socket limit.
socket_name=mbpane
session_name=megabrain-pane-mechanics

# WHY this is unset before anything else: tmux resolves its server from $TMUX first and
# only falls back to TMUX_TMPDIR, so a test that runs inside the operator's tmux would
# otherwise reach the operator's server. An earlier version of this file did exactly
# that and its cleanup killed the operator's session.
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$state_dir"
export MEGABRAIN_STATE_DIR="$state_dir/state"

tmux_cmd() {
  tmux -L "$socket_name" "$@"
}

cleanup() {
  tmux -L "$socket_name" kill-server >/dev/null 2>&1 || true
  rm -rf "$state_dir"
  return 0
}
trap cleanup EXIT

source "$root/lib/common.sh"
source "$root/lib/module-tmux-runtime.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected output not to contain '$2'" ;;
    *) ;;
  esac
}

wait_for_pane_count() {
  local session="$1" expected="$2" attempt=0 actual
  while [ "$attempt" -lt 200 ]; do
    actual="$(tmux_cmd list-panes -t "$session" -F '#{pane_id}' | wc -l | tr -d ' ')"
    [ "$actual" -eq "$expected" ] && return 0
    sleep 0.05
    attempt=$((attempt + 1))
  done
  fail "timed out waiting for $expected panes in $session (got $actual)"
}

wait_for_pane_text() {
  local pane="$1" expected="$2" attempt=0 capture=""
  while [ "$attempt" -lt 200 ]; do
    capture="$(tmux_cmd capture-pane -p -J -t "$pane" -S -20)"
    case "$capture" in
      *"$expected"*) return 0 ;;
    esac
    sleep 0.05
    attempt=$((attempt + 1))
  done
  fail "timed out waiting for '$expected' in pane $pane"
}

tmux_cmd new-session -d -s "$session_name" -x 120 -y 30 bash
wait_for_pane_count "$session_name" 1
session_info="$(tmux_cmd display-message -p -t "$session_name" '#{socket_path},#{pid},#{session_id}')"

# The library calls bare tmux, so it has to be pointed at this test's server. Refuse to
# continue unless that server really lives under the temporary directory, because every
# destructive step below runs against whatever this resolves to.
case "${session_info%%,*}" in
  "$state_dir"/*) ;;
  *) fail "refusing to run: the tmux server is at ${session_info%%,*}, outside $state_dir" ;;
esac
export TMUX="$session_info"

# A child pane must not take the focus. The operator keeps typing into their own pane
# while a child is launched, and a stolen focus sends those keystrokes into the child.
operator_pane="$(tmux_cmd display-message -p -t "$session_name" '#{pane_id}')"
assert_equal "$(tmux_cmd list-panes -t "$session_name" -F '#{pane_id}' | wc -l | tr -d ' ')" 1

child_pane="$(megabrain_tmux_split_pane "$session_name" "$root")"
[ -n "$child_pane" ] || fail 'split produced no pane'
wait_for_pane_count "$session_name" 2

assert_equal "$(tmux_cmd list-panes -t "$session_name" -F '#{pane_id}' | wc -l | tr -d ' ')" 2
[ "$child_pane" != "$operator_pane" ] || fail 'split returned the operator pane'
assert_equal "$(tmux_cmd display-message -p -t "$session_name" '#{pane_id}')" "$operator_pane"
printf 'split: a child pane is created and the operator keeps the focus\n'

# The launch command must reach the child shell on an empty line. A pane that already
# holds a stray keystroke once turned "cd /path" into "mocd /path", and the agent never
# started. The stray text below is that exact shape.
export MEGABRAIN_TMUX_ENTER_TIMEOUT_SECONDS=6
export MEGABRAIN_TMUX_ENTER_WAIT=0.3
tmux_cmd send-keys -t "$child_pane" -l 'mo'
wait_for_pane_text "$child_pane" mo

if ! megabrain_tmux_send_agent "$child_pane" 'sleep 30'; then
  fail 'the launch command was never submitted from a pane holding a stray keystroke'
fi

# WHY the wait: send_agent returns once tmux accepted the keys, not once the shell has
# execed the command, so reading the pane straight away catches zsh about one run in three.
waited=0
while [ "$(tmux_cmd display-message -p -t "$child_pane" '#{pane_current_command}')" != sleep ] &&
  [ "$waited" -lt 200 ]; do
  sleep 0.05
  waited=$((waited + 1))
done
assert_equal "$(tmux_cmd display-message -p -t "$child_pane" '#{pane_current_command}')" sleep
child_screen="$(tmux_cmd capture-pane -p -J -t "$child_pane" -S -20)"
assert_not_contains "$child_screen" 'command not found'
assert_not_contains "$child_screen" 'mosleep'
printf 'launch: a stray keystroke is cleared and the command runs unmangled\n'

# WHY sourcing only common.sh: it is the one file every entry point loads, and the tmux
# identity is resolved there. While the helper it needs lived in another module, a caller
# that loaded just this file got host unknown instead of tmux, with nothing to notice.
identity="$(env -u SUPERSET_TERMINAL_ID -u ORCA_TERMINAL_HANDLE \
  TMUX="$session_info" TMUX_PANE="$operator_pane" \
  bash -c 'source "$1/lib/common.sh"; megabrain_session_id >/dev/null; printf "%s %s" "$MEGABRAIN_SESSION_HOST" "$MEGABRAIN_SESSION_ID"' _ "$root")"
assert_equal "$identity" "tmux $session_name:$operator_pane"
printf 'identity: common.sh alone resolves the pane to a tmux host\n'

trap - EXIT
cleanup
printf 'ok: child pane focus and launch line hygiene\n'
