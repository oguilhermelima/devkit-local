#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-receipt.XXXXXX")"

cleanup() {
  rm -rf "$state_dir"
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir"
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

create_dispatch() {
  local dispatch_id="$1" state="$2" terminal_id="${3:-child-terminal}"
  megabrain_dispatch_meta_write "$dispatch_id" parent-terminal orca orca "" "$terminal_id" "$root" fix/prompt-delivery-proof codex label "$state" gpt-5 true codex "" "" host ide >/dev/null
}

create_dispatch stalled-report spawning
megabrain_dispatch_message_append stalled-report child stalled 'child could not run the dispatch command' child-terminal >/dev/null
megabrain_spawn_mark_prompt_failed stalled-report prompt-send-not-observed
failure_output="$(megabrain_dispatch_failure_error stalled-report 'dispatch did not observe prompt send' 2>&1)"
assert_contains "$failure_output" 'child message: "child could not run the dispatch command"'
assert_equal "$(jq -r '.state' "$state_dir/dispatches/stalled-report/meta.json")" failed
printf 'failed dispatch reports the child stalled message\n'

# A turn-end hook is evidence that a child turn ended, not evidence that this prompt
# reached it. An empty turn must remain pending rather than becoming a receipt.
create_dispatch empty-turn running
env -u SUPERSET_TERMINAL_ID -u TMUX -u TMUX_PANE ORCA_TERMINAL_HANDLE=child-terminal MEGABRAIN_DISPATCH_ID=empty-turn MEGABRAIN_HOOK_AGENT=codex \
  "$root/hooks/megabrain-turn-end.sh" '{"last_assistant_message":""}' >/dev/null
assert_equal "$(jq -r '.promptDelivery' "$state_dir/dispatches/empty-turn/meta.json")" pending
assert_equal "$(jq -r '.state' "$state_dir/dispatches/empty-turn/meta.json")" stalled
printf 'empty child turn does not confirm prompt delivery\n'

# The child receipt is the delivery fact. It is durable in the dispatch queue and must be
# observed before the parent marks the prompt delivered.
create_dispatch optional-receipt spawning command-terminal
received_output="$(env -u SUPERSET_TERMINAL_ID -u TMUX -u TMUX_PANE ORCA_TERMINAL_HANDLE=command-terminal MEGABRAIN_STATE_DIR="$state_dir" \
  "$root/megabrain" received)"
assert_equal "$received_output" 'received sent: optional-receipt'
received_message="$state_dir/dispatches/optional-receipt/messages/0001-child-received.json"
[ -f "$received_message" ] || fail 'received command did not leave a durable message'
assert_equal "$(jq -r '.type' "$received_message")" received
assert_equal "$(jq -r '.state' "$state_dir/dispatches/optional-receipt/meta.json")" spawning
printf 'received command is durable and authoritative\n'

receipt_dispatch=receipt-retry
create_dispatch "$receipt_dispatch" spawning command-terminal
receipt_send_count=0
megabrain_dispatch_native_send() {
  receipt_send_count=$((receipt_send_count + 1))
  if [ "$receipt_send_count" -eq 2 ]; then
    megabrain_dispatch_message_append "$receipt_dispatch" child received 'prompt received' child-terminal >/dev/null
  fi
  return 0
}
export MEGABRAIN_PROMPT_RECEIPT_ATTEMPTS=3
export MEGABRAIN_PROMPT_RECEIPT_TIMEOUT_SECONDS=0
megabrain_dispatch_send_prompt_with_receipt "$receipt_dispatch" 'prompt delivered after retry' ||
  fail 'prompt was not delivered after the child receipt appeared'
assert_equal "$receipt_send_count" 2
assert_equal "$(jq -r '.promptDelivery' "$state_dir/dispatches/$receipt_dispatch/meta.json")" pending
printf 'prompt receipt: missing first receipt causes a bounded resend\n'

no_receipt_dispatch=no-receipt
create_dispatch "$no_receipt_dispatch" spawning command-terminal
no_receipt_send_count=0
megabrain_dispatch_native_send() {
  no_receipt_send_count=$((no_receipt_send_count + 1))
  return 0
}
export MEGABRAIN_PROMPT_RECEIPT_ATTEMPTS=2
if megabrain_dispatch_send_prompt_with_receipt "$no_receipt_dispatch" 'prompt without receipt'; then
  fail 'prompt without a receipt unexpectedly succeeded'
fi
assert_equal "$no_receipt_send_count" 2
printf 'prompt receipt: exhaustion fails without claiming delivery\n'

create_dispatch running-reply running
reply_result="$(megabrain_dispatch_reply running-reply --text 'Continue work' --json)"
assert_equal "$(jq -r '.status' <<<"$reply_result")" queued
reply_message="$(find "$state_dir/dispatches/running-reply/messages" -name '*.json' -print -quit)"
assert_equal "$(jq -r '.type' "$reply_message")" reply
assert_equal "$(jq -r '.text' "$reply_message")" 'Continue work'
printf 'running child accepts queued parent reply\n'

printf 'ok: receipt delivery and running reply scenarios\n'
