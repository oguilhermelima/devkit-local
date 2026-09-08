#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-rename.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected '$1' to contain '$2'" ;;
  esac
}

assert_equal() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_file() {
  [ -f "$1" ] || fail "expected file: $1"
}

assert_symlink_target() {
  [ -L "$1" ] || fail "expected symlink: $1"
  assert_equal "$(readlink "$1")" "$2"
}

assert_backup_matches() {
  local path="$1" original="$2" backup
  backup="$(find "$(dirname "$path")" -maxdepth 1 -name "$(basename "$path").megabrain-backup-*" -type f -print -quit)"
  [ -n "$backup" ] || fail "expected backup for $path"
  cmp -s "$original" "$backup" || fail "backup for $path differs from original"
}

old_alias_output="$("$root/devkit" --version 2>&1)"
assert_contains "$old_alias_output" 'deprecated'
assert_contains "$old_alias_output" 'megabrain'
assert_contains "$("$root/megabrain" --version)" 'megabrain'
assert_contains "$("$root/mb" --version)" 'megabrain'
printf 'command aliases: megabrain, mb, and deprecated devkit\n'

home="$work/home"
mkdir -p "$home/.devkit/dispatches/dispatch-1/messages" "$home/.devkit/sessions"
printf '{"id":1}\n' >"$home/.devkit/dispatches/dispatch-1/meta.json"
printf '{"message":"kept"}\n' >"$home/.devkit/dispatches/dispatch-1/messages/one.json"
printf '{"chains":[] }\n' >"$home/.devkit/chains.json"
printf '{"version":1,"facts":[] }\n' >"$home/.devkit/facts.json"
printf '{"models":[] }\n' >"$home/.devkit/models.json"
printf '{"session":"kept"}\n' >"$home/.devkit/sessions/session.json"
before="$work/before"
cp -Rp "$home/.devkit" "$before"
migration_output="$(HOME="$home" "$root/megabrain" migrate)"
assert_contains "$migration_output" 'Moved'
diff -qr "$before" "$home/.megabrain"
[ ! -e "$home/.devkit" ] || fail 'old state directory still exists after migration'
second_output="$(HOME="$home" "$root/megabrain" migrate)"
assert_contains "$second_output" 'No migration needed'
diff -qr "$before" "$home/.megabrain"
printf 'state migration: contents preserved and second run is a no-op\n'

explicit_old="$work/explicit-old"
mkdir -p "$explicit_old"
printf '{}\n' >"$explicit_old/state.json"
old_env_output="$(HOME="$home" DEVKIT_STATE_DIR="$explicit_old" bash -c 'source "$1/lib/common.sh"; printf "%s\n" "$DEVKIT_STATE_DIR"' _ "$root" 2>&1)"
assert_contains "$old_env_output" 'DEVKIT_STATE_DIR is deprecated'
assert_contains "$old_env_output" "$explicit_old"
printf 'deprecated state override: honored with notice\n'

integration_home="$work/integration-home"
mkdir -p "$integration_home"
printf 'export EXISTING=1\n' >"$integration_home/.zshrc"
original_zshrc="$work/original-zshrc"
cp "$integration_home/.zshrc" "$original_zshrc"
HOME="$integration_home" "$root/megabrain" tmux wrapper --yes >/dev/null
HOME="$integration_home" "$root/megabrain" tmux tune --yes >/dev/null
grep -Fxc '# >>> megabrain tmux wrapper >>>' "$integration_home/.zshrc" | grep -Fx 1
grep -Fxc '# >>> megabrain tmux tuning >>>' "$integration_home/.tmux.conf" | grep -Fx 1
assert_backup_matches "$integration_home/.zshrc" "$original_zshrc"
HOME="$integration_home" "$root/megabrain" tmux wrapper --revert >/dev/null
HOME="$integration_home" "$root/megabrain" tmux tune --revert >/dev/null
cmp -s "$original_zshrc" "$integration_home/.zshrc" || fail 'zshrc was not restored by reverse operation'
printf 'marked integrations: backed up, replaced once, and reverted\n'

for agent in claude codex agy cursor; do
  mkdir -p "$integration_home/.$agent"
  case "$agent" in
    cursor) printf '{"hooks":{"afterAgentResponse":[{"command":"old"}]}}\n' >"$integration_home/.$agent/hooks.json" ;;
    *) printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"old"}]}]}}\n' >"$integration_home/.$agent/hooks.json" ;;
  esac
  cp "$integration_home/.$agent/hooks.json" "$work/${agent}-hooks.json"
  mkdir -p "$work/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/$agent"
  chmod +x "$work/bin/$agent"
done
PATH="$work/bin:$PATH" HOME="$integration_home" MEGABRAIN_STATE_DIR="$integration_home/state" \
  "$root/megabrain" install orchestration-hooks --yes >/dev/null
for agent in claude codex agy cursor; do
  config="$integration_home/.$agent/hooks.json"
  assert_file "$config"
  assert_backup_matches "$config" "$work/${agent}-hooks.json"
  count="$(jq '[.. | objects | .command? // empty | select(test("megabrain-turn-end[.]sh"))] | length' "$config")"
  assert_equal "$count" 1
done
printf 'agent hooks: all four updated with backups and one entry each\n'

install_home="$work/install-home"
mkdir -p "$install_home/.devkit-local"
HOME="$install_home" "$root/install.sh" --agents none --skill none --agents-md none --modules none --yes >/dev/null
assert_symlink_target "$install_home/.local/bin/megabrain" "$root/megabrain"
assert_symlink_target "$install_home/.local/bin/devkit" "$root/devkit"
[ -d "$install_home/.devkit-local" ] || fail 'legacy install directory was removed'
printf 'installer: new command and deprecated alias links are present\n'

printf 'ok: megabrain rename and migration scenarios\n'
