#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/devkit-chain.XXXXXX")"
home_dir="$state_dir/home"
call_file="$state_dir/spawn-call"

cleanup() {
  local rc=$?
  rm -rf "$state_dir"
  return "$rc"
}
trap cleanup EXIT

export DEVKIT_STATE_DIR="$state_dir/state"
export HOME="$home_dir"
rollouts_dir="$HOME/.codex/sessions/2026/09/07"
mkdir -p "$rollouts_dir"

source "$root/lib/common.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-chain.sh"

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

assert_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "expected command to fail: $*"
  fi
}

write_config() {
  printf '%s\n' "$1" >"$DEVKIT_CHAIN_FILE"
}

write_rollout() {
  local path="$1" used="$2" reset="$3"
  printf '%s\n' "{\"timestamp\":\"2026-09-07T08:15:21.790Z\",\"ordinal\":15,\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":19712,\"cached_input_tokens\":2816,\"cache_write_input_tokens\":0,\"output_tokens\":22,\"reasoning_output_tokens\":13,\"total_tokens\":19734},\"model_context_window\":258400},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":$used,\"window_minutes\":300,\"resets_at\":$reset},\"secondary\":{\"used_percent\":19.0,\"window_minutes\":10080,\"resets_at\":$reset}}}}" >"$path"
}

future_reset="$(($(date +%s) + 3600))"
cp "$root/tests/fixtures/codex-rollout-rate-limits.jsonl" "$rollouts_dir/rollout-real-shaped.jsonl"
devkit_chain_limit_read codex 5h
assert_equal "$DEVKIT_CHAIN_LIMIT_STATUS" current
assert_equal "$DEVKIT_CHAIN_LIMIT_USED" 73.0
assert_equal "$DEVKIT_CHAIN_LIMIT_RESETS" 4102444800
printf 'limit real-shaped sample guard: current at 73 percent\n'

write_rollout "$rollouts_dir/rollout-current.jsonl" 97.0 "$future_reset"
printf '%s\n' '{"timestamp":"2026-09-07T08:15:22.790Z","ordinal":16,"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}' >>"$rollouts_dir/rollout-current.jsonl"
touch -t 202609070101 "$rollouts_dir/rollout-real-shaped.jsonl"
touch -t 202609070102 "$rollouts_dir/rollout-current.jsonl"
devkit_chain_limit_read codex 5h
assert_equal "$DEVKIT_CHAIN_LIMIT_STATUS" current
assert_equal "$DEVKIT_CHAIN_LIMIT_USED" 97.0
printf 'limit trailing non-snapshot line: last usable snapshot\n'

printf '%s\n' '{"timestamp":"2026-09-07T08:15:23.790Z","ordinal":17,"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}' >"$rollouts_dir/rollout-empty.jsonl"
touch -t 202609070103 "$rollouts_dir/rollout-empty.jsonl"
devkit_chain_limit_read codex 5h
assert_equal "$DEVKIT_CHAIN_LIMIT_STATUS" current
assert_equal "$DEVKIT_CHAIN_LIMIT_USED" 97.0
printf 'limit newest file without snapshot: older usable snapshot\n'

seeded="$(DEVKIT_STATE_DIR="$DEVKIT_STATE_DIR" "$root/devkit" chain list --json)"
assert_equal "$(printf '%s' "$seeded" | jq '.chains | length')" 3
assert_equal "$(printf '%s' "$seeded" | jq -r '[.chains[].when | keys[]] | unique | join(",")')" parentAgent
printf 'seed and list: passed\n'

config='{"chains":{"parent":{"when":{"parentAgent":"codex"},"steps":[{"agent":"agy","model":"m","effort":"e"}]},"specific":{"when":{"parentAgent":"codex","parentEffort":"high"},"steps":[{"agent":"claude","model":"m","effort":"e"}]}},"defaultSteps":[{"agent":"codex","model":"m","effort":"e"}]}'
devkit_chain_select "$config" parent codex '' ''
assert_equal "$DEVKIT_CHAIN_SELECTED_NAME" parent
printf 'selection explicit name: parent\n'
devkit_chain_select "$config" '' codex '' ''
assert_equal "$DEVKIT_CHAIN_SELECTED_NAME" parent
printf 'selection one selector: parent\n'
devkit_chain_select "$config" '' codex '' high
assert_equal "$DEVKIT_CHAIN_SELECTED_NAME" specific
printf 'selection most specific: specific\n'
tie_config='{"chains":{"alpha":{"when":{"parentAgent":"codex"},"steps":[{"agent":"agy","model":"m","effort":"e"}]},"beta":{"when":{"parentAgent":"codex"},"steps":[{"agent":"claude","model":"m","effort":"e"}]}},"defaultSteps":[]}'
if tie_error="$(devkit_chain_select "$tie_config" '' codex '' '' 2>&1)"; then
  fail 'tie selection unexpectedly succeeded'
fi
assert_contains "$tie_error" 'alpha, beta'
printf 'selection tie: error lists candidates\n'
model_config='{"chains":{"model":{"when":{"parentAgent":"codex","parentModel":"known"},"steps":[{"agent":"agy","model":"m","effort":"e"}]}},"defaultSteps":[{"agent":"codex","model":"m","effort":"e"}]}'
devkit_chain_select "$model_config" '' codex '' ''
assert_equal "$DEVKIT_CHAIN_SELECTION_DEFAULT" true
printf 'selection unknown parent model: default\n'
none_config='{"chains":{"claude-only":{"when":{"parentAgent":"claude"},"steps":[{"agent":"agy","model":"m","effort":"e"}]}},"defaultSteps":[{"agent":"codex","model":"m","effort":"e"}]}'
devkit_chain_select "$none_config" '' agy '' ''
assert_equal "$DEVKIT_CHAIN_SELECTION_DEFAULT" true
printf 'selection no match: defaultSteps\n'

write_rollout "$rollouts_dir/rollout-under.jsonl" 40.0 "$future_reset"
printf '%s\n' '{"timestamp":"2026-09-07T08:15:24.790Z","ordinal":18,"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}' >>"$rollouts_dir/rollout-under.jsonl"
touch -t 202609070104 "$rollouts_dir/rollout-under.jsonl"
devkit_chain_limit_read codex 5h
assert_equal "$DEVKIT_CHAIN_LIMIT_STATUS" current
assert_equal "$DEVKIT_CHAIN_LIMIT_USED" 40.0
printf 'limit under threshold: current at 40 percent\n'
past_reset="$(($(date +%s) - 60))"
write_rollout "$rollouts_dir/rollout-stale.jsonl" 99.0 "$past_reset"
touch -t 202609070105 "$rollouts_dir/rollout-stale.jsonl"
devkit_chain_limit_read codex 5h
assert_equal "$DEVKIT_CHAIN_LIMIT_STATUS" unknown
assert_contains "$DEVKIT_CHAIN_LIMIT_REASON" 'stale'
printf 'limit stale snapshot: unknown\n'
devkit_chain_limit_read claude 5h
assert_equal "$DEVKIT_CHAIN_LIMIT_STATUS" unknown
printf 'limit unavailable provider: unknown and usable\n'
rm -f "$rollouts_dir"/rollout-*.jsonl
printf '%s\n' '{"timestamp":"2026-09-07T08:15:25.790Z","ordinal":19,"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}' >"$rollouts_dir/rollout-empty-only.jsonl"
devkit_chain_limit_read codex 5h
assert_equal "$DEVKIT_CHAIN_LIMIT_STATUS" unknown
assert_contains "$DEVKIT_CHAIN_LIMIT_REASON" 'no rate limit snapshot'
printf 'limit absent: unknown honestly\n'

write_config '{"chains":{"run":{"when":{"parentAgent":"codex"},"steps":[{"agent":"codex","model":"m1","effort":"e1","until":{"usedPercent":95,"window":"5h"}},{"agent":"agy","model":"m2","effort":"e2"}]}},"defaultSteps":[]}'
command_orchestrate() {
  printf '%s\n' "$*" >"$call_file"
  printf '{"dispatch":"dispatch-chain"}\n'
}
write_config '{"chains":{"unknown":{"when":{"parentAgent":"codex"},"steps":[{"agent":"codex","model":"m1","effort":"e1","until":{"usedPercent":95,"window":"5h"}},{"agent":"agy","model":"m2","effort":"e2"}]}},"defaultSteps":[]}'
run_output="$(command_chain_run --parent-agent codex --worktree "$root" --prompt test --json)"
assert_equal "$(printf '%s' "$run_output" | jq -r '.step')" 1
assert_equal "$(printf '%s' "$run_output" | jq -r '.agent')" codex
assert_equal "$(printf '%s' "$run_output" | jq '.skipped | length')" 0
printf 'limit unknown: step is usable, not exhausted\n'

write_rollout "$rollouts_dir/rollout-run.jsonl" 97.0 "$future_reset"
touch -t 202609070106 "$rollouts_dir/rollout-run.jsonl"
run_output="$(command_chain_run --parent-agent codex --worktree "$root" --prompt test --json)"
assert_equal "$(printf '%s' "$run_output" | jq -r '.step')" 2
assert_contains "$(printf '%s' "$run_output" | jq -r '.skipped[0].reason')" '97.0'
assert_contains "$(cat "$call_file")" 'spawn'
assert_contains "$(cat "$call_file")" '--agent agy'
printf 'run limit skip: step 2 and spawn entry point invoked\n'

write_config '{"chains":{"run":{"when":{"parentAgent":"codex"},"steps":[{"agent":"claude","model":"m1","effort":"e1"},{"agent":"agy","model":"m2","effort":"e2"}]}},"defaultSteps":[]}'
command_orchestrate() {
  printf '%s\n' "$*" >"$call_file"
  case " $* " in
    *' --agent claude '*) printf 'launch failed\n' >&2; return 1 ;;
    *) printf '{"dispatch":"dispatch-after-failure"}\n' ;;
  esac
}
run_output="$(command_chain_run --parent-agent codex --worktree "$root" --prompt test --json)"
assert_equal "$(printf '%s' "$run_output" | jq -r '.step')" 2
assert_equal "$(printf '%s' "$run_output" | jq -r '.skipped[0].kind')" failure
printf 'run failure trigger: advanced to step 2\n'

write_config '{"chains":{"run":{"when":{"parentAgent":"codex"},"steps":[{"agent":"codex","model":"m1","effort":"e1","until":{"usedPercent":95,"window":"5h"}},{"agent":"claude","model":"m2","effort":"e2","until":{"usedPercent":95,"window":"5h"}}]}},"defaultSteps":[]}'
command_orchestrate() {
  printf 'launch failed\n' >&2
  return 1
}
if exhaustion="$(command_chain_run --parent-agent codex --worktree "$root" --prompt test --json)"; then
  fail 'all unusable steps unexpectedly succeeded'
fi
assert_equal "$(printf '%s' "$exhaustion" | jq '.skipped | length')" 2
assert_contains "$(printf '%s' "$exhaustion" | jq -r '.skipped[0].reason')" 'resets at'
assert_contains "$(printf '%s' "$exhaustion" | jq -r '.skipped[1].reason')" 'unknown'
printf 'run exhaustion: every step reported with reset and unknown\n'

export DEVKIT_CHAIN_NAME=run DEVKIT_CHAIN_STEP=2 DEVKIT_CHAIN_TOTAL=2 DEVKIT_CHAIN_REASON='codex exhausted' DEVKIT_CHAIN_DEFAULT=false
devkit_dispatch_meta_write dispatch-record parent superset superset workspace terminal "$root" main agy label running m true agy '' '' host ide '' '' '' >/dev/null
assert_equal "$(jq -r '.chain.name' "$DEVKIT_STATE_DIR/dispatches/dispatch-record/meta.json")" run
assert_equal "$(jq -r '.chain.step' "$DEVKIT_STATE_DIR/dispatches/dispatch-record/meta.json")" 2
printf 'dispatch reporting: chosen chain and step persisted\n'

printf 'ok: chain selection, limits, failure advance, exhaustion, and reporting\n'
