#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
formula="$root/Formula/megabrain.rb"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "$formula" ] || fail "formula is missing: $formula"
grep -F 'depends_on "jq"' "$formula" >/dev/null || fail 'formula does not depend on jq'
grep -F 'libexec.install' "$formula" >/dev/null || fail 'formula does not install into libexec'
grep -F 'bin.install_symlink libexec/"megabrain"' "$formula" >/dev/null || fail 'formula does not link megabrain'
grep -F 'bin.install_symlink libexec/"mb"' "$formula" >/dev/null || fail 'formula does not link mb'
grep -F 'test do' "$formula" >/dev/null || fail 'formula has no test block'
grep -F 'def caveats' "$formula" >/dev/null || fail 'formula has no caveats method'
grep -F 'megabrain install' "$formula" >/dev/null || fail 'formula caveats omit machine setup'
grep -F 'kept in sync by megabrain' "$formula" >/dev/null || fail 'formula caveats omit skill synchronization'

printf 'ok: Homebrew formula structure\n'
