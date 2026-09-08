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

# The skill is what a fresh agent session actually reads, and it is the piece that
# went stale unnoticed: it documented chain list but never chain run, so sessions
# picked an agent and model by hand. It may shorten a usage line for readability, but
# it must never name a flag the command does not have.
skill="$root/skills/megabrain/SKILL.md"
[ -f "$skill" ] || fail "the skill is missing: $skill"

skill_key() {
  local first="$1" second="$2"
  if [ -n "$second" ] && megabrain_usage_line "$first-$second" >/dev/null 2>&1; then
    printf '%s-%s\n' "$first" "$second"
  elif megabrain_usage_line "$first" >/dev/null 2>&1; then
    printf '%s\n' "$first"
  fi
}

skill_checked=0
while IFS= read -r line; do
  set -- $line
  shift
  key="$(skill_key "${1:-}" "${2:-}")"
  [ -n "$key" ] || continue
  canonical="$(megabrain_usage_line "$key")"
  for flag in $(printf '%s\n' "$line" | grep -oE '\-\-[a-z][a-z-]*' | sort -u); do
    case "$canonical" in
      *"$flag"*) ;;
      *) fail "the skill documents $flag for '$key', which its usage line does not have: $canonical" ;;
    esac
  done
  skill_checked=$((skill_checked + 1))
done < <(grep -oE '^megabrain [a-z][a-z-]*( [a-z][a-z-]*)?[^|]*' "$skill")

[ "$skill_checked" -ge 25 ] || fail "expected at least 25 skill command lines, checked $skill_checked"

# A command the skill never names does not exist as far as a fresh session is
# concerned. This started as one hardcoded check for chain run, which is exactly why
# orchestrate prune shipped and went undocumented on the same day: a rule that names
# one command cannot notice the next one. Every key must appear.
skill_group_covered=' model-add model-refresh fact-add fact-edit fact-remove '
skill_text="$(cat "$skill")"
while IFS= read -r key; do
  [ -n "$key" ] || continue
  case "$skill_group_covered" in
    *" $key "*) continue ;;
  esac
  words="$(printf '%s' "$key" | tr '-' ' ')"
  case "$skill_text" in
    *"megabrain $words"*) ;;
    *) fail "the skill never names 'megabrain $words', so a session has no way to learn it exists" ;;
  esac
done < <(usage_keys)

printf 'ok: the skill names %s commands and invents no flags\n' "$skill_checked"

printf 'ok: %s usage keys agree across help, errors, and AGENTS.md\n' "$checked"
