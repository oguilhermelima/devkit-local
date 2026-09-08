#!/usr/bin/env bash
# Runs the whole suite inside a container, so a destructive mistake cannot reach the host.
# The local run stays the authority for macOS bash 3.2; this is the safety net for
# everything that starts a tmux server, writes an agent config or installs a module.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
image=megabrain-suite

docker build -t "$image" -f "$root/tests/container/Dockerfile" "$root/tests/container" >/dev/null

# The checkout is mounted read-only and copied inside before anything runs. Read-only is
# what stops a test writing to the host tree; the copy is what lets the tests work at all.
exec docker run --rm \
  -v "$root:/src:ro" \
  "$image" -c '
    set -uo pipefail
    cp -r /src "$HOME/work" && cd "$HOME/work"
    printf "bash %s on %s\n\n" "$BASH_VERSION" "$(uname -sm)"
    failed=0 passed=0
    for t in tests/*.sh; do
      printf "%-46s" "$t"
      if timeout 180 bash "$t" >/tmp/out 2>&1; then
        echo PASS
        passed=$((passed + 1))
      else
        echo FAIL
        tail -6 /tmp/out | sed "s/^/    /"
        failed=$((failed + 1))
      fi
    done
    printf "\n%s passed, %s failed\n" "$passed" "$failed"
    [ "$failed" -eq 0 ]
  '
