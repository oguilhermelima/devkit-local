#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/devkit-receipt.XXXXXX")"

cleanup() {
  rm -rf "$state_dir"
}
trap cleanup EXIT

export DEVKIT_STATE_DIR="$state_dir"
export DEVKIT_PROMPT_RECEIPT_TIMEOUT_SECONDS=1
export ORCA_TERMINAL_HANDLE=parent-terminal
unset SUPERSET_TERMINAL_ID
source "$root/lib/common.sh"
source "$root/lib/module-parent-notify.sh"
source "$root/lib/module-orchestrate.sh"

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

create_dispatch() {
  local dispatch_id="$1" state="$2"
  devkit_dispatch_meta_write "$dispatch_id" parent-terminal orca orca "" child-terminal "$root" fix/prompt-delivery-proof codex label "$state" gpt-5 true codex "" "" host ide >/dev/null
}

create_dispatch receipt-test spawning
devkit_dispatch_message_append receipt-test child received 'prompt received' child-terminal >/dev/null
devkit_dispatch_wait_for_prompt_receipt receipt-test
delivery_path="$(find "$state_dir/dispatches/receipt-test/deliveries" -name '*.json' -print -quit)"
[ -n "$delivery_path" ] || fail 'receipt did not create a delivery'
assert_equal "$(jq -r '.status' "$delivery_path")" acknowledged
printf 'received receipt is durable and acknowledged\n'

create_dispatch timeout-test spawning
assert_failure devkit_dispatch_wait_for_prompt_receipt timeout-test
assert_equal "$(find "$state_dir/dispatches/timeout-test/deliveries" -name '*.json' | wc -l | tr -d ' ')" 0
printf 'missing receipt cannot confirm delivery\n'

create_dispatch running-reply running
reply_result="$(devkit_dispatch_reply running-reply --text 'Continue work' --json)"
assert_equal "$(jq -r '.status' <<<"$reply_result")" queued
reply_message="$(find "$state_dir/dispatches/running-reply/messages" -name '*.json' -print -quit)"
assert_equal "$(jq -r '.type' "$reply_message")" reply
assert_equal "$(jq -r '.text' "$reply_message")" 'Continue work'
printf 'running child accepts queued parent reply\n'

printf 'ok: receipt delivery and running reply scenarios\n'
