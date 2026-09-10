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

if ! command -v brew >/dev/null 2>&1; then
  printf 'skip: brew audit unavailable because brew is not installed\n'
else
  work="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-brew-audit.XXXXXX")"
  tap_name="megabrain-test/megabrain-audit-$$"
  tap_root="$work/homebrew-local"
  cleanup() {
    local rc=$?
    HOMEBREW_NO_AUTO_UPDATE=1 brew untap "$tap_name" --force >/dev/null 2>&1 || true
    chmod -R u+rwX "$work" 2>/dev/null || true
    rm -rf "$work"
    return "$rc"
  }
  trap cleanup EXIT

  mkdir -p "$tap_root/Formula"
  cp "$formula" "$tap_root/Formula/megabrain.rb"
  git -C "$tap_root" init -q
  git -C "$tap_root" add Formula/megabrain.rb
  git -C "$tap_root" -c user.name=megabrain-test -c user.email=test@example.invalid \
    commit -qm 'fixture formula for audit' || fail 'could not commit temporary tap fixture'
  HOMEBREW_NO_AUTO_UPDATE=1 brew tap "$tap_name" "$tap_root" >/dev/null ||
    fail 'could not create temporary local tap for audit'

  audit_output="$(HOMEBREW_NO_AUTO_UPDATE=1 brew audit --strict "$tap_name/megabrain" 2>&1)" ||
    fail "brew audit --strict $tap_name/megabrain failed: $audit_output"
  printf 'scenario 2: brew audit runs by formula name in a temporary local tap\n'
fi

printf 'ok: Homebrew formula structure and audit\n'
