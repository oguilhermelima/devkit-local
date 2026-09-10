#!/usr/bin/env bash

megabrain_test_jobs_resolve() {
  local cpu_count

  if [ -n "${MEGABRAIN_TEST_JOBS:-}" ]; then
    printf '%s\n' "$MEGABRAIN_TEST_JOBS"
    return 0
  fi

  cpu_count="$(nproc 2>/dev/null || true)"
  case "$cpu_count" in
    ''|*[!0-9]*|0) printf '1\n' ;;
    *) printf '%s\n' "$cpu_count" ;;
  esac
}
