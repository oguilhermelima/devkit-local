#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-runtime.XXXXXX")"
before_worktrees="$(git -C "$root" worktree list --porcelain)"
spawn_gate_passed=false

cleanup() {
  local rc=$?
  rm -rf "$state_dir"
  [ "$spawn_gate_passed" = true ] || return 1
  return "$rc"
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir"
source "$root/lib/common.sh"
source "$root/lib/module-context.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-tmux-runtime.sh"
source "$root/lib/module-worktree.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "expected command to fail: $*"
  fi
}

assert_no_creation() {
  local before_files after_files after_worktrees
  before_files="$(find "$state_dir" -type f -print 2>/dev/null | sort)"
  after_files="$(find "$state_dir" -type f -print 2>/dev/null | sort)"
  assert_equal "$after_files" "$before_files"
  after_worktrees="$(git -C "$root" worktree list --porcelain)"
  assert_equal "$after_worktrees" "$before_worktrees"
}

write_state() {
  mkdir -p "$state_dir"
  jq -n --argjson installed "$1" '{"tmux-runtime": {installed: $installed}}' >"$MEGABRAIN_STATE_FILE"
}

megabrain_tmux_available() {
  [ "${TEST_TMUX_AVAILABLE:-true}" = true ]
}

assert_runtime() {
  local expected="$1" requested="$2"
  megabrain_resolve_spawn_runtime "$requested"
  assert_equal "$MEGABRAIN_SPAWN_RUNTIME" "$expected"
}

export SUPERSET_TERMINAL_ID=parent-terminal
unset ORCA_TERMINAL_HANDLE
write_state true
assert_runtime tmux auto
printf 'enabled/no flag -> resolved runtime: tmux\n'
assert_runtime host false
printf 'enabled/--tmux false -> resolved runtime: ide\n'

write_state false
assert_runtime host auto
printf 'disabled/no flag -> resolved runtime: ide\n'
assert_runtime tmux true
printf 'disabled/--tmux true -> resolved runtime: tmux\n'

TEST_TMUX_AVAILABLE=false
before_files="$(find "$state_dir" -type f -print 2>/dev/null | sort)"
before_worktrees="$(git -C "$root" worktree list --porcelain)"
assert_failure megabrain_resolve_spawn_runtime true
after_files="$(find "$state_dir" -type f -print 2>/dev/null | sort)"
assert_equal "$after_files" "$before_files"
after_worktrees="$(git -C "$root" worktree list --porcelain)"
assert_equal "$after_worktrees" "$before_worktrees"
printf -- '--tmux true without tmux -> clear failure, nothing created\n'

unset SUPERSET_TERMINAL_ID
unset ORCA_TERMINAL_HANDLE
TEST_TMUX_AVAILABLE=true
before_files="$(find "$state_dir" -type f -print 2>/dev/null | sort)"
before_worktrees="$(git -C "$root" worktree list --porcelain)"
assert_failure megabrain_resolve_spawn_runtime false
after_files="$(find "$state_dir" -type f -print 2>/dev/null | sort)"
assert_equal "$after_files" "$before_files"
after_worktrees="$(git -C "$root" worktree list --porcelain)"
assert_equal "$after_worktrees" "$before_worktrees"
printf 'IDE from unmanaged shell -> clear failure, nothing created\n'

write_state true
export TMUX=tmux-parent-server
export TMUX_PANE=%1
megabrain_dispatch_tmux_caller_session() {
  printf 'tmux-parent\n'
}
assert_runtime tmux auto
assert_equal "$MEGABRAIN_SPAWN_CONTEXT" tmux
printf 'tmux runtime from an unmanaged pane -> resolved runtime: tmux\n'
unset TMUX TMUX_PANE

export SUPERSET_TERMINAL_ID=parent-terminal
spawn_agent_arg_count=0
megabrain_workspace_id_for_target() {
  printf 'workspace-test\n'
}
megabrain_launch_agent() {
  spawn_agent_arg_count="$#"
  MEGABRAIN_LAST_DISPATCH=spawn-no-agent-arg
  MEGABRAIN_LAST_SPAWN_RUNTIME=host
}
megabrain_worktree_create --worktree "$root" --agent codex --model gpt-5 --effort medium \
  --prompt spawn-without-agent-arg --tmux false --orchestrate --json >/dev/null
assert_equal "$spawn_agent_arg_count" 7
spawn_gate_passed=true
printf 'spawn without --agent-arg -> empty optional array accepted\n'

# WHY: the runtime is decided by reading one flag out of the state file. An unreadable
# state file made that read fail like an unset flag, so every spawn silently dropped from
# a tmux pane to an IDE tab and the only thing the operator saw was doctor blaming the
# module for being disabled. A file that cannot be parsed has to say so.
broken_state="$state_dir/broken-state"
mkdir -p "$broken_state"
printf '%s\n' '{"tmux-runtime": {"installed": true} THIS IS NOT JSON' >"$broken_state/state.json"

runtime_stderr="$(MEGABRAIN_STATE_DIR="$broken_state" MEGABRAIN_STATE_FILE="$broken_state/state.json" \
  bash -c 'source "$1/lib/common.sh"; megabrain_runtime_enabled; printf ""' _ "$root" 2>&1 >/dev/null)"
case "$runtime_stderr" in
  *'not valid JSON'*) ;;
  *) fail "an unreadable state file changed the runtime without saying so: '$runtime_stderr'" ;;
esac
printf 'an unreadable state file is reported instead of read as a disabled flag\n'

printf 'ok: spawn runtime resolution truth table\n'
