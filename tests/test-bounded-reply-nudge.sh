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

# A pane can repaint without accepting stdin. Pane movement is not proof that Enter submitted.
repaint_pane="$(tmux_cmd split-window -d -t "$session_name" -c "$root" -P -F '#{pane_id}' \
  "sh -c 'n=0; while :; do n=\$((n + 1)); printf \"\\033[2J\\033[HREPAINT %s\\n\\n\\n\" \"\$n\"; sleep 0.1; done'")"
repaint_answer='TEXTO QUE NAO SUBMETE'
repaint_output="$(megabrain_tmux_send_text "$repaint_pane" "$repaint_answer" claude; printf '%s' "$MEGABRAIN_TMUX_SEND_STATUS")"
assert_equal "$repaint_output" queued
repaint_capture="$(tmux_cmd capture-pane -p -J -t "$repaint_pane" -S -4)"
assert_not_contains "$repaint_capture" "$repaint_answer"
tmux_cmd kill-pane -t "$repaint_pane"
printf 'repainting pane: ignored activity, queued the nudge, and cleared the composer\n'

# A process that never reads stdin makes a long literal write exercise the real pty backpressure.
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
  sleep 0.1
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

# A non-codex pane must not receive the codex-only Tab fallback. Its composer is
# cleared after the failed Enter attempt, and the durable queue still owns the reply.
mock_mode=stuck
mock_pane_file="$state_root/mock-pane"
mock_keys="$state_root/mock-keys"
: >"$mock_keys"
printf 'draft\n' >"$mock_pane_file"
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
printf 'stuck composer: failed nudge is queued and composer is cleared\n'

# An accepting pane clears its composer after Enter and reports replied.
mock_mode=accept
printf 'draft\n' >"$mock_pane_file"
dispatch_id=accepted-reply
create_meta "$dispatch_id" '%accepted' codex
accepted_answer='reply accepted by codex composer'
accepted_output="$(megabrain_dispatch_reply "$dispatch_id" --text "$accepted_answer" --json)"
assert_equal "$(jq -r '.status' <<<"$accepted_output")" replied
assert_equal "$(cat "$mock_pane_file")" ''
accepted_message="$state_root/state/dispatches/$dispatch_id/messages"/*.json
assert_equal "$(find "$state_root/state/dispatches/$dispatch_id/messages" -name '*.json' | wc -l | tr -d ' ')" 1
assert_equal "$(jq -r '.text' $accepted_message)" "$accepted_answer"
printf 'accepted composer: Enter reports replied and keeps one queue message\n'

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
assert_equal "$second_output" replied
assert_equal "$(cat "$second_composer_file")" ''
printf 'similar second nudge: transcript text did not override the composer result\n'

# The durable answer is long, but the transport must type only a short pull pointer.
log_file="$state_root/tmux-send.log"
tmux() {
  case "${1:-}" in
    display-message) printf '%s\n' "$session_name" ;;
    send-keys) printf '%s\n' "$*" >>"$log_file" ;;
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

printf 'ok: bounded reply nudge scenarios\n'
