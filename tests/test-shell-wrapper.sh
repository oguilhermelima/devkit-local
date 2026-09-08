#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-wrapper.XXXXXX")"

cleanup() {
  rm -rf "$work_dir"
  return 0
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected output to contain '$2', got: $1" ;;
  esac
}

run_wrapper() { # run_wrapper <home> <login shell>
  env HOME="$1" SHELL="$2" MEGABRAIN_STATE_DIR="$1/state" \
    "$root/megabrain" tmux wrapper --yes 2>&1
}

# WHY: the wrapper is a zsh function sourced from .zshrc. On a machine whose login shell is
# bash, writing it changes nothing the user will ever load, and the command used to report
# "tmux agent wrapper applied" anyway and create a .zshrc for someone who does not use zsh.
# A command that cannot do its job has to say so rather than claim success and leave litter.
bash_home="$work_dir/bash-user"
mkdir -p "$bash_home"
printf '# a bash user\n' >"$bash_home/.bashrc"

set +e
bash_output="$(run_wrapper "$bash_home" /bin/bash)"
bash_status=$?
set -e

[ "$bash_status" -ne 0 ] || fail "the wrapper claimed success on a bash login shell: $bash_output"
assert_contains "$bash_output" zsh
[ ! -f "$bash_home/.zshrc" ] || fail 'a .zshrc was created for a user whose shell is not zsh'
[ "$(cat "$bash_home/.bashrc")" = '# a bash user' ] || fail 'the bash user'"'"'s own rc file was modified'
printf 'a login shell it cannot serve is refused, and nothing is written\n'

# WHY the other half: refusing has to stay narrow. A zsh user must still get the wrapper, or
# the check above would pass just as well against a command that never works.
zsh_home="$work_dir/zsh-user"
mkdir -p "$zsh_home"
printf '# a zsh user\n' >"$zsh_home/.zshrc"

zsh_output="$(run_wrapper "$zsh_home" /bin/zsh)"
assert_contains "$zsh_output" applied
[ -f "$zsh_home/.megabrain/zsh/megabrain-agent-tmux.zsh" ] || fail 'the wrapper file was not installed for a zsh user'
grep -q megabrain "$zsh_home/.zshrc" || fail 'the zsh user rc file did not get the wrapper block'
printf 'a zsh login shell still gets the wrapper\n'

printf 'ok: the shell wrapper serves zsh and refuses what it cannot serve\n'
