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
    failed=0 passed=0 slowest_test="" slowest_seconds=0
    for t in tests/*.sh; do
      started=$(date +%s)
      if timeout 60 bash "$t" >/tmp/out 2>&1; then
        test_status=0
      else
        test_status=$?
      fi
      elapsed=$(( $(date +%s) - started ))
      if [ "$elapsed" -gt "$slowest_seconds" ]; then
        slowest_seconds="$elapsed"
        slowest_test="$t"
      fi
      if [ "$test_status" -eq 0 ]; then
        printf "%-46s PASS (%ss)\n" "$t" "$elapsed"
        passed=$((passed + 1))
      else
        printf "%-46s FAIL (%ss)\n" "$t" "$elapsed"
        tail -6 /tmp/out | sed "s/^/    /"
        failed=$((failed + 1))
      fi
    done
    printf "\n%s passed, %s failed\n" "$passed" "$failed"
    printf "slowest: %s (%ss); timeout ceiling: 60s\n" "$slowest_test" "$slowest_seconds"
    [ "$failed" -eq 0 ]
  '
