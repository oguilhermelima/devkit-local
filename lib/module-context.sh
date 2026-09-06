#!/usr/bin/env bash

devkit_context_detect() {
  local current_json

  if [ -n "${SUPERSET_WORKSPACE_ID:-}" ]; then
    printf 'superset\n'
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
  local format="plain"
  local arg
  for arg in "$@"; do
    case "$arg" in
      --json) format="json" ;;
      -h|--help)
        printf 'Usage: devkit context [--json]\n'
        return 0
        ;;
      *) devkit_error "unknown context option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done

  local host
  host="$(devkit_context_detect)"
  if [ "$format" = json ]; then
    jq -n --arg host "$host" \
      --arg workspace "${SUPERSET_WORKSPACE_ID:-}" \
      --arg terminal "${SUPERSET_TERMINAL_ID:-}" \
      --arg agent "${SUPERSET_AGENT_ID:-}" \
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
    reply) devkit_dispatch_reply "$@" ;;
    close) devkit_dispatch_close "$@" ;;
    -h|--help|"")
      printf 'Usage: devkit orchestrate spawn ... | devkit orchestrate list [--json]\n'
      printf '       devkit orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--json]\n'
      printf '       devkit orchestrate reply <dispatch-id> --text <answer> [--json]\n'
      printf '       devkit orchestrate close <dispatch-id> [--json]\n'
      ;;
    *) devkit_error "unknown orchestrate command: $subcommand"; return "$DEVKIT_USAGE_ERROR" ;;
  esac
}

command_orchestrate_list() {
  local json=false
  local arg
  for arg in "$@"; do
    case "$arg" in
      --json) json=true ;;
      -h|--help)
        printf 'Usage: devkit orchestrate list [--json]\n'
        return 0
        ;;
      *) devkit_error "unknown orchestrate list option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done

  local orca_json='[]'
  local superset_json='[]'
  if devkit_require_command orca; then
    orca_json="$(orca terminal list --json 2>/dev/null || printf '[]')"
  fi
  if devkit_superset_available; then
    superset_json="$(devkit_superset_terminals_json)"
  fi

  if [ "$json" = true ]; then
    jq -n --argjson orca "$(printf '%s' "$orca_json" | jq -c '(.result.terminals // .terminals // . // [])' 2>/dev/null || printf '[]')" \
      --argjson superset "$(printf '%s' "$superset_json" | jq -c '(.result.terminals // .terminals // . // [])' 2>/dev/null || printf '[]')" '
      [($orca[]? | {host: "orca", worktree: (.worktreePath // .worktree.path // .worktree // ""), agent: (.agent // .agentId // .agentIdentity // .provider // ""), status: (.status // (if .connected == true then "connected" else "unknown" end))}),
       ($superset[]? | {host: "superset", worktree: (.worktreePath // .workspaceId // .workspace // .workspaceId // ""), agent: (.agent // .agentId // .provider // .title // ""), status: (.status // (if .exited == true then "exited" else "connected" end))})]'
    return 0
  fi

  printf '%-10s %-48s %-20s %s\n' HOST WORKTREE/WORKSPACE AGENT STATUS
  printf '%s\n' "$orca_json" | jq -r '(.result.terminals // .terminals // . // [])[]? | ["orca", (.worktreePath // .worktree.path // .worktree // ""), (.agent // .agentId // .agentIdentity // .provider // ""), (.status // (if .connected == true then "connected" else "unknown" end))] | @tsv' 2>/dev/null | while IFS=$'\t' read -r host worktree agent status; do
    printf '%-10s %-48s %-20s %s\n' "$host" "$worktree" "$agent" "$status"
  done
  printf '%s\n' "$superset_json" | jq -r '(.result.terminals // .terminals // . // [])[]? | ["superset", (.worktreePath // .workspaceId // .workspace // ""), (.agent // .agentId // .provider // .title // ""), (.status // (if .exited == true then "exited" else "connected" end))] | @tsv' 2>/dev/null | while IFS=$'\t' read -r host worktree agent status; do
    printf '%-10s %-48s %-20s %s\n' "$host" "$worktree" "$agent" "$status"
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
