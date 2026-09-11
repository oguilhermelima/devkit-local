#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-nudge-release.XXXXXX")"
state_dir="$(cd -P "$state_dir" && pwd -P)"

cleanup() {
  local rc=$?
  rm -rf "$state_dir"
  return "$rc"
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir"
export ORCA_TERMINAL_HANDLE=parent-terminal
unset SUPERSET_TERMINAL_ID TMUX TMUX_PANE

source "$root/lib/common.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-parent-notify.sh"

fail_count=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fail_count=$((fail_count + 1))
}

assert_equal() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_file_absent() {
  [ ! -e "$1" ] || fail "expected '$1' to be absent"
}

create_dispatch() {
  local dispatch_id="$1"
  megabrain_dispatch_meta_write "$dispatch_id" parent-terminal orca orca '' "$dispatch_id-terminal" \
    "$root" main codex label running gpt-5 true codex '' '' host ide '' '' >/dev/null
}

append_message() {
  local dispatch_id="$1" type="$2" text="$3"
  megabrain_dispatch_message_append "$dispatch_id" child "$type" "$text" child-terminal >/dev/null
}

notify_calls=0
megabrain_parent_notify_channel() {
  printf 'orca\n'
}
megabrain_parent_notify() {
  notify_calls=$((notify_calls + 1))
}

# A first actionable child message still creates one nudge claim.
create_dispatch first-actionable
append_message first-actionable ask 'first actionable message'
first_meta="$(megabrain_dispatch_meta_read first-actionable)"
megabrain_parent_notify_dispatch "$first_meta"
assert_equal "$notify_calls" 1
assert_equal "$(jq -r '.messageSeq' "$state_dir/dispatches/first-actionable/nudge-state.json")" 1
printf 'first actionable message nudges once\n'

# Advancing the cursor proves that the parent saw the first message and releases
# its claim, allowing a later actionable message to nudge once.
notify_calls=0
create_dispatch cursor-advances
append_message cursor-advances ask 'first actionable message'
cursor_meta="$(megabrain_dispatch_meta_read cursor-advances)"
megabrain_parent_notify_dispatch "$cursor_meta"
megabrain_dispatch_cursor_write cursor-advances 1
append_message cursor-advances done 'second actionable message'
cursor_meta="$(megabrain_dispatch_meta_read cursor-advances)"
megabrain_parent_notify_dispatch "$cursor_meta"
assert_equal "$notify_calls" 2
assert_equal "$(jq -r '.messageSeq' "$state_dir/dispatches/cursor-advances/nudge-state.json")" 2
printf 'cursor advancement releases the prior nudge\n'

# A cursor already at the message sequence is durable evidence that the parent
# has seen it, even when no nudge state or delivery exists.
notify_calls=0
create_dispatch already-seen
append_message already-seen ask 'already seen message'
megabrain_dispatch_cursor_write already-seen 1
seen_meta="$(megabrain_dispatch_meta_read already-seen)"
megabrain_parent_notify_dispatch "$seen_meta"
assert_equal "$notify_calls" 0
printf 'already-seen message does not nudge\n'

# Direct mailbox reads do not create deliveries. The cursor alone must release
# the prior claim so a later actionable message remains visible to the parent.
notify_calls=0
create_dispatch read-without-delivery
append_message read-without-delivery ask 'first message read directly'
read_meta="$(megabrain_dispatch_meta_read read-without-delivery)"
megabrain_parent_notify_dispatch "$read_meta"
megabrain_dispatch_cursor_write read-without-delivery 1
append_message read-without-delivery done 'completion read directly'
read_meta="$(megabrain_dispatch_meta_read read-without-delivery)"
megabrain_parent_notify_dispatch "$read_meta"
assert_equal "$notify_calls" 2
assert_file_absent "$state_dir/dispatches/read-without-delivery/deliveries/delivery.json"
assert_equal "$(find "$state_dir/dispatches/read-without-delivery/deliveries" -name '*.json' -print | wc -l | tr -d ' ')" 0
printf 'direct mailbox read without delivery still nudges new mail\n'

[ "$fail_count" -eq 0 ] || exit 1
