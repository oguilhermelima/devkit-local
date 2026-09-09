#!/usr/bin/env bash
# Runs the whole suite inside a container, so a destructive mistake cannot reach the host.
# The local run stays the authority for macOS bash 3.2; this is the safety net for
# everything that starts a tmux server, writes an agent config or installs a module.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
image=megabrain-suite
test_jobs="${MEGABRAIN_TEST_JOBS:-8}"

docker build -t "$image" -f "$root/tests/container/Dockerfile" "$root/tests/container" >/dev/null

# The checkout is mounted read-only and copied inside before anything runs. Read-only is
# what stops a test writing to the host tree; the copy is what lets the tests work at all.
exec docker run --rm \
  -e "MEGABRAIN_TEST_JOBS=$test_jobs" \
  -v "$root:/src:ro" \
  "$image" -c '
    set -uo pipefail
    [ "${1:-}" = -- ] && shift
    cp -r /src "$HOME/work" && cd "$HOME/work"
    printf "bash %s on %s\n\n" "$BASH_VERSION" "$(uname -sm)"
    selected_tests=""
    if [ "$#" -eq 0 ]; then
      selected_tests="tests/*.sh"
    else
      for requested in "$@"; do
        case "$requested" in
          *.sh) pattern="tests/$requested" ;;
          *) pattern="tests/$requested.sh" ;;
        esac
        case "$requested" in
          tests/*) pattern="$requested" ;;
        esac
        found=false
        for test_path in $pattern; do
          [ -f "$test_path" ] || continue
          if [ -n "$selected_tests" ]; then
            selected_tests="$selected_tests $test_path"
          else
            selected_tests="$test_path"
          fi
          found=true
        done
        if [ "$found" != true ]; then
          printf "no tests matched: %s\n" "$requested" >&2
          exit 2
        fi
      done
    fi
    test_jobs="${MEGABRAIN_TEST_JOBS:-8}"
    if [ -z "$test_jobs" ]; then
      printf "MEGABRAIN_TEST_JOBS must be a positive integer: %s\n" "$test_jobs" >&2
      exit 2
    fi
    case "$test_jobs" in
      *[!0-9]*)
        printf "MEGABRAIN_TEST_JOBS must be a positive integer: %s\n" "$test_jobs" >&2
        exit 2
        ;;
    esac
    [ "$test_jobs" -gt 0 ] || {
      printf "MEGABRAIN_TEST_JOBS must be greater than zero\n" >&2
      exit 2
    }

    result_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-suite.XXXXXX")"
    run_test() {
      local t="$1" name out meta started test_status elapsed
      name="$(basename "$t" .sh)"
      out="$result_dir/$name.out"
      meta="$result_dir/$name.meta"
      started=$(date +%s)
      if timeout 60 bash "$t" >"$out" 2>&1; then
        test_status=0
      else
        test_status=$?
      fi
      elapsed=$(( $(date +%s) - started ))
      printf "%s %s\n" "$test_status" "$elapsed" >"$meta"
    }
    export result_dir
    export -f run_test
    printf "%s\n" "${test_jobs} test workers"
    printf "%s\\n" $selected_tests | xargs -P "$test_jobs" -n 1 bash -c "run_test \"\$1\"" _

    failed=0 passed=0 slowest_test="" slowest_seconds=0
    for t in $selected_tests; do
      name="$(basename "$t" .sh)"
      out="$result_dir/$name.out"
      meta="$result_dir/$name.meta"
      if [ -f "$meta" ]; then
        IFS=" " read -r test_status elapsed <"$meta"
      else
        test_status=124
        elapsed=60
      fi
      if [ -z "$slowest_test" ] || [ "$elapsed" -gt "$slowest_seconds" ]; then
        slowest_seconds="$elapsed"
        slowest_test="$t"
      fi
      if [ "$test_status" -eq 0 ]; then
        printf "%-46s PASS (%ss)\n" "$t" "$elapsed"
        passed=$((passed + 1))
      else
        printf "%-46s FAIL (%ss)\n" "$t" "$elapsed"
        tail -6 "$out" | sed "s/^/    /"
        failed=$((failed + 1))
      fi
    done
    printf "\n%s passed, %s failed\n" "$passed" "$failed"
    printf "slowest: %s (%ss); timeout ceiling: 60s; workers: %s\n" "$slowest_test" "$slowest_seconds" "$test_jobs"
    rm -rf "$result_dir"
    [ "$failed" -eq 0 ]
  ' -- "$@"
