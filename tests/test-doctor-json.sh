#!/usr/bin/env bash

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-doctor.XXXXXX")"

cleanup() {
  rm -rf "$state_dir"
  return 0
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir/state"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# A module doctor that printed advice to stdout used to land a human sentence inside
# the captured JSON, so the whole run came back as a jq parse error.
all_json="$("$root/megabrain" doctor --json 2>/dev/null)"
printf '%s' "$all_json" | jq -e 'type == "array" and length > 0' >/dev/null ||
  fail "doctor --json did not produce a JSON array: $all_json"
printf '%s' "$all_json" | jq -e 'all(.[]; has("module") and has("status"))' >/dev/null ||
  fail "doctor --json entries are missing module or status"

while IFS= read -r module_name; do
  module_json="$("$root/megabrain" doctor "$module_name" --json 2>/dev/null)"
  printf '%s' "$module_json" | jq -e --arg module_name "$module_name" '.module == $module_name' >/dev/null ||
    fail "doctor $module_name --json did not produce that module's object: $module_json"
done < <(printf '%s' "$all_json" | jq -r '.[].module')

advice="$("$root/megabrain" doctor --json 2>&1 >/dev/null)"
case "$advice" in
  *'CODEX ACTION REQUIRED'*) printf 'advice for the operator still reaches stderr\n' ;;
  *) printf 'no operator advice in this environment; stderr stayed empty\n' ;;
esac

source "$root/lib/common.sh"
source "$root/lib/module-context.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-tmux-runtime.sh"
source "$root/lib/module-install.sh"
megabrain_require_command() { return 1; }
megabrain_superset_available() { return 1; }
megabrain_runtime_enabled() { return 0; }
megabrain_tmux_available() { return 0; }
module_orchestration_doctor >/dev/null 2>&1 || fail 'tmux-only orchestration was not usable without host CLIs'
[ "$MODULE_STATUS" = ok ] || fail "tmux-only orchestration doctor status was $MODULE_STATUS"
case "$MODULE_REASON" in
  *optional*) ;;
  *) fail "tmux-only orchestration doctor did not mark host CLIs optional: $MODULE_REASON" ;;
esac
printf 'tmux runtime makes absent orchestration CLIs optional\n'

printf 'ok: doctor --json is machine readable for every module\n'
