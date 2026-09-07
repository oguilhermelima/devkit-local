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
    reconcile) devkit_dispatch_reconcile "$@" ;;
    watch) devkit_dispatch_watch "$@" ;;
    read) devkit_dispatch_read "$@" ;;
    ack|acknowledge) devkit_dispatch_ack "$@" ;;
    reply) devkit_dispatch_reply "$@" ;;
    close) devkit_dispatch_close "$@" ;;
    -h|--help|"")
      printf 'Usage: devkit orchestrate spawn ... | devkit orchestrate list [--all|--orphans] [--json]\n'
      printf '       devkit orchestrate reconcile <dispatch-id> [--all] [--json]\n'
      printf '       devkit orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--wait-mode nudge|poll] [--json]\n'
      printf '       devkit orchestrate read <dispatch-id> [--lines <count>] [--json]\n'
      printf '       devkit orchestrate ack <dispatch-id> <delivery-id> [--consumer <id>] [--generation <number>] [--json]\n'
      printf '       devkit orchestrate reply <dispatch-id> --text <answer> [--json]\n'
      printf '       devkit orchestrate close <dispatch-id> [--json]\n'
      ;;
    *) devkit_error "unknown orchestrate command: $subcommand"; return "$DEVKIT_USAGE_ERROR" ;;
  esac
}

devkit_dispatch_host_terminal_records() {
  local meta="$1" host workspace_id
  host="$(printf '%s' "$meta" | jq -r '.childHost // empty')"
  workspace_id="$(printf '%s' "$meta" | jq -r '.workspaceId // empty')"
  case "$host" in
    orca)
      devkit_require_command orca || return 1
      orca terminal list --json 2>/dev/null
      ;;
    superset)
      [ -n "$workspace_id" ] || return 1
      devkit_superset_available || return 1
      devkit_superset terminals list --workspace "$workspace_id" --json 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

devkit_dispatch_terminal_id_exists() {
  local records="$1" terminal_id="$2"
  printf '%s' "$records" | jq -e --arg id "$terminal_id" '
    def records: if type == "array" then . else (.result.terminals // .terminals // .sessions // .result.sessions // []) end;
    any(records[]?; (.handle // .terminalHandle // .terminalId // .sessionId // .id // "") == $id)
  ' >/dev/null 2>&1
}

devkit_dispatch_terminal_identity_matches() {
  local records="$1" terminal_id="$2" dispatch_id="$3"
  printf '%s' "$records" | jq -e --arg id "$terminal_id" --arg dispatch "$dispatch_id" '
    def records: if type == "array" then . else (.result.terminals // .terminals // .sessions // .result.sessions // []) end;
    any(records[]?;
      (.handle // .terminalHandle // .terminalId // .sessionId // .id // "") == $id and
      (($id == $dispatch) or ([
        .dispatchId, .metadata.dispatchId, .metadata.devkitDispatchId,
        .env.DEVKIT_DISPATCH_ID, .environment.DEVKIT_DISPATCH_ID,
        .command, .title, .name
      ] | map(select(. != null) | tostring) | join(" ") | contains($dispatch)))
    )
  ' >/dev/null 2>&1
}

devkit_dispatch_parent_status() {
  local meta="$1" host parent workspace_json workspace_id terminals queried=false
  DEVKIT_PARENT_STATUS=unknown
  host="$(printf '%s' "$meta" | jq -r '.parentHost // empty')"
  parent="$(printf '%s' "$meta" | jq -r '.parentSessionId // empty')"
  case "$host" in
    orca)
      devkit_require_command orca || return 0
      terminals="$(orca terminal list --json 2>/dev/null || true)"
      printf '%s' "$terminals" | jq -e . >/dev/null 2>&1 || return 0
      if devkit_dispatch_terminal_id_exists "$terminals" "$parent"; then
        DEVKIT_PARENT_STATUS=alive
      else
        DEVKIT_PARENT_STATUS=gone
      fi
      ;;
    superset)
      devkit_superset_available || return 0
      workspace_json="$(devkit_superset workspaces list --local --json 2>/dev/null || true)"
      printf '%s' "$workspace_json" | jq -e . >/dev/null 2>&1 || return 0
      while IFS= read -r workspace_id; do
        [ -n "$workspace_id" ] || continue
        queried=true
        terminals="$(devkit_superset terminals list --workspace "$workspace_id" --json 2>/dev/null || true)"
        printf '%s' "$terminals" | jq -e . >/dev/null 2>&1 || { DEVKIT_PARENT_STATUS=unknown; return 0; }
        if devkit_dispatch_terminal_id_exists "$terminals" "$parent"; then
          DEVKIT_PARENT_STATUS=alive
          return 0
        fi
      done < <(printf '%s' "$workspace_json" | jq -r '(if type == "array" then . else (.result.workspaces? // .workspaces? // .result? // []) end)[]? | (.id // .workspaceId // .workspace.id // empty)' 2>/dev/null)
      [ "$queried" = true ] && DEVKIT_PARENT_STATUS=gone
      ;;
    *) ;;
  esac
}

devkit_dispatch_parent_alive() {
  devkit_dispatch_parent_status "$1"
  [ "${DEVKIT_PARENT_STATUS:-unknown}" = alive ]
}

devkit_dispatch_terminal_status() {
  local meta="$1" dispatch_id terminal_id runtime records tmux_session tmux_pane pane_pid
  DEVKIT_TERMINAL_STATUS=unknown
  dispatch_id="$(printf '%s' "$meta" | jq -r '.dispatchId')"
  terminal_id="$(printf '%s' "$meta" | jq -r '.terminalId // empty')"
  runtime="$(printf '%s' "$meta" | jq -r '.runtime // "host"')"
  if [ "$runtime" = tmux ]; then
    tmux_session="$(printf '%s' "$meta" | jq -r '.tmuxSession // empty')"
    tmux_pane="$(printf '%s' "$meta" | jq -r '.tmuxPane // empty')"
    if ! devkit_require_command tmux || ! devkit_tmux_session_exists "$tmux_session"; then
      DEVKIT_TERMINAL_STATUS=missing
      return 0
    fi
    if ! tmux list-panes -t "$tmux_session" -F '#{pane_id}' 2>/dev/null | grep -Fx "$tmux_pane" >/dev/null 2>&1; then
      DEVKIT_TERMINAL_STATUS=missing
      return 0
    fi
    pane_pid="$(tmux display-message -p -t "$tmux_pane" '#{pane_pid}' 2>/dev/null || true)"
    if [ -n "$pane_pid" ] && ps eww -p "$pane_pid" 2>/dev/null | grep -F "DEVKIT_DISPATCH_ID=$dispatch_id" >/dev/null 2>&1; then
      DEVKIT_TERMINAL_STATUS=proven
    fi
    return 0
  fi
  records="$(devkit_dispatch_host_terminal_records "$meta" 2>/dev/null || true)"
  printf '%s' "$records" | jq -e . >/dev/null 2>&1 || return 0
  if ! devkit_dispatch_terminal_id_exists "$records" "$terminal_id"; then
    DEVKIT_TERMINAL_STATUS=missing
    return 0
  fi
  if devkit_dispatch_terminal_identity_matches "$records" "$terminal_id" "$dispatch_id"; then
    DEVKIT_TERMINAL_STATUS=proven
  fi
}

command_orchestrate_list() {
  local json=false all=false orphans=false arg caller_id caller_host meta_path meta owned orphan entries='[]' state dispatch_id outcome
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
    if [ "$(printf '%s' "$meta" | jq -r '.state // empty')" != closed ]; then
      devkit_dispatch_reconcile_one "$dispatch_id" >/dev/null 2>&1 || true
      meta="$(devkit_dispatch_meta_read "$dispatch_id" 2>/dev/null || printf '%s' "$meta")"
    fi
    owned=false
    if [ -n "$caller_id" ] && printf '%s' "$meta" | jq -e --arg id "$caller_id" --arg host "$caller_host" '.parentSessionId == $id and .parentHost == $host' >/dev/null 2>&1; then
      owned=true
    fi
    orphan=false
    devkit_dispatch_parent_status "$meta"
    [ "${DEVKIT_PARENT_STATUS:-unknown}" = gone ] && orphan=true
    state="$(printf '%s' "$meta" | jq -r '.state // empty')"
    if [ "$all" != true ] && [ "$orphans" != true ] && [ "$owned" != true ]; then continue; fi
    if [ "$orphans" = true ] && [ "$orphan" != true ]; then continue; fi
    outcome="$(printf '%s' "$meta" | jq -r '.reconcileOutcome // "unchanged"')"
    entries="$(jq --argjson item "$meta" --argjson owned "$owned" --argjson orphan "$orphan" --arg outcome "$outcome" '. + [$item + {ownedByCaller: $owned, orphan: $orphan, reconcileResult: $outcome}]' <<<"$entries")"
  done
  if [ "$json" = true ]; then
    printf '%s\n' "$entries"
    return 0
  fi
  printf '%-38s %-20s %-18s %-12s %-10s %s\n' DISPATCH STATE PROCESS TERMINAL OWNERSHIP WORKTREE
  printf '%s\n' "$entries" | jq -r '.[] | [.dispatchId, .state, (.processState // "unknown"), (.terminalState // "unknown"), (if .ownedByCaller then "owned" else "not-owned" end), .worktreePath] | @tsv' | while IFS=$'\t' read -r dispatch state process terminal ownership worktree; do
    printf '%-38s %-20s %-18s %-12s %-10s %s\n' "$dispatch" "$state" "$process" "$terminal" "$ownership" "$worktree"
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
