#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-receipt.XXXXXX")"

cleanup() {
  rm -rf "$state_dir"
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir"
export MEGABRAIN_PROMPT_RECEIPT_TIMEOUT_SECONDS=1
export ORCA_TERMINAL_HANDLE=parent-terminal
unset SUPERSET_TERMINAL_ID
source "$root/lib/common.sh"
source "$root/lib/module-tmux-runtime.sh"
source "$root/lib/module-parent-notify.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-worktree.sh"

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

assert_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "expected command to fail: $*"
  fi
}

create_dispatch() {
  local dispatch_id="$1" state="$2"
  megabrain_dispatch_meta_write "$dispatch_id" parent-terminal orca orca "" child-terminal "$root" fix/prompt-delivery-proof codex label "$state" gpt-5 true codex "" "" host ide >/dev/null
}

create_tmux_dispatch() {
  megabrain_dispatch_meta_write "$1" parent-terminal orca orca "" child-terminal "$root" fix/prompt-delivery-proof codex label spawning gpt-5 true codex tmux-session %1 tmux tmux >/dev/null
}

create_dispatch receipt-test spawning
megabrain_dispatch_message_append receipt-test child received 'prompt received' child-terminal >/dev/null
megabrain_dispatch_wait_for_prompt_receipt receipt-test
delivery_path="$(find "$state_dir/dispatches/receipt-test/deliveries" -name '*.json' -print -quit)"
[ -n "$delivery_path" ] || fail 'receipt did not create a delivery'
assert_equal "$(jq -r '.status' "$delivery_path")" acknowledged
printf 'received receipt is durable and acknowledged\n'

create_dispatch timeout-test spawning
assert_failure megabrain_dispatch_wait_for_prompt_receipt timeout-test
assert_equal "$(find "$state_dir/dispatches/timeout-test/deliveries" -name '*.json' | wc -l | tr -d ' ')" 0
megabrain_spawn_mark_prompt_failed timeout-test prompt-receipt-timeout
assert_equal "$(jq -r '.promptDelivered' "$state_dir/dispatches/timeout-test/meta.json")" false
assert_equal "$(jq -r '.promptDelivery' "$state_dir/dispatches/timeout-test/meta.json")" not-delivered
assert_equal "$(jq -r '.promptDeliveryReason' "$state_dir/dispatches/timeout-test/meta.json")" prompt-receipt-timeout
printf 'missing receipt cannot confirm delivery\n'

create_dispatch stalled-report spawning
megabrain_dispatch_message_append stalled-report child stalled 'child could not run the dispatch command' child-terminal >/dev/null
megabrain_spawn_mark_prompt_failed stalled-report prompt-receipt-timeout
failure_output="$(megabrain_dispatch_failure_error stalled-report 'dispatch did not receive a prompt receipt' 2>&1)"
assert_contains "$failure_output" 'child message: "child could not run the dispatch command"'
assert_equal "$(jq -r '.state' "$state_dir/dispatches/stalled-report/meta.json")" failed
printf 'failed dispatch reports the child stalled message\n'

tmux_mode=unresponsive
tmux_enter_count=0
tmux_draft=''
tmux_capture_file="$state_dir/tmux-captures"
printf '0\n' >"$tmux_capture_file"
tmux() {
  local command="${1:-}" count
  case "$command" in
    send-keys)
      if [ "${4:-}" = -l ]; then
        tmux_draft="${5:-}"
      fi
      if [ "${4:-}" = Enter ]; then
        tmux_enter_count=$((tmux_enter_count + 1))
      fi
      return 0
      ;;
    capture-pane)
      count="$(cat "$tmux_capture_file")"
      count=$((count + 1))
      printf '%s\n' "$count" >"$tmux_capture_file"
      if [ "$tmux_mode" = responsive ] && [ "$count" -ge 2 ]; then
        printf 'submitted\n'
      else
        printf 'composer %s\n' "$tmux_draft"
      fi
      return 0
      ;;
    *) return 1 ;;
  esac
}
megabrain_tmux_session_exists() {
  return 0
}
export MEGABRAIN_TMUX_ENTER_RETRIES=2
create_tmux_dispatch pane-activity-test
assert_failure megabrain_dispatch_wait_for_prompt_receipt pane-activity-test
megabrain_spawn_mark_prompt_failed pane-activity-test prompt-receipt-timeout
assert_equal "$(jq -r '.promptDelivered' "$state_dir/dispatches/pane-activity-test/meta.json")" false
printf 'pane activity without a queue receipt cannot confirm delivery\n'

export MEGABRAIN_TMUX_ENTER_RETRIES=3
export MEGABRAIN_TMUX_ENTER_WAIT=0
tmux_mode=unresponsive
tmux_enter_count=0
printf '0\n' >"$tmux_capture_file"
megabrain_tmux_send_text %1 'unresponsive message'
assert_equal "$tmux_enter_count" 3
printf 'message delivery: unresponsive pane receives bounded Enter retries\n'

tmux_mode=responsive
tmux_enter_count=0
printf '0\n' >"$tmux_capture_file"
megabrain_tmux_send_text %1 'responsive message'
assert_equal "$tmux_enter_count" 1
printf 'message delivery: responsive pane stops after the first Enter\n'

create_dispatch running-reply running
reply_result="$(megabrain_dispatch_reply running-reply --text 'Continue work' --json)"
assert_equal "$(jq -r '.status' <<<"$reply_result")" queued
reply_message="$(find "$state_dir/dispatches/running-reply/messages" -name '*.json' -print -quit)"
assert_equal "$(jq -r '.type' "$reply_message")" reply
assert_equal "$(jq -r '.text' "$reply_message")" 'Continue work'
printf 'running child accepts queued parent reply\n'

printf 'ok: receipt delivery and running reply scenarios\n'
