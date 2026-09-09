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

# tmux transport is best effort only. It does not inspect the TUI or claim that Enter
# submitted the text; durable dispatch delivery is confirmed by a child receipt.
repaint_pane='%repaint'
repaint_composer_file="$state_root/repaint-composer"
repaint_count=0
: >"$repaint_composer_file"
tmux() {
  local command="${1:-}"
  case "$command" in
    capture-pane)
      repaint_count=$((repaint_count + 1))
      printf 'REPAINT %s\n' "$repaint_count"
      cat "$repaint_composer_file"
      ;;
    send-keys)
      case "${4:-}" in
        -l) printf '%s\n' "${5:-}" >"$repaint_composer_file" ;;
        C-e) : ;;
      esac
      case "$*" in
        *BSpace*) : >"$repaint_composer_file" ;;
      esac
      return 0
      ;;
    *) return 0 ;;
  esac
}
repaint_answer='TEXTO QUE NAO SUBMETE'
repaint_output="$(megabrain_tmux_send_text "$repaint_pane" "$repaint_answer" claude; printf '%s' "$MEGABRAIN_TMUX_SEND_STATUS")"
assert_equal "$repaint_output" not-typed
repaint_capture="$(cat "$repaint_composer_file")"
assert_equal "$repaint_capture" ''
printf 'tmux transport: failed nudge leaves no composer draft\n'
unset -f tmux

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

# A non-codex pane must not receive the codex-only Tab fallback. The transport does not
# clear or inspect the composer; the durable queue owns the reply.
mock_mode=stuck
mock_pane_file="$state_root/mock-pane"
mock_keys="$state_root/mock-keys"
: >"$mock_keys"
: >"$mock_pane_file"
tmux() {
  local command="${1:-}"
  case "$command" in
    display-message) printf '%s\n' "$session_name" ;;
    capture-pane) cat "$mock_pane_file" ;;
    send-keys)
      printf '%s\n' "$*" >>"$mock_keys"
      case "${4:-}" in
        -l) printf '%s\n' "${5:-}" >"$mock_pane_file" ;;
        C-e) : ;;
        Tab)
          if [ "$mock_mode" = accept ]; then : >"$mock_pane_file"; fi
          ;;
        Enter)
          if [ "$mock_mode" = accept ]; then : >"$mock_pane_file"; fi
          ;;
      esac
      case "$*" in
        *BSpace*) : >"$mock_pane_file" ;;
      esac
      return 0
      ;;
    *) return 0 ;;
  esac
}
megabrain_tmux_session_exists() {
  return 0
}
export MEGABRAIN_TMUX_ENTER_WAIT=0

dispatch_id=stuck-reply
create_meta "$dispatch_id" '%stuck' claude
stuck_answer='reply stays durable when claude composer does not submit'
stuck_output="$(megabrain_dispatch_reply "$dispatch_id" --text "$stuck_answer" --json)"
assert_equal "$(jq -r '.status' <<<"$stuck_output")" queued
assert_equal "$(cat "$mock_pane_file")" ''
assert_not_contains "$(cat "$mock_keys")" 'Tab'
stuck_message="$state_root/state/dispatches/$dispatch_id/messages"/*.json
assert_equal "$(find "$state_root/state/dispatches/$dispatch_id/messages" -name '*.json' | wc -l | tr -d ' ')" 1
assert_equal "$(jq -r '.text' $stuck_message)" "$stuck_answer"
printf 'stuck composer: nudge is queued without claiming delivery\n'

# An accepting pane is still only a queued transport send; only a child receipt proves delivery.
mock_mode=accept
printf 'draft\n' >"$mock_pane_file"
dispatch_id=accepted-reply
create_meta "$dispatch_id" '%accepted' codex
accepted_answer='reply accepted by codex composer'
accepted_output="$(megabrain_dispatch_reply "$dispatch_id" --text "$accepted_answer" --json)"
assert_equal "$(jq -r '.status' <<<"$accepted_output")" queued
assert_equal "$(cat "$mock_pane_file")" ''
accepted_message="$state_root/state/dispatches/$dispatch_id/messages"/*.json
assert_equal "$(find "$state_root/state/dispatches/$dispatch_id/messages" -name '*.json' | wc -l | tr -d ' ')" 1
assert_equal "$(jq -r '.text' $accepted_message)" "$accepted_answer"
printf 'accepted composer: Enter remains best effort and keeps one queue message\n'

# A prior pointer in the transcript must not make a similar, newly submitted pointer look queued.
second_composer_file="$state_root/second-composer"
second_transcript='megabrain check --timeout 120 dispatch-old'
second_answer='megabrain check --timeout 120 dispatch-new'
: >"$second_composer_file"
mock_mode=accept
tmux() {
  local command="${1:-}" pane_output
  case "$command" in
    display-message) printf '%s\n' "$session_name" ;;
    capture-pane)
      pane_output="$(
        printf '%s\n' "$second_transcript"
        printf 'history filler\n%.0s' 1 2 3 4 5 6
        cat "$second_composer_file"
      )"
      case "$*" in
        *'-S -4'*) printf '%s\n' "$pane_output" | tail -n 4 ;;
        *) printf '%s\n' "$pane_output" ;;
      esac
      ;;
    send-keys)
      case "${4:-}" in
        -l) printf '%s\n' "${5:-}" >"$second_composer_file" ;;
        Enter)
          if [ "$mock_mode" = accept ]; then : >"$second_composer_file"; fi
          ;;
        C-e) : ;;
      esac
      case "$*" in
        *BSpace*) : >"$second_composer_file" ;;
      esac
      return 0
      ;;
    *) return 0 ;;
  esac
}
second_output="$(megabrain_tmux_send_text %second "$second_answer" claude; printf '%s' "$MEGABRAIN_TMUX_SEND_STATUS")"
assert_equal "$second_output" queued
assert_equal "$(cat "$second_composer_file")" ''
printf 'similar second nudge: transport does not inspect transcript text\n'

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

# The durable answer is long, but the transport must type only a short pull pointer.
log_file="$state_root/tmux-send.log"
pointer_composer_file="$state_root/pointer-composer"
: >"$pointer_composer_file"
tmux() {
  case "${1:-}" in
    display-message) printf '%s\n' "$session_name" ;;
    capture-pane) cat "$pointer_composer_file" ;;
    send-keys)
      printf '%s\n' "$*" >>"$log_file"
      case "${4:-}" in
        -l) printf '%s\n' "${5:-}" >"$pointer_composer_file" ;;
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
assert_contains "$typed" 'megabrain check'
assert_not_contains "$typed" "$pointer_answer"
pointer_message="$state_root/state/dispatches/$dispatch_id/messages"/*.json
assert_equal "$(jq -r '.text' $pointer_message)" "$pointer_answer"
assert_contains "$(jq -r '.sessionId' $pointer_message)" ':'
printf 'reply transport: pointer excludes the answer and parent provenance is recorded\n'

# A busy Codex pane ignores Enter, but its documented Tab affordance queues the current
# input. A failed affordance must remove exactly the text this call typed, leaving no draft.
nudge_composer_file="$state_root/nudge-composer"
nudge_queue_file="$state_root/nudge-queue"
nudge_keys_file="$state_root/nudge-keys"
nudge_agent=codex
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
          else
            return 1
          fi
          ;;
        -N)
          count="${3:-0}"
          if [ "${6:-}" = BSpace ]; then
            printf '%s\n' "backspaces=$count" >>"$nudge_keys_file"
            : >"$nudge_composer_file"
          fi
          ;;
      esac
      ;;
    *) return 0 ;;
  esac
}

busy_codex='codex reply queued separately from the busy composer'
nudge_agent=codex
nudge_mode=accept
: >"$nudge_composer_file"
: >"$nudge_queue_file"
busy_status="$(megabrain_tmux_send_nudge %busy "$busy_codex" codex; printf '%s' "$MEGABRAIN_TMUX_SEND_STATUS")"
assert_equal "$busy_status" queued
assert_equal "$(cat "$nudge_composer_file")" ''
assert_equal "$(cat "$nudge_queue_file")" "$busy_codex"
assert_contains "$(cat "$nudge_keys_file")" ' Tab'
assert_not_contains "$(cat "$nudge_keys_file")" ' Enter'
printf 'busy Codex: Tab queues the nudge while Enter is ignored\n'

failed_codex='codex text is removed when its queue affordance fails'
nudge_agent=codex
nudge_mode=reject
: >"$nudge_composer_file"
: >"$nudge_queue_file"
: >"$nudge_keys_file"
failed_status="$(megabrain_tmux_send_nudge %busy "$failed_codex" codex; printf '%s' "$MEGABRAIN_TMUX_SEND_STATUS")"
assert_equal "$failed_status" not-typed
assert_equal "$(cat "$nudge_composer_file")" ''
assert_equal "$(cat "$nudge_queue_file")" ''
assert_contains "$(cat "$nudge_keys_file")" 'backspaces='
assert_not_contains "$(cat "$nudge_keys_file")" ' C-u'
printf 'failed Codex queue: exactly typed text is removed\n'

claude_nudge='claude Enter queues a busy follow-up'
nudge_agent=claude
nudge_mode=accept
: >"$nudge_composer_file"
: >"$nudge_queue_file"
: >"$nudge_keys_file"
claude_status="$(megabrain_tmux_send_nudge %busy "$claude_nudge" claude; printf '%s' "$MEGABRAIN_TMUX_SEND_STATUS")"
assert_equal "$claude_status" queued
assert_equal "$(cat "$nudge_composer_file")" ''
assert_equal "$(cat "$nudge_queue_file")" "$claude_nudge"
assert_contains "$(cat "$nudge_keys_file")" ' Enter'
assert_not_contains "$(cat "$nudge_keys_file")" ' Tab'
printf 'busy Claude: Enter queues the nudge\n'

# No affordance has been established for agy. It is safer to leave the durable queue as
# the only path than to put an unsubmitted pointer into an unknown composer.
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

# Two nudges to one busy pane are independent queue entries, never one concatenated draft.
nudge_agent=codex
nudge_mode=accept
: >"$nudge_composer_file"
: >"$nudge_queue_file"
: >"$nudge_keys_file"
(
  megabrain_tmux_send_nudge %busy 'first concurrent nudge' codex
  printf '%s\n' "$MEGABRAIN_TMUX_SEND_STATUS" >"$state_root/first-status"
) &
first_pid=$!
(
  megabrain_tmux_send_nudge %busy 'second concurrent nudge' codex
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
