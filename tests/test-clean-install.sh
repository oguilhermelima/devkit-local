#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-clean-install.XXXXXX")"
cleanup() {
  local rc=$?
  chmod -R u+rwX "$work" 2>/dev/null || true
  rm -rf "$work"
  return "$rc"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

version="$(jq -r '.version' "$root/.claude-plugin/plugin.json")"
archive="$work/release.tar.gz"
install_root="$work/install"
home="$work/home"
mkdir -p "$install_root" "$home"

"$root/scripts/release.sh" "v$version" --output "$archive" >/dev/null ||
  fail 'could not create release tarball for clean-install proof'
tar -xzf "$archive" -C "$install_root"
release_root="$install_root/megabrain-$version"
[ -x "$release_root/megabrain" ] || fail 'release tarball did not produce an executable install'
[ ! -d "$release_root/.git" ] || fail 'clean release install unexpectedly contains a git directory'

chmod -R a-w "$release_root"
[ ! -w "$release_root" ] || fail 'clean release install root is writable'
export HOME="$home"
export MEGABRAIN_STATE_DIR="$home/.megabrain"

version_output="$($release_root/megabrain version)"
case "$version_output" in
  "megabrain $version") ;;
  *) fail "clean install returned an unexpected version: $version_output" ;;
esac
context_json="$($release_root/megabrain context --json)"
printf '%s' "$context_json" | jq -e '.host == "unknown"' >/dev/null || fail 'clean install context failed'
$release_root/megabrain model list >/dev/null || fail 'clean install model list failed'

printf 'ok: release tarball runs from a non-git, read-only install root\n'
