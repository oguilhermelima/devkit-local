#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-ack-receipt.XXXXXX")"
dispatch_id=ack-receipt

cleanup() {
  local rc=$?
  wait 2>/dev/null || true
  rm -rf "$state_dir"
  return "$rc"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

export MEGABRAIN_STATE_DIR="$state_dir"
source "$root/lib/common.sh"
source "$root/lib/module-orchestrate.sh"

megabrain_dispatch_meta_write "$dispatch_id" parent-terminal superset superset workspace-test \
  child-terminal "$root" main codex label running gpt-5 true codex '' '' host ide >/dev/null

# The reply is written by a delayed producer so the child really waits on the queue.
(
  sleep 1
  megabrain_dispatch_message_append "$dispatch_id" parent reply 'answer from coordinator' parent-terminal >/dev/null
) &

child_delivery="$(env -u TMUX -u TMUX_PANE MEGABRAIN_STATE_DIR="$state_dir" \
  SUPERSET_TERMINAL_ID=child-terminal "$root/megabrain" check --timeout 3 --poll-interval 1 --json)"
assert_equal "$(printf '%s' "$child_delivery" | jq -r '.messages[0].type')" reply
child_delivery_id="$(printf '%s' "$child_delivery" | jq -r '.deliveryId')"
[ -n "$child_delivery_id" ] || fail 'child did not receive a delivery id'

child_ack="$(env -u TMUX -u TMUX_PANE MEGABRAIN_STATE_DIR="$state_dir" \
  SUPERSET_TERMINAL_ID=child-terminal "$root/megabrain" ack "$child_delivery_id" --json)"
assert_equal "$(printf '%s' "$child_ack" | jq -r '.duplicate')" false

parent_delivery="$(env -u TMUX -u TMUX_PANE MEGABRAIN_STATE_DIR="$state_dir" \
  SUPERSET_TERMINAL_ID=parent-terminal "$root/megabrain" orchestrate watch "$dispatch_id" \
  --timeout 1 --poll-interval 1 --wait-mode poll --json)"
assert_equal "$(printf '%s' "$parent_delivery" | jq -r '.messages[0].type')" ack
assert_equal "$(printf '%s' "$parent_delivery" | jq -r '.messages[0].text')" "$child_delivery_id"
parent_delivery_id="$(printf '%s' "$parent_delivery" | jq -r '.deliveryId')"

env -u TMUX -u TMUX_PANE MEGABRAIN_STATE_DIR="$state_dir" SUPERSET_TERMINAL_ID=parent-terminal \
  "$root/megabrain" orchestrate ack "$dispatch_id" "$parent_delivery_id" --json >/dev/null

assert_equal "$(find "$state_dir/dispatches/$dispatch_id/messages" -name '*-child-ack.json' | wc -l | tr -d ' ')" 1
printf 'child reply acknowledgement reaches the coordinator queue without an ack loop\n'

