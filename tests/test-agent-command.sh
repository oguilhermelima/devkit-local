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

assert_equal() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
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

for command_text in 'codex' 'DEVKIT_NO_TMUX=1 codex' 'env FOO=1 codex'; do
  assembled="$(devkit_terminal_command_with_agent_permissions "$command_text")"
  printf 'permissions: %s\n' "$assembled"
  assert_contains "$assembled" --dangerously-bypass-approvals-and-sandbox
  case "$command_text" in
    'codex') assert_contains "$assembled" 'codex --' ;;
    'DEVKIT_NO_TMUX=1 codex') assert_contains "$assembled" 'DEVKIT_NO_TMUX=1 codex --' ;;
    'env FOO=1 codex') assert_contains "$assembled" 'env FOO=1 codex --' ;;
  esac
done

assert_equal "$(devkit_terminal_command_with_agent_permissions 'pnpm dev')" 'pnpm dev'
printf 'permissions: pnpm dev\n'

printf 'ok: agent command assembly excludes prompt and preserves passthrough quoting\n'
