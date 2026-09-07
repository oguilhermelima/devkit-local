#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$root/lib/common.sh"
source "$root/lib/module-tmux-runtime.sh"
source "$root/lib/module-parent-notify.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "expected command to fail: $*"
  fi
}

capture_mode=consumed
capture_index_file="$(mktemp "${TMPDIR:-/tmp}/devkit-delivery.XXXXXX")"
enter_count=0

cleanup() {
  rm -f "$capture_index_file"
}
trap cleanup EXIT

tmux() {
  if [ "${1:-}" = send-keys ]; then
    if [ "${*: -1}" = Enter ]; then
      enter_count=$((enter_count + 1))
    fi
    return 0
  fi
  return 1
}

devkit_tmux_capture_pane() {
  local capture_count
  capture_count="$(cat "$capture_index_file")"
  capture_count=$((capture_count + 1))
  printf '%s\n' "$capture_count" >"$capture_index_file"
  case "$capture_mode:$capture_count" in
    consumed:1|retry:1|tick:1) printf 'status 1\n› PING\n' ;;
    consumed:2|retry:3) printf 'status 2\n› \nWorking\n' ;;
    retry:2) printf 'status 2\n› PING\n' ;;
    tick:*) printf 'status %s\n› PING\n' "$capture_count" ;;
    *) printf 'status %s\n› \nWorking\n' "$capture_count" ;;
  esac
}

capture_mode=consumed
printf '0\n' >"$capture_index_file"
enter_count=0
devkit_tmux_send_text pane PING
assert_equal "$enter_count" 1
printf 'consumed input confirms delivery\n'

capture_mode=retry
printf '0\n' >"$capture_index_file"
enter_count=0
devkit_tmux_send_text pane PING
assert_equal "$enter_count" 2
printf 'Enter retries until consumed input is visible\n'

capture_mode=tick
printf '0\n' >"$capture_index_file"
enter_count=0
assert_failure devkit_tmux_send_text pane PING
assert_equal "$enter_count" "$DEVKIT_TMUX_ENTER_RETRIES"
printf 'status ticks cannot confirm delivery while input remains\n'

notify_used=false
devkit_tmux_send_text() {
  notify_used=true
  return 0
}
notify_meta="$(jq -cn '{parentTmuxPane:"%1"}')"
devkit_parent_notify_tmux "$notify_meta" pointer
assert_equal "$notify_used" true
printf 'parent notices use the shared delivery confirmation\n'

printf 'ok: prompt delivery confirmation scenarios\n'
