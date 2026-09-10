#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-dispatch-transcript.XXXXXX")"
live_sessions="$state_dir/live-sessions"
capture_log="$state_dir/capture.log"
release_log="$state_dir/release.log"
pipe_log="$state_dir/pipe.log"
active_pipe_path=''

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

assert_file() {
  [ -f "$1" ] || fail "expected file to exist: $1"
}

assert_missing() {
  [ ! -e "$1" ] || fail "expected path to be absent: $1"
}

export MEGABRAIN_STATE_DIR="$state_dir/state"
export SUPERSET_TERMINAL_ID=parent-terminal
unset TMUX TMUX_PANE
touch "$capture_log" "$pipe_log" "$release_log"

source "$root/lib/common.sh"
source "$root/lib/module-context.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-install.sh"

capture_output='captured dispatch transcript'
capture_available=true
pipe_start_available=true

megabrain_tmux_capture_pane() {
  local pane="$1" start="$2"
  printf '%s\t%s\n' "$pane" "$start" >>"$capture_log"
  [ "$capture_available" = true ] || return 1
  printf '%s\n' "$capture_output"
}

megabrain_tmux_pipe_pane_start() {
  local pane="$1" path="$2"
  printf 'start\t%s\t%s\n' "$pane" "$path" >>"$pipe_log"
  [ "$pipe_start_available" = true ] || return 1
  active_pipe_path="$path"
  printf '%s\n' "$capture_output" >>"$path"
}

megabrain_tmux_pipe_pane_stop() {
  local pane="$1"
  printf 'stop\t%s\n' "$pane" >>"$pipe_log"
  printf '%s\n' "$capture_output" >>"$active_pipe_path"
}

megabrain_tmux_session_exists() {
  grep -Fx "$1" "$live_sessions" >/dev/null 2>&1
}

megabrain_dispatch_close_refuse_caller() {
  return 0
}

megabrain_dispatch_native_close() {
  local meta="$1" session
  session="$(printf '%s' "$meta" | jq -r '.tmuxSession // empty')"
  printf '%s\n' "$session" >>"$release_log"
  if [ -f "$live_sessions" ]; then
    grep -Fvx "$session" "$live_sessions" >"$live_sessions.tmp" || true
    mv -f "$live_sessions.tmp" "$live_sessions"
  fi
}

write_dispatch() {
  local dispatch_id="$1" state="$2" session="$3"
  megabrain_dispatch_meta_write "$dispatch_id" parent-terminal superset superset workspace-test child-terminal \
    "$root" main codex label "$state" gpt-5 true codex "$session" "%99" tmux tmux \
    '' '' workspace-test >/dev/null
}

set_old_timestamp() {
  local dispatch_id="$1" path tmp
  path="$MEGABRAIN_DISPATCH_DIR/$dispatch_id/meta.json"
  tmp="$(mktemp "$MEGABRAIN_DISPATCH_DIR/$dispatch_id/.old.XXXXXX")"
  jq --arg old '2020-01-01T00:00:00Z' '.createdAt = $old | .updatedAt = $old' "$path" >"$tmp"
  mv -f "$tmp" "$path"
}

transcript_path() {
  printf '%s/transcript\n' "$(megabrain_dispatch_dir "$1")"
}

printf '%s\n' 'transition-session' >"$live_sessions"
write_dispatch transition-session running transition-session
megabrain_dispatch_start_transcript transition-session %99
assert_contains "$(cat "$pipe_log")" 'start	%99'
before_capture="$(wc -l <"$capture_log" | tr -d ' ')"
megabrain_dispatch_meta_update_state transition-session done
after_capture="$(wc -l <"$capture_log" | tr -d ' ')"
assert_equal "$after_capture" "$before_capture"
assert_file "$(transcript_path transition-session)"
assert_contains "$(cat "$(transcript_path transition-session)")" 'captured dispatch transcript'
printf 'dispatch start streams output without terminal-state snapshotting\n'

pipe_start_available=false
write_dispatch transition-missing running transition-missing
if megabrain_dispatch_start_transcript transition-missing %100 >/dev/null 2>&1; then
  fail 'transcript start succeeded when the pipe could not be started'
fi
assert_equal "$(jq -r '.state' "$MEGABRAIN_DISPATCH_DIR/transition-missing/meta.json")" running
printf 'dispatch start fails loudly when the pipe cannot be started\n'
capture_available=true
pipe_start_available=true

printf '%s\n' 'close-session' >"$live_sessions"
capture_output='final output before close'
write_dispatch close-session done close-session
megabrain_dispatch_start_transcript close-session %99
megabrain_dispatch_close close-session --json >/dev/null
assert_contains "$(cat "$(transcript_path close-session)")" 'final output before close'
assert_equal "$(jq -r '.state' "$MEGABRAIN_DISPATCH_DIR/close-session/meta.json")" closed
assert_contains "$(cat "$pipe_log")" 'stop'
printf 'close stops the persisted transcript stream before releasing tmux\n'

capture_available=false
write_dispatch read-fallback done read-fallback
printf '%s\n' 'persisted read output' >"$(transcript_path read-fallback)"
read_result="$(command_orchestrate read read-fallback --lines 20 --json)"
assert_equal "$(printf '%s' "$read_result" | jq -r '.source')" file
assert_equal "$(printf '%s' "$read_result" | jq -r '.text')" 'persisted read output'
printf 'read falls back to the persisted transcript and reports file source\n'
capture_available=true

printf '%s\n' 'doctor-leak' >"$live_sessions"
write_dispatch doctor-leak done doctor-leak
write_dispatch doctor-clean done doctor-clean
megabrain_runtime_enabled() { return 0; }
megabrain_tmux_available() { return 0; }
megabrain_require_command() { return 1; }
megabrain_superset_available() { return 1; }
module_orchestration_doctor >/dev/null 2>&1 || fail 'doctor rejected a healthy tmux-only setup'
assert_equal "$MODULE_LEAKED_DISPATCH_SESSIONS" 1
printf 'doctor counts one terminal dispatch session leak\n'
printf '%s\n' >"$live_sessions"
module_orchestration_doctor >/dev/null 2>&1 || fail 'doctor rejected a healthy tmux-only setup without leaks'
assert_equal "$MODULE_LEAKED_DISPATCH_SESSIONS" 0
printf 'doctor reports zero terminal dispatch session leaks when released\n'

capture_output='prune transcript'
printf '%s\n' 'prune-session' >"$live_sessions"
write_dispatch prune-session done prune-session
megabrain_dispatch_start_transcript prune-session %99
set_old_timestamp prune-session
prune_result="$(command_orchestrate prune --json)"
assert_equal "$(printf '%s' "$prune_result" | jq -r '.archived')" 1
assert_missing "$MEGABRAIN_DISPATCH_DIR/prune-session"
assert_equal "$(grep -c '^prune-session$' "$release_log")" 1
assert_contains "$(cat "$pipe_log")" 'stop'
if grep -Fx 'prune-session' "$live_sessions" >/dev/null 2>&1; then
  fail 'prune left the released tmux session alive'
fi
printf 'prune releases the tmux session after persisting its transcript\n'

printf '%s\n' 'open-session' >"$live_sessions"
write_dispatch open-session running open-session
set_old_timestamp open-session
prune_result="$(command_orchestrate prune --json)"
assert_equal "$(printf '%s' "$prune_result" | jq -r '.skippedDispatches[] | select(.dispatchId == "open-session") | .state')" running
assert_file "$MEGABRAIN_DISPATCH_DIR/open-session/meta.json"
assert_equal "$(grep -c '^open-session$' "$live_sessions")" 1
printf 'prune refuses an open dispatch and leaves its session alive\n'

printf 'ok: dispatch transcript persistence and session release\n'
