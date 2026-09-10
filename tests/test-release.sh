#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

release_script="$root/scripts/release.sh"
version="$(jq -r '.version' "$root/.claude-plugin/plugin.json")"
archive="$work/megabrain-$version.tar.gz"

if mismatch_output="$("$release_script" v0.2.0 --output "$archive" 2>&1)"; then
  mismatch_status=0
else
  mismatch_status=$?
fi
[ "$mismatch_status" -ne 0 ] || fail 'release script accepted a tag that differs from the manifest'
case "$mismatch_output" in
  *"does not match manifest version $version"*) ;;
  *) fail "mismatch error did not name the manifest version: $mismatch_output" ;;
esac
printf 'scenario 1: mismatched release tag is refused\n'

matching_output="$($release_script "v$version" --output "$archive" 2>&1)" ||
  fail "matching release tag was refused: $matching_output"
[ -s "$archive" ] || fail 'matching release did not produce a tarball'
case "$matching_output" in
  *"git tag -a v$version"*) ;;
  *) fail "release instructions omitted the tag command: $matching_output" ;;
esac
case "$matching_output" in
  *"gh release create v$version"*) ;;
  *) fail "release instructions omitted the release command: $matching_output" ;;
esac
tar -tzf "$archive" | grep -F "megabrain-$version/megabrain" >/dev/null ||
  fail 'release tarball does not contain the megabrain entrypoint'
printf 'scenario 2: matching release tag creates the formula tarball and instructions\n'

printf 'ok: release guard scenarios\n'
