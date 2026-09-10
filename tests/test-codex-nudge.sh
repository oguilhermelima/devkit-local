#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-codex-nudge.XXXXXX")"
composer="$state_dir/composer"
queued="$state_dir/queued"
keys="$state_dir/keys"

cleanup() {
  rm -rf "$state_dir"
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir"
source "$root/lib/common.sh"
source "$root/lib/module-tmux-runtime.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

# The affordance must be explicit. An empty result is also what an unexecuted path
# produces, so the assertion below is paired with the fake pane's queue signal.
assert_equal "$(megabrain_tmux_nudge_affordance codex 2>/dev/null || true)" Tab

for codex_mode in busy idle; do
  : >"$composer"
  : >"$queued"
  : >"$keys"
  tmux() {
    local command="${1:-}"
    case "$command" in
      display-message)
        printf '120\n'
        ;;
      send-keys)
        if [ "${4:-}" = -l ]; then
          printf '%s' "${5:-}" >>"$composer"
        elif [ "${4:-}" = Tab ]; then
          printf '%s\n' "$codex_mode:Tab" >>"$keys"
          cat "$composer" >"$queued"
          : >"$composer"
        else
          fail "unexpected tmux key: ${4:-}"
        fi
        ;;
      *)
        fail "unexpected tmux command: $command"
        ;;
    esac
  }

  pointer="mail: megabrain orchestrate watch codex-$codex_mode"
  megabrain_tmux_send_nudge %codex "$pointer" codex
  assert_equal "$MEGABRAIN_TMUX_SEND_STATUS" queued
  assert_equal "$(cat "$keys")" "$codex_mode:Tab"
  assert_equal "$(cat "$queued")" "$pointer"
  assert_equal "$(cat "$composer")" ''
  printf 'codex %s nudge: Tab queued the pointer and cleared the composer\n' "$codex_mode"
done

printf 'ok: Codex nudge has an explicit queue affordance\n'
