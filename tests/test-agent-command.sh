#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$root/lib/common.sh"
source "$root/lib/module-tmux-runtime.sh"
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

assert_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "expected command to fail: $*"
  fi
}

prompt='Inspect this prompt only after readiness'
for agent in codex claude; do
  command_text="$(devkit_agent_command "$agent" gpt-5 high --extra-flag 'value with spaces')"
  printf '%s: %s\n' "$agent" "$command_text"
  assert_contains "$command_text" gpt-5
  assert_contains "$command_text" high
  assert_contains "$command_text" --extra-flag
  assert_contains "$command_text" 'value\ with\ spaces'
  assert_not_contains "$command_text" "$prompt"
done

agy_command="$(devkit_agent_command agy gemini-3.8-flash high --extra-flag 'value with spaces')"
printf 'agy: %s\n' "$agy_command"
assert_contains "$agy_command" --model
assert_contains "$agy_command" gemini-3.8-flash-high
assert_contains "$agy_command" 'value\ with\ spaces'
assert_not_contains "$agy_command" --effort
assert_not_contains "$agy_command" "$prompt"

agy_low_command="$(devkit_agent_command agy gemini-3.8-flash-high low)"
assert_contains "$agy_low_command" gemini-3.8-flash-low
assert_not_contains "$agy_low_command" --effort

assert_failure devkit_agent_command agy claude-sonnet-4-6 high
invalid_agy_error="$(devkit_agent_command agy claude-sonnet-4-6 high 2>&1 >/dev/null || true)"
assert_contains "$invalid_agy_error" 'gemini-3.8-flash-high'
assert_contains "$invalid_agy_error" 'gpt-oss-120b-medium'
printf 'agy invalid effort: refused with valid model ids\n'

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

tmux_display_count_file="$(mktemp "${TMPDIR:-/tmp}/devkit-agent-command.XXXXXX")"
printf '0\n' >"$tmux_display_count_file"
trap 'rm -f "$tmux_display_count_file"' EXIT
tmux() {
  local display_count
  case "$1" in
    send-keys) return 0 ;;
    display-message)
      display_count="$(cat "$tmux_display_count_file")"
      display_count=$((display_count + 1))
      printf '%s\n' "$display_count" >"$tmux_display_count_file"
      if [ "$display_count" -ge 6 ]; then
        printf 'agy\n'
      else
        printf 'bash\n'
      fi
      ;;
    capture-pane)
      printf '%s\n' '--effort is not supported for model gemini-2.5-pro. Using Gemini 3.8 Flash (High) instead.'
      ;;
    *) return 1 ;;
  esac
}

export DEVKIT_TMUX_ENTER_TIMEOUT_SECONDS=2
export DEVKIT_TMUX_ENTER_WAIT=0
devkit_tmux_send_agent '%1' 'agy'
printf 'tmux launch wait: delayed agent evidence accepted\n'
substitution_report="$(devkit_tmux_model_substitution_report '%1')"
assert_contains "$substitution_report" 'not supported for model'
assert_contains "$substitution_report" 'instead'
printf 'model substitution: startup warning surfaced\n'

printf 'ok: agent command assembly excludes prompt and preserves passthrough quoting\n'
