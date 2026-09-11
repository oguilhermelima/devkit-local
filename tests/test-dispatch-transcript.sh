#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_state_dir="${MEGABRAIN_STATE_DIR:-${HOME:-/tmp}/.megabrain}"
real_transcript=''
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

for candidate in "$source_state_dir"/dispatches/*/transcript; do
  [ -f "$candidate" ] || continue
  if LC_ALL=C grep -Fq 'Worktree:' "$candidate" &&
    LC_ALL=C grep -Fq 'DEFECT A' "$candidate" &&
    LC_ALL=C grep -Fq 'refusing to delete' "$candidate"; then
    real_transcript="$candidate"
    break
  fi
done

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

megabrain_dispatch_terminal_status() {
  MEGABRAIN_TERMINAL_STATUS=proven
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

capture_output='first streamed output'
write_dispatch reconnect-session running reconnect-session
megabrain_dispatch_start_transcript reconnect-session %99
capture_output='second streamed output'
megabrain_dispatch_start_transcript reconnect-session %99
assert_contains "$(cat "$(transcript_path reconnect-session)")" 'first streamed output'
assert_contains "$(cat "$(transcript_path reconnect-session)")" 'second streamed output'
printf 'transcript stream appends output across reconnect\n'

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

write_dispatch rendered-fallback done rendered-fallback
printf 'old one\nold two\n\033[2A\033[2K\033]0;ignored title\007\033[?2026h\033[1mfinal one\033[0m\033[1B\033[1G\033[2Kfinal two\033[?2026l\nplain three\n' >"$(transcript_path rendered-fallback)"
cp "$(transcript_path rendered-fallback)" "$state_dir/rendered-fallback.raw"
scenario_failures=0
scenario_equal() {
  if [ "$1" != "$2" ]; then
    printf 'SCENARIO FAIL: expected %s, got %s\n' "$2" "$1" >&2
    scenario_failures=$((scenario_failures + 1))
  fi
}

scenario_not_contains() {
  case "$1" in
    *"$2"*)
      printf 'SCENARIO FAIL: did not expect %s in %s\n' "$2" "$1" >&2
      scenario_failures=$((scenario_failures + 1))
      ;;
  esac
}

rendered_result="$(command_orchestrate read rendered-fallback --lines 3 --json)"
assert_equal "$(printf '%s' "$rendered_result" | jq -r '.source')" file
if ! cmp -s "$(transcript_path rendered-fallback)" "$state_dir/rendered-fallback.raw"; then
  fail 'rendering changed the persisted transcript'
fi
scenario_equal "$(printf '%s' "$rendered_result" | jq -r '.text')" $'final one\nfinal two\nplain three'
scenario_not_contains "$(printf '%s' "$rendered_result" | jq -r '.text')" 'old one'
scenario_not_contains "$(printf '%s' "$rendered_result" | jq -r '.text')" 'ignored title'
if [ "$scenario_failures" -ne 0 ]; then
  printf 'observed %s rendering scenario failure(s) before implementation\n' "$scenario_failures"
fi
printf 'read renders terminal controls and keeps the final overwritten lines\n'

limited_result="$(command_orchestrate read rendered-fallback --lines 2 --json)"
scenario_equal "$(printf '%s' "$limited_result" | jq -r '.text')" $'final one\nfinal two\nplain three'
scenario_equal "$(printf '%s' "$limited_result" | jq -r '.text | split("\n") | length')" 3
if [ "$scenario_failures" -ne 0 ]; then
  printf 'observed %s transcript scenario failure(s) before implementation\n' "$scenario_failures"
  fail 'transcript rendering scenarios failed'
fi
printf 'read keeps complete rendered history\n'

if [ -n "$real_transcript" ]; then
  write_dispatch rendered-history done rendered-history
  dd if="$real_transcript" of="$(transcript_path rendered-history)" bs=1 count=8500000 2>/dev/null ||
    fail 'could not copy the real transcript slice'
  history_result="$(command_orchestrate read rendered-history --lines 1000 --json)"
  history_text="$(printf '%s' "$history_result" | jq -r '.text')"
  assert_contains "$history_text" 'Worktree:'
  assert_contains "$history_text" 'DEFECT A'
  assert_contains "$history_text" 'refusing to delete'
  history_worktree_line="$(printf '%s\n' "$history_text" | awk '/Worktree:/ && !found { print NR; found=1 }')"
  history_defect_line="$(printf '%s\n' "$history_text" | awk '/DEFECT A/ && !found { print NR; found=1 }')"
  history_refusal_line="$(printf '%s\n' "$history_text" | awk '/refusing to delete/ && !found { print NR; found=1 }')"
  [ "$history_worktree_line" -lt "$history_defect_line" ] || fail 'rendered history reordered Worktree and DEFECT A'
  [ "$history_defect_line" -lt "$history_refusal_line" ] || fail 'rendered history reordered DEFECT A and refusal'
  printf 'read preserves scrolled history from a real transcript slice in order\n'
else
  printf 'read history scenario skipped because no suitable real transcript is available\n'
fi

capture_available=true
capture_output='live pane already rendered'
write_dispatch read-live done read-live
live_result="$(command_orchestrate read read-live --lines 20 --json)"
assert_equal "$(printf '%s' "$live_result" | jq -r '.source')" tmux
assert_equal "$(printf '%s' "$live_result" | jq -r '.text')" 'live pane already rendered'
printf 'read keeps the live pane rendering path\n'

write_dispatch plain-fallback done plain-fallback
printf '%s\n' 'plain transcript one' 'plain transcript two' >"$(transcript_path plain-fallback)"
capture_available=false
plain_result="$(command_orchestrate read plain-fallback --lines 20 --json)"
assert_equal "$(printf '%s' "$plain_result" | jq -r '.text')" $'plain transcript one\nplain transcript two'
printf 'read passes through an already plain transcript\n'
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

printf '%s\n' 'shared-session' >"$live_sessions"
regression_failures=0
assert_regression_equal() {
  if [ "$1" != "$2" ]; then
    printf 'REGRESSION FAIL: expected %s, got %s\n' "$2" "$1" >&2
    regression_failures=$((regression_failures + 1))
  fi
}

megabrain_dispatch_meta_write shared-session parent-terminal superset superset workspace-test child-terminal \
  "$root" main codex label done gpt-5 true codex shared-session %98 tmux tmux shared-session %0 workspace-test >/dev/null
set_old_timestamp shared-session
module_orchestration_doctor >/dev/null 2>&1 || fail 'doctor rejected a shared tmux setup'
assert_regression_equal "$MODULE_LEAKED_DISPATCH_SESSIONS" 0
shared_result="$(command_orchestrate prune --json)"
assert_regression_equal "$(printf '%s' "$shared_result" | jq -r '.archived')" 1
assert_file "$MEGABRAIN_DISPATCH_DIR/archive/$(date -u '+%Y-%m')/shared-session/meta.json"
if ! grep -Fx 'shared-session' "$live_sessions" >/dev/null 2>&1; then
  printf 'REGRESSION FAIL: prune released the parent-owned tmux session\n' >&2
  regression_failures=$((regression_failures + 1))
fi
if grep -Fx 'shared-session' "$release_log" >/dev/null 2>&1; then
  printf 'REGRESSION FAIL: prune invoked release for the parent-owned tmux session\n' >&2
  regression_failures=$((regression_failures + 1))
fi
printf 'shared parent tmux sessions are not counted or released\n'

printf '%s\n' 'caller-session' >"$live_sessions"
megabrain_dispatch_tmux_caller_session() {
  printf '%s\n' 'caller-session'
}
export TMUX=caller-server TMUX_PANE=%0
megabrain_dispatch_meta_write caller-session-record parent-terminal superset superset workspace-test child-terminal \
  "$root" main codex label done gpt-5 true codex caller-session %99 tmux tmux other-session %1 workspace-test >/dev/null
set_old_timestamp caller-session-record
module_orchestration_doctor >/dev/null 2>&1 || fail 'doctor rejected a caller session setup'
assert_regression_equal "$MODULE_LEAKED_DISPATCH_SESSIONS" 0
caller_result="$(command_orchestrate prune --json)"
assert_regression_equal "$(printf '%s' "$caller_result" | jq -r '.archived')" 1
assert_file "$MEGABRAIN_DISPATCH_DIR/archive/$(date -u '+%Y-%m')/caller-session-record/meta.json"
if ! grep -Fx 'caller-session' "$live_sessions" >/dev/null 2>&1; then
  printf 'REGRESSION FAIL: prune released the caller tmux session\n' >&2
  regression_failures=$((regression_failures + 1))
fi
if grep -Fx 'caller-session' "$release_log" >/dev/null 2>&1; then
  printf 'REGRESSION FAIL: prune invoked release for the caller tmux session\n' >&2
  regression_failures=$((regression_failures + 1))
fi
printf 'caller tmux sessions are never counted or released\n'
[ "$regression_failures" -eq 0 ] || fail 'session ownership regressions detected'

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

printf '%s\n' 'unproven-session' >"$live_sessions"
write_dispatch unproven-session done unproven-session
touch "$(transcript_path unproven-session)"
set_old_timestamp unproven-session
megabrain_dispatch_terminal_status() {
  MEGABRAIN_TERMINAL_STATUS=unknown
}
unproven_prune_result="$(command_orchestrate prune --json)"
assert_equal "$(printf '%s' "$unproven_prune_result" | jq -r '.archived')" 1
if grep -Fx 'unproven-session' "$live_sessions" >/dev/null 2>&1; then
  :
else
  fail 'prune released an unproven terminal identity'
fi
if grep -Fx 'unproven-session' "$release_log" >/dev/null 2>&1; then
  fail 'prune released an unproven terminal identity'
fi
printf 'prune leaves a terminal with unproven identity alive\n'

printf 'ok: dispatch transcript persistence and session release\n'
