#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/devkit-list-performance.XXXXXX")"
wrapper_dir="$state_dir/bin"
count_file="$state_dir/jq-count"
real_jq="$(command -v jq)"

cleanup() {
  rm -rf "$state_dir"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$wrapper_dir" "$state_dir/dispatches"
printf '0\n' >"$count_file"

printf '%s\n' '#!/usr/bin/env bash' \
  'count=$(cat "$DEVKIT_TEST_JQ_COUNT")' \
  'count=$((count + 1))' \
  'printf "%s\\n" "$count" >"$DEVKIT_TEST_JQ_COUNT"' \
  'exec "$DEVKIT_TEST_JQ_REAL" "$@"' >"$wrapper_dir/jq"
chmod +x "$wrapper_dir/jq"

for i in $(seq 1 200); do
  dispatch_id="dispatch-$i"
  dispatch_dir="$state_dir/dispatches/$dispatch_id"
  mkdir -p "$dispatch_dir"
  "$real_jq" -n \
    --arg dispatchId "$dispatch_id" \
    --arg worktreePath "$root" \
    '{dispatchId: $dispatchId, parentSessionId: "parent", parentHost: "unknown", childHost: "unknown", workspaceId: "", terminalId: "", worktreePath: $worktreePath, state: "closed", processState: "stopped", terminalState: "released", reconcileOutcome: null}' \
    >"$dispatch_dir/meta.json"
done

export DEVKIT_STATE_DIR="$state_dir"
export DEVKIT_DISPATCH_DIR="$state_dir/dispatches"
export DEVKIT_TEST_JQ_COUNT="$count_file"
export DEVKIT_TEST_JQ_REAL="$real_jq"

source "$root/lib/common.sh"
source "$root/lib/module-context.sh"
source "$root/lib/module-orchestrate.sh"

devkit_dispatch_parent_status() {
  DEVKIT_PARENT_STATUS=unknown
}

PATH="$wrapper_dir:$PATH"
export PATH

output="$(command_orchestrate_list --all --json)"
count="$(cat "$count_file")"
[ "$(printf '%s' "$output" | "$real_jq" 'length')" = 200 ] || fail "list returned the wrong number of dispatches"
[ "$count" -le 6 ] || fail "orchestrate list used $count jq invocations for 200 dispatches"

printf 'ok: orchestrate list stays linear at 200 dispatches with %s jq invocations\n' "$count"
