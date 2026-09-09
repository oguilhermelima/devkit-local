#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_root="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-state-doctor.XXXXXX")"

cleanup() {
  local rc=$?
  rm -rf "$state_root"
  return "$rc"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

export HOME="$state_root/home"
export MEGABRAIN_STATE_DIR="$state_root/state"
mkdir -p "$HOME" "$MEGABRAIN_STATE_DIR"

source "$root/lib/common.sh"
source "$root/lib/module-native.sh"
source "$root/lib/module-install.sh"

uname() {
  printf 'Darwin\n'
}

appium_driver_installed=true
appium() {
  if [ "$1" = driver ] && [ "$2" = list ] && [ "$3" = --installed ]; then
    if [ "$appium_driver_installed" = true ]; then
      printf 'xcuitest@12.10.0 [installed (npm)]\n'
    else
      printf 'uiautomator2@4.2.0 [installed (npm)]\n'
    fi
    return 0
  fi
  return 1
}

write_state() {
  jq -n --argjson installed "$1" \
    '{"simulator-native": {installed: $installed, details: "historical result"}}' \
    >"$MEGABRAIN_STATE_FILE"
}

write_state false
first_output="$(megabrain_doctor_one simulator-native 2>&1)" ||
  fail 'doctor did not accept an installed native simulator'
[ "$(jq -r '."simulator-native".installed' "$MEGABRAIN_STATE_FILE")" = true ] ||
  fail 'doctor left a false state after observing the driver'
case "$first_output" in
  *'state reconciled'*) ;;
  *) fail 'doctor did not report its state reconciliation' ;;
esac
printf 'stale false state is reconciled to an installed native simulator\n'

appium_driver_installed=false
write_state true
if megabrain_doctor_one simulator-native >/dev/null 2>&1; then
  fail 'doctor accepted a missing native simulator driver'
fi
[ "$(jq -r '."simulator-native".installed' "$MEGABRAIN_STATE_FILE")" = false ] ||
  fail 'doctor left a true state after observing the missing driver'
printf 'stale true state is reconciled to a missing native simulator\n'

printf 'ok: doctor does not stay silent when state.json disagrees with reality\n'
