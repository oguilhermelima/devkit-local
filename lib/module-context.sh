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

DEVKIT_DISPATCH_LIST_CACHE_ACTIVE=false
DEVKIT_DISPATCH_LIST_ORCA_PREPARED=false
DEVKIT_DISPATCH_LIST_ORCA_AVAILABLE=false
DEVKIT_DISPATCH_LIST_ORCA_VALID=false
DEVKIT_DISPATCH_LIST_ORCA_TERMINALS='[]'
DEVKIT_DISPATCH_LIST_ORCA_IDS=''
DEVKIT_DISPATCH_LIST_SUPERSET_PREPARED=false
DEVKIT_DISPATCH_LIST_SUPERSET_AVAILABLE=false
DEVKIT_DISPATCH_LIST_SUPERSET_VALID=false
DEVKIT_DISPATCH_LIST_SUPERSET_TERMINALS='[]'
DEVKIT_DISPATCH_LIST_SUPERSET_IDS=''

devkit_dispatch_list_cache_reset() {
  DEVKIT_DISPATCH_LIST_CACHE_ACTIVE=true
  DEVKIT_DISPATCH_LIST_ORCA_PREPARED=false
  DEVKIT_DISPATCH_LIST_ORCA_AVAILABLE=false
  DEVKIT_DISPATCH_LIST_ORCA_VALID=false
  DEVKIT_DISPATCH_LIST_ORCA_TERMINALS='[]'
  DEVKIT_DISPATCH_LIST_ORCA_IDS=''
  DEVKIT_DISPATCH_LIST_SUPERSET_PREPARED=false
  DEVKIT_DISPATCH_LIST_SUPERSET_AVAILABLE=false
  DEVKIT_DISPATCH_LIST_SUPERSET_VALID=false
  DEVKIT_DISPATCH_LIST_SUPERSET_TERMINALS='[]'
  DEVKIT_DISPATCH_LIST_SUPERSET_IDS=''
}

devkit_dispatch_list_cache_disable() {
  DEVKIT_DISPATCH_LIST_CACHE_ACTIVE=false
}

devkit_dispatch_list_cache_prepare_host() {
  local host="$1" records
  case "$host" in
    orca)
      [ "$DEVKIT_DISPATCH_LIST_ORCA_PREPARED" = true ] && return 0
      DEVKIT_DISPATCH_LIST_ORCA_PREPARED=true
      if ! devkit_require_command orca; then
        return 0
      fi
      DEVKIT_DISPATCH_LIST_ORCA_AVAILABLE=true
      records="$(orca terminal list --json 2>/dev/null || true)"
      DEVKIT_DISPATCH_LIST_ORCA_TERMINALS="$records"
      if printf '%s' "$records" | jq -e . >/dev/null 2>&1; then
        DEVKIT_DISPATCH_LIST_ORCA_VALID=true
        DEVKIT_DISPATCH_LIST_ORCA_IDS="$(printf '%s' "$records" | jq -r '
          def records: if type == "array" then . else (.result.terminals // .terminals // .sessions // .result.sessions // []) end;
          records[]? | (.handle // .terminalHandle // .terminalId // .sessionId // .id // "")
        ' 2>/dev/null || true)"
      fi
      ;;
    superset)
      [ "$DEVKIT_DISPATCH_LIST_SUPERSET_PREPARED" = true ] && return 0
      DEVKIT_DISPATCH_LIST_SUPERSET_PREPARED=true
      if ! devkit_superset_available; then
        return 0
      fi
      DEVKIT_DISPATCH_LIST_SUPERSET_AVAILABLE=true
      records="$(devkit_superset_terminals_json 2>/dev/null || true)"
      DEVKIT_DISPATCH_LIST_SUPERSET_TERMINALS="$records"
      if printf '%s' "$records" | jq -e . >/dev/null 2>&1; then
        DEVKIT_DISPATCH_LIST_SUPERSET_VALID=true
        DEVKIT_DISPATCH_LIST_SUPERSET_IDS="$(printf '%s' "$records" | jq -r '
          def records: if type == "array" then . else (.result.terminals // .terminals // .sessions // .result.sessions // []) end;
          records[]? | (.handle // .terminalHandle // .terminalId // .sessionId // .id // "")
        ' 2>/dev/null || true)"
      fi
      ;;
  esac
}

devkit_dispatch_host_terminal_records() {
  local meta="$1" host workspace_id
  host="$(printf '%s' "$meta" | jq -r '.childHost // empty')"
  workspace_id="$(printf '%s' "$meta" | jq -r '.workspaceId // empty')"
  if [ "$DEVKIT_DISPATCH_LIST_CACHE_ACTIVE" = true ]; then
    devkit_dispatch_list_cache_prepare_host "$host"
    case "$host" in
      orca)
        [ "$DEVKIT_DISPATCH_LIST_ORCA_AVAILABLE" = true ] || return 1
        printf '%s' "$DEVKIT_DISPATCH_LIST_ORCA_TERMINALS"
        return 0
        ;;
      superset)
        [ "$DEVKIT_DISPATCH_LIST_SUPERSET_AVAILABLE" = true ] || return 1
        printf '%s' "$DEVKIT_DISPATCH_LIST_SUPERSET_TERMINALS"
        return 0
        ;;
      *) return 1 ;;
    esac
  fi
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
  if [ "$DEVKIT_DISPATCH_LIST_CACHE_ACTIVE" = true ]; then
    case "$host" in
      orca)
        devkit_dispatch_list_cache_prepare_host orca
        [ "$DEVKIT_DISPATCH_LIST_ORCA_AVAILABLE" = true ] || return 0
        [ "$DEVKIT_DISPATCH_LIST_ORCA_VALID" = true ] || return 0
        if [ -n "$parent" ] && printf '%s\n' "$DEVKIT_DISPATCH_LIST_ORCA_IDS" | grep -Fx "$parent" >/dev/null 2>&1; then
          DEVKIT_PARENT_STATUS=alive
        else
          DEVKIT_PARENT_STATUS=gone
        fi
        return 0
        ;;
      superset)
        devkit_dispatch_list_cache_prepare_host superset
        [ "$DEVKIT_DISPATCH_LIST_SUPERSET_AVAILABLE" = true ] || return 0
        [ "$DEVKIT_DISPATCH_LIST_SUPERSET_VALID" = true ] || return 0
        if [ -n "$parent" ] && printf '%s\n' "$DEVKIT_DISPATCH_LIST_SUPERSET_IDS" | grep -Fx "$parent" >/dev/null 2>&1; then
          DEVKIT_PARENT_STATUS=alive
        else
          DEVKIT_PARENT_STATUS=gone
        fi
        return 0
        ;;
      *) return 0 ;;
    esac
  fi
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
  local json=false all=false orphans=false arg caller_id caller_host meta_path
  local meta_summary dispatch_id state child_host parent_host open_dispatches=''
  local need_orca=false need_superset=false entries final_orca_ids final_superset_ids
  local orca_known=false superset_known=false
  local -a meta_paths
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
  meta_paths=()
  for meta_path in "$DEVKIT_DISPATCH_DIR"/*/meta.json; do
    [ -f "$meta_path" ] || continue
    meta_paths[${#meta_paths[@]}]="$meta_path"
  done
  if [ "${#meta_paths[@]}" -eq 0 ]; then
    if [ "$json" = true ]; then
      printf '[]\n'
      return 0
    fi
    printf '%-38s %-20s %-18s %-12s %-10s %s\n' DISPATCH STATE PROCESS TERMINAL OWNERSHIP WORKTREE
    return 0
  fi

  # One slurp keeps field extraction linear instead of spawning jq for each field.
  meta_summary="$(jq -s -r '
    .[] | [(.dispatchId // ""), (.state // ""), (.childHost // ""), (.parentHost // "")] | @tsv
  ' "${meta_paths[@]}")" || return 1
  while IFS=$'\t' read -r dispatch_id state child_host parent_host; do
    [ -n "$dispatch_id" ] || continue
    [ "$state" = closed ] || open_dispatches="${open_dispatches}${dispatch_id}"$'\n'
    case "$child_host:$parent_host" in
      orca:*) need_orca=true ;;
      superset:*) need_superset=true ;;
    esac
    case "$parent_host" in
      orca|superset)
        [ "$parent_host" = orca ] && need_orca=true
        [ "$parent_host" = superset ] && need_superset=true
        ;;
    esac
  done <<EOF
$meta_summary
EOF

  devkit_dispatch_list_cache_reset
  [ "$need_orca" = true ] && devkit_dispatch_list_cache_prepare_host orca
  [ "$need_superset" = true ] && devkit_dispatch_list_cache_prepare_host superset
  while IFS= read -r dispatch_id; do
    [ -n "$dispatch_id" ] || continue
    devkit_dispatch_reconcile_one "$dispatch_id" >/dev/null 2>&1 || true
  done <<EOF
$open_dispatches
EOF

  final_orca_ids="$DEVKIT_DISPATCH_LIST_ORCA_IDS"
  final_superset_ids="$DEVKIT_DISPATCH_LIST_SUPERSET_IDS"
  [ "$DEVKIT_DISPATCH_LIST_ORCA_AVAILABLE" = true ] && [ "$DEVKIT_DISPATCH_LIST_ORCA_VALID" = true ] && orca_known=true
  [ "$DEVKIT_DISPATCH_LIST_SUPERSET_AVAILABLE" = true ] && [ "$DEVKIT_DISPATCH_LIST_SUPERSET_VALID" = true ] && superset_known=true
  entries="$(jq -s \
    --arg callerId "$caller_id" --arg callerHost "$caller_host" \
    --arg orcaIds "$final_orca_ids" --arg supersetIds "$final_superset_ids" \
    --argjson orcaKnown "$orca_known" --argjson supersetKnown "$superset_known" \
    --argjson all "$all" --argjson orphans "$orphans" '
    def ids($value): $value | split("\n") | map(select(length > 0));
    map(. as $item
      | ($item.parentSessionId // "") as $parentId
      | ($item.parentHost // "") as $parentHost
      | (($callerId != "") and ($item.parentSessionId == $callerId) and ($parentHost == $callerHost)) as $owned
      | (if $parentHost == "orca" and $orcaKnown then
           (ids($orcaIds) | index($parentId) == null)
         elif $parentHost == "superset" and $supersetKnown then
           (ids($supersetIds) | index($parentId) == null)
         else false
         end) as $orphan
      | $item + {ownedByCaller: $owned, orphan: $orphan, reconcileResult: ($item.reconcileOutcome // "unchanged")})
    | map(select(($all or $orphans or .ownedByCaller) and (($orphans | not) or .orphan)))
  ' "${meta_paths[@]}")" || {
    devkit_dispatch_list_cache_disable
    return 1
  }
  devkit_dispatch_list_cache_disable
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
