#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-parent-turn-end.XXXXXX")"
bin_dir="$state_dir/bin"
send_log="$state_dir/send.log"
mkdir -p "$bin_dir"

cleanup() {
  local rc=$?
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

printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$*" >>"$MEGABRAIN_TEST_SEND_LOG"' >"$bin_dir/superset"
chmod +x "$bin_dir/superset"
printf '%s\n' '#!/bin/sh' 'if [ "$1" = capture-pane ]; then cat "$MEGABRAIN_TEST_PANE_OUTPUT"; fi' >"$bin_dir/tmux"
chmod +x "$bin_dir/tmux"
: >"$send_log"

export MEGABRAIN_STATE_DIR="$state_dir/state"
export MEGABRAIN_TEST_SEND_LOG="$send_log"
export MEGABRAIN_TEST_PANE_OUTPUT="$state_dir/pane.out"
export SUPERSET_TERMINAL_ID=parent-terminal
export PATH="$bin_dir:$PATH"
unset ORCA_TERMINAL_HANDLE TMUX TMUX_PANE

source "$root/lib/common.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-parent-notify.sh"

create_dispatch() {
  local dispatch_id="$1" state="$2"
  megabrain_dispatch_meta_write "$dispatch_id" parent-terminal superset superset workspace-test "child-$dispatch_id" \
    "$root" main codex label "$state" gpt-5 true codex "" "" host ide >/dev/null
}

append_ask() {
  local dispatch_id="$1" text="$2"
  megabrain_dispatch_message_append "$dispatch_id" child ask "$text" "child-$dispatch_id" >/dev/null
}

append_message() {
  local dispatch_id="$1" type="$2" text="$3"
  megabrain_dispatch_message_append "$dispatch_id" child "$type" "$text" "child-$dispatch_id" >/dev/null
}

run_hook() {
  "$root/hooks/megabrain-turn-end.sh" '{}' >/dev/null
}

send_count() {
  wc -l <"$send_log" | tr -d ' '
}

create_dispatch alpha running
create_dispatch beta waiting_for_reply
create_dispatch closed closed
create_dispatch done done
create_dispatch failed failed
create_dispatch orphaned orphaned
append_ask alpha 'alpha question'
append_ask beta 'beta question'
append_ask closed 'closed question'
append_ask done 'done question'
append_ask failed 'failed question'
append_ask orphaned 'orphaned question'

run_hook
assert_equal "$(send_count)" 1
first_notice="$(cat "$send_log")"
assert_contains "$first_notice" '2 mails: run megabrain orchestrate list'
assert_not_contains "$first_notice" alpha
assert_not_contains "$first_notice" beta
assert_not_contains "$first_notice" closed
assert_not_contains "$first_notice" done
assert_not_contains "$first_notice" failed
assert_not_contains "$first_notice" orphaned
assert_equal "$(jq -r '.lastReadSeq' "$MEGABRAIN_DISPATCH_DIR/alpha/cursor.json")" 1
assert_equal "$(jq -r '.lastReadSeq' "$MEGABRAIN_DISPATCH_DIR/beta/cursor.json")" 1
printf 'parent ask mail: one aggregate pointer for two open dispatches\n'

run_hook
assert_equal "$(send_count)" 1
printf 'loop guard: second turn typed nothing\n'

append_ask alpha 'alpha follow-up'
run_hook
assert_equal "$(send_count)" 2
latest_notice="$(tail -n 1 "$send_log")"
assert_contains "$latest_notice" '1 mails: run megabrain orchestrate list'
assert_equal "$(jq -r '.lastReadSeq' "$MEGABRAIN_DISPATCH_DIR/alpha/cursor.json")" 2
assert_equal "$(jq -r '.lastReadSeq' "$MEGABRAIN_DISPATCH_DIR/beta/cursor.json")" 1
printf 'new child mail: pointer delivered again\n'

create_dispatch waiter running
append_ask waiter 'waiter question'
waiter_meta="$(megabrain_dispatch_meta_read waiter)"
megabrain_parent_notify_waiter_register waiter "$waiter_meta"
run_hook
assert_equal "$(send_count)" 2
assert_equal "$(jq -r '.lastReadSeq' "$MEGABRAIN_DISPATCH_DIR/waiter/cursor.json")" 0
printf 'active waiter: dispatch omitted and cursor unchanged\n'

megabrain_parent_notify_waiter_unregister waiter
run_hook
assert_equal "$(send_count)" 3
latest_notice="$(tail -n 1 "$send_log")"
assert_contains "$latest_notice" '1 mails: run megabrain orchestrate list'
assert_equal "$(jq -r '.lastReadSeq' "$MEGABRAIN_DISPATCH_DIR/waiter/cursor.json")" 1
run_hook
assert_equal "$(send_count)" 3
printf 'waiter removal: deferred mail delivered once\n'

create_dispatch type-ask running
create_dispatch type-done running
create_dispatch type-stalled running
create_dispatch type-received running
create_dispatch type-ack running
append_message type-ask ask 'ask needs a decision'
append_message type-done done 'done needs acknowledgement'
append_message type-stalled stalled 'stalled needs intervention'
append_message type-received received 'prompt received'
append_message type-ack ack 'delivery-id'

run_hook
assert_equal "$(send_count)" 4
latest_notice="$(tail -n 1 "$send_log")"
assert_contains "$latest_notice" '3 mails: run megabrain orchestrate list'
assert_equal "$(jq -r '.lastReadSeq' "$MEGABRAIN_DISPATCH_DIR/type-ask/cursor.json")" 1
assert_equal "$(jq -r '.lastReadSeq' "$MEGABRAIN_DISPATCH_DIR/type-done/cursor.json")" 1
assert_equal "$(jq -r '.lastReadSeq' "$MEGABRAIN_DISPATCH_DIR/type-stalled/cursor.json")" 1
assert_equal "$(jq -r '.lastReadSeq' "$MEGABRAIN_DISPATCH_DIR/type-received/cursor.json")" 0
assert_equal "$(jq -r '.lastReadSeq' "$MEGABRAIN_DISPATCH_DIR/type-ack/cursor.json")" 0
printf 'parent pointer: ask, done, and stalled interrupt; received and ack do not\n'

ack_delivery="$("$root/megabrain" orchestrate watch type-ack --timeout 0 --poll-interval 0 --wait-mode poll --json)"
assert_equal "$(jq -r '.messages | length' <<<"$ack_delivery")" 0
full_delivery="$("$root/megabrain" orchestrate watch type-ack --timeout 0 --poll-interval 0 --wait-mode poll --full --consumer protocol-trace --json)"
assert_equal "$(jq -r '.messages | length' <<<"$full_delivery")" 1
assert_equal "$(jq -r '.messages[0].type' <<<"$full_delivery")" ack
printf 'ack-only queue: default view hides protocol evidence and full view reveals it\n'

printf 'child branch: covered by tests/test-e2e-findings.sh\n'

megabrain_dispatch_meta_write refused parent-terminal superset tmux workspace-test refused-terminal \
  "$root" main codex label running gpt-5 true codex refusal-session refusal-pane tmux tmux >/dev/null
printf '%s\n%s\n' \
  "You've hit your usage limit for this account." \
  'Switch to another model now,' >"$MEGABRAIN_TEST_PANE_OUTPUT"
run_hook
assert_equal "$(jq -r '.state' "$MEGABRAIN_DISPATCH_DIR/refused/meta.json")" failed
assert_equal "$(jq -r '.processState' "$MEGABRAIN_DISPATCH_DIR/refused/meta.json")" failed
assert_equal "$(jq -r '.stage' "$MEGABRAIN_DISPATCH_DIR/refused/meta.json")" limit-refused
assert_equal "$(jq -r '.reconcileOutcome' "$MEGABRAIN_DISPATCH_DIR/refused/meta.json")" limit-refused
assert_contains "$(jq -r '.reason' "$MEGABRAIN_DISPATCH_DIR/refused/meta.json")" 'usage limit'
printf 'parent hook: records a pane usage-limit refusal without waiting\n'
