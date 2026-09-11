#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-parent-visibility.XXXXXX")"

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

export MEGABRAIN_STATE_DIR="$state_dir"
export SUPERSET_TERMINAL_ID=parent-terminal
unset TMUX TMUX_PANE ORCA_TERMINAL_HANDLE

source "$root/lib/common.sh"
source "$root/lib/module-tmux-runtime.sh"
source "$root/lib/module-context.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-parent-notify.sh"

create_dispatch() {
  local id="$1" state="${2:-running}"
  megabrain_dispatch_meta_write "$id" parent-terminal superset superset workspace-test "child-$id" \
    "$root" main codex label "$state" gpt-5 true codex '' '' host ide >/dev/null
}

assert_due() {
  megabrain_dispatch_stalled_is_due "$1" || fail "$2"
}

assert_not_due() {
  if megabrain_dispatch_stalled_is_due "$1"; then
    fail "$2"
  fi
}

# ---------------------------------------------------------------------------
# Defect 1: the stalled signal must fire in the healthy (proven) path too,
# but only once the recent-activity debounce that guarded it originally has
# elapsed. Both halves of that guard are exercised here.
# ---------------------------------------------------------------------------

create_dispatch stalled-proven-idle
megabrain_dispatch_terminal_status() { MEGABRAIN_TERMINAL_STATUS=proven; }
meta="$(megabrain_dispatch_meta_read stalled-proven-idle)"
assert_due "$meta" 'a proven terminal with no prior child activity must be due for stalled'
printf 'proven terminal with no recent child activity is due for stalled\n'

create_dispatch stalled-proven-recent
megabrain_dispatch_message_append stalled-proven-recent child received 'prompt received' child-terminal >/dev/null
meta="$(megabrain_dispatch_meta_read stalled-proven-recent)"
assert_not_due "$meta" 'a proven terminal with recent child activity must not be due for stalled (debounce guard)'
printf 'proven terminal with recent child activity is not due for stalled\n'

create_dispatch stalled-missing-case
megabrain_dispatch_terminal_status() { MEGABRAIN_TERMINAL_STATUS=missing; }
megabrain_dispatch_message_append stalled-missing-case child received 'prompt received' child-terminal >/dev/null
meta="$(megabrain_dispatch_meta_read stalled-missing-case)"
assert_due "$meta" 'a missing terminal must always be due for stalled, even with recent activity'
printf 'missing terminal is due for stalled regardless of recent activity\n'

create_dispatch stalled-unknown-recent
megabrain_dispatch_terminal_status() { MEGABRAIN_TERMINAL_STATUS=unknown; }
megabrain_dispatch_message_append stalled-unknown-recent child ask 'a question' child-terminal >/dev/null
meta="$(megabrain_dispatch_meta_read stalled-unknown-recent)"
assert_not_due "$meta" 'an unknown terminal with recent activity must not be due for stalled'
printf 'unknown terminal with recent activity is not due for stalled\n'

# ---------------------------------------------------------------------------
# Defect 2: mail visibility (actionable vs protocol) has exactly one owner.
# Scenarios are derived from the canonical arrays, not hand-listed, so they
# do not rot if a type is ever added or removed from either array.
# ---------------------------------------------------------------------------

if declare -F megabrain_dispatch_last_child_mail_seq >/dev/null 2>&1; then
  fail 'dead classification function megabrain_dispatch_last_child_mail_seq is still defined'
fi
printf 'the dead classification function was removed\n'

create_dispatch mail-class-actionable
for key in "${MEGABRAIN_DISPATCH_MAIL_ACTIONABLE_KEYS[@]}"; do
  [ "${key%%:*}" = child ] || continue
  megabrain_dispatch_message_append mail-class-actionable child "${key#child:}" "actionable ${key#child:}" child-terminal >/dev/null
done
checked=0
for path in "$(megabrain_dispatch_deliveries_dir mail-class-actionable)"/*.json; do
  [ -f "$path" ] || continue
  megabrain_dispatch_delivery_matches_mailbox mail-class-actionable "$path" parent false ||
    fail "actionable delivery $path is not visible to the parent by default"
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail 'no actionable child deliveries were created to check'
printf 'every actionable child type in the canonical array is visible to the parent by default\n'

create_dispatch mail-class-protocol
for key in "${MEGABRAIN_DISPATCH_MAIL_PROTOCOL_KEYS[@]}"; do
  [ "${key%%:*}" = child ] || continue
  megabrain_dispatch_message_append mail-class-protocol child "${key#child:}" "protocol ${key#child:}" child-terminal >/dev/null
done
checked=0
for path in "$(megabrain_dispatch_deliveries_dir mail-class-protocol)"/*.json; do
  [ -f "$path" ] || continue
  if megabrain_dispatch_delivery_matches_mailbox mail-class-protocol "$path" parent false; then
    fail "protocol delivery $path is unexpectedly visible to the parent by default"
  fi
  megabrain_dispatch_delivery_matches_mailbox mail-class-protocol "$path" parent true ||
    fail "protocol delivery $path is not visible to the parent with --full"
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail 'no protocol child deliveries were created to check'
printf 'every protocol child type in the canonical array is hidden by default and visible with --full\n'

# ---------------------------------------------------------------------------
# Defect 3: a megabrain-sender usage message must actually reach the parent.
# ---------------------------------------------------------------------------

create_dispatch usage-routes-to-parent
megabrain_dispatch_message_append usage-routes-to-parent megabrain usage 'usage near limit' megabrain >/dev/null
usage_delivery=""
for path in "$(megabrain_dispatch_deliveries_dir usage-routes-to-parent)"/*.json; do
  [ -f "$path" ] || continue
  usage_delivery="$path"
done
[ -n "$usage_delivery" ] || fail 'a megabrain usage message created no delivery at all'
assert_equal "$(jq -r '.recipient' "$usage_delivery")" parent
megabrain_dispatch_delivery_matches_mailbox usage-routes-to-parent "$usage_delivery" parent false ||
  fail 'megabrain usage delivery is not visible to the parent by default'
printf 'a megabrain usage message is routed to the parent and visible by default\n'

# ---------------------------------------------------------------------------
# Defect 4: orchestrate reply must report the truth about whether its nudge
# was typed, without ever turning a failed nudge into a failed reply.
# ---------------------------------------------------------------------------

megabrain_dispatch_meta_write nudge-fails parent-terminal superset superset workspace-test child-nudge-fails \
  "$root" main codex label stalled gpt-5 true codex '' '' host ide >/dev/null
megabrain_superset() {
  if [ "$1" = terminals ] && [ "$2" = send ]; then
    return 1
  fi
  return 1
}
reply_fail_output="$(megabrain_dispatch_reply nudge-fails --text 'answer despite a dead pane' --json)"
assert_equal "$(printf '%s' "$reply_fail_output" | jq -r '.status')" queued
assert_equal "$(printf '%s' "$reply_fail_output" | jq -r '.nudge')" not-typed
printf 'a failed terminal send is reported as nudge=not-typed while status stays queued\n'

megabrain_dispatch_meta_write nudge-succeeds parent-terminal superset superset workspace-test child-nudge-succeeds \
  "$root" main codex label stalled gpt-5 true codex '' '' host ide >/dev/null
megabrain_superset() {
  if [ "$1" = terminals ] && [ "$2" = send ]; then
    printf '{}\n'
    return 0
  fi
  return 1
}
reply_ok_output="$(megabrain_dispatch_reply nudge-succeeds --text 'answer reaches a live pane' --json)"
assert_equal "$(printf '%s' "$reply_ok_output" | jq -r '.status')" queued
assert_equal "$(printf '%s' "$reply_ok_output" | jq -r '.nudge')" typed
printf 'a successful terminal send is reported as nudge=typed\n'

printf 'ok: parent visibility gaps covered for stalled signal, mail classification, usage routing, and nudge honesty\n'
