#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-terminal.XXXXXX")"
fake_port_state="$state_dir/fake-port-state"
fake_port_probe_file="$state_dir/fake-port-probes"
fake_port_ready_file="$state_dir/fake-port-ready"
fake_tree_state="$state_dir/fake-tree-state"
fake_host_live=true
fake_port_listening=true
fake_port_stuck=false
fake_port_probe_count=0
fake_port_ready_after=0

printf 'listening\n' >"$fake_port_state"
printf '0\n' >"$fake_port_probe_file"
printf '0\n' >"$fake_port_ready_file"
printf 'alive\n' >"$fake_tree_state"

fake_port_set_listening() {
  printf '%s\n' "$1" >"$fake_port_state"
}
fake_id=terminal-one
fake_pid=100
fake_port=8082
fake_title='DEV web'
fake_killed=''
fake_old_tree_gone=false

cleanup() {
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

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected '$1' to contain '$2'" ;;
  esac
}

assert_json_true() {
  printf '%s' "$1" | jq -e "$2" >/dev/null || fail "JSON assertion failed: $2\n$1"
}

export MEGABRAIN_STATE_DIR="$state_dir"
export SUPERSET_TERMINAL_ID=parent-terminal
unset ORCA_TERMINAL_HANDLE TMUX TMUX_PANE

source "$root/lib/common.sh"
source "$root/lib/module-context.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-worktree.sh"

megabrain_superset_available() { return 0; }
megabrain_workspace_id_for_target() { printf 'workspace-test\n'; }

megabrain_superset() {
  case "${1:-}:${2:-}" in
    terminals:create)
      if [ "$(cat "$fake_port_state")" = free ] && [ "$fake_port_stuck" = false ]; then
        printf '0\n' >"$fake_port_probe_file"
        printf '12\n' >"$fake_port_ready_file"
      fi
      printf '{"terminalId":"%s","pid":%s,"port":%s}\n' "$fake_id" "$fake_pid" "$fake_port"
      ;;
    terminals:list)
      if [ "$fake_host_live" = true ]; then
        printf '{"terminals":[{"terminalId":"%s","pid":%s,"port":%s}]}\n' "$fake_id" "$fake_pid" "$fake_port"
      else
        printf '{"terminals":[]}\n'
      fi
      ;;
    *) return 1 ;;
  esac
}

# The process commands are fake fixtures. The child is the listener and the parent is
# the process megabrain recorded when it created the terminal. A naive listener-only kill
# makes the child respawn; killing the recorded root removes the old tree.
lsof() {
  if [ "$(cat "$fake_port_state")" = free ] && [ "$fake_port_stuck" = false ] && [ "$(cat "$fake_port_ready_file")" -gt 0 ]; then
    fake_port_probe_count="$(cat "$fake_port_probe_file")"
    fake_port_probe_count=$((fake_port_probe_count + 1))
    printf '%s\n' "$fake_port_probe_count" >"$fake_port_probe_file"
    if [ "$fake_port_probe_count" -ge "$(cat "$fake_port_ready_file")" ]; then
      fake_port_set_listening listening
    fi
  fi
  if [ "$(cat "$fake_port_state")" = listening ]; then
    printf '101\n'
  fi
}

ps() {
  if [ "${1:-}" = -o ] && [ "${2:-}" = ppid= ]; then
    case "${4:-}" in
      100) printf '1\n' ;;
      101) printf '100\n' ;;
      *) printf '1\n' ;;
    esac
  fi
}

pgrep() {
  if [ "${1:-}" = -P ]; then
    case "${2:-}" in
      100) printf '101\n' ;;
      *) ;;
    esac
  fi
}

kill() {
  local signal pid
  signal="$1"
  pid="$2"
  fake_killed="$fake_killed $pid"
  if [ "$pid" = 100 ]; then
    printf 'gone\n' >"$fake_tree_state"
    if [ "$fake_port_stuck" = false ]; then
      fake_port_set_listening free
    fi
  elif [ "$pid" = 101 ] && [ "$(cat "$fake_tree_state")" = alive ]; then
    fail 'listener-only kill respawned the old process tree'
  fi
  return 0
}

scenario_create_json_preserves_identity() {
  local output record dispatch_id
  fake_id=terminal-create
  fake_pid=100
  fake_port=8082
  output="$(command_terminal create --worktree "$root" --command 'run server' --title "$fake_title" --json)"
  assert_json_true "$output" '.terminalId == "terminal-create" and .pid == 100 and .port == 8082'
  record="$MEGABRAIN_TERMINAL_DIR/terminal-create.json"
  [ -f "$record" ] || fail 'create did not persist a terminal record'
  dispatch_id=identity-dispatch
  megabrain_dispatch_meta_write "$dispatch_id" parent-terminal superset superset workspace-test \
    "$(jq -r '.terminalId' <<<"$output")" "$root" main codex label running gpt-5 true codex '' '' host ide >/dev/null
  assert_equal "$(jq -r '.terminalId' "$MEGABRAIN_DISPATCH_DIR/$dispatch_id/meta.json")" terminal-create
  printf 'create --json returns the identity used by dispatch metadata\n'
}

scenario_list_keeps_stale() {
  local output
  fake_host_live=false
  output="$(command_terminal list --json)"
  assert_json_true "$output" 'length == 1 and .[0].terminalId == "terminal-create" and .[0].status == "stale"'
  fake_host_live=true
  printf 'list retains a terminal missing from the host as stale\n'
}

scenario_restart_selectors() {
  local output failure_output
  fake_host_live=true
  fake_port_set_listening listening
  fake_port_stuck=false
  fake_id=terminal-create
  fake_pid=100
  fake_port=8082
  output="$(command_terminal restart id:terminal-create --timeout 0 --json)"
  assert_json_true "$output" '.selector == "id:terminal-create" and .killedPid == 100 and .recreated == true'

  fake_id=terminal-title
  fake_pid=100
  fake_port=8083
  fake_title='DEV title'
  command_terminal create --worktree "$root" --command 'run title' --title "$fake_title" --json >/dev/null
  fake_port_set_listening listening
  output="$(command_terminal restart "title:$fake_title" --timeout 0 --json)"
  assert_json_true "$output" '.selector == "title:DEV title" and .recreated == true'

  fake_id=terminal-port
  fake_pid=100
  fake_port=8084
  command_terminal create --worktree "$root" --command 'run port' --title 'DEV port' --json >/dev/null
  fake_port_set_listening listening
  output="$(command_terminal restart port:8084 --timeout 0 --json)"
  assert_json_true "$output" '.selector == "port:8084" and .recreated == true'

  fake_id=terminal-worktree
  fake_pid=100
  fake_port=8085
  command_terminal create --worktree "$root" --command 'run worktree' --title 'DEV worktree' --json >/dev/null
  fake_port_set_listening listening
  output="$(command_terminal restart "worktree:$root" --timeout 0 --json)"
  assert_equal "$(jq -r '.selector' <<<"$output")" "worktree:$root"
  assert_json_true "$output" '.recreated == true'

  if failure_output="$(command_terminal restart id:missing --timeout 0 2>&1)"; then
    fail 'unresolvable selector unexpectedly succeeded'
  fi
  assert_contains "$failure_output" 'terminal selector could not be resolved'
  printf 'restart resolves id, title, port and worktree selectors independently\n'
}

scenario_restart_safety_and_wait() {
  local output failure_output
  fake_id=terminal-tree
  fake_pid=100
  fake_port=8090
  fake_port_set_listening listening
  fake_port_stuck=false
  printf 'alive\n' >"$fake_tree_state"
  fake_port_set_listening listening
  printf '0\n' >"$fake_port_ready_file"
  printf '0\n' >"$fake_port_probe_file"
  fake_port_ready_after=0
  fake_port_probe_count=0
  command_terminal create --worktree "$root" --command 'run tree' --title 'DEV tree' --json >/dev/null
  fake_port_set_listening listening
  output="$(command_terminal restart id:terminal-tree --wait-port 8090 --timeout 2 --json)"
  assert_json_true "$output" '.recreated == true and .port == 8090 and .listeningAfterMs >= 0'
  assert_json_true "$output" '.listeningAfterMs >= 1000'
  [ "$(cat "$fake_tree_state")" = gone ] || fail 'restart did not kill the recorded process root'

  fake_id=terminal-timeout
  fake_pid=100
  fake_port=8091
  fake_port_stuck=true
  fake_port_set_listening listening
  command_terminal create --worktree "$root" --command 'run timeout' --title 'DEV timeout' --json >/dev/null
  if failure_output="$(command_terminal restart id:terminal-timeout --timeout 0 2>&1)"; then
    fail 'port-free timeout unexpectedly succeeded'
  fi
  assert_contains "$failure_output" 'timed out waiting for port 8091 to become free'

  fake_port_stuck=false
  fake_port_set_listening free
  printf '0\n' >"$fake_port_ready_file"
  if failure_output="$(command_terminal restart port:8091 --timeout 0 2>&1)"; then
    fail 'a non-listening port unexpectedly resolved'
  fi
  assert_contains "$failure_output" 'port 8091 is not listening'
  printf 'restart kills the recorded root, waits for free ports, and distinguishes timeout\n'
}

case "${SCENARIO:-all}" in
  1) scenario_create_json_preserves_identity ;;
  2) scenario_list_keeps_stale ;;
  3) scenario_restart_selectors ;;
  4) scenario_restart_safety_and_wait ;;
  all)
    scenario_create_json_preserves_identity
    scenario_list_keeps_stale
    scenario_restart_selectors
    scenario_restart_safety_and_wait
    printf 'ok: terminal identity, listing, selector resolution, safe tree restart, and port waits\n'
    ;;
  *) fail "unknown scenario: $SCENARIO" ;;
esac
