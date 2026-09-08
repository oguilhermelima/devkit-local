#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-finish.XXXXXX")"
state_dir="$work_dir/state"

cleanup() {
  rm -rf "$work_dir"
  return 0
}
trap cleanup EXIT

export MEGABRAIN_STATE_DIR="$state_dir"
source "$root/lib/common.sh"
source "$root/lib/module-worktree.sh"

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

# The removal is stubbed to fail the way a real orchestrator does: a non-zero exit
# with its own message on stdout as JSON. That is the shape that used to be swallowed,
# because --json sends that stdout to /dev/null.
megabrain_require_command() {
  case "$1" in
    orca) return 0 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
megabrain_superset_available() { return 1; }
orca() {
  printf '{"ok":false,"error":"worktree has uncommitted changes"}\n'
  return 1
}

# The resolver only knows worktrees under the shared root, so the fixture has to live
# there for the test to reach the removal at all. An earlier version of this file did not,
# and passed on an unrelated "worktree not found" without ever exercising the refusal.
megabrain_worktree_root() { printf '%s\n' "$work_dir"; }

git init -q "$work_dir/repo"
git -C "$work_dir/repo" config user.email tester@example.com
git -C "$work_dir/repo" config user.name tester
printf 'base\n' >"$work_dir/repo/base.txt"
git -C "$work_dir/repo" add base.txt
git -C "$work_dir/repo" commit -qm 'base'
git -C "$work_dir/repo" worktree add -q "$work_dir/wt" -b feat/unfinished
printf 'work that is not committed\n' >"$work_dir/wt/dirty.txt"

# WHY: a refusal that says nothing is indistinguishable from a crash. The removal used to
# fail with an empty stdout and an empty stderr, because --json sent the underlying tool's
# own message to /dev/null and megabrain added none of its own, so the caller was left with
# an exit code and no way to tell an unmerged branch from a broken install.
set +e
finish_out="$(megabrain_worktree_finish "$work_dir/wt" --json 2>"$work_dir/finish.err")"
finish_rc=$?
set -e

[ "$finish_rc" -ne 0 ] || fail 'removing a worktree with uncommitted work succeeded'
finish_err="$(cat "$work_dir/finish.err")"
[ -n "$finish_err" ] || fail "the refusal reported nothing: stdout was '$finish_out'"
assert_contains "$finish_err" 'megabrain:'
case "$finish_err" in
  *'worktree not found'*) fail 'the test never reached the removal; it failed while resolving the target' ;;
esac
assert_contains "$finish_err" 'uncommitted changes'
printf 'a refused removal says why on stderr\n'

# WHY: refusing has to mean the work is still there. This is the only assertion that
# distinguishes a refusal from a partial removal that reported an error afterwards.
[ -f "$work_dir/wt/dirty.txt" ] || fail 'the worktree was removed despite the refusal'
git -C "$work_dir/repo" branch --list feat/unfinished | grep -q feat/unfinished ||
  fail 'the branch was deleted despite the refusal'
printf 'a refused removal leaves the worktree and the branch alone\n'

printf 'ok: worktree finish refuses loudly and destroys nothing\n'
