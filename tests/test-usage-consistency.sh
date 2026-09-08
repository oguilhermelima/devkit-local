#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-usage.XXXXXX")"

cleanup() {
  rm -rf "$state_dir"
  return 0
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir/state"
source "$root/lib/common.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "$3" ;;
  esac
}

# Group commands list their subcommands instead of documenting one invocation, and
# AGENTS.md spells the appium verbs out one per line, so neither has a doc entry.
no_doc_entry=' worktree chain model fact native-appium '

usage_keys() {
  awk '/^megabrain_usage_line\(\) \{/ { inside = 1; next }
       inside && /^\}/ { inside = 0 }
       inside' "$root/lib/common.sh" |
    sed -n 's/^    \([a-z][a-z-]*\)).*/\1/p'
}

agents_md="$(cat "$root/AGENTS.md")"
checked=0

while IFS= read -r key; do
  [ -n "$key" ] || continue
  line="$(megabrain_usage_line "$key")" || fail "no usage line for key: $key"

  # Keys are the command path with spaces replaced by dashes.
  read -r -a argv <<<"$(printf '%s' "$key" | tr '-' ' ')"
  if ! help_output="$("$root/megabrain" "${argv[@]}" --help 2>&1)"; then
    fail "megabrain ${argv[*]} --help exited non-zero"
  fi
  assert_contains "$help_output" "Usage: megabrain $line" \
    "help for '${argv[*]}' does not match the usage table: $help_output"

  case "$no_doc_entry" in
    *" $key "*) ;;
    *)
      assert_contains "$agents_md" "- Run megabrain $line." \
        "AGENTS.md has no entry matching the usage table for '$key'"
      ;;
  esac
  checked=$((checked + 1))
done < <(usage_keys)

[ "$checked" -ge 40 ] || fail "expected at least 40 usage keys, checked $checked"

# A missing argument must quote the same line the help prints, which is the drift
# that put three different close usages in one file.
close_error="$("$root/megabrain" orchestrate close 2>&1 || true)"
assert_contains "$close_error" "Usage: megabrain $(megabrain_usage_line orchestrate-close)" \
  "orchestrate close error text drifted from its help text: $close_error"

watch_error="$("$root/megabrain" orchestrate watch 2>&1 || true)"
assert_contains "$watch_error" "Usage: megabrain $(megabrain_usage_line orchestrate-watch)" \
  "orchestrate watch error text drifted from its help text: $watch_error"

printf 'ok: %s usage keys agree across help, errors, and AGENTS.md\n' "$checked"
