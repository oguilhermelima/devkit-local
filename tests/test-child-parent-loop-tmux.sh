#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/support/child-parent-loop-common.bash"

run_flow tmux

printf 'ok: child parent loop end to end in tmux runtime\n'
