#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_root="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-reply-nudge.XXXXXX")"
state_root="$(cd -P "$state_root" && pwd -P)"
socket_name=mbreply
session_name=megabrain-reply-nudge
parent_pane=""
child_pane=""
tmux_info=""
parent_identity=""

unset TMUX TMUX_PANE
export TMUX_TMPDIR="$state_root"
export MEGABRAIN_STATE_DIR="$state_root/state"
export ORCA_TERMINAL_HANDLE=""
export SUPERSET_TERMINAL_ID=""

tmux_cmd() {
  tmux -L "$socket_name" "$@"
}

cleanup() {
  local rc=$?
  command tmux -L "$socket_name" kill-server >/dev/null 2>&1 || true
  rm -rf "$state_root"
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
    *"$2"*) fail "expected output not to contain '$2'" ;;
    *) ;;
  esac
}

source "$root/lib/common.sh"
source "$root/lib/module-tmux-runtime.sh"
source "$root/lib/module-orchestrate.sh"

tmux_cmd new-session -d -s "$session_name" -x 120 -y 30 bash
parent_pane="$(tmux_cmd display-message -p -t "$session_name" '#{pane_id}')"
tmux_info="$(tmux_cmd display-message -p -t "$parent_pane" '#{socket_path},#{pid},#{session_id}')"
case "${tmux_info%%,*}" in
  "$state_root"/*) ;;
  *) fail "refusing to run: the tmux server is outside $state_root" ;;
esac
export TMUX="$tmux_info"
export TMUX_PANE="$parent_pane"
parent_identity="$(megabrain_session_id)"
child_pane="$(tmux_cmd split-window -d -t "$session_name" -c "$root" -P -F '#{pane_id}' 'trap "" INT; sleep 60')"

create_meta() {
  local dispatch_id="$1" pane="$2" agent="${3:-codex}"
  megabrain_dispatch_meta_write "$dispatch_id" "$parent_identity" tmux tmux "" child-terminal \
    "$root" main "$agent" label running gpt-5 true "$agent" "$session_name" "$pane" tmux tmux \
    "$session_name" "$parent_pane" "" >/dev/null
}

# A process that never reads stdin exercises the real pty backpressure. This is a
# transport-bound test only; the composer-delivery proof is the repainting scenario above.
dispatch_id=bounded-reply
create_meta "$dispatch_id" "$child_pane"
answer="$(printf '%65536s' '' | tr ' ' x)"
done_file="$state_root/reply-done"
reply_output="$state_root/reply-output"
reply_error="$state_root/reply-error"
(
  if megabrain_dispatch_reply "$dispatch_id" --text "$answer" --json >"$reply_output" 2>"$reply_error"; then
    printf '0\n' >"$done_file"
  else
    printf '1\n' >"$done_file"
  fi
) &
reply_pid=$!
started="$(date +%s)"
while [ ! -f "$done_file" ]; do
  now="$(date +%s)"
  [ $((now - started)) -lt 3 ] || break
  sleep 0.05
done
if [ ! -f "$done_file" ]; then
  kill "$reply_pid" >/dev/null 2>&1 || true
  wait "$reply_pid" 2>/dev/null || true
  fail 'reply remained blocked while the child pane did not read stdin'
fi
wait "$reply_pid"
case "$(jq -r '.status' "$reply_output")" in
  queued|replied) ;;
  *) fail "reply did not queue or nudge: $(cat "$reply_output")" ;;
esac
assert_equal "$(find "$state_root/state/dispatches/$dispatch_id/messages" -name '*.json' | wc -l | tr -d ' ')" 1
assert_equal "$(jq -r '.text' "$state_root/state/dispatches/$dispatch_id/messages"/*.json)" "$answer"
printf 'busy child: reply returns within the bound and keeps the full queue message\n'

tmux_cmd kill-pane -t "$child_pane"

# Width is read from the target pane, so the cap follows narrow and wide terminals.
nudge_width=70
tmux() {
  case "$1" in
    display-message) printf '%s\n' "$nudge_width" ;;
    *) return 0 ;;
  esac
}
long_nudge='[megabrain] mail available; run megabrain orchestrate watch dispatch-with-a-very-long-identifier'
capped_nudge="$(megabrain_tmux_nudge_text_for_pane %width "$long_nudge")"
# The container's C locale counts the UTF-8 ellipsis as three characters. Replace
# that display-cell marker before measuring so this assertion is locale-independent.
capped_nudge_length="$(printf '%s' "$capped_nudge" | sed 's/…/x/g' | wc -m | tr -d ' ')"
assert_equal "$capped_nudge_length" "$nudge_width"
assert_contains "$capped_nudge" '…'
printf 'nudge width: text is capped to pane columns with an ellipsis\n'
unset -f tmux

# Codex's Tab affordance queues the pointer, so no stale draft can survive in the pane.
log_file="$state_root/tmux-send.log"
pointer_composer_file="$state_root/pointer-composer"
pointer_queue_file="$state_root/pointer-queue"
: >"$log_file"
: >"$pointer_composer_file"
: >"$pointer_queue_file"
tmux() {
  case "${1:-}" in
    display-message) printf '%s\n' "$session_name" ;;
    capture-pane) cat "$pointer_composer_file" ;;
    send-keys)
      printf '%s\n' "$*" >>"$log_file"
      case "${4:-}" in
        -l) printf '%s\n' "${5:-}" >"$pointer_composer_file" ;;
        Tab)
          cat "$pointer_composer_file" >"$pointer_queue_file"
          : >"$pointer_composer_file"
          ;;
      esac
      case "$*" in
        *BSpace*) : >"$pointer_composer_file" ;;
      esac
      ;;
    *) return 0 ;;
  esac
}
megabrain_tmux_session_exists() {
  return 0
}
dispatch_id=pointer-reply
create_meta "$dispatch_id" '%fake'
pointer_answer='answer body must stay in the queue'
pointer_output="$(megabrain_dispatch_reply "$dispatch_id" --text "$pointer_answer" --json)"
assert_equal "$(jq -r '.status' <<<"$pointer_output")" queued
typed="$(cat "$log_file")"
assert_contains "$typed" ' Tab'
assert_not_contains "$typed" ' Enter'
assert_equal "$(cat "$pointer_composer_file")" ''
assert_equal "$(cat "$pointer_queue_file")" '[megabrain] reply available; run megabrain check'
pointer_message="$state_root/state/dispatches/$dispatch_id/messages"/*.json
assert_equal "$(jq -r '.text' $pointer_message)" "$pointer_answer"
assert_contains "$(jq -r '.sessionId' $pointer_message)" ':'
pointer_transport_status="$(megabrain_tmux_send_nudge %fake 'codex pointer is queued' codex; printf '%s' "$MEGABRAIN_TMUX_SEND_STATUS")"
assert_equal "$pointer_transport_status" queued
printf 'reply transport: Tab queues the pointer and parent provenance is recorded\n'

# Claude and Codex have measured busy-pane affordances; agy stays on the durable queue path
# because its safe nudge affordance is not established here.
nudge_composer_file="$state_root/nudge-composer"
nudge_queue_file="$state_root/nudge-queue"
nudge_keys_file="$state_root/nudge-keys"
nudge_agent=claude
nudge_mode=accept
: >"$nudge_composer_file"
: >"$nudge_queue_file"
: >"$nudge_keys_file"
tmux() {
  local command="${1:-}" count
  case "$command" in
    display-message) printf '120\n' ;;
    send-keys)
      printf '%s\n' "$*" >>"$nudge_keys_file"
      if [ "${2:-}" = -N ]; then
        count="${3:-0}"
        if [ "${6:-}" = BSpace ]; then
          printf '%s\n' "backspaces=$count" >>"$nudge_keys_file"
          : >"$nudge_composer_file"
        fi
        return 0
      fi
      case "${4:-}" in
        -l)
          # The delay makes overlapping writers reproduce a pane-level race if no lock
          # serializes the complete text-plus-affordance transaction.
          sleep 0.1
          printf '%s' "${5:-}" >"$nudge_composer_file"
          ;;
        Enter)
          if [ "$nudge_agent" = claude ] && [ "$nudge_mode" = accept ]; then
            cat "$nudge_composer_file" >>"$nudge_queue_file"
            printf '\n' >>"$nudge_queue_file"
            : >"$nudge_composer_file"
          fi
          ;;
        Tab)
          if [ "$nudge_agent" = codex ] && [ "$nudge_mode" = accept ]; then
            cat "$nudge_composer_file" >>"$nudge_queue_file"
            printf '\n' >>"$nudge_queue_file"
            : >"$nudge_composer_file"
          fi
          ;;
      esac
      ;;
    *) return 0 ;;
  esac
}

busy_claude='claude reply queued separately from the busy composer'
nudge_agent=claude
nudge_mode=accept
: >"$nudge_composer_file"
: >"$nudge_queue_file"
busy_status="$(megabrain_tmux_send_nudge %busy "$busy_claude" claude; printf '%s' "$MEGABRAIN_TMUX_SEND_STATUS")"
assert_equal "$busy_status" queued
assert_equal "$(cat "$nudge_composer_file")" ''
assert_equal "$(cat "$nudge_queue_file")" "$busy_claude"
assert_contains "$(cat "$nudge_keys_file")" ' Enter'
assert_not_contains "$(cat "$nudge_keys_file")" ' Tab'
printf 'busy Claude: Enter queues the nudge\n'

# Codex's measured Tab affordance is distinct from agy's unknown composer.
nudge_agent=codex
nudge_mode=accept
: >"$nudge_composer_file"
: >"$nudge_queue_file"
: >"$nudge_keys_file"
unknown_status="$(megabrain_tmux_send_nudge %busy 'codex pointer is queued with Tab' codex; printf '%s' "$MEGABRAIN_TMUX_SEND_STATUS")"
assert_equal "$unknown_status" queued
assert_equal "$(cat "$nudge_composer_file")" ''
assert_equal "$(cat "$nudge_queue_file")" 'codex pointer is queued with Tab'
assert_contains "$(cat "$nudge_keys_file")" ' Tab'
printf 'Codex queue: Tab queues the nudge\n'

nudge_agent=agy
nudge_mode=accept
: >"$nudge_composer_file"
: >"$nudge_queue_file"
: >"$nudge_keys_file"
unknown_status="$(megabrain_tmux_send_nudge %busy 'agy pointer is not typed without a proven queue' agy; printf '%s' "$MEGABRAIN_TMUX_SEND_STATUS")"
assert_equal "$unknown_status" not-typed
assert_equal "$(cat "$nudge_composer_file")" ''
assert_equal "$(cat "$nudge_queue_file")" ''
assert_equal "$(cat "$nudge_keys_file")" ''
printf 'unknown agy queue: nudge is not typed\n'

# Two Claude nudges to one busy pane are independent queue entries, never one concatenated
# draft. The lock must cover both the literal and its Enter.
nudge_agent=claude
nudge_mode=accept
: >"$nudge_composer_file"
: >"$nudge_queue_file"
: >"$nudge_keys_file"
(
  megabrain_tmux_send_nudge %busy 'first concurrent nudge' claude
  printf '%s\n' "$MEGABRAIN_TMUX_SEND_STATUS" >"$state_root/first-status"
) &
first_pid=$!
(
  megabrain_tmux_send_nudge %busy 'second concurrent nudge' claude
  printf '%s\n' "$MEGABRAIN_TMUX_SEND_STATUS" >"$state_root/second-status"
) &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
assert_equal "$(wc -l <"$nudge_queue_file" | tr -d ' ')" 2
grep -Fx 'first concurrent nudge' "$nudge_queue_file" >/dev/null || fail 'first concurrent nudge was not a separate queue entry'
grep -Fx 'second concurrent nudge' "$nudge_queue_file" >/dev/null || fail 'second concurrent nudge was not a separate queue entry'
assert_equal "$(cat "$nudge_composer_file")" ''
assert_equal "$(cat "$state_root/first-status")" queued
assert_equal "$(cat "$state_root/second-status")" queued
printf 'concurrent busy pane: nudges remain ordered queue entries\n'

printf 'ok: bounded reply nudge scenarios\n'
