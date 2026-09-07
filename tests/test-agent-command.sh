#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$root/lib/common.sh"
source "$root/lib/module-worktree.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected '$1' to contain '$2'" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected '$1' not to contain '$2'" ;;
    *) ;;
  esac
}

prompt='Inspect this prompt only after readiness'
for agent in codex claude agy; do
  command_text="$(devkit_agent_command "$agent" gpt-5 high --extra-flag 'value with spaces')"
  printf '%s: %s\n' "$agent" "$command_text"
  assert_contains "$command_text" gpt-5
  assert_contains "$command_text" high
  assert_contains "$command_text" --extra-flag
  assert_contains "$command_text" 'value\ with\ spaces'
  assert_not_contains "$command_text" "$prompt"
done

printf 'ok: agent command assembly excludes prompt and preserves passthrough quoting\n'
