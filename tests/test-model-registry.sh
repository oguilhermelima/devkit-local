#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/devkit-models.XXXXXX")"
bin_dir="$state_dir/bin"
mkdir -p "$bin_dir"

cleanup() {
  local rc=$?
  rm -rf "$state_dir"
  return "$rc"
}
trap cleanup EXIT

export DEVKIT_STATE_DIR="$state_dir/state"
export PATH="$bin_dir:$PATH"

fail() {
  printf 'FAIL: %s\n' "$*"
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

list_output="$("$root/devkit" model list --json)"
assert_equal "$(printf '%s' "$list_output" | jq '[.models[] | select(.agent == "codex")] | length')" 10
assert_equal "$(printf '%s' "$list_output" | jq '[.models[] | select(.agent == "claude")] | length')" 18
assert_equal "$(printf '%s' "$list_output" | jq '[.models[] | select(.agent == "agy")] | length')" 14
assert_equal "$(printf '%s' "$list_output" | jq -r '.models[] | select(.agent == "agy" and .model == "gemini-3.8-flash-high") | .provenance.kind')" live
assert_equal "$(printf '%s' "$list_output" | jq -r '.models[] | select(.agent == "codex") | .provenance.kind' | head -n 1)" sourced
assert_equal "$(printf '%s' "$list_output" | jq -r '.models[] | select(.agent == "codex") | .provenance.url' | sort -u)" 'https://learn.chatgpt.com/docs/models?surface=app'
assert_equal "$(printf '%s' "$list_output" | jq -r '.models[] | select(.agent == "claude") | .provenance.url' | sort -u)" 'https://platform.claude.com/docs/en/about-claude/model-deprecations'
assert_equal "$(printf '%s' "$list_output" | jq -r '.models[] | select(.agent == "codex" and .model == "gpt-6-astra") | .reasoning.levels | join(",")')" 'low,medium,high,xhigh,max,ultra'
assert_equal "$(printf '%s' "$list_output" | jq -r '.models[] | select(.agent == "codex" and .model == "gpt-5.4") | [.status, .retirementDate] | join(",")')" 'retired,2026-08-31'
assert_equal "$(printf '%s' "$list_output" | jq -r '.models[] | select(.agent == "claude" and .model == "claude-mythos-preview") | .status')" deprecated
assert_equal "$(printf '%s' "$list_output" | jq -r '[.models[] | select(.agent == "claude" and .status == "retired")] | length')" 6
printf 'registry inventory: 14 agy, 10 codex, 18 claude with sourced provenance\n'

assert_equal "$(grep -l '^command_model()' "$root"/lib/*.sh | wc -l | tr -d ' ')" 1
printf 'dispatcher ownership: one command_model owner\n'

cat >"$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = models ]; then
  printf '%s\n' \
    'gemini-3.8-flash-high' 'gemini-3.8-flash-medium' 'gemini-3.8-flash-low' \
    'gemini-3.7-flash-high' 'gemini-3.7-flash-medium' 'gemini-3.7-flash-low' \
    'gemini-3.6-flash-high' 'gemini-3.6-flash-medium' 'gemini-3.6-flash-low' \
    'gemini-3.1-pro-high' 'gemini-3.1-pro-low' 'claude-sonnet-4-6' \
    'claude-opus-4-6-thinking' 'gpt-oss-120b-medium' 'gemini-9.1-flash-low'
  exit 0
fi
exit 1
EOF
chmod +x "$bin_dir/agy"
before_refresh="$(printf '%s' "$list_output" | jq -r '.models[] | select(.agent == "agy") | .provenance.obtainedAt' | head -n 1)"
"$root/devkit" model refresh agy >/dev/null
after_refresh="$("$root/devkit" model list --json)"
assert_equal "$(printf '%s' "$after_refresh" | jq -r '[.models[] | select(.agent == "agy")] | length')" 15
assert_equal "$(printf '%s' "$after_refresh" | jq -r '.models[] | select(.agent == "agy" and .model == "gemini-9.1-flash-low") | .provenance.kind')" live
assert_not_equal() { [ "$1" != "$2" ] || fail "expected values to differ: $1"; }
assert_not_equal "$before_refresh" "$(printf '%s' "$after_refresh" | jq -r '.models[] | select(.agent == "agy" and .model == "gemini-9.1-flash-low") | .provenance.obtainedAt')"
printf 'registry refresh: agy source replaced entries and timestamp\n'

"$root/devkit" model add codex user-model --reasoning low,medium,high >/dev/null
assert_equal "$("$root/devkit" model list --json | jq -r '.models[] | select(.model == "user-model") | .provenance.kind')" curated
assert_failure_contains 'already registered' "$root/devkit" model add codex user-model --reasoning low
assert_failure_contains 'reasoning levels' "$root/devkit" model add codex malformed-model --reasoning low,,high
printf 'registry add: user entry accepted, duplicate and malformed input refused\n'

assert_failure_contains 'has effort as part of the model id' "$root/devkit" chain add agy-with-effort \
  --when '{"parentAgent":"codex"}' \
  --steps '[{"agent":"agy","model":"gemini-3.8-flash-high","effort":"high"}]'
"$root/devkit" chain add agy-without-effort \
  --when '{"parentAgent":"codex"}' \
  --steps '[{"agent":"agy","model":"gemini-3.8-flash-high"}]' >/dev/null
assert_equal "$("$root/devkit" chain list --json | jq -r '.chains[] | select(.name == "agy-without-effort") | .steps[0].effort // "absent"')" absent
assert_failure_contains 'requires a separate reasoning level' "$root/devkit" chain add codex-without-effort \
  --when '{"parentAgent":"codex"}' \
  --steps '[{"agent":"codex","model":"gpt-6-astra"}]'
assert_failure_contains 'requires a separate reasoning level' "$root/devkit" chain add claude-without-effort \
  --when '{"parentAgent":"codex"}' \
  --steps '[{"agent":"claude","model":"claude-sonnet-5"}]'
retired_output="$("$root/devkit" chain add retired-model-chain \
  --when '{"parentAgent":"codex"}' \
  --steps '[{"agent":"codex","model":"gpt-5.4","effort":"high"}]' 2>&1)"
assert_contains "$retired_output" 'Warning: model'
assert_contains "$retired_output" 'retirement date: 2026-08-31'
printf 'chain effort: embedded agy effort omitted, separate axes required, retired models warn\n'

assert_failure_contains 'unknown-model' "$root/devkit" chain add unknown-model-chain \
  --when '{"parentAgent":"codex"}' \
  --steps '[{"agent":"codex","model":"unknown-model","effort":"high"}]'
assert_failure_contains 'does not support reasoning level' "$root/devkit" chain add bad-effort-chain \
  --when '{"parentAgent":"codex"}' \
  --steps '[{"agent":"codex","model":"gpt-5.6-luna","effort":"none"}]'
unknown_ids_output="$("$root/devkit" chain add readable-unknown-chain \
  --when '{"parentAgent":"codex"}' \
  --steps '[{"agent":"codex","model":"unknown-readable-model","effort":"high"}]' 2>&1 || true)"
assert_contains "$unknown_ids_output" 'Valid model ids:'
assert_not_contains "$unknown_ids_output" 'gpt-6-astra,gpt-5.6'
"$root/devkit" chain add escaped-chain --allow-unknown-model \
  --when '{"parentAgent":"codex"}' \
  --steps '[{"agent":"codex","model":"future-model","effort":"high"}]' >/dev/null
assert_equal "$("$root/devkit" chain list --json | jq -r '.chains[] | select(.name == "escaped-chain") | .steps[0].unvalidated')" true
printf 'chain guard: unknown and unsupported values refused; escape hatch records unvalidated\n'

original='{"chains":{"legacy":{"when":{"parentAgent":"codex"},"steps":[{"agent":"agy","model":"gemini-2.5-pro","effort":"high"},{"agent":"claude","model":"claude-sonnet-4-5","effort":"high"}]}},"defaultSteps":[]}'
mkdir -p "$DEVKIT_STATE_DIR"
printf '%s\n' "$original" >"$DEVKIT_STATE_DIR/chains.json"
if migration_output="$("$root/devkit" chain list 2>&1)"; then
  fail 'invalid legacy chain unexpectedly listed successfully'
fi
assert_contains "$migration_output" 'chain legacy step 1'
assert_contains "$migration_output" 'gemini-2.5-pro'
assert_contains "$migration_output" 'chain legacy step 2'
assert_contains "$migration_output" 'claude-sonnet-4-5'
assert_equal "$(cat "$DEVKIT_STATE_DIR/chains.json")" "$original"
"$root/devkit" chain repair legacy --step 1 --model gemini-3.8-flash-high >/dev/null
"$root/devkit" chain repair legacy --step 2 --model claude-sonnet-5 --effort high >/dev/null
assert_equal "$("$root/devkit" chain list --json | jq -r '.chains[] | select(.name == "legacy") | .steps[0].model')" gemini-3.8-flash-high
assert_equal "$("$root/devkit" chain list --json | jq -r '.chains[] | select(.name == "legacy") | .steps[0].effort // "absent"')" absent
assert_equal "$("$root/devkit" chain list --json | jq -r '.chains[] | select(.name == "legacy") | .steps[1].model')" claude-sonnet-5
printf 'migration: legacy values reported without rewrite and repaired explicitly\n'

printf 'ok: model registry, provenance, chain guard, escape hatch, and migration\n'
