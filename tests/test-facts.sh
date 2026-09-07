#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/devkit-facts.XXXXXX")"
facts_file="$state_dir/facts.json"

cleanup() {
  local rc=$?
  rm -rf "$state_dir"
  return "$rc"
}
trap cleanup EXIT

export DEVKIT_STATE_DIR="$state_dir/state"
export DEVKIT_FACTS_FILE="$facts_file"

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

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected '$1' not to contain '$2'" ;;
    *) ;;
  esac
}

assert_failure_contains() {
  local expected="$1" output
  shift
  if output="$("$@" 2>&1)"; then
    fail "expected command to fail: $*"
  fi
  printf '%s\n' "$output"
  assert_contains "$output" "$expected"
}

list_output="$("$root/devkit" fact list --json)"
assert_equal "$(printf '%s' "$list_output" | jq 'length')" 0
printf 'empty store initializes as a facts array\n'

assert_failure_contains provenance.who "$root/devkit" fact add missing-provenance --measurement measured
"$root/devkit" fact add bash-version --measurement 'Bash 3.2.57 is installed on macOS' --who tester --when 2026-09-07T19:27:29Z --command 'bash --version' --json >/dev/null
repo_id="$(git -C "$root" config --get remote.origin.url)"
"$root/devkit" fact add repo-fact --measurement 'repository measurement' --who tester --when 2026-09-07T19:27:29Z --command 'git remote -v' --scope repository --json >/dev/null
"$root/devkit" fact add other-repo --measurement 'must stay out of this prompt' --who tester --when 2026-09-07T19:27:29Z --command 'printf other' --repository other-repository --json >/dev/null
list_output="$("$root/devkit" fact list --json)"
assert_equal "$(printf '%s' "$list_output" | jq 'length')" 3
assert_equal "$(printf '%s' "$list_output" | jq -r --arg id repo-fact '.[] | select(.id == $id) | .scope.repository')" "$repo_id"
printf 'add and list preserve provenance and repository scope\n'

editor="$state_dir/editor"
printf '%s\n' '#!/usr/bin/env bash' 'jq '\''(.facts |= map(if .id == "repo-fact" then .measurement = "edited measurement" else . end))'\'' "$1" >"$1.next"' 'mv "$1.next" "$1"' >"$editor"
chmod +x "$editor"
EDITOR="$editor" "$root/devkit" fact edit repo-fact --json >/dev/null
assert_equal "$("$root/devkit" fact list --json | jq -r '.[] | select(.id == "repo-fact") | .measurement')" 'edited measurement'
printf 'edit changes one fact through the validated temporary copy\n'

preamble="$(bash -c 'source "$1/lib/common.sh"; source "$1/lib/module-orchestrate.sh"; devkit_dispatch_preamble "$1"' _ "$root")"
assert_contains "$preamble" 'Before starting work, run ./devkit received'
assert_contains "$preamble" 'bash-version'
assert_contains "$preamble" 'repo-fact'
assert_contains "$preamble" 'Treat each fact as a starting point with provenance, not as truth.'
assert_contains "$preamble" 'your measurement wins; report the disagreement.'
assert_not_contains "$preamble" 'other-repo'
printf 'preamble keeps protocol, injects matching facts, and excludes another repository\n'

if limited="$({ DEVKIT_FACT_MAX_INJECTED=1 bash -c 'source "$1/lib/common.sh"; source "$1/lib/module-orchestrate.sh"; devkit_dispatch_preamble "$1";' _ "$root"; } 2>&1)"; then
  fail 'fact count limit unexpectedly accepted the store'
fi
assert_contains "$limited" 'fact count limit'
printf '%s\n' "$limited"

if limited="$({ DEVKIT_FACT_MAX_PREAMBLE_BYTES=10 bash -c 'source "$1/lib/common.sh"; source "$1/lib/module-orchestrate.sh"; devkit_dispatch_preamble "$1";' _ "$root"; } 2>&1)"; then
  fail 'fact byte limit unexpectedly accepted the store'
fi
assert_contains "$limited" 'byte limit'
printf '%s\n' "$limited"

removed="$("$root/devkit" fact remove other-repo --json)"
assert_equal "$(printf '%s' "$removed" | jq -r '.removed')" true
assert_equal "$("$root/devkit" fact list --json | jq 'length')" 2
printf 'remove deletes only the requested fact\n'

printf 'ok: fact provenance, commands, preamble scope, and size limits\n'
