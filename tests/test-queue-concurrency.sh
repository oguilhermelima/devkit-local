#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-queue.XXXXXX")"

cleanup() {
  wait 2>/dev/null || true
  rm -rf "$state_dir"
  return 0
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir"
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

megabrain_dispatch_meta_write queue-race parent-terminal orca orca "" child-terminal "$root" main codex label running gpt-5 true codex '' '' host ide >/dev/null

# WHY: a parent reply and a child ask are written by different processes into the same
# mailbox, so the sequence number and the file name are allocated concurrently. Without
# the lock two writers pick the same sequence and one message silently overwrites the
# other, which is the one way the queue can lose something. The serial tests cannot see
# that, so this is the only place the durability claim is actually exercised.
writers=20
for i in $(seq 1 "$writers"); do
  ( megabrain_dispatch_message_append queue-race child ask "concurrent body $i" child-terminal >/dev/null 2>&1 ) &
done
wait

messages_dir="$state_dir/dispatches/queue-race/messages"
written="$(find "$messages_dir" -name '*.json' | wc -l | tr -d ' ')"
assert_equal "$written" "$writers"

unique_seqs="$(find "$messages_dir" -name '*.json' -exec jq -r '.seq' {} \; | sort -u | wc -l | tr -d ' ')"
assert_equal "$unique_seqs" "$writers"

unique_bodies="$(find "$messages_dir" -name '*.json' -exec jq -r '.text' {} \; | sort -u | wc -l | tr -d ' ')"
assert_equal "$unique_bodies" "$writers"

[ ! -d "$messages_dir/.lock" ] || fail 'the mailbox lock was left behind'
printf '%s concurrent writers: every message kept, every sequence unique\n' "$writers"

printf 'ok: the queue does not lose a message under concurrent writers\n'
