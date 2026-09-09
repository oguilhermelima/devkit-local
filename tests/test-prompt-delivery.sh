#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-receipt.XXXXXX")"

cleanup() {
  rm -rf "$state_dir"
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir"
export ORCA_TERMINAL_HANDLE=parent-terminal
unset SUPERSET_TERMINAL_ID
source "$root/lib/common.sh"
source "$root/lib/module-tmux-runtime.sh"
source "$root/lib/module-parent-notify.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-worktree.sh"

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

create_dispatch() {
  local dispatch_id="$1" state="$2" terminal_id="${3:-child-terminal}"
  megabrain_dispatch_meta_write "$dispatch_id" parent-terminal orca orca "" "$terminal_id" "$root" fix/prompt-delivery-proof codex label "$state" gpt-5 true codex "" "" host ide >/dev/null
}

create_dispatch stalled-report spawning
megabrain_dispatch_message_append stalled-report child stalled 'child could not run the dispatch command' child-terminal >/dev/null
megabrain_spawn_mark_prompt_failed stalled-report prompt-send-not-observed
failure_output="$(megabrain_dispatch_failure_error stalled-report 'dispatch did not observe prompt send' 2>&1)"
assert_contains "$failure_output" 'child message: "child could not run the dispatch command"'
assert_equal "$(jq -r '.state' "$state_dir/dispatches/stalled-report/meta.json")" failed
printf 'failed dispatch reports the child stalled message\n'

# A turn-end hook is evidence that a child turn ended, not evidence that this prompt
# reached it. An empty turn must remain pending rather than becoming a receipt.
create_dispatch empty-turn running
env -u SUPERSET_TERMINAL_ID -u TMUX -u TMUX_PANE ORCA_TERMINAL_HANDLE=child-terminal MEGABRAIN_DISPATCH_ID=empty-turn MEGABRAIN_HOOK_AGENT=codex \
  "$root/hooks/megabrain-turn-end.sh" '{"last_assistant_message":""}' >/dev/null
assert_equal "$(jq -r '.promptDelivery' "$state_dir/dispatches/empty-turn/meta.json")" pending
assert_equal "$(jq -r '.state' "$state_dir/dispatches/empty-turn/meta.json")" stalled
printf 'empty child turn does not confirm prompt delivery\n'

# The explicit command remains optional while delivery is observed mechanically by the transport.
create_dispatch optional-receipt spawning command-terminal
received_output="$(env -u SUPERSET_TERMINAL_ID -u TMUX -u TMUX_PANE ORCA_TERMINAL_HANDLE=command-terminal MEGABRAIN_STATE_DIR="$state_dir" \
  "$root/megabrain" received)"
assert_equal "$received_output" 'received sent: optional-receipt'
received_message="$state_dir/dispatches/optional-receipt/messages/0001-child-received.json"
[ -f "$received_message" ] || fail 'received command did not leave a durable message'
assert_equal "$(jq -r '.type' "$received_message")" received
assert_equal "$(jq -r '.state' "$state_dir/dispatches/optional-receipt/meta.json")" spawning
printf 'received command remains optional and durable\n'

tmux_mode=unresponsive
tmux_enter_count=0
tmux_draft_file="$state_dir/tmux-draft"
tmux_capture_file="$state_dir/tmux-captures"
: >"$tmux_draft_file"
printf '0\n' >"$tmux_capture_file"
tmux() {
  local command="${1:-}" count
  case "$command" in
    send-keys)
      if [ "${4:-}" = -l ]; then
        printf '%s\n' "${5:-}" >"$tmux_draft_file"
      fi
      if [ "${4:-}" = Enter ]; then
        tmux_enter_count=$((tmux_enter_count + 1))
      fi
      return 0
      ;;
    capture-pane)
      count="$(cat "$tmux_capture_file")"
      count=$((count + 1))
      printf '%s\n' "$count" >"$tmux_capture_file"
      if [ "$tmux_mode" = responsive ] && [ "$count" -ge 1 ]; then
        printf 'submitted\n'
      else
        printf 'composer '
        cat "$tmux_draft_file"
      fi
      return 0
      ;;
    *) return 1 ;;
  esac
}
megabrain_tmux_session_exists() {
  return 0
}
export MEGABRAIN_TMUX_ENTER_RETRIES=2
export MEGABRAIN_TMUX_ENTER_RETRIES=3
export MEGABRAIN_TMUX_ENTER_WAIT=0
tmux_mode=unresponsive
tmux_enter_count=0
printf '0\n' >"$tmux_capture_file"
megabrain_tmux_send_text %1 'unresponsive message'
assert_equal "$tmux_enter_count" 3
printf 'message delivery: unresponsive pane receives bounded Enter retries\n'

tmux_mode=responsive
tmux_enter_count=0
printf '0\n' >"$tmux_capture_file"
megabrain_tmux_send_text %1 'responsive message'
assert_equal "$tmux_enter_count" 1
printf 'message delivery: responsive pane stops after the first Enter\n'

# pane_current_command proves that the agent process exists, not that its composer
# accepts input. This fake keeps reporting codex while MCP startup is visible and
# exposes Codex's measured idle-composer text only on the third capture.
readiness_capture_count=0
readiness_send_log="$state_dir/readiness-sends"
readiness_capture_file="$state_dir/readiness-captures"
: >"$readiness_send_log"
printf '0\n' >"$readiness_capture_file"
tmux() {
  local command="${1:-}" format="${5:-}" capture_count
  case "$command" in
    display-message)
      case "$format" in
        '#{pane_current_command}') printf 'codex\n' ;;
        '#{pane_height}') printf '20\n' ;;
        *) return 1 ;;
      esac
      return 0
      ;;
    send-keys)
      if [ "${4:-}" = -l ]; then
        capture_count="$(cat "$readiness_capture_file")"
        printf '%s\t%s\n' "$([ "$capture_count" -ge 3 ] && printf ready || printf starting)" "${5:-}" >>"$readiness_send_log"
      fi
      return 0
      ;;
    capture-pane)
      capture_count="$(cat "$readiness_capture_file")"
      capture_count=$((capture_count + 1))
      printf '%s\n' "$capture_count" >"$readiness_capture_file"
      if [ "$capture_count" -ge 3 ]; then
        printf '› Ask Codex to do anything\n'
      else
        printf 'Starting MCP servers (2/4): codex_apps, playwright\n'
      fi
      return 0
      ;;
    *) return 1 ;;
  esac
}
export MEGABRAIN_TMUX_SETTLE_ATTEMPTS=3
export MEGABRAIN_TMUX_SETTLE_SECONDS=0
megabrain_tmux_settle_pane %1 codex || fail 'pane readiness unexpectedly timed out'
megabrain_tmux_send_agent %1 'prompt sent only after composer readiness' prompt || fail 'ready fake pane rejected prompt'
assert_equal "$(sed -n '1p' "$readiness_send_log" | cut -f1)" ready
assert_equal "$(sed -n '1p' "$readiness_send_log" | cut -f2-)" 'prompt sent only after composer readiness'
printf 'composer readiness: prompt waits for Codex idle-composer signal\n'

create_dispatch running-reply running
reply_result="$(megabrain_dispatch_reply running-reply --text 'Continue work' --json)"
assert_equal "$(jq -r '.status' <<<"$reply_result")" queued
reply_message="$(find "$state_dir/dispatches/running-reply/messages" -name '*.json' -print -quit)"
assert_equal "$(jq -r '.type' "$reply_message")" reply
assert_equal "$(jq -r '.text' "$reply_message")" 'Continue work'
printf 'running child accepts queued parent reply\n'

printf 'ok: receipt delivery and running reply scenarios\n'
