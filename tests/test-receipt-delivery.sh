#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-prompt-budget.XXXXXX")"

cleanup() {
  rm -rf "$state_dir"
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir"
source "$root/lib/common.sh"
source "$root/lib/module-orchestrate.sh"

# WHY: an oversized prompt is refused before anything is created, never truncated. Both
# transports are checked because they carry very different limits.
big="$(head -c $((MEGABRAIN_PROMPT_BUDGET_TMUX_BYTES + 1)) /dev/zero | tr '\0' 'x')"
if megabrain_validate_prompt_budget "$big" tmux prompt 2>/dev/null; then
  fail 'a prompt over the tmux budget was accepted'
fi
if ! megabrain_validate_prompt_budget "$big" argv prompt 2>/dev/null; then
  fail 'a prompt inside the argv budget was refused'
fi
huge="$(head -c $((MEGABRAIN_PROMPT_BUDGET_ARGV_BYTES + 1)) /dev/zero | tr '\0' 'x')"
if megabrain_validate_prompt_budget "$huge" argv prompt 2>/dev/null; then
  fail 'a prompt over the argv budget was accepted'
fi
printf 'prompt budgets refuse oversize on both transports\n'

printf 'ok: prompt budget scenarios\n'
