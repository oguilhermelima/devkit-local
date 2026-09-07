#!/usr/bin/env bash

devkit_context_detect() {
  local current_json
  devkit_session_id >/dev/null
  if [ -n "${DEVKIT_SESSION_ID:-}" ]; then
    printf '%s\n' "$DEVKIT_SESSION_HOST"
    return 0
  fi
  if devkit_require_command orca; then
    current_json="$(orca worktree current --json 2>/dev/null || true)"
    if printf '%s' "$current_json" | jq -e '.ok == true and (.result.worktree.path // .result.worktree.git.path) != null' >/dev/null 2>&1; then
      printf 'orca\n'
      return 0
    fi
  fi
  printf 'unknown\n'
}

command_context() {
  local format="plain" arg host
  for arg in "$@"; do
    case "$arg" in
      --json) format="json" ;;
      -h|--help) printf 'Usage: devkit context [--json]\n'; return 0 ;;
      *) devkit_error "unknown context option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  host="$(devkit_context_detect)"
  devkit_session_id >/dev/null
  if [ "$format" = json ]; then
    jq -n --arg host "$host" --arg workspace "${SUPERSET_WORKSPACE_ID:-}" \
      --arg terminal "${DEVKIT_SESSION_ID:-}" --arg agent "${SUPERSET_AGENT_ID:-}" \
      '{host: $host, workspaceId: (if $workspace|length > 0 then $workspace else null end), terminalId: (if $terminal|length > 0 then $terminal else null end), agentId: (if $agent|length > 0 then $agent else null end)}'
  else
    printf '%s\n' "$host"
  fi
}

command_orchestrate() {
  local subcommand="${1:-}"
  shift || true
  case "$subcommand" in
    spawn) command_worktree create --orchestrate "$@" ;;
    list) command_orchestrate_list "$@" ;;
    watch) devkit_dispatch_watch "$@" ;;
    read) devkit_dispatch_read "$@" ;;
    reply) devkit_dispatch_reply "$@" ;;
    close) devkit_dispatch_close "$@" ;;
    -h|--help|"")
      printf 'Usage: devkit orchestrate spawn ... | devkit orchestrate list [--all|--orphans] [--json]\n'
      printf '       devkit orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--json]\n'
      printf '       devkit orchestrate read <dispatch-id> [--lines <count>] [--json]\n'
      printf '       devkit orchestrate reply <dispatch-id> --text <answer> [--json]\n'
      printf '       devkit orchestrate close <dispatch-id> [--json]\n'
      ;;
    *) devkit_error "unknown orchestrate command: $subcommand"; return "$DEVKIT_USAGE_ERROR" ;;
  esac
}

devkit_dispatch_parent_alive() {
  local meta="$1" host parent workspace_json workspace_id terminals
  host="$(printf '%s' "$meta" | jq -r '.parentHost')"
  parent="$(printf '%s' "$meta" | jq -r '.parentSessionId')"
  case "$host" in
    orca)
      devkit_require_command orca || return 1
      orca terminal list --json 2>/dev/null | jq -e --arg id "$parent" 'any((.result.terminals // .terminals // . // [])[]?; (.handle // .terminalHandle // .id // "") == $id)' >/dev/null 2>&1
      ;;
    superset)
      devkit_superset_available || return 1
      workspace_json="$(devkit_superset workspaces list --local --json 2>/dev/null || printf '[]')"
      while IFS= read -r workspace_id; do
        [ -n "$workspace_id" ] || continue
        terminals="$(devkit_superset terminals list --workspace "$workspace_id" --json 2>/dev/null || printf '[]')"
        if printf '%s' "$terminals" | jq -e --arg id "$parent" 'any((.result.terminals // .terminals // .sessions // .result.sessions // [])[]?; (.id // .terminalId // .sessionId // .handle // "") == $id)' >/dev/null 2>&1; then
          return 0
        fi
      done < <(printf '%s' "$workspace_json" | jq -r '(if type == "array" then . else (.result.workspaces? // .workspaces? // .result? // []) end)[]? | (.id // .workspaceId // .workspace.id // empty)' 2>/dev/null)
      return 1
      ;;
    *) return 1 ;;
  esac
}

command_orchestrate_list() {
  local json=false all=false orphans=false arg caller_id caller_host meta_path meta owned orphan entries='[]' state dispatch_id
  for arg in "$@"; do
    case "$arg" in
      --json) json=true ;;
      --all) all=true ;;
      --orphans) orphans=true ;;
      -h|--help) printf 'Usage: devkit orchestrate list [--all|--orphans] [--json]\n'; return 0 ;;
      *) devkit_error "unknown orchestrate list option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  devkit_session_id >/dev/null
  caller_id="$DEVKIT_SESSION_ID"
  caller_host="$DEVKIT_SESSION_HOST"
  for meta_path in "$DEVKIT_DISPATCH_DIR"/*/meta.json; do
    [ -f "$meta_path" ] || continue
    meta="$(cat "$meta_path")"
    dispatch_id="$(printf '%s' "$meta" | jq -r '.dispatchId')"
    owned=false
    if [ -n "$caller_id" ] && printf '%s' "$meta" | jq -e --arg id "$caller_id" --arg host "$caller_host" '.parentSessionId == $id and .parentHost == $host' >/dev/null 2>&1; then
      owned=true
    fi
    orphan=false
    if ! devkit_dispatch_parent_alive "$meta"; then orphan=true; fi
    state="$(printf '%s' "$meta" | jq -r '.state // empty')"
    if [ "$orphan" = true ] && [ "$state" != orphaned ] && [ "$state" != closed ] && [ "$state" != done ]; then
      devkit_dispatch_meta_update_state "$dispatch_id" orphaned >/dev/null 2>&1 || true
      meta="$(devkit_dispatch_meta_read "$dispatch_id" 2>/dev/null || printf '%s' "$meta")"
    fi
    if [ "$all" != true ] && [ "$orphans" != true ] && [ "$owned" != true ]; then continue; fi
    if [ "$orphans" = true ] && [ "$orphan" != true ]; then continue; fi
    entries="$(jq --argjson item "$meta" --argjson owned "$owned" --argjson orphan "$orphan" '. + [$item + {ownedByCaller: $owned, orphan: $orphan}]' <<<"$entries")"
  done
  if [ "$json" = true ]; then
    printf '%s\n' "$entries"
    return 0
  fi
  printf '%-38s %-20s %-10s %-10s %s\n' DISPATCH STATE HOST OWNERSHIP WORKTREE
  printf '%s\n' "$entries" | jq -r '.[] | [.dispatchId, .state, .childHost, (if .ownedByCaller then "owned" else "not-owned" end), .worktreePath] | @tsv' | while IFS=$'\t' read -r dispatch state child_host ownership worktree; do
    printf '%-38s %-20s %-10s %-10s %s\n' "$dispatch" "$state" "$child_host" "$ownership" "$worktree"
  done
}

devkit_superset_terminals_json() {
  local workspaces workspace_id terminal_json
  workspaces="$(devkit_superset workspaces list --local --json 2>/dev/null || printf '[]')"
  printf '%s\n' "$workspaces" | jq -r '(if type == "array" then . else (.result.workspaces? // .workspaces? // .result? // []) end)[]? | (.id // .workspaceId // .workspace.id // empty)' 2>/dev/null | while IFS= read -r workspace_id; do
    [ -n "$workspace_id" ] || continue
    terminal_json="$(devkit_superset terminals list --workspace "$workspace_id" --json 2>/dev/null || printf '[]')"
    printf '%s\n' "$terminal_json" | jq -c '(.result.terminals // .terminals // .sessions // .result.sessions // [])[]?' 2>/dev/null
  done | jq -s '{result: {terminals: .}}'
}
