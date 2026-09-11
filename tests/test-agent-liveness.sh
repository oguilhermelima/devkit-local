#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-agent-liveness.XXXXXX")"
fixture_dir="$root/tests/fixtures/agent-liveness"
pane_output="$state_dir/pane.out"

cleanup() {
  rm -rf "$state_dir"
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

export MEGABRAIN_STATE_DIR="$state_dir/state"
export SUPERSET_TERMINAL_ID=parent-terminal
unset TMUX TMUX_PANE

source "$root/lib/common.sh"
source "$root/lib/module-tmux-runtime.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-context.sh"
source "$root/lib/module-parent-notify.sh"

megabrain_tmux_capture_pane() {
  cat "$pane_output"
}

megabrain_tmux_agent_for_pane() {
  printf 'codex\n'
}

create_dispatch() {
  local dispatch_id="$1" state="${2:-running}"
  megabrain_dispatch_meta_write "$dispatch_id" parent-terminal superset superset workspace child-terminal \
    "$root" main codex label "$state" gpt-5 true codex session pane tmux tmux >/dev/null
}

write_pane_fixture() {
  cp "$fixture_dir/$1.transcript" "$pane_output"
}

create_dispatch working
write_pane_fixture working
working_result="$(megabrain_dispatch_liveness_read working --json)"
assert_equal "$(jq -r '.terminalLiveness' <<<"$working_result")" working
assert_equal "$(jq -r '.source' <<<"$working_result")" tmux
printf 'real transcript frame classifies a working agent\n'

write_pane_fixture idle
idle_result="$(megabrain_dispatch_liveness_read working --json)"
assert_equal "$(jq -r '.terminalLiveness' <<<"$idle_result")" idle
printf 'real transcript frame classifies an idle agent\n'

write_pane_fixture usage-limit
blocked_result="$(megabrain_dispatch_liveness_read working --json)"
assert_equal "$(jq -r '.terminalLiveness' <<<"$blocked_result")" blocked
assert_contains "$(jq -r '.reason' <<<"$blocked_result")" 'usage limit'
printf 'usage-limit frame classifies one blocked cause\n'

write_pane_fixture transport-error
blocked_result="$(megabrain_dispatch_liveness_read working --json)"
assert_equal "$(jq -r '.terminalLiveness' <<<"$blocked_result")" blocked
assert_contains "$(jq -r '.reason' <<<"$blocked_result")" 'socket connection'
printf 'transport-error frame classifies a second blocked cause\n'

write_pane_fixture unknown
unknown_result="$(megabrain_dispatch_liveness_read working --json)"
assert_equal "$(jq -r '.terminalLiveness' <<<"$unknown_result")" unknown
printf 'unrecognised frame remains unknown\n'

printf '%s\n' "You've hit your usage limit for this account." "Switch to another model now," | sed 's/^/quoted marker: /' >"$pane_output"
quoted_result="$(megabrain_dispatch_liveness_read working --json)"
assert_equal "$(jq -r '.terminalLiveness' <<<"$quoted_result")" unknown
printf 'quoted marker does not trigger blocked classification\n'

before_meta="$(cat "$MEGABRAIN_DISPATCH_DIR/working/meta.json")"
write_pane_fixture working
megabrain_dispatch_liveness_read working --json >/dev/null
assert_equal "$(cat "$MEGABRAIN_DISPATCH_DIR/working/meta.json")" "$before_meta"
printf 'liveness read does not mutate dispatch metadata\n'

create_dispatch legacy-timeout timeout
create_dispatch legacy-stalled stalled
assert_equal "$(jq -r '.state' <<<"$(megabrain_dispatch_meta_read legacy-timeout)")" running
assert_equal "$(jq -r '.state' <<<"$(megabrain_dispatch_meta_read legacy-stalled)")" running
printf 'retired states in old records normalise to running\n'

create_dispatch protocol-view
megabrain_dispatch_message_append protocol-view child received 'prompt received' child-terminal >/dev/null
megabrain_dispatch_message_append protocol-view child ack delivery-id child-terminal >/dev/null
megabrain_dispatch_message_append protocol-view child ask 'needs a decision' child-terminal >/dev/null
default_view="$(megabrain_dispatch_watch protocol-view --timeout 0 --poll-interval 0 --wait-mode poll --json)"
assert_equal "$(jq -r '.messages | length' <<<"$default_view")" 1
assert_equal "$(jq -r '.messages[0].type' <<<"$default_view")" ask
full_view="$(megabrain_dispatch_watch protocol-view --timeout 0 --poll-interval 0 --wait-mode poll --full --consumer protocol-trace --json)"
assert_equal "$(jq -r '.messages | length' <<<"$full_view")" 3
assert_equal "$(jq -r '[.messages[].type] | join(",")' <<<"$full_view")" 'received,ack,ask'
printf 'default view hides protocol evidence and full trace reveals it\n'

printf 'ok: agent liveness, retired state migration, and protocol view\n'
