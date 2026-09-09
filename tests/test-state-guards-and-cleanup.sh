#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_root="$(mktemp -d "${TMPDIR:-/tmp}/megabrain-state-guards.XXXXXX")"

cleanup() {
  rm -rf "$state_root"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected '$1' to contain '$2'" ;;
  esac
}

assert_missing() {
  [ ! -e "$1" ] || fail "expected path to be absent: $1"
}

export HOME="$state_root/home"
export MEGABRAIN_STATE_DIR="$state_root/state"
export SUPERSET_TERMINAL_ID=parent-terminal
unset TMUX TMUX_PANE

source "$root/lib/common.sh"
source "$root/lib/module-context.sh"
source "$root/lib/module-orchestrate.sh"
source "$root/lib/module-worktree.sh"
source "$root/lib/module-install.sh"

mkdir -p "$MEGABRAIN_DISPATCH_DIR"

write_old_timestamp() {
  local dispatch_id="$1" path tmp
  path="$MEGABRAIN_DISPATCH_DIR/$dispatch_id/meta.json"
  tmp="$(mktemp "$MEGABRAIN_DISPATCH_DIR/$dispatch_id/.old.XXXXXX")"
  jq --arg old '2020-01-01T00:00:00Z' '.createdAt = $old | .updatedAt = $old' "$path" >"$tmp"
  mv -f "$tmp" "$path"
}

write_dispatch() {
  local dispatch_id="$1" state="$2"
  megabrain_dispatch_meta_write "$dispatch_id" parent-terminal superset superset workspace-test child-terminal \
    "$root" main codex label "$state" gpt-5 true codex '' '' host ide >/dev/null
}

scenario_reply_uses_transition_table() {
  local output failure_output
  write_dispatch orphaned-reply orphaned
  megabrain_dispatch_native_send() { return 1; }

  output="$(megabrain_dispatch_reply orphaned-reply --text 'resume orphan' --json)"
  assert_equal "$(printf '%s' "$output" | jq -r '.status')" queued
  assert_equal "$(jq -r '.state' "$MEGABRAIN_DISPATCH_DIR/orphaned-reply/meta.json")" running
  assert_equal "$(jq -r '.type' "$MEGABRAIN_DISPATCH_DIR/orphaned-reply/messages"/*.json)" reply

  write_dispatch forbidden-reply failed
  if failure_output="$(megabrain_dispatch_reply forbidden-reply --text 'must fail' 2>&1)"; then
    fail 'a forbidden reply transition succeeded'
  fi
  assert_contains "$failure_output" 'state failed'
  printf 'orphaned reply follows the table and failed reply is rejected\n'
}

scenario_timeout_is_prunable() {
  local output archive_path
  write_dispatch timeout-prunable timeout
  write_old_timestamp timeout-prunable
  output="$(command_orchestrate prune --json)"
  assert_equal "$(printf '%s' "$output" | jq -r '.archived')" 1
  archive_path="$(printf '%s' "$output" | jq -r '.archivedDispatches[0].path')"
  [ -f "$archive_path/meta.json" ] || fail 'timeout dispatch was not archived'
  printf 'timeout is counted and archived by default prune\n'
}

scenario_mark_running_uses_transition_table() {
  write_dispatch orphaned-running orphaned
  megabrain_spawn_mark_running_if_spawning orphaned-running
  assert_equal "$(jq -r '.state' "$MEGABRAIN_DISPATCH_DIR/orphaned-running/meta.json")" running

  write_dispatch stalled-running stalled
  megabrain_spawn_mark_running_if_spawning stalled-running
  assert_equal "$(jq -r '.state' "$MEGABRAIN_DISPATCH_DIR/stalled-running/meta.json")" running
  printf 'orphaned and stalled can return to running\n'
}

scenario_missing_meta_is_reported() {
  local output
  mkdir -p "$MEGABRAIN_DISPATCH_DIR/dispatch-without-meta/messages"
  printf '%s\n' 'left behind' >"$MEGABRAIN_DISPATCH_DIR/dispatch-without-meta/messages/0001-child-done.json"
  megabrain_runtime_enabled() { return 1; }
  megabrain_require_command() { return 1; }
  megabrain_superset_available() { return 1; }
  megabrain_dispatch_health_counts
  output="${MODULE_UNTRACKED_DISPATCHES:-}"
  assert_contains "$output" 'dispatch-without-meta'
  printf 'doctor inventory reports dispatch-without-meta\n'
}

setup_fake_superset() {
  fake_shared_root="$1"
  mkdir -p "$fake_shared_root" "$state_root/superset"
  megabrain_superset_available() { return 0; }
  megabrain_worktree_root() { printf '%s\n' "$fake_shared_root"; }
  megabrain_context_detect() { printf 'superset\n'; }
  megabrain_resolve_spawn_runtime() {
    MEGABRAIN_SPAWN_RUNTIME=ide
    MEGABRAIN_SPAWN_CONTEXT=superset
  }
  megabrain_project_name_for_path() { printf 'fake-project\n'; }
  megabrain_superset() {
    local kind="${1:-}" action="${2:-}" project_file="$state_root/superset/project.json" workspace_file="$state_root/superset/workspace.json"
    case "$kind:$action" in
      projects:list)
        if [ -f "$project_file" ]; then
          jq -n --argjson project "$(cat "$project_file")" '{projects: [$project]}'
        else
          printf '{"projects":[]}\n'
        fi
        ;;
      projects:create)
        printf '%s\n' '{"id":"project-created","path":"'"$test_repo"'"}' >"$project_file"
        printf '%s\n' '{"result":{"project":{"id":"project-created"}}}'
        ;;
      projects:delete)
        rm -f "$project_file"
        printf '%s\n' '{"deleted":true}'
        ;;
      workspaces:list)
        if [ -f "$workspace_file" ]; then
          jq -n --argjson workspace "$(cat "$workspace_file")" '{workspaces: [$workspace]}'
        else
          printf '{"workspaces":[]}\n'
        fi
        ;;
      workspaces:create)
        if [ "${workspace_creation_mode:-success}" = no-id ]; then
          printf '%s\n' '{}'
        else
          printf '%s\n' '{"id":"workspace-created","branch":"feat/test"}' >"$workspace_file"
          printf '%s\n' '{"result":{"workspace":{"id":"workspace-created"}}}'
        fi
        ;;
      workspaces:delete)
        rm -f "$workspace_file"
        printf '%s\n' '{"deleted":true}'
        ;;
      *) return 1 ;;
    esac
  }
}

scenario_launch_failure_rolls_back_owned_objects() {
  local repo_dir shared_root worktree_path output branch
  test_repo="$state_root/repo"
  shared_root="$state_root/shared"
  repo_dir="$test_repo"
  git init -q "$repo_dir"
  git -C "$repo_dir" config user.email tester@example.com
  git -C "$repo_dir" config user.name tester
  printf 'base\n' >"$repo_dir/base.txt"
  git -C "$repo_dir" add base.txt
  git -C "$repo_dir" commit -qm base
  setup_fake_superset "$shared_root"
  megabrain_launch_agent() {
    megabrain_error 'simulated agent launch failure'
    return 1
  }

  branch='feat/test'
  worktree_path="$shared_root/feat-test"
  if output="$(megabrain_worktree_create --repo "$repo_dir" --branch "$branch" --agent codex --model gpt-5 --effort medium --prompt test --tmux false --orchestrate --json 2>&1)"; then
    fail 'launch failure unexpectedly succeeded'
  fi
  assert_contains "$output" "$worktree_path"
  assert_contains "$output" 'workspace-created'
  assert_contains "$output" 'project-created'
  assert_missing "$worktree_path"
  git -C "$repo_dir" branch --list "$branch" | grep -q "$branch" && fail 'created branch was not removed'
  assert_missing "$state_root/superset/workspace.json"
  assert_missing "$state_root/superset/project.json"

  workspace_creation_mode=no-id
  branch='feat/no-workspace-id'
  worktree_path="$shared_root/feat-no-workspace-id"
  output="$(megabrain_worktree_create --repo "$repo_dir" --branch "$branch" --agent codex --model gpt-5 --effort medium --prompt test --tmux false --orchestrate --json 2>&1 || true)"
  assert_contains "$output" 'project-created'
  assert_contains "$output" 'workspace identity unavailable'
  assert_missing "$worktree_path"
  git -C "$repo_dir" branch --list "$branch" | grep -q "$branch" && fail 'branch survived unidentified workspace rollback'
  assert_missing "$state_root/superset/project.json"
  printf 'failed launch removes only objects created by this invocation\n'
}

case "${SCENARIO:-all}" in
  1) scenario_reply_uses_transition_table ;;
  2) scenario_timeout_is_prunable ;;
  3) scenario_mark_running_uses_transition_table ;;
  4) scenario_missing_meta_is_reported ;;
  5) scenario_launch_failure_rolls_back_owned_objects ;;
  all)
    scenario_reply_uses_transition_table
    scenario_timeout_is_prunable
    scenario_mark_running_uses_transition_table
    scenario_missing_meta_is_reported
    scenario_launch_failure_rolls_back_owned_objects
    printf 'ok: state guards, dispatch visibility, and launch rollback\n'
    ;;
  *)
    fail "unknown scenario: $SCENARIO"
    ;;
esac
