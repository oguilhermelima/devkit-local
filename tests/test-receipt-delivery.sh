#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/devkit-receipt-retry.XXXXXX")"

cleanup() {
  rm -rf "$state_dir"
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir"
export MEGABRAIN_PROMPT_RECEIPT_TIMEOUT_SECONDS=1
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
  devkit_dispatch_meta_write receipt-retry parent-terminal orca orca "" child-terminal "$root" fix/prompt-delivery-proof codex label spawning gpt-5 true codex "" "" host ide >/dev/null
}

create_dispatch
(
  sleep 0.1
  devkit_dispatch_message_append receipt-retry child received 'prompt received' child-terminal >/dev/null
) &
devkit_dispatch_wait_for_prompt_receipt receipt-retry
wait
printf 'receipt wait observes a later queue confirmation\n'

printf 'ok: receipt confirmation timing\n'
