#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-receipt-retry.XXXXXX")"

cleanup() {
  # The writer below holds a lock directory under $state_dir; removing the tree
  # while it is mid-write races it into a failure that hides the real result.
  wait 2>/dev/null || true
  rm -rf "$state_dir"
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir"
# WHY: what this proves is that the wait observes a confirmation queued after it
# started, not that it gives up quickly. A one second budget lost that race against
# a loaded machine roughly one run in six, and failed with no output at all.
export MEGABRAIN_PROMPT_RECEIPT_TIMEOUT_SECONDS=15
export ORCA_TERMINAL_HANDLE=parent-terminal
unset SUPERSET_TERMINAL_ID
source "$root/lib/common.sh"
source "$root/lib/module-parent-notify.sh"
source "$root/lib/module-orchestrate.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

create_dispatch() {
  megabrain_dispatch_meta_write receipt-retry parent-terminal orca orca "" child-terminal "$root" fix/prompt-delivery-proof codex label spawning gpt-5 true codex "" "" host ide >/dev/null
}

create_dispatch
(
  sleep 0.1
  megabrain_dispatch_message_append receipt-retry child received 'prompt received' child-terminal >/dev/null
) &
megabrain_dispatch_wait_for_prompt_receipt receipt-retry
wait
printf 'receipt wait observes a later queue confirmation\n'

# WHY: the queue receipt is authoritative precisely because pane activity can be faked,
# so the wait must reject a delivery that is not a receipt instead of treating the first
# message of any kind as proof the prompt landed.
create_dispatch_named() {
  megabrain_dispatch_meta_write "$1" parent-terminal orca orca "" child-terminal "$root" fix/prompt-delivery-proof codex label spawning gpt-5 true codex '' '' host ide >/dev/null
}

create_dispatch_named receipt-wrong-type
megabrain_dispatch_message_append receipt-wrong-type child ask 'not a receipt' child-terminal >/dev/null
if megabrain_dispatch_wait_for_prompt_receipt receipt-wrong-type; then
  fail 'an ask was accepted as a prompt receipt'
fi
printf 'receipt wait rejects a delivery that is not a receipt\n'

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

printf 'ok: receipt confirmation timing and prompt budgets\n'
