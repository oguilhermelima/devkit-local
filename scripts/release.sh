#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
manifest="$root/.claude-plugin/plugin.json"
output=""
tag="${1:-}"

fail() {
  printf 'release: %s\n' "$*" >&2
  exit 1
}

[ -f "$manifest" ] || fail "manifest is missing: $manifest"
version="$(jq -er '.version | strings | select(length > 0)' "$manifest")" ||
  fail "could not read a version from $manifest"
[ -n "$tag" ] || fail "usage: scripts/release.sh v$version [--output <path>]"
expected_tag="v$version"
[ "$tag" = "$expected_tag" ] ||
  fail "tag $tag does not match manifest version $version (expected $expected_tag)"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -gt 1 ] || fail '--output requires a path'
      output="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: scripts/release.sh v%s [--output <path>]\n' "$version"
      exit 0
      ;;
    *) fail "unknown option: $1" ;;
  esac
done

[ -n "$output" ] || output="$root/dist/megabrain-$version.tar.gz"
output_dir="$(dirname "$output")"
mkdir -p "$output_dir" || fail "could not create output directory: $output_dir"
temp="$(mktemp "$output.XXXXXX")" || fail "could not create temporary archive: $output"
if ! git -C "$root" archive --format=tar.gz --prefix="megabrain-$version/" HEAD -o "$temp"; then
  rm -f "$temp"
  fail 'could not create release archive from HEAD'
fi
if ! mv -f "$temp" "$output"; then
  rm -f "$temp"
  fail "could not install release archive: $output"
fi

printf 'release archive: %s\n' "$output"
printf 'git tag -a %s -m "Release %s"\n' "$tag" "$version"
printf 'git push origin %s\n' "$tag"
printf 'gh release create %s %s --title "Release %s" --generate-notes\n' "$tag" "$output" "$version"
