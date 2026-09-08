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
old_env_output="$(HOME="$home" DEVKIT_STATE_DIR="$explicit_old" bash -c 'source "$1/lib/common.sh"; printf "%s\n" "$MEGABRAIN_STATE_DIR"' _ "$root" 2>&1)"
assert_contains "$old_env_output" 'DEVKIT_STATE_DIR is deprecated'
assert_contains "$old_env_output" "$explicit_old"
printf 'deprecated state override: honored with notice\n'

nested_state="$work/nested-state"
MEGABRAIN_STATE_DIR="$nested_state" bash -c 'source "$1/lib/common.sh"; source "$1/lib/module-orchestrate.sh"; megabrain_dispatch_meta_write nested-dispatch parent-terminal superset superset workspace nested-child "$1" main codex label spawning gpt-5 true codex "" "" host ide >/dev/null' _ "$root"
nested_output="$(env -u TMUX -u TMUX_PANE MEGABRAIN_STATE_DIR="$nested_state" SUPERSET_TERMINAL_ID=nested-child bash -c 'MEGABRAIN_STATE_DIR="$1" SUPERSET_TERMINAL_ID="$2" "$3" received' _ "$nested_state" nested-child "$root/megabrain")"
assert_contains "$nested_output" 'received sent: nested-dispatch'
assert_equal "$(find "$nested_state/dispatches/nested-dispatch/messages" -name '*-child-received.json' | wc -l | tr -d ' ')" 1
assert_equal "$(jq -r '.state' "$nested_state/dispatches/nested-dispatch/meta.json")" spawning
printf 'nested megabrain invocation inherits one state directory\n'

hostile_state="$work/hostile-state"
hostile_output="$(env -u TMUX -u TMUX_PANE MEGABRAIN_STATE_DIR="$nested_state" DEVKIT_STATE_DIR="$hostile_state" SUPERSET_TERMINAL_ID=nested-child bash -c 'MEGABRAIN_STATE_DIR="$1" DEVKIT_STATE_DIR="$2" SUPERSET_TERMINAL_ID="$3" "$4" received' _ "$nested_state" "$hostile_state" nested-child "$root/megabrain" 2>&1)"
assert_contains "$hostile_output" 'DEVKIT_STATE_DIR is deprecated and ignored because MEGABRAIN_STATE_DIR is set'
assert_contains "$hostile_output" 'received sent: nested-dispatch'
[ ! -e "$hostile_state" ] || fail 'legacy state directory was used despite the new variable'
assert_equal "$(find "$nested_state/dispatches/nested-dispatch/messages" -name '*-child-received.json' | wc -l | tr -d ' ')" 2
printf 'conflicting legacy state is ignored with an explicit warning\n'

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

legacy_root="$work/old-location/devkit-local"
for agent in claude codex agy cursor; do
  mkdir -p "$integration_home/.$agent"
  config="$integration_home/.$agent/hooks.json"
  [ "$agent" = claude ] && config="$integration_home/.$agent/settings.json"
  case "$agent" in
    cursor)
      jq -n --arg command "MEGABRAIN_HOOK_AGENT=$agent $legacy_root/hooks/devkit-turn-end.sh" \
        '{hooks:{afterAgentResponse:[{command:"keep"},{command:$command},{command:$command}]}}' >"$config"
      ;;
    *)
      jq -n --arg command "MEGABRAIN_HOOK_AGENT=$agent $legacy_root/hooks/devkit-turn-end.sh" \
        '{hooks:{Stop:[{hooks:[{type:"command",command:"keep"},{type:"command",command:$command},{type:"command",command:$command}]}]}}' >"$config"
      ;;
  esac
  cp "$config" "$work/${agent}-hooks.json"
  mkdir -p "$work/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/$agent"
  chmod +x "$work/bin/$agent"
done
PATH="$work/bin:$PATH" HOME="$integration_home" MEGABRAIN_STATE_DIR="$integration_home/state" \
  "$root/megabrain" install orchestration-hooks --yes >/dev/null
for agent in claude codex agy cursor; do
  config="$integration_home/.$agent/hooks.json"
  [ "$agent" = claude ] && config="$integration_home/.$agent/settings.json"
  assert_file "$config"
  assert_backup_matches "$config" "$work/${agent}-hooks.json"
  count="$(jq '[.. | objects | .command? // empty | select(test("megabrain-turn-end[.]sh"))] | length' "$config")"
  assert_equal "$count" 1
  assert_equal "$(jq -r '.. | objects | .command? // empty | select(test("megabrain-turn-end[.]sh"))' "$config")" \
    "MEGABRAIN_HOOK_AGENT=$agent $root/hooks/megabrain-turn-end.sh"
  if grep -F "$legacy_root/hooks/devkit-turn-end.sh" "$config" >/dev/null 2>&1; then
    fail "$agent config retained the legacy hook path"
  fi
done
printf 'agent hooks: all four updated with backups and one entry each\n'

PATH="$work/bin:$PATH" HOME="$integration_home" MEGABRAIN_STATE_DIR="$integration_home/state" \
  "$root/megabrain" install orchestration-hooks --revert >/dev/null
for agent in claude codex agy cursor; do
  config="$integration_home/.$agent/hooks.json"
  [ "$agent" = claude ] && config="$integration_home/.$agent/settings.json"
  cmp -s "$work/${agent}-hooks.json" "$config" || fail "$agent hooks were not restored"
done
printf 'agent hooks: reverse operation restored the legacy entries\n'

moved_root="$work/moved/megabrain-local"
mkdir -p "$(dirname "$moved_root")"
cp -Rp "$root" "$moved_root"
moved_root="$(cd -P "$moved_root" && pwd -P)"
PATH="$work/bin:$PATH" HOME="$integration_home" MEGABRAIN_STATE_DIR="$integration_home/state" \
  "$moved_root/megabrain" install orchestration-hooks --yes >/dev/null
for agent in claude codex agy cursor; do
  config="$integration_home/.$agent/hooks.json"
  [ "$agent" = claude ] && config="$integration_home/.$agent/settings.json"
  moved_entry="$(jq -r '.. | objects | .command? // empty | select(test("megabrain-turn-end[.]sh"))' "$config")"
  assert_equal "$moved_entry" "MEGABRAIN_HOOK_AGENT=$agent $moved_root/hooks/megabrain-turn-end.sh"
  assert_file "$moved_root/hooks/megabrain-turn-end.sh"
  [ -x "$moved_root/hooks/megabrain-turn-end.sh" ] || fail 'moved hook is not executable'
done
printf 'agent hooks: repair resolved the moved checkout dynamically\n'

install_home="$work/install-home"
mkdir -p "$install_home/.devkit-local"
HOME="$install_home" "$root/install.sh" --agents none --skill none --agents-md none --modules none --yes >/dev/null
assert_symlink_target "$install_home/.local/bin/megabrain" "$root/megabrain"
assert_symlink_target "$install_home/.local/bin/devkit" "$root/devkit"
[ -d "$install_home/.devkit-local" ] || fail 'legacy install directory was removed'
printf 'installer: new command and deprecated alias links are present\n'

printf 'ok: megabrain rename and migration scenarios\n'
