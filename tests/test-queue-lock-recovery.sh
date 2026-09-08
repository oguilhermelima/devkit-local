#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-lock.XXXXXX")"

cleanup() {
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

# Runs one append with a wall-clock bound and reports what happened, so a mailbox that
# never returns shows up as a failed assertion instead of a hung suite.
append_bounded() { # append_bounded <dispatch> <text> <seconds>
  local dispatch_id="$1" text="$2" limit="$3" pid waited=0
  ( megabrain_dispatch_message_append "$dispatch_id" child ask "$text" child-terminal >/dev/null 2>&1 ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    printf 'hung\n'
    return 0
  fi
  if wait "$pid" 2>/dev/null; then printf 'wrote\n'; else printf 'refused\n'; fi
}

megabrain_dispatch_meta_write stale-lock parent-terminal orca orca "" child-terminal "$root" main codex label running gpt-5 true codex '' '' host ide >/dev/null
megabrain_dispatch_meta_write held-lock parent-terminal orca orca "" child-terminal "$root" main codex label running gpt-5 true codex '' '' host ide >/dev/null

# WHY: the lock is a directory, so it outlives the process that made it. A writer killed
# between mkdir and rmdir leaves it behind, and every later ask, done, received and reply
# for that dispatch waits on it. Nothing else in the tool can recover a mailbox in that
# state, so the wait has to be bounded and a lock this old has to be broken.
stale_lock="$state_dir/dispatches/stale-lock/messages/.lock"
mkdir -p "$stale_lock"
touch -t 200001010000 "$stale_lock"
assert_equal "$(append_bounded stale-lock 'after a stale lock' 20)" wrote
assert_equal "$(find "$state_dir/dispatches/stale-lock/messages" -name '*.json' | wc -l | tr -d ' ')" 1
printf 'a lock left behind by a dead writer is broken and the message is written\n'

# WHY: a lock a live writer is holding right now must not be stolen, because stealing it
# reintroduces the lost message the lock exists to prevent. The caller gets a refusal it
# can report instead of a wait that never ends.
held_lock="$state_dir/dispatches/held-lock/messages/.lock"
mkdir -p "$held_lock"
assert_equal "$(append_bounded held-lock 'while another writer holds it' 30)" refused
assert_equal "$(find "$state_dir/dispatches/held-lock/messages" -name '*.json' | wc -l | tr -d ' ')" 0
[ -d "$held_lock" ] || fail 'a lock held by a live writer was stolen'
printf 'a lock held right now is not stolen and the caller is refused\n'

printf 'ok: mailbox lock recovery and refusal\n'
