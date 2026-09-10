#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-skill-sync.XXXXXX")"
cleanup() {
  local rc=$?
  chmod -R u+rwX "$work" 2>/dev/null || true
  rm -rf "$work"
  return "$rc"
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

export HOME="$work/home"
export MEGABRAIN_STATE_DIR="$work/state"
mkdir -p "$HOME/.claude/plugins/cache/megabrain-local/megabrain/0.1.0/skills/megabrain"

source "$root/lib/common.sh"
source "$root/lib/module-skill.sh"

source_skill="$root/skills/megabrain/SKILL.md"
cached_skill="$HOME/.claude/plugins/cache/megabrain-local/megabrain/0.1.0/skills/megabrain/SKILL.md"
cp "$source_skill" "$cached_skill"
printf '\nold cached content\n' >>"$cached_skill"

megabrain_skill_reconcile
cmp -s "$source_skill" "$cached_skill" || fail 'runtime reconcile did not repair skill drift'
printf 'scenario 1: drift is detected and repaired\n'

target_hash_calls=0
megabrain_skill_hash_file() {
  target_hash_calls=$((target_hash_calls + 1))
  megabrain_sha256_file "$@"
}
megabrain_skill_reconcile
assert_equal "$target_hash_calls" 0
printf 'scenario 2: current skill is a no-op\n'

chmod 0555 "$(dirname "$cached_skill")"
printf '\nnew cached content\n' >>"$cached_skill" 2>/dev/null || true
if reconcile_output="$(megabrain_skill_reconcile 2>&1)"; then
  fail 'unwritable skill target was accepted'
fi
assert_contains "$reconcile_output" 'skill target is not writable'
chmod 0755 "$(dirname "$cached_skill")"
printf 'scenario 3: an unwritable target reports clearly\n'

cp "$source_skill" "$cached_skill"
rm -rf "$MEGABRAIN_STATE_DIR"
mkdir -p "$MEGABRAIN_STATE_DIR"
target_hash_calls=0
megabrain_skill_reconcile
first_calls="$target_hash_calls"
[ "$first_calls" -gt 0 ] || fail 'initial reconcile did not inspect target content'
megabrain_skill_reconcile
assert_equal "$target_hash_calls" "$first_calls"
printf 'scenario 4: the stamp prevents a repeated target comparison\n'

cp "$source_skill" "$cached_skill"
printf '\nuncorrected drift\n' >>"$cached_skill"
doctor_json="$("$root/megabrain" doctor skill-sync --json 2>/dev/null)" || true
printf '%s' "$doctor_json" | jq -e '.module == "skill-sync" and .status == "misconfigured" and (.reason | contains("skill drift"))' >/dev/null ||
  fail "doctor did not report skill drift as its own condition: $doctor_json"
cmp -s "$source_skill" "$cached_skill" && fail 'doctor silently repaired drift before reporting it'
printf 'scenario 5: doctor reports skill drift independently\n'

printf 'ok: skill synchronization scenarios\n'
