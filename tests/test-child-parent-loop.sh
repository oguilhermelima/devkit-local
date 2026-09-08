#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir=""
socket_name=devkitloop
session_name=""
parent_pane=""
parent_tmux=""
child_pane=""
child_session=""
fake_send_mode=ok
fake_close=false

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_not_equal() {
  [ "$1" != "$2" ] || fail "expected values to differ, both were '$1'"
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

set_state_dir() {
  state_dir="$1"
  MEGABRAIN_STATE_DIR="$state_dir"
  MEGABRAIN_STATE_FILE="$state_dir/state.json"
  MEGABRAIN_CHAIN_FILE="$state_dir/chains.json"
  MEGABRAIN_DISPATCH_DIR="$state_dir/dispatches"
  MEGABRAIN_TMUX_SESSION_DIR="$state_dir/sessions"
  mkdir -p "$state_dir"
  jq -n '{chains:{loop:{when:{parentAgent:"codex"},steps:[{agent:"codex",model:"test-model",effort:"low"}]}},defaultSteps:[]}' >"$MEGABRAIN_CHAIN_FILE"
}

fake_codex() {
  :
}

orca() {
  local command_text="" session
  if [ "${1:-}" = terminal ] && [ "${2:-}" = create ]; then
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --command ]; then
        command_text="${2:-}"
        shift 2
      else
        shift
      fi
    done
    session="${command_text##* -s }"
    tmux_cmd new-session -d -s "$session" "$(megabrain_agent_command)"
    printf '{"result":{"terminal":{"handle":"child-terminal"}}}\n'
  elif [ "${1:-}" = terminal ] && [ "${2:-}" = close ]; then
    fake_close=true
    printf '{"ok":true}\n'
  else
    return 1
  fi
}

source "$root/lib/common.sh"
source "$root/lib/module-context.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-parent-notify.sh"
source "$root/lib/module-tmux-runtime.sh"
source "$root/lib/module-worktree.sh"
source "$root/lib/module-chain.sh"

megabrain_context_detect() {
  printf '%s\n' "$MEGABRAIN_TEST_CONTEXT"
}

megabrain_workspace_id_for_target() {
  printf 'workspace-test\n'
}

megabrain_agent_command() {
  printf '%s\n' "awk 'BEGIN { print \"READY\"; print \"CHILD$\"; fflush() } { print \"agent-response:\" \$0; print \"CHILD$\"; fflush() }'"
}

megabrain_superset_available() {
  return 0
}

megabrain_superset() {
  if [ "${1:-}" = terminals ] && [ "${2:-}" = create ]; then
    printf '{"terminalId":"child-terminal"}\n'
  elif [ "${1:-}" = terminals ] && [ "${2:-}" = read ]; then
    printf '{"text":"READY"}\n'
  elif [ "${1:-}" = terminals ] && [ "${2:-}" = send ]; then
    [ "$fake_send_mode" = fail ] && return 1
    printf '%s\n' "${8:-}" >>"$state_dir/fake-sends.log"
    printf '{"ok":true}\n'
  elif [ "${1:-}" = terminals ] && [ "${2:-}" = close ]; then
    fake_close=true
    printf '{"ok":true}\n'
  else
    return 1
  fi
}

megabrain_tmux_available() {
  return 0
}

megabrain_dispatch_wait_for_prompt_receipt() {
  return 0
}

prepare_tmux_parent() {
  session_name="devkit-loop-parent-$$"
  tmux_cmd new-session -d -s "$session_name" bash
  parent_pane="$(tmux_cmd display-message -p -t "$session_name" '#{pane_id}')"
  parent_tmux="$(tmux_cmd display-message -p -t "$parent_pane" '#{socket_path},#{pid},#{session_id}')"
  tmux_cmd set-environment -t "$session_name" MEGABRAIN_STATE_DIR "$state_dir"
  export TMUX="$parent_tmux" TMUX_PANE="$parent_pane"
  tmux_cmd send-keys -t "$parent_pane" -l "PS1='PARENT$ '; export PS1; printf 'parent-ready\\n'"
  tmux_cmd send-keys -t "$parent_pane" Enter
  sleep 0.1
}

assert_claude_idle_fixtures() {
  local fixture_session fixture_pane fixture_meta
  fixture_session="devkit-loop-claude-$$"
  tmux_cmd new-session -d -s "$fixture_session" "printf '%s' '  ⏵⏵ bypass permissions on · 1 shell · ← for agents'; sleep 2"
  fixture_pane="$(tmux_cmd display-message -p -t "$fixture_session" '#{pane_id}')"
  fixture_meta="$(jq -cn --arg session "$fixture_session" --arg pane "$fixture_pane" '{parentTmuxSession:$session,parentTmuxPane:$pane}')"
  assert_equal "$(megabrain_parent_notify_tmux_is_idle "$fixture_meta")" true
  tmux_cmd kill-session -t "$fixture_session"
  tmux_cmd new-session -d -s "$fixture_session" "printf '%s' '  ✳ Working · esc to interrupt'; sleep 2"
  fixture_pane="$(tmux_cmd display-message -p -t "$fixture_session" '#{pane_id}')"
  fixture_meta="$(jq -cn --arg session "$fixture_session" --arg pane "$fixture_pane" '{parentTmuxSession:$session,parentTmuxPane:$pane}')"
  assert_equal "$(megabrain_parent_notify_tmux_is_idle "$fixture_meta")" false
  tmux_cmd kill-session -t "$fixture_session"
  tmux_cmd new-session -d -s "$fixture_session" "printf '%s' '  unknown pane'; sleep 2"
  fixture_pane="$(tmux_cmd display-message -p -t "$fixture_session" '#{pane_id}')"
  fixture_meta="$(jq -cn --arg session "$fixture_session" --arg pane "$fixture_pane" '{parentTmuxSession:$session,parentTmuxPane:$pane}')"
  assert_equal "$(megabrain_parent_notify_tmux_is_idle "$fixture_meta")" unknown
  tmux_cmd kill-session -t "$fixture_session"
}

child_command() {
  local verb="$1" text="${2:-}"
  if [ "$MEGABRAIN_TEST_RUNTIME" = tmux ]; then
    if [ "$verb" = received ]; then
      env -u SUPERSET_TERMINAL_ID MEGABRAIN_STATE_DIR="$state_dir" ORCA_TERMINAL_HANDLE=parent-terminal TMUX="$child_tmux" TMUX_PANE="$child_pane" "$root/devkit" "$verb"
    else
      env -u SUPERSET_TERMINAL_ID MEGABRAIN_STATE_DIR="$state_dir" ORCA_TERMINAL_HANDLE=parent-terminal TMUX="$child_tmux" TMUX_PANE="$child_pane" "$root/devkit" "$verb" "$text"
    fi
  else
    if [ "$verb" = received ]; then
      env -u TMUX -u TMUX_PANE MEGABRAIN_STATE_DIR="$state_dir" SUPERSET_TERMINAL_ID=child-terminal "$root/devkit" "$verb"
    else
      env -u TMUX -u TMUX_PANE MEGABRAIN_STATE_DIR="$state_dir" SUPERSET_TERMINAL_ID=child-terminal "$root/devkit" "$verb" "$text"
    fi
  fi
}

child_check() {
  if [ "$MEGABRAIN_TEST_RUNTIME" = tmux ]; then
    env -u SUPERSET_TERMINAL_ID MEGABRAIN_STATE_DIR="$state_dir" ORCA_TERMINAL_HANDLE=parent-terminal TMUX="$child_tmux" TMUX_PANE="$child_pane" "$root/devkit" check --timeout 0 --json
  else
    env -u TMUX -u TMUX_PANE MEGABRAIN_STATE_DIR="$state_dir" SUPERSET_TERMINAL_ID=child-terminal "$root/devkit" check --timeout 0 --json
  fi
}

child_ack() {
  if [ "$MEGABRAIN_TEST_RUNTIME" = tmux ]; then
    env -u SUPERSET_TERMINAL_ID MEGABRAIN_STATE_DIR="$state_dir" ORCA_TERMINAL_HANDLE=parent-terminal TMUX="$child_tmux" TMUX_PANE="$child_pane" "$root/devkit" ack "$1" --json
  else
    env -u TMUX -u TMUX_PANE MEGABRAIN_STATE_DIR="$state_dir" SUPERSET_TERMINAL_ID=child-terminal "$root/devkit" ack "$1" --json
  fi
}

parent_watch() {
  megabrain_dispatch_watch "$dispatch_id" --timeout 0 --poll-interval 0 --wait-mode poll --json
}

parent_ack() {
  megabrain_dispatch_ack "$dispatch_id" "$1" --json
}

run_flow() {
  local runtime="$1" chain_output dispatch_meta dispatch_id delivery replay delivery_id reply_result push_check push_ack
  local question_delivery question_delivery_id pull_result pull_delivery_id done_delivery done_delivery_id
  local busy_pane busy_before busy_after
  MEGABRAIN_TEST_RUNTIME="$runtime"
  fake_send_mode=ok
  fake_close=false
  set_state_dir "$(mktemp -d "${TMPDIR:-/tmp}/devkit-loop-$runtime.XXXXXX")"
  export MEGABRAIN_TEST_CONTEXT
  if [ "$runtime" = tmux ]; then
    MEGABRAIN_TEST_CONTEXT=orca
    export ORCA_TERMINAL_HANDLE=parent-terminal
    unset SUPERSET_TERMINAL_ID
    prepare_tmux_parent
    assert_claude_idle_fixtures
    spawn_choice=true
  else
    MEGABRAIN_TEST_CONTEXT=superset
    export SUPERSET_TERMINAL_ID=parent-terminal
    unset ORCA_TERMINAL_HANDLE TMUX TMUX_PANE
    spawn_choice=false
  fi
  chain_output="$(command_chain_run loop --parent-agent codex --worktree "$root" --prompt chain-launch --tmux "$spawn_choice" --json)"
  assert_equal "$(printf '%s' "$chain_output" | jq -r '.step')" 1
  assert_equal "$(printf '%s' "$chain_output" | jq -r '.agent')" codex
  dispatch_id="$(printf '%s' "$chain_output" | jq -r '.dispatch.dispatch // empty')"
  [ -n "$dispatch_id" ] || fail "$runtime chain did not launch a dispatch"
  if [ "$runtime" = tmux ]; then
    assert_equal "$(tmux_cmd show-environment -t "$session_name" MEGABRAIN_STATE_DIR)" "MEGABRAIN_STATE_DIR=$state_dir"
  fi
  dispatch_meta="$(megabrain_dispatch_meta_read "$dispatch_id")"
  assert_equal "$(printf '%s' "$dispatch_meta" | jq -r '.promptDelivered')" true
  if [ "$runtime" = tmux ]; then
    child_session="$(printf '%s' "$dispatch_meta" | jq -r '.tmuxSession')"
    child_pane="$(printf '%s' "$dispatch_meta" | jq -r '.tmuxPane')"
    child_tmux="$(tmux_cmd display-message -p -t "$child_pane" '#{socket_path},#{pid},#{session_id}')"
    assert_contains "$(tmux_cmd capture-pane -p -t "$child_pane" -S -30)" 'agent-response:chain-launch'
  else
    assert_contains "$(cat "$state_dir/fake-sends.log")" chain-launch
    assert_not_equal "$dispatch_id" "$(printf '%s' "$dispatch_meta" | jq -r '.terminalId')"
    assert_contains "$(cat "$state_dir/fake-sends.log")" "SUPERSET_TERMINAL_ID=child-terminal"
    assert_contains "$(cat "$state_dir/fake-sends.log")" "MEGABRAIN_DISPATCH_ID=$dispatch_id"
    assert_contains "$(cat "$state_dir/fake-sends.log")" "MEGABRAIN_STATE_DIR=$state_dir"
  fi
  child_command received >/dev/null
  receipt_delivery="$(parent_watch)"
  receipt_delivery_id="$(jq -r '.deliveryId' <<<"$receipt_delivery")"
  parent_ack "$receipt_delivery_id" >/dev/null
  child_command ask "$runtime-question" >/dev/null
  delivery="$(parent_watch)"
  replay="$(parent_watch)"
  delivery_id="$(jq -r '.deliveryId' <<<"$delivery")"
  assert_equal "$(jq -r '.messages[0].text' <<<"$delivery")" "$runtime-question"
  assert_equal "$(jq -r '.replayed' <<<"$replay")" true
  assert_equal "$(jq -r '.deliveryId' <<<"$replay")" "$delivery_id"
  parent_ack "$delivery_id" >/dev/null
  reply_result="$(megabrain_dispatch_reply "$dispatch_id" --text "printf $runtime-push-received" --json)"
  assert_equal "$(jq -r '.status' <<<"$reply_result")" replied
  if [ "$runtime" = tmux ]; then
    assert_contains "$(tmux_cmd capture-pane -p -t "$child_pane" -S -30)" "agent-response:printf $runtime-push-received"
  else
    assert_contains "$(cat "$state_dir/fake-sends.log")" "$runtime-push-received"
  fi
  push_check="$(child_check)"
  assert_contains "$(jq -r '.text' <<<"$push_check")" "$runtime-push-received"
  push_delivery="$(jq -r '.deliveryId' <<<"$push_check")"
  push_ack="$(child_ack "$push_delivery")"
  assert_equal "$(jq -r '.duplicate' <<<"$push_ack")" false
  child_command ask "$runtime-pull-question" >/dev/null
  question_delivery="$(parent_watch)"
  question_delivery_id="$(jq -r '.deliveryId' <<<"$question_delivery")"
  parent_ack "$question_delivery_id" >/dev/null
  if [ "$runtime" = tmux ]; then
    busy_pane="$(tmux_cmd split-window -v -t "$child_session" -P -F '#{pane_id}' "printf '%s' 'Working · esc to interrupt'; sleep 5")"
    busy_before="$(tmux_cmd capture-pane -p -t "$busy_pane" -S -10)"
    jq --arg pane "$busy_pane" '.tmuxPane = $pane' "$state_dir/dispatches/$dispatch_id/meta.json" >"$state_dir/meta.tmp"
    mv -f "$state_dir/meta.tmp" "$state_dir/dispatches/$dispatch_id/meta.json"
    child_pane="$busy_pane"
  else
    fake_send_mode=fail
  fi
  pull_result="$(megabrain_dispatch_reply "$dispatch_id" --text "printf $runtime-pull-received" --json)"
  assert_equal "$(jq -r '.status' <<<"$pull_result")" queued
  if [ "$runtime" = tmux ]; then
    busy_after="$(tmux_cmd capture-pane -p -t "$busy_pane" -S -10)"
    assert_equal "$busy_after" "$busy_before"
  else
    assert_not_contains "$(cat "$state_dir/fake-sends.log")" "$runtime-pull-received"
  fi
  pull_result="$(child_check)"
  assert_contains "$(jq -r '.text' <<<"$pull_result")" "$runtime-pull-received"
  pull_delivery_id="$(jq -r '.deliveryId' <<<"$pull_result")"
  child_ack "$pull_delivery_id" >/dev/null
  child_command done "$runtime-complete" >/dev/null
  done_delivery="$(parent_watch)"
  assert_equal "$(jq -r '.messages[0].text' <<<"$done_delivery")" "$runtime-complete"
  done_delivery_id="$(jq -r '.deliveryId' <<<"$done_delivery")"
  parent_ack "$done_delivery_id" >/dev/null
  assert_equal "$(jq -r '.duplicate' <<<"$(parent_ack "$done_delivery_id")")" true
  queue_types="$(find "$state_dir/dispatches/$dispatch_id/messages" -name '*.json' -exec jq -r '[.from, .type] | join("/")' {} \; | sort)"
  assert_contains "$queue_types" 'child/received'
  assert_contains "$queue_types" 'child/ask'
  assert_contains "$queue_types" 'parent/reply'
  assert_contains "$queue_types" 'child/done'
  if [ "$runtime" = tmux ]; then
    tmux_cmd kill-pane -t "$(printf '%s' "$dispatch_meta" | jq -r '.tmuxPane')"
    megabrain_dispatch_close "$dispatch_id" --json >/dev/null
    assert_equal "$(tmux_cmd has-session -t "$child_session" >/dev/null 2>&1; printf '%s' "$?")" 1
  else
    megabrain_dispatch_close "$dispatch_id" --json >/dev/null
  fi
  assert_equal "$(jq -r '.state' "$state_dir/dispatches/$dispatch_id/meta.json")" closed
  assert_equal "$(find "$state_dir/dispatches/$dispatch_id/deliveries" -name '*.json' -exec jq -r 'select(.status == "outstanding") | .id' {} \; | wc -l | tr -d ' ')" 0
  printf '%s end-to-end: chain, queue, replay, push, pull, done, duplicate ack, and close\n' "$runtime"
}

BREAK_BUSY_GUARD="${BREAK_BUSY_GUARD:-false}"
BREAK_CLAUDE_IDLE="${BREAK_CLAUDE_IDLE:-false}"
if [ "$BREAK_BUSY_GUARD" = true ]; then
  megabrain_dispatch_child_is_idle() { printf 'true\n'; }
fi
if [ "$BREAK_CLAUDE_IDLE" = true ]; then
  megabrain_parent_notify_tmux_is_idle() { printf 'unknown\n'; }
fi

run_flow tmux
run_flow host

tmux_cmd kill-session -t "$session_name" >/dev/null 2>&1 || true
tmux_cmd kill-server >/dev/null 2>&1 || true
printf 'ok: child parent loop end to end in tmux and non-tmux runtimes\n'
