#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

archive_head_tree() {
  local help_output=''
  help_output="$(git -C "$root" archive -h 2>&1 || true)"
  case "$help_output" in
    *--mtime*)
      git -C "$root" archive --format=tar --mtime='1970-01-01 00:00:00' \
        --prefix="megabrain-$version/" HEAD^{tree} -- . ':(exclude)Formula'
      ;;
    *)
      git -C "$root" archive --format=tar --prefix="megabrain-$version/" \
        HEAD^{tree} -- . ':(exclude)Formula'
      ;;
  esac
}

release_script="$root/scripts/release.sh"
version="$(jq -r '.version' "$root/.claude-plugin/plugin.json")"
archive="$work/megabrain-$version.tar.gz"
formula="$work/megabrain.rb"

if help_output="$("$release_script" --help 2>&1)"; then
  help_status=0
else
  help_status=$?
fi
[ "$help_status" -eq 0 ] || fail "--help was refused: $help_output"
case "$help_output" in
  *'Build a release archive and render the Homebrew formula.'*) ;;
  *) fail "--help did not describe the release operation: $help_output" ;;
esac
case "$help_output" in
  *'v<version>'*|*'v0.2.0'*) ;;
  *) fail "--help did not describe the tag argument: $help_output" ;;
esac
case "$help_output" in
  *'--output <path>'*) ;;
  *) fail "--help omitted --output: $help_output" ;;
esac
case "$help_output" in
  *'--formula-output <path>'*) ;;
  *) fail "--help omitted --formula-output: $help_output" ;;
esac
case "$help_output" in
  *'prints the commands for the operator to run'*|*'does not tag or push'*) ;;
  *) fail "--help did not explain operator commands: $help_output" ;;
esac
printf 'scenario 1: release help describes arguments and operator commands\n'

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
printf 'scenario 2: mismatched release tag is refused\n'

matching_output="$($release_script "v$version" --output "$archive" --formula-output "$formula" 2>&1)" ||
  fail "matching release tag was refused: $matching_output"
[ -s "$archive" ] || fail 'matching release did not produce a tarball'
[ -s "$formula" ] || fail 'matching release did not render a formula'
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
grep -F "releases/download/v$version/megabrain-$version.tar.gz" "$formula" >/dev/null || fail 'rendered formula has the wrong version'
grep -Eq '^  sha256 "[0-9a-f]{64}"$' "$formula" || fail 'rendered formula has no concrete sha256'
grep -F '__VERSION__' "$formula" >/dev/null && fail 'rendered formula retained a version placeholder'
printf 'scenario 3: matching release tag creates the formula tarball and instructions\n'

committed_archive="$work/committed.tar.gz"
archive_head_tree | gzip -n >"$committed_archive" || fail 'could not archive the committed release tree'
if tar -tzf "$committed_archive" | grep -F '/Formula/' >/dev/null; then
  fail 'release archive includes Formula files'
fi
committed_hash="$(shasum -a 256 "$committed_archive" | awk '{print $1}')"
formula_hash="$(sed -n 's/^  sha256 "\([0-9a-f]*\)"$/\1/p' "$root/Formula/megabrain.rb")"
[ -n "$formula_hash" ] || fail 'committed formula has no sha256'
[ "$formula_hash" = "$committed_hash" ] ||
  fail "committed formula hash $formula_hash does not match HEAD archive $committed_hash"
printf 'scenario 4: committed formula hash matches the Formula-excluded HEAD archive\n'

printf 'ok: release guard scenarios\n'
