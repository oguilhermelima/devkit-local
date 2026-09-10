#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
manifest="$root/.claude-plugin/plugin.json"
template="$root/Formula/megabrain.rb.in"
output=""
formula_output=""
tag="${1:-}"

fail() {
  printf 'release: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  local path="$1" output=''
  if command -v shasum >/dev/null 2>&1; then
    output="$(shasum -a 256 "$path")" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    output="$(sha256sum "$path")" || return 1
  else
    return 1
  fi
  printf '%s\n' "${output%% *}"
}

[ -f "$manifest" ] || fail "manifest is missing: $manifest"
[ -f "$template" ] || fail "formula template is missing: $template"
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
    --formula-output)
      [ "$#" -gt 1 ] || fail '--formula-output requires a path'
      formula_output="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: scripts/release.sh v%s [--output <path>] [--formula-output <path>]\n' "$version"
      exit 0
      ;;
    *) fail "unknown option: $1" ;;
  esac
done

[ -n "$output" ] || output="$root/dist/megabrain-$version.tar.gz"
[ -n "$formula_output" ] || formula_output="$root/Formula/megabrain.rb"
output_dir="$(dirname "$output")"
formula_dir="$(dirname "$formula_output")"
mkdir -p "$output_dir" || fail "could not create output directory: $output_dir"
temp="$(mktemp "$output.XXXXXX")" || fail "could not create temporary archive: $output"
if ! git -C "$root" archive --format=tar --mtime=0 --prefix="megabrain-$version/" HEAD -- . ':(exclude)Formula' | gzip -n >"$temp"; then
  rm -f "$temp"
  fail 'could not create release archive from HEAD'
fi

archive_hash="$(sha256_file "$temp")" || {
  rm -f "$temp"
  fail 'could not hash release archive'
}
if ! mv -f "$temp" "$output"; then
  rm -f "$temp"
  fail "could not install release archive: $output"
fi
mkdir -p "$formula_dir" || fail "could not create formula directory: $formula_dir"
formula_temp="$(mktemp "$formula_output.XXXXXX")" || fail "could not create temporary formula: $formula_output"
if ! sed -e "s/__VERSION__/$version/g" -e "s/__SHA256__/$archive_hash/g" "$template" >"$formula_temp"; then
  rm -f "$formula_temp"
  fail 'could not render Homebrew formula'
fi
if ! mv -f "$formula_temp" "$formula_output"; then
  rm -f "$formula_temp"
  fail "could not install rendered formula: $formula_output"
fi

printf 'release archive: %s\n' "$output"
printf 'rendered formula: %s\n' "$formula_output"
printf 'git tag -a %s -m "Release %s"\n' "$tag" "$version"
printf 'git push origin %s\n' "$tag"
printf 'gh release create %s %s --title "Release %s" --generate-notes\n' "$tag" "$output" "$version"
