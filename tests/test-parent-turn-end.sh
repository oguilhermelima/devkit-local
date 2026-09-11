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

create_dispatch event-hook running
append_ask event-hook 'event-backed question'
assert_equal "$(send_count)" 1
run_hook
assert_equal "$(send_count)" 1
assert_equal "$(jq -r '.lastReadSeq' "$MEGABRAIN_DISPATCH_DIR/event-hook/cursor.json")" 0
printf 'event-backed child mail is not nudged again by the parent turn-end hook\n'

create_dispatch protocol-hook running
append_message protocol-hook received 'prompt received'
append_message protocol-hook ack 'delivery-id'
assert_equal "$(send_count)" 1
run_hook
assert_equal "$(send_count)" 1
printf 'received and ack do not nudge from append or the parent turn-end hook\n'

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
