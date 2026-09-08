#!/usr/bin/env bash

MEGABRAIN_AGENT_OPTION_TEMPLATES='codex|-c|model="%s"|-c|model_reasoning_effort="%s"
claude|--model|%s|--effort|%s
agy|--model|%s||'
# Codex has no --model or --effort flags, so its overrides use -c.
MEGABRAIN_AGY_MODEL_IDS='gemini-3.8-flash-high
gemini-3.8-flash-medium
gemini-3.8-flash-low
gemini-3.7-flash-high
gemini-3.7-flash-medium
gemini-3.7-flash-low
gemini-3.6-flash-high
gemini-3.6-flash-medium
gemini-3.6-flash-low
gemini-3.1-pro-high
gemini-3.1-pro-low
claude-sonnet-4-6
claude-opus-4-6-thinking
gpt-oss-120b-medium'
MEGABRAIN_AGENT_LAUNCH_ARGS='codex|--dangerously-bypass-hook-trust
codex|--dangerously-bypass-approvals-and-sandbox
claude|--dangerously-skip-permissions
agy|--dangerously-skip-permissions'
MEGABRAIN_AGENT_READY_TIMEOUT_MS="${MEGABRAIN_AGENT_READY_TIMEOUT_MS:-10000}"

megabrain_worktree_root() {
  local raw read_only=false
  if [ "${1:-}" = --read-only ]; then
    read_only=true
  fi
  if ! megabrain_superset_available; then
    megabrain_error "superset CLI is required for shared worktrees"
    return 1
  fi
  raw="$(megabrain_superset settings get worktreeBaseDir 2>/dev/null || true)"
  raw="$(printf '%s\n' "$raw" | megabrain_trim)"
  if [ -n "$raw" ] && [ "$raw" != "null" ]; then
    raw="$(printf '%s' "$raw" | jq -r 'if type == "object" then (.value // .result.value // .path // .result.path // empty) elif type == "string" then . else empty end' 2>/dev/null || printf '%s' "$raw")"
    raw="$(printf '%s\n' "$raw" | megabrain_trim)"
  fi
  if [ -z "$raw" ]; then
    if [ "$read_only" = true ] || [ ! -t 0 ]; then
      megabrain_error "Superset worktreeBaseDir is unset; run superset settings set worktreeBaseDir <path>"
      return 1
    fi
    read -r -p "Shared worktree root: " raw
    [ -n "$raw" ] || { megabrain_error "worktree root cannot be empty"; return 1; }
    megabrain_superset settings set worktreeBaseDir "$raw" >/dev/null || return 1
  fi
  raw="${raw/#\~/$HOME}"
  if [ "${raw#/}" = "$raw" ]; then
    raw="$PWD/$raw"
  fi
  MEGABRAIN_SHARED_ROOT="$(cd "$raw" 2>/dev/null && pwd -P || true)"
  if [ -z "$MEGABRAIN_SHARED_ROOT" ]; then
    MEGABRAIN_SHARED_ROOT="$raw"
  fi
  printf '%s\n' "$MEGABRAIN_SHARED_ROOT"
}

megabrain_repo_from_orca() {
  local selector="$1"
  local selector_lower path display_name display_lower base_name git_root common_dir canonical_root
  selector_lower="$(megabrain_lower "$selector")"
  if [ -d "$selector" ] && git -C "$selector" rev-parse --show-toplevel >/dev/null 2>&1; then
    git_root="$(git -C "$selector" rev-parse --show-toplevel)"
    common_dir="$(git -C "$selector" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    case "$common_dir" in
      */.git)
        canonical_root="${common_dir%/.git}"
        if git -C "$canonical_root" rev-parse --show-toplevel >/dev/null 2>&1; then
          printf '%s\n' "$(git -C "$canonical_root" rev-parse --show-toplevel)"
          return 0
        fi
        ;;
    esac
    printf '%s\n' "$git_root"
    return 0
  fi
  if [ -f "$selector" ] && git -C "$(dirname "$selector")" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$(dirname "$selector")" rev-parse --show-toplevel
    return 0
  fi
  if ! megabrain_require_command orca; then
    megabrain_error "repo must be a git path when orca is not installed"
    return 1
  fi
  while IFS=$'\t' read -r display_name path; do
    [ -n "$path" ] || continue
    display_lower="$(megabrain_lower "$display_name")"
    base_name="$(megabrain_lower "$(basename "$path")")"
    if [ "$selector_lower" = "$display_lower" ] || [ "$selector_lower" = "$base_name" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(orca repo list --json 2>/dev/null | jq -r '.result.repos[]? | [(.displayName // ""), (.path // "")] | @tsv' 2>/dev/null)
  megabrain_error "repo not found: $selector"
  return 1
}

megabrain_repo_default_base() {
  local repo="$1"
  local base
  base="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  base="${base#origin/}"
  if [ -z "$base" ]; then
    base="$(git -C "$repo" config --get init.defaultBranch 2>/dev/null || true)"
  fi
  if [ -z "$base" ]; then
    base="main"
  fi
  printf '%s\n' "$base"
}

megabrain_slug_from_branch() {
  local branch="$1"
  branch="${branch//\//-}"
  if [ -z "$branch" ] || [ "$branch" = "." ] || [ "$branch" = ".." ] || [[ "$branch" == *"/"* ]] || [[ "$branch" == *$'\n'* ]]; then
    return 1
  fi
  printf '%s\n' "$branch"
}

megabrain_agy_model_known() {
  if declare -F megabrain_model_known >/dev/null 2>&1 && megabrain_model_known agy "$1"; then
    return 0
  fi
  printf '%s\n' "$MEGABRAIN_AGY_MODEL_IDS" | grep -Fx -- "$1" >/dev/null 2>&1
}

megabrain_agy_model_error() {
  megabrain_error "$1"
  printf 'Valid agy model ids:\n%s\n' "$MEGABRAIN_AGY_MODEL_IDS" >&2
}

megabrain_agy_model_id() {
  local model="$1" effort="$2" base candidate
  case "$model" in
    *-high) base="${model%-high}" ;;
    *-medium) base="${model%-medium}" ;;
    *-low) base="${model%-low}" ;;
    *) base="$model" ;;
  esac
  if declare -F megabrain_model_known >/dev/null 2>&1 && megabrain_model_known agy "$model"; then
    if megabrain_model_validate_reasoning agy "$model" "$effort" >/dev/null 2>&1; then
      printf '%s\n' "$model"
      return 0
    fi
  fi
  candidate="${base}-${effort}"
  if megabrain_agy_model_known "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  megabrain_agy_model_error "agy cannot honor effort '$effort' for model '$model'"
  return 1
}

megabrain_superset_projects_json() {
  megabrain_superset projects list --json 2>/dev/null
}

megabrain_superset_workspaces_json() {
  megabrain_superset workspaces list --local --json 2>/dev/null
}

megabrain_project_id_for_path() {
  local repo_path="$1"
  megabrain_superset_projects_json | jq -r --arg path "$repo_path" '
    (if type == "array" then . else (.result.projects? // .projects? // .result? // []) end)[]? |
    select((.path // .localPath // .repoPath // "") == $path) |
    (.id // .projectId // .project.id // empty)' 2>/dev/null | head -n 1
}

megabrain_project_name_for_path() {
  local repo_path="$1"
  local name
  name="$(orca repo list --json 2>/dev/null | jq -r --arg path "$repo_path" '.result.repos[]? | select(.path == $path) | .displayName' 2>/dev/null | head -n 1)"
  if [ -z "$name" ]; then
    name="$(basename "$repo_path")"
  fi
  printf '%s\n' "$name"
}

megabrain_ensure_superset_project() {
  local repo_path="$1"
  local project_id project_name response
  project_id="$(megabrain_project_id_for_path "$repo_path")"
  if [ -n "$project_id" ]; then
    printf '%s\n' "$project_id"
    return 0
  fi
  project_name="$(megabrain_project_name_for_path "$repo_path")"
  response="$(megabrain_superset projects create --local --import "$repo_path" --name "$project_name" --json 2>/dev/null || true)"
  project_id="$(printf '%s' "$response" | jq -r '.result.project.id // .result.id // .project.id // .id // empty' 2>/dev/null)"
  if [ -z "$project_id" ]; then
    project_id="$(megabrain_project_id_for_path "$repo_path")"
  fi
  [ -n "$project_id" ] || { megabrain_error "could not register Superset project for $repo_path"; return 1; }
  printf '%s\n' "$project_id"
}

megabrain_workspace_id_for_target() {
  local target="$1"
  megabrain_superset_workspaces_json | jq -r --arg target "$target" '
    (if type == "array" then . else (.result.workspaces? // .workspaces? // .result? // []) end)[]? |
    select((.branch // .git.branch // "" | sub("^refs/heads/"; "")) == $target or
           (.worktreePath // .path // .worktree.path // "") == $target or
           (.name // "") == $target) |
    (.id // .workspaceId // .workspace.id // empty)' 2>/dev/null | head -n 1
}

megabrain_workspace_path_for_target() {
  local target="$1"
  megabrain_superset_workspaces_json | jq -r --arg target "$target" '
    (if type == "array" then . else (.result.workspaces? // .workspaces? // .result? // []) end)[]? |
    select((.branch // .git.branch // "" | sub("^refs/heads/"; "")) == $target or
           (.worktreePath // .path // .worktree.path // "") == $target or
           (.name // "") == $target) |
    (.worktreePath // .path // .worktree.path // empty)' 2>/dev/null | head -n 1
}

megabrain_workspace_create() {
  local project_id="$1" branch="$2" slug="$3"
  local response id
  response="$(megabrain_superset workspaces create --local --project "$project_id" --branch "$branch" --name "$slug" --json 2>/dev/null || true)"
  id="$(printf '%s' "$response" | jq -r '.result.workspace.id // .result.id // .workspace.id // .id // empty' 2>/dev/null)"
  if [ -z "$id" ]; then
    id="$(megabrain_workspace_id_for_target "$branch")"
  fi
  [ -n "$id" ] || { megabrain_error "could not create or find Superset workspace for $branch"; return 1; }
  printf '%s\n' "$id"
}

megabrain_agent_command() {
  local agent="$1" model="$2" effort="$3"
  local agent_lower model_flag model_format effort_flag effort_format model_value effort_value
  local option_template known_agent known_model_flag known_model_format known_effort_flag known_effort_format
  local launch_agent launch_arg
  shift 3
  local -a command_parts passthrough_args=()
  [ "$#" -eq 0 ] || passthrough_args=("$@")
  command_parts=("$agent")
  agent_lower="$(megabrain_lower "$agent")"
  if [ "$agent_lower" = agy ] && [ -n "$model" ]; then
    [ -n "$effort" ] || {
      megabrain_agy_model_error "agy requires an effort that is part of the model id"
      return 1
    }
    model="$(megabrain_agy_model_id "$model" "$effort")" || return 1
  fi
  while IFS='|' read -r launch_agent launch_arg; do
    [ "$launch_agent" = "$agent_lower" ] && command_parts+=("$launch_arg")
  done <<EOF
$MEGABRAIN_AGENT_LAUNCH_ARGS
EOF
  option_template='--model|%s|--effort|%s'
  while IFS='|' read -r known_agent known_model_flag known_model_format known_effort_flag known_effort_format; do
    if [ "$known_agent" = "$agent_lower" ]; then
      option_template="$known_model_flag|$known_model_format|$known_effort_flag|$known_effort_format"
      break
    fi
  done <<EOF
$MEGABRAIN_AGENT_OPTION_TEMPLATES
EOF
  IFS='|' read -r model_flag model_format effort_flag effort_format <<<"$option_template"
  if [ -n "$model" ]; then
    printf -v model_value "$model_format" "$model"
    command_parts+=("$model_flag" "$model_value")
  fi
  if [ -n "$effort" ] && [ -n "$effort_flag" ]; then
    printf -v effort_value "$effort_format" "$effort"
    command_parts+=("$effort_flag" "$effort_value")
  fi
  if [ "${#passthrough_args[@]}" -gt 0 ]; then
    command_parts+=("${passthrough_args[@]}")
  fi
  printf '%q ' "${command_parts[@]}"
}

megabrain_terminal_command_with_agent_permissions() {
  local command_text="$1" prefix agent_lower launch_agent launch_arg launch_args="" rest
  if [[ "$command_text" =~ ^([[:space:]]*(env[[:space:]]+)?([a-zA-Z_][a-zA-Z0-9_]*=[^[:space:]]*[[:space:]]+)*)(codex|claude|agy)([[:space:]]|$) ]]; then
    prefix="${BASH_REMATCH[1]}"
    agent_lower="${BASH_REMATCH[4]}"
  else
    printf '%s\n' "$command_text"
    return 0
  fi
  rest="${command_text:${#prefix}+${#agent_lower}}"
  while IFS='|' read -r launch_agent launch_arg; do
    if [ "$launch_agent" = "$agent_lower" ]; then
      case " $command_text " in
        *" $launch_arg "*) ;;
        *) launch_args="$launch_args $(printf '%q' "$launch_arg")" ;;
      esac
    fi
  done <<EOF
$MEGABRAIN_AGENT_LAUNCH_ARGS
EOF
  printf '%s%s%s%s\n' "$prefix" "$agent_lower" "$launch_args" "$rest"
}

megabrain_resolve_spawn_runtime() {
  local requested="${1:-auto}"
  MEGABRAIN_SPAWN_RUNTIME=""
  MEGABRAIN_SPAWN_CONTEXT=""
  case "$requested" in
    auto)
      if megabrain_runtime_enabled; then
        requested=tmux
      else
        requested=host
      fi
      ;;
    true) requested=tmux ;;
    false) requested=host ;;
    tmux|host) ;;
    *) megabrain_error "invalid spawn runtime: $requested"; return "$MEGABRAIN_USAGE_ERROR" ;;
  esac
  if [ "$requested" = tmux ]; then
    megabrain_tmux_available || { megabrain_error "tmux spawn runtime was selected but tmux is not on PATH"; return 1; }
  fi
  megabrain_session_id >/dev/null
  if [ -z "$MEGABRAIN_SESSION_ID" ]; then
    if [ "$requested" = host ]; then
      megabrain_error "IDE spawn runtime requires a managed Orca or Superset terminal"
      return 1
    fi
    megabrain_error "tmux spawn runtime requires a managed Orca or Superset terminal"
    return 1
  fi
  MEGABRAIN_SPAWN_RUNTIME="$requested"
  MEGABRAIN_SPAWN_CONTEXT="$MEGABRAIN_SESSION_HOST"
  case "$MEGABRAIN_SPAWN_CONTEXT" in
    orca|superset) ;;
    tmux)
      [ "$requested" = tmux ] || { megabrain_error "IDE spawn runtime requires a managed Orca or Superset terminal"; return 1; }
      ;;
    *) megabrain_error "cannot launch agent from unknown orchestration host"; return 1 ;;
  esac
}

megabrain_project_run_command() {
  local repo_root="$1" config_path="$1/.superset/config.json" command_text
  [ -f "$config_path" ] || return 1
  command_text="$(jq -er '
    if (.run? | type) == "array" then
      [.run[]? | select(type == "string" and length > 0)] |
      if length > 0 then join(" && ") else empty end
    else
      empty
    end
  ' "$config_path" 2>/dev/null)" || return 1
  [ -n "$command_text" ] || return 1
  printf '%s\n' "$command_text"
}

megabrain_tmux_cleanup_launch() {
  local context="$1" workspace_id="$2" terminal_id="$3" tmux_session="$4" tmux_pane="$5" host_terminal_created="$6"
  if [ "$host_terminal_created" = true ]; then
    tmux kill-session -t "$tmux_session" >/dev/null 2>&1 || true
    [ -n "$terminal_id" ] || return 0
    case "$context" in
      superset) megabrain_superset terminals close --workspace "$workspace_id" --terminal "$terminal_id" --json >/dev/null 2>&1 || true ;;
      orca) orca terminal close --terminal "$terminal_id" --json >/dev/null 2>&1 || true ;;
    esac
  elif [ -n "$tmux_pane" ]; then
    tmux kill-pane -t "$tmux_pane" >/dev/null 2>&1 || true
  fi
}

megabrain_host_cleanup_launch() {
  local context="$1" workspace_id="$2" terminal_id="$3"
  case "$context" in
    superset) megabrain_superset terminals close --workspace "$workspace_id" --terminal "$terminal_id" --json >/dev/null 2>&1 || true ;;
    orca) orca terminal close --terminal "$terminal_id" --json >/dev/null 2>&1 || true ;;
  esac
}

megabrain_host_terminal_readback() {
  local context="$1" workspace_id="$2" terminal_id="$3" response
  # WHY: Read-back fails at creation instead of waiting 30 seconds for a receipt from an unreachable terminal.
  case "$context" in
    superset)
      response="$(megabrain_superset terminals read --workspace "$workspace_id" --terminal "$terminal_id" --json 2>/dev/null)" || {
        megabrain_error "Superset terminal $terminal_id could not be read immediately after creation"
        return 1
      }
      ;;
    orca)
      response="$(orca terminal read --terminal "$terminal_id" --json 2>/dev/null)" || {
        megabrain_error "orca terminal $terminal_id could not be read immediately after creation"
        return 1
      }
      ;;
    *)
      megabrain_error "unsupported host terminal context: $context"
      return 1
      ;;
  esac
  printf '%s' "$response" | jq -e . >/dev/null 2>&1 || {
    megabrain_error "$context terminal $terminal_id returned invalid read-back data"
    return 1
  }
}

megabrain_superset_wait_for_terminal_ready() {
  local workspace_id="$1" terminal_id="$2" timeout_ms="${MEGABRAIN_AGENT_READY_TIMEOUT_MS:-10000}"
  local attempts=$(( (timeout_ms + 99) / 100 )) attempt output rendered previous=""
  [ "$attempts" -gt 0 ] || attempts=1
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    output="$(megabrain_superset terminals read --workspace "$workspace_id" --terminal "$terminal_id" --json 2>/dev/null || true)"
    rendered="$(printf '%s' "$output" | jq -r '
      if type == "string" then .
      elif type == "object" then (.text // .output // .content // .result.text // .result.output // tostring)
      else tostring
      end
    ' 2>/dev/null || true)"
    if [ -n "$(printf '%s' "$rendered" | tr -d '[:space:]')" ] && [ "$rendered" = "$previous" ]; then
      return 0
    fi
    previous="$rendered"
    sleep 0.1
  done
  megabrain_error "Superset terminal $terminal_id did not settle within ${timeout_ms}ms"
  return 1
}

megabrain_spawn_mark_prompt_delivered() {
  megabrain_dispatch_meta_update_prompt "$1" true delivered
}

megabrain_spawn_mark_prompt_failed() {
  local dispatch_id="$1" reason="$2"
  megabrain_dispatch_meta_update_prompt "$dispatch_id" false not-delivered "$reason" >/dev/null 2>&1 || true
  megabrain_dispatch_meta_update_state "$dispatch_id" failed >/dev/null 2>&1 || true
  megabrain_dispatch_meta_update_process_state "$dispatch_id" failed >/dev/null 2>&1 || true
  megabrain_dispatch_meta_update_fields "$dispatch_id" __keep__ __keep__ __keep__ prompt-delivery "$reason" __keep__ __keep__ __keep__ >/dev/null 2>&1 || true
}

megabrain_spawn_mark_running_if_spawning() {
  local dispatch_id="$1" state
  state="$(megabrain_dispatch_meta_read "$dispatch_id" | jq -r '.state // empty')" || return 1
  case "$state" in
    spawning) megabrain_dispatch_meta_update_state "$dispatch_id" running ;;
    running|waiting_for_reply|done) return 0 ;;
    *) megabrain_error "dispatch $dispatch_id cannot become running from state $state"; return 1 ;;
  esac
}

megabrain_launch_agent() {
  local worktree_path="$1" workspace_id="$2" agent="$3" model="$4" effort="$5" prompt="$6" label="${7:-}"
  local context="" command_text="" response="" session_id="" final_prompt="" dispatch_preamble="" parent_id="" parent_host="" child_host="" branch="" meta=""
  local parent_tmux_session="" parent_tmux_pane="" parent_workspace_id="${SUPERSET_WORKSPACE_ID:-}"
  local agent_used="" model_honored=false substitution_report="" dispatch_id="" runtime="" tmux_session="" tmux_pane="" existing_session="" tmux_command="" host_terminal_created=false
  local -a passthrough_args=()
  shift 7
  [ "$#" -eq 0 ] || passthrough_args=("$@")
  MEGABRAIN_LAST_DISPATCH=""
  megabrain_session_id >/dev/null
  parent_id="$MEGABRAIN_SESSION_ID"
  parent_host="$MEGABRAIN_SESSION_HOST"
  if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
    parent_tmux_session="$(megabrain_dispatch_tmux_caller_session 2>/dev/null || true)"
    parent_tmux_pane="$TMUX_PANE"
  fi
  [ -n "$parent_id" ] || { megabrain_error "cannot spawn a managed dispatch from an unmanaged shell"; return 1; }
  if [ -z "${MEGABRAIN_SPAWN_RUNTIME:-}" ] || [ -z "${MEGABRAIN_SPAWN_CONTEXT:-}" ] || [ "$MEGABRAIN_SPAWN_CONTEXT" != "$parent_host" ]; then
    megabrain_resolve_spawn_runtime auto || return 1
  fi
  runtime="$MEGABRAIN_SPAWN_RUNTIME"
  context="$MEGABRAIN_SPAWN_CONTEXT"
  MEGABRAIN_LAST_RUNTIME="$runtime"
  if [ "$runtime" = tmux ]; then
    MEGABRAIN_LAST_SPAWN_RUNTIME=tmux
  else
    MEGABRAIN_LAST_SPAWN_RUNTIME=ide
  fi
  agent_used="$agent"
  branch="$(git -C "$worktree_path" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')"
  [ -n "$label" ] || label="$(megabrain_dispatch_default_label)"
  case "$label" in
    *$'\n'*) megabrain_error "dispatch label cannot contain a newline"; return "$MEGABRAIN_USAGE_ERROR" ;;
  esac
  dispatch_preamble="$(megabrain_dispatch_preamble "$worktree_path")" || return 1
  final_prompt="[megabrain dispatch: ${label}]

${dispatch_preamble}

${prompt}"
  if [ "$runtime" = tmux ]; then
    megabrain_validate_prompt_budget "$final_prompt" tmux prompt || return 1
  else
    megabrain_validate_prompt_budget "$final_prompt" argv prompt || return 1
  fi
  if [ "$runtime" = tmux ]; then
    dispatch_id="$(megabrain_dispatch_new_id)" || return 1
    if [ "$context" = superset ]; then
      megabrain_superset_available || { megabrain_error "superset CLI is not available"; return 1; }
    elif [ "$context" = orca ]; then
      megabrain_require_command orca || { megabrain_error "orca CLI is not available"; return 1; }
    elif [ "$context" != tmux ]; then
      megabrain_error "cannot launch agent from unknown orchestration host"
      return 1
    fi
    megabrain_tmux_existing_session_for_worktree "$worktree_path" || true
    existing_session="${MEGABRAIN_TMUX_EXISTING_SESSION:-}"
    if [ -z "$existing_session" ] && [ "$context" = tmux ]; then
      existing_session="$parent_tmux_session"
    fi
    if [ -n "$existing_session" ]; then
      tmux_session="$existing_session"
      session_id="$(megabrain_tmux_host_terminal_for_session "$tmux_session" 2>/dev/null || true)"
      [ -n "$session_id" ] || session_id="$parent_id"
      [ -n "$session_id" ] || session_id="unknown-host-terminal"
      tmux_pane="$(megabrain_tmux_split_pane "$tmux_session" "$worktree_path")" || {
        megabrain_error "could not split tmux session $tmux_session"
        return 1
      }
    else
      tmux_session="megabrain-$dispatch_id"
      # Start a shell first so terminal-identification replies cannot leak into the agent composer.
      tmux_command="tmux new-session -A -s $(printf '%q' "$tmux_session")"
      if [ "$context" = orca ]; then
        response="$(orca terminal create --worktree "path:$worktree_path" --title "$agent $worktree_path" --command "$tmux_command" --json)" || return 1
        host_terminal_created=true
        session_id="$(printf '%s' "$response" | jq -r '.result.terminal.handle // .terminal.handle // .handle // empty' 2>/dev/null)"
      else
        response="$(megabrain_superset terminals create --workspace "$workspace_id" --command "$tmux_command" --json)" || return 1
        host_terminal_created=true
        session_id="$(printf '%s' "$response" | jq -r '.terminalId // .sessionId // .result.terminalId // .result.sessionId // .terminal.sessionId // .result.terminal.sessionId // .terminal.id // .result.terminal.id // .id // empty' 2>/dev/null)"
      fi
      if [ -z "$session_id" ]; then
        megabrain_tmux_cleanup_launch "$context" "$workspace_id" "" "$tmux_session" "" "$host_terminal_created"
        megabrain_error "$context terminal create returned no terminal identity; raw response: $response"
        return 1
      fi
      megabrain_tmux_wait_for_session "$tmux_session" || {
        megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "" "$host_terminal_created"
        megabrain_error "tmux session $tmux_session did not become available"
        return 1
      }
      megabrain_tmux_set_state_dir "$tmux_session" || {
        megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "" "$host_terminal_created"
        megabrain_error "could not scope tmux child session $tmux_session to $MEGABRAIN_STATE_DIR"
        return 1
      }
      tmux_pane="$(megabrain_tmux_first_pane "$tmux_session")"
    fi
    if [ -z "$tmux_pane" ]; then
      megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "" "$host_terminal_created"
      megabrain_error "tmux session $tmux_session has no pane"
      return 1
    fi
    megabrain_tmux_apply_config "$tmux_session" || {
      megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "$tmux_pane" "$host_terminal_created"
      megabrain_error "could not apply megabrain tmux configuration to $tmux_session"
      return 1
    }
    if [ "${#passthrough_args[@]}" -gt 0 ]; then
      command_text="$(megabrain_agent_command "$agent_used" "$model" "$effort" "${passthrough_args[@]}")" || {
        megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "$tmux_pane" "$host_terminal_created"
        return 1
      }
    else
      command_text="$(megabrain_agent_command "$agent_used" "$model" "$effort")" || {
        megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "$tmux_pane" "$host_terminal_created"
        return 1
      }
    fi
    command_text="cd $(printf '%q' "$worktree_path") && MEGABRAIN_DISPATCH_ID=$(printf '%q' "$dispatch_id") MEGABRAIN_TMUX_SESSION=$(printf '%q' "$tmux_session") MEGABRAIN_TMUX_PANE=$(printf '%q' "$tmux_pane") $command_text"
    megabrain_dispatch_meta_write "$dispatch_id" "$parent_id" "$parent_host" "$context" "$workspace_id" "$session_id" "$worktree_path" "$branch" "$agent" "$label" spawning "$model" true "$agent_used" "$tmux_session" "$tmux_pane" tmux tmux "$parent_tmux_session" "$parent_tmux_pane" "$parent_workspace_id" >/dev/null || {
      megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "$tmux_pane" "$host_terminal_created"
      megabrain_error "could not persist dispatch metadata: $dispatch_id"
      return 1
    }
    if ! megabrain_tmux_send_agent "$tmux_pane" "$command_text"; then
      megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "$tmux_pane" "$host_terminal_created"
      megabrain_spawn_mark_prompt_failed "$dispatch_id" command-not-submitted
      return 1
    fi
    if ! megabrain_tmux_settle_pane "$tmux_pane"; then
      megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "$tmux_pane" "$host_terminal_created"
      megabrain_spawn_mark_prompt_failed "$dispatch_id" readiness-timeout
      return 1
    fi
    substitution_report="$(megabrain_tmux_model_substitution_report "$tmux_pane" 2>/dev/null || true)"
    if [ -n "$substitution_report" ]; then
      megabrain_dispatch_meta_update_model_substitution "$dispatch_id" "$substitution_report" || {
        megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "$tmux_pane" "$host_terminal_created"
        megabrain_spawn_mark_prompt_failed "$dispatch_id" model-substitution-record-failed
        return 1
      }
      megabrain_error "agent reported model substitution: $substitution_report"
    fi
    if ! megabrain_tmux_agent_output_clean "$tmux_pane"; then
      megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "$tmux_pane" "$host_terminal_created"
      megabrain_spawn_mark_prompt_failed "$dispatch_id" readiness-output-invalid
      megabrain_dispatch_failure_error "$dispatch_id" "agent output contains terminal-identification escape leakage in pane $tmux_pane"
      return 1
    fi
    if ! megabrain_tmux_send_agent "$tmux_pane" "$final_prompt" prompt; then
      megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "$tmux_pane" "$host_terminal_created"
      megabrain_spawn_mark_prompt_failed "$dispatch_id" prompt-send-failed
      return 1
    fi
    if ! megabrain_dispatch_wait_for_prompt_receipt "$dispatch_id"; then
      megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "$tmux_pane" "$host_terminal_created"
      megabrain_spawn_mark_prompt_failed "$dispatch_id" prompt-receipt-timeout
      return 1
    fi
    if ! megabrain_spawn_mark_prompt_delivered "$dispatch_id"; then
      megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "$tmux_pane" "$host_terminal_created"
      megabrain_spawn_mark_prompt_failed "$dispatch_id" prompt-confirmation-failed
      return 1
    fi
    megabrain_spawn_mark_running_if_spawning "$dispatch_id" || {
      megabrain_tmux_cleanup_launch "$context" "$workspace_id" "$session_id" "$tmux_session" "$tmux_pane" "$host_terminal_created"
      megabrain_spawn_mark_prompt_failed "$dispatch_id" state-persist-failed
      megabrain_dispatch_failure_error "$dispatch_id" "could not persist tmux dispatch state: $dispatch_id"
      return 1
    }
    MEGABRAIN_LAST_DISPATCH="$dispatch_id"
    printf '%s\n' "$response"
    return 0
  fi
  if [ "${#passthrough_args[@]}" -gt 0 ]; then
    command_text="$(megabrain_agent_command "$agent" "$model" "$effort" "${passthrough_args[@]}")" || {
      megabrain_error "could not build $agent launch command"
      return 1
    }
  else
    command_text="$(megabrain_agent_command "$agent" "$model" "$effort")" || {
      megabrain_error "could not build $agent launch command"
      return 1
    }
  fi
  dispatch_id="$(megabrain_dispatch_new_id)" || return 1
  case "$context" in
    orca)
      megabrain_require_command orca || { megabrain_error "orca CLI is not available"; return 1; }
      response="$(orca terminal create --worktree "path:$worktree_path" --title "$agent $worktree_path" --json)" || {
        megabrain_error "orca terminal create failed for $worktree_path"
        return 1
      }
      session_id="$(printf '%s' "$response" | jq -r '.result.terminal.handle // .terminal.handle // .handle // empty' 2>/dev/null)"
      child_host=orca
      ;;
    superset)
      megabrain_superset_available || { megabrain_error "superset CLI is not available"; return 1; }
      response="$(megabrain_superset terminals create --workspace "$workspace_id" --json)" || {
        megabrain_error "Superset terminals create failed for workspace $workspace_id"
        return 1
      }
      session_id="$(printf '%s' "$response" | jq -r '.terminalId // .sessionId // .result.terminalId // .result.sessionId // .terminal.sessionId // .result.terminal.sessionId // .terminal.id // .result.terminal.id // .id // empty' 2>/dev/null)"
      [ -n "$session_id" ] || { megabrain_error "Superset terminals create returned no terminal identity"; return 1; }
      child_host=superset
      ;;
    *)
      megabrain_error "cannot launch agent from unknown orchestration host"
      return 1
      ;;
  esac
  [ -n "$session_id" ] || { megabrain_error "agent launch returned no terminal identity"; return 1; }
  if ! megabrain_host_terminal_readback "$context" "$workspace_id" "$session_id"; then
    megabrain_host_cleanup_launch "$context" "$workspace_id" "$session_id"
    return 1
  fi
  model_honored=true
  megabrain_dispatch_meta_write "$dispatch_id" "$parent_id" "$parent_host" "$child_host" "$workspace_id" "$session_id" "$worktree_path" "$branch" "$agent" "$label" spawning "$model" "$model_honored" "$agent_used" "" "" host ide "$parent_tmux_session" "$parent_tmux_pane" "$parent_workspace_id" >/dev/null || {
    megabrain_host_cleanup_launch "$context" "$workspace_id" "$session_id"
    megabrain_error "could not persist dispatch metadata: $dispatch_id"
    return 1
  }
  if [ "$child_host" = orca ]; then
    command_text="cd $(printf '%q' "$worktree_path") && env -u TMUX -u TMUX_PANE MEGABRAIN_STATE_DIR=$(printf '%q' "$MEGABRAIN_STATE_DIR") ORCA_TERMINAL_HANDLE=$(printf '%q' "$session_id") MEGABRAIN_DISPATCH_ID=$(printf '%q' "$dispatch_id") $command_text"
  else
    command_text="cd $(printf '%q' "$worktree_path") && env -u TMUX -u TMUX_PANE MEGABRAIN_STATE_DIR=$(printf '%q' "$MEGABRAIN_STATE_DIR") SUPERSET_TERMINAL_ID=$(printf '%q' "$session_id") MEGABRAIN_DISPATCH_ID=$(printf '%q' "$dispatch_id") $command_text"
  fi
  meta="$(megabrain_dispatch_meta_read "$dispatch_id")" || {
    megabrain_host_cleanup_launch "$context" "$workspace_id" "$session_id"
    megabrain_spawn_mark_prompt_failed "$dispatch_id" metadata-read-failed
    megabrain_dispatch_failure_error "$dispatch_id" "could not read dispatch metadata: $dispatch_id"
    return 1
  }
  if ! megabrain_dispatch_native_send "$meta" "$command_text"; then
    megabrain_host_cleanup_launch "$context" "$workspace_id" "$session_id"
    megabrain_spawn_mark_prompt_failed "$dispatch_id" command-not-submitted
    megabrain_dispatch_failure_error "$dispatch_id" "could not start agent in $child_host terminal $session_id"
    return 1
  fi
  if [ "$child_host" = orca ]; then
    if ! orca terminal wait --terminal "$session_id" --for tui-idle --timeout-ms "$MEGABRAIN_AGENT_READY_TIMEOUT_MS" >/dev/null; then
      megabrain_host_cleanup_launch "$context" "$workspace_id" "$session_id"
      megabrain_spawn_mark_prompt_failed "$dispatch_id" readiness-timeout
      megabrain_dispatch_failure_error "$dispatch_id" "orca terminal $session_id did not become ready within ${MEGABRAIN_AGENT_READY_TIMEOUT_MS}ms"
      return 1
    fi
  elif ! megabrain_superset_wait_for_terminal_ready "$workspace_id" "$session_id"; then
    megabrain_host_cleanup_launch "$context" "$workspace_id" "$session_id"
    megabrain_spawn_mark_prompt_failed "$dispatch_id" readiness-timeout
    megabrain_dispatch_failure_error "$dispatch_id" "Superset terminal $session_id did not become ready"
    return 1
  fi
  meta="$(megabrain_dispatch_meta_read "$dispatch_id")" || return 1
  if ! megabrain_dispatch_native_send "$meta" "$final_prompt"; then
    megabrain_host_cleanup_launch "$context" "$workspace_id" "$session_id"
    megabrain_spawn_mark_prompt_failed "$dispatch_id" prompt-send-failed
    megabrain_dispatch_failure_error "$dispatch_id" "could not send prompt to $child_host terminal $session_id"
    return 1
  fi
  if ! megabrain_dispatch_wait_for_prompt_receipt "$dispatch_id"; then
    megabrain_host_cleanup_launch "$context" "$workspace_id" "$session_id"
    megabrain_spawn_mark_prompt_failed "$dispatch_id" prompt-receipt-timeout
    megabrain_dispatch_failure_error "$dispatch_id" "dispatch $dispatch_id did not receive a prompt receipt within ${MEGABRAIN_PROMPT_RECEIPT_TIMEOUT_SECONDS}s"
    return 1
  fi
  if ! megabrain_spawn_mark_prompt_delivered "$dispatch_id"; then
    megabrain_host_cleanup_launch "$context" "$workspace_id" "$session_id"
    megabrain_spawn_mark_prompt_failed "$dispatch_id" prompt-confirmation-failed
    megabrain_dispatch_failure_error "$dispatch_id" "could not record prompt delivery for dispatch $dispatch_id"
    return 1
  fi
  megabrain_spawn_mark_running_if_spawning "$dispatch_id" || {
    megabrain_spawn_mark_prompt_failed "$dispatch_id" state-persist-failed
    megabrain_dispatch_failure_error "$dispatch_id" "could not persist host dispatch state: $session_id"
    return 1
  }
  MEGABRAIN_LAST_DISPATCH="$dispatch_id"
  printf '%s\n' "$response"
  return 0
}

megabrain_terminal_create() {
  local worktree_selector="" command_text="" title="" json=false arg worktree_path host workspace_id response
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --worktree) worktree_selector="${2:-}"; shift 2 ;;
      --command) command_text="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help)
        megabrain_usage_show terminal-create
        printf 'Without --command, use the worktree .superset/config.json run script.\n'
        printf 'Superset tabs are not titled; only Orca tabs are.\n'
        return 0
        ;;
      *) megabrain_error "unknown terminal create option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  if [ -n "$worktree_selector" ]; then
    if [ -d "$worktree_selector" ]; then
      worktree_path="$(git -C "$worktree_selector" rev-parse --show-toplevel 2>/dev/null || true)"
    else
      megabrain_error "worktree path is not a Git directory: $worktree_selector"
      return 1
    fi
  else
    worktree_path="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  [ -n "$worktree_path" ] || { megabrain_error "could not resolve a Git worktree from ${worktree_selector:-$PWD}"; return 1; }
  if [ -z "$command_text" ]; then
    command_text="$(megabrain_project_run_command "$worktree_path" || true)"
    [ -n "$command_text" ] || {
      megabrain_error "no --command given and no .superset/config.json run script found in $worktree_path"
      return "$MEGABRAIN_USAGE_ERROR"
    }
  fi
  command_text="$(megabrain_terminal_command_with_agent_permissions "$command_text")"
  host="$(megabrain_context_detect)"
  case "$host" in
    orca)
      megabrain_require_command orca || { megabrain_error "orca CLI is not available"; return 1; }
      if [ -n "$title" ]; then
        response="$(orca terminal create --worktree "path:$worktree_path" --title "$title" --command "$command_text" --json)" || return 1
      else
        response="$(orca terminal create --worktree "path:$worktree_path" --command "$command_text" --json)" || return 1
      fi
      ;;
    superset)
      megabrain_superset_available || { megabrain_error "superset CLI is not available"; return 1; }
      workspace_id="$(megabrain_workspace_id_for_target "$worktree_path")"
      if [ -z "$workspace_id" ]; then
        megabrain_error "no Superset workspace is registered for $worktree_path; run megabrain worktree adopt $worktree_path first"
        return 1
      fi
      response="$(megabrain_superset terminals create --workspace "$workspace_id" --command "$command_text" --json)" || return 1
      ;;
    *)
      megabrain_error "cannot create terminal from unknown orchestration host"
      return 1
      ;;
  esac
  if [ "$json" = true ]; then
    jq -n --arg host "$host" --arg worktree "$worktree_path" --arg title "$title" \
      '{host: $host, worktree: $worktree, title: (if $title|length > 0 then $title else null end)}'
  else
    printf '%s\n' "$response"
  fi
}

megabrain_worktree_create() {
  local repo_selector="" branch="" base="" slug="" agent="" model="" effort="" prompt="" label="" worktree_selector="" orchestrate=false json=false reused=false
  local arg repo_path shared_root worktree_path project_id workspace_id dispatch="" host runtime="" tmux_choice=auto
  local -a agent_args=()
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --repo) repo_selector="${2:-}"; shift 2 ;;
      --branch) branch="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --name) slug="${2:-}"; shift 2 ;;
      --agent) agent="${2:-}"; shift 2 ;;
      --model) model="${2:-}"; shift 2 ;;
      --effort) effort="${2:-}"; shift 2 ;;
      --prompt) prompt="${2:-}"; shift 2 ;;
      --label) label="${2:-}"; shift 2 ;;
      --worktree) worktree_selector="${2:-}"; shift 2 ;;
      --tmux) tmux_choice="${2:-}"; shift 2 ;;
      --agent-arg)
        [ "$#" -ge 2 ] && [ -n "${2:-}" ] || { megabrain_error "--agent-arg requires a non-empty value"; return "$MEGABRAIN_USAGE_ERROR"; }
        agent_args+=("$2")
        shift 2
        ;;
      --orchestrate) orchestrate=true; shift ;;
      --json) json=true; shift ;;
      -h|--help)
        if [ "$orchestrate" = true ]; then
          megabrain_usage_show orchestrate-spawn
        else
          megabrain_usage_show worktree-create
        fi
        return 0
        ;;
      *) megabrain_error "unknown worktree create option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  if [ "$orchestrate" = true ]; then
    megabrain_session_id >/dev/null
    [ -n "$MEGABRAIN_SESSION_ID" ] || { megabrain_error "cannot spawn a managed dispatch from an unmanaged shell"; return 1; }
  fi
  if [ -n "$worktree_selector" ] && [ "$orchestrate" != true ]; then
    megabrain_error "--worktree is only supported by orchestrate spawn"
    return "$MEGABRAIN_USAGE_ERROR"
  fi
  if [ "$orchestrate" != true ] && [ "$tmux_choice" != auto ]; then
    megabrain_error "--tmux is only supported by orchestrate spawn"
    return "$MEGABRAIN_USAGE_ERROR"
  fi
  if [ -z "$worktree_selector" ]; then
    [ -n "$repo_selector" ] || { megabrain_error "--repo is required"; return "$MEGABRAIN_USAGE_ERROR"; }
    [ -n "$branch" ] || { megabrain_error "--branch is required"; return "$MEGABRAIN_USAGE_ERROR"; }
  fi
  host="$(megabrain_context_detect)"
  if [ "$orchestrate" = true ]; then
    [ -n "$agent" ] || { megabrain_error "--agent is required for orchestrate spawn"; return "$MEGABRAIN_USAGE_ERROR"; }
    [ -n "$model" ] || { megabrain_error "--model is required for orchestrate spawn"; return "$MEGABRAIN_USAGE_ERROR"; }
    if [ -z "$effort" ] && { ! megabrain_model_known "$agent" "$model" || megabrain_model_effort_separate "$agent" "$model"; }; then
      megabrain_error "--effort is required for orchestrate spawn"
      return "$MEGABRAIN_USAGE_ERROR"
    fi
    [ -n "$prompt" ] || { megabrain_error "--prompt is required for orchestrate spawn"; return "$MEGABRAIN_USAGE_ERROR"; }
    megabrain_resolve_spawn_runtime "$tmux_choice" || return 1
    runtime="$MEGABRAIN_SPAWN_RUNTIME"
    host="$MEGABRAIN_SPAWN_CONTEXT"
    if [ "$runtime" = tmux ]; then
      megabrain_validate_prompt_budget "$prompt" tmux prompt || return 1
    else
      megabrain_validate_prompt_budget "$prompt" argv prompt || return 1
    fi
  fi
  if [ "$host" != superset ] && [ -n "$agent" ] && ! megabrain_require_command "$agent"; then
    megabrain_error "agent is not on PATH: $agent"
    return 1
  fi
  if [ -n "$worktree_selector" ]; then
    if [ -d "$worktree_selector" ]; then
      worktree_path="$(git -C "$worktree_selector" rev-parse --show-toplevel 2>/dev/null || true)"
    else
      shared_root="$(megabrain_worktree_root --read-only 2>/dev/null || true)"
      worktree_path="$(megabrain_find_worktree_path "$worktree_selector" "$shared_root" 2>/dev/null || true)"
    fi
    [ -n "$worktree_path" ] || { megabrain_error "existing Git worktree not found: $worktree_selector"; return 1; }
    reused=true
    branch="$(git -C "$worktree_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    [ -n "$branch" ] || { megabrain_error "cannot spawn in detached worktree: $worktree_path"; return 1; }
    workspace_id="$(megabrain_workspace_id_for_target "$worktree_path" 2>/dev/null || true)"
    if [ "$host" = superset ] && [ -z "$workspace_id" ]; then
      megabrain_error "no Superset workspace is registered for $worktree_path; run megabrain worktree adopt $worktree_path first"
      return 1
    fi
    repo_path="$(git -C "$worktree_path" rev-parse --show-toplevel)"
  else
    repo_path="$(megabrain_repo_from_orca "$repo_selector")" || return 1
    shared_root="$(megabrain_worktree_root)" || return 1
    [ -n "$base" ] || base="$(megabrain_repo_default_base "$repo_path")"
    [ -n "$slug" ] || slug="$(megabrain_slug_from_branch "$branch")" || { megabrain_error "branch cannot produce a safe slug"; return 1; }
    case "$slug" in
      .|..|*/*|*"$'\n'"*) megabrain_error "invalid worktree name: $slug"; return 1 ;;
    esac
    worktree_path="$shared_root/$slug"
    [ ! -e "$worktree_path" ] || { megabrain_error "worktree path already exists: $worktree_path"; return 1; }
    mkdir -p "$shared_root" || return 1
    if [ "$json" = true ]; then
      git -C "$repo_path" worktree add "$worktree_path" -b "$branch" "$base" >/dev/null || { megabrain_error "could not create git worktree"; return 1; }
    elif ! git -C "$repo_path" worktree add "$worktree_path" -b "$branch" "$base"; then
      megabrain_error "could not create git worktree"
      return 1
    fi
    project_id="$(megabrain_ensure_superset_project "$repo_path")" || {
      git -C "$repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
      git -C "$repo_path" branch -D "$branch" >/dev/null 2>&1 || true
      return 1
    }
    workspace_id="$(megabrain_workspace_create "$project_id" "$branch" "$slug")" || {
      git -C "$repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
      git -C "$repo_path" branch -D "$branch" >/dev/null 2>&1 || true
      return 1
    }
  fi
  if [ "$json" != true ]; then
    printf 'worktree: %s\nbranch: %s\nworkspace: %s\nreused: %s\n' "$worktree_path" "$branch" "$workspace_id" "$reused"
  fi
  if [ -n "$agent" ]; then
    # Bash 3.2 rejects empty array expansion under set -u.
    if [ "${#agent_args[@]}" -gt 0 ]; then
      if [ "$json" = true ]; then
        megabrain_launch_agent "$worktree_path" "$workspace_id" "$agent" "$model" "$effort" "$prompt" "$label" "${agent_args[@]}" >/dev/null || return 1
      else
        megabrain_launch_agent "$worktree_path" "$workspace_id" "$agent" "$model" "$effort" "$prompt" "$label" "${agent_args[@]}" || return 1
      fi
    else
      if [ "$json" = true ]; then
        megabrain_launch_agent "$worktree_path" "$workspace_id" "$agent" "$model" "$effort" "$prompt" "$label" >/dev/null || return 1
      else
        megabrain_launch_agent "$worktree_path" "$workspace_id" "$agent" "$model" "$effort" "$prompt" "$label" || return 1
      fi
    fi
    dispatch="$MEGABRAIN_LAST_DISPATCH"
    runtime="$MEGABRAIN_LAST_SPAWN_RUNTIME"
    if [ -n "$dispatch" ] && [ "$json" != true ]; then
      printf 'dispatch: %s\nruntime: %s\n' "$dispatch" "$runtime"
    fi
  fi
  if [ "$orchestrate" = true ] && [ "$json" != true ]; then
    megabrain_info "host: $(megabrain_context_detect)"
  fi
  if [ "$json" = true ]; then
    if [ -n "${dispatch:-}" ]; then
      jq -n --arg worktree "$worktree_path" --arg branch "$branch" --arg workspace "$workspace_id" --arg dispatch "$dispatch" --arg reused "$reused" --arg runtime "$runtime" \
        '{worktree: $worktree, branch: $branch, workspace: (if $workspace|length > 0 then $workspace else null end), dispatch: $dispatch, reused: ($reused == "true"), runtime: $runtime}'
    else
      jq -n --arg worktree "$worktree_path" --arg branch "$branch" --arg workspace "$workspace_id" --arg reused "$reused" \
        '{worktree: $worktree, branch: $branch, workspace: (if $workspace|length > 0 then $workspace else null end), reused: ($reused == "true")}'
    fi
  fi
  return 0
}

megabrain_find_worktree_path() {
  local target="$1" shared_root="$2" path branch line current_path current_branch
  if [ -d "$target" ] && git -C "$target" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$target" rev-parse --show-toplevel
    return 0
  fi
  if [ -z "$shared_root" ]; then
    git worktree list --porcelain 2>/dev/null | awk -v target="$target" '
      /^worktree / { path = $2 }
      /^branch / { branch = $2; sub("refs/heads/", "", branch); if (branch == target || path ~ "/" target "$" ) print path }
    ' | head -n 1
    return 0
  fi
  for path in "$shared_root"/*; do
    [ -d "$path" ] || continue
    git -C "$path" rev-parse --show-toplevel >/dev/null 2>&1 || continue
    current_path="$(git -C "$path" rev-parse --show-toplevel)"
    current_branch="$(git -C "$current_path" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')"
    if [ "$target" = "$current_branch" ] || [ "$target" = "${current_branch#refs/heads/}" ] || [ "$target" = "$(basename "$current_path")" ]; then
      printf '%s\n' "$current_path"
      return 0
    fi
  done
  return 1
}

megabrain_worktree_finish() {
  local target="" delete_branch=false force=false json=false arg shared_root path workspace_id="" repo_path branch base merged
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      --delete-branch) delete_branch=true; shift ;;
      --force) force=true; shift ;;
      -h|--help) megabrain_usage_show worktree-finish; return 0 ;;
      *)
        [ -z "$target" ] || { megabrain_error "unknown worktree finish option: $arg"; return "$MEGABRAIN_USAGE_ERROR"; }
        target="$arg"
        shift
        ;;
    esac
  done
  [ -n "$target" ] || { megabrain_usage_fail worktree-finish; return "$MEGABRAIN_USAGE_ERROR"; }
  shared_root="$(megabrain_worktree_root 2>/dev/null || true)"
  path=""
  if megabrain_superset_available; then
    path="$(megabrain_workspace_path_for_target "$target")"
    workspace_id="$(megabrain_workspace_id_for_target "$target")"
  fi
  if [ -z "$path" ] && [ -n "$shared_root" ]; then
    path="$(megabrain_find_worktree_path "$target" "$shared_root" 2>/dev/null || true)"
  fi
  if [ -z "$path" ]; then
    megabrain_error "worktree not found: $target"
    return 1
  fi
  repo_path="$(git -C "$path" rev-parse --git-common-dir)"
  case "$repo_path" in
    /*) ;;
    *) repo_path="$path/$repo_path" ;;
  esac
  repo_path="$(dirname "$(realpath "$repo_path")")"
  branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  # WHY: under --json the remover's own stdout goes to /dev/null so it cannot corrupt the
  # JSON, which used to leave a refusal with an empty stdout, an empty stderr and only an
  # exit code. The output is captured instead, and reported as megabrain's own error when
  # the removal fails, so the caller learns whether the branch was unmerged or the install
  # was broken.
  megabrain_worktree_removal_failed() {
    local output="$1" reason
    # The orchestrators answer in JSON, so lift their own message out of it when there is
    # one and fall back to the raw text for a remover that writes plain lines.
    reason="$(printf '%s' "$output" | jq -r 'if (.error | type) == "object" then (.error.message // .error.code // empty) else (.error // .message // empty) end' 2>/dev/null || true)"
    [ -n "$reason" ] || reason="$output"
    reason="$(printf '%s' "$reason" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
    [ -n "$reason" ] || reason='the remover gave no reason'
    megabrain_error "could not remove worktree $path: $reason"
  }
  local removal_output removal_status=0
  if [ -n "$workspace_id" ]; then
    removal_output="$(megabrain_superset workspaces delete "$workspace_id" --local --json 2>&1)" || removal_status=$?
  elif megabrain_require_command orca; then
    removal_output="$(orca worktree rm --worktree "path:$path" $([ "$force" = true ] && printf '%s' --force) --json 2>&1)" || removal_status=$?
  else
    removal_output="$(git -C "$repo_path" worktree remove $([ "$force" = true ] && printf '%s' --force) "$path" 2>&1)" || removal_status=$?
  fi
  if [ "$removal_status" -ne 0 ]; then
    megabrain_worktree_removal_failed "$removal_output"
    return 1
  fi
  [ "$json" = true ] || [ -z "$removal_output" ] || printf '%s\n' "$removal_output"
  if [ "$delete_branch" = true ] && [ -n "$branch" ]; then
    base="$(megabrain_repo_default_base "$repo_path")"
    if [ "$force" != true ]; then
      merged="$(git -C "$repo_path" branch --merged "$base" 2>/dev/null || true)"
      if ! printf '%s\n' "$merged" | sed 's/^..//' | awk '{print $1}' | grep -Fx "$branch" >/dev/null; then
        megabrain_error "refusing to delete unmerged branch: $branch (use --force to override)"
        return 1
      fi
    fi
    if [ "$json" = true ]; then
      git -C "$repo_path" branch $([ "$force" = true ] && printf '%s' -D || printf '%s' -d) "$branch" >/dev/null
    else
      git -C "$repo_path" branch $([ "$force" = true ] && printf '%s' -D || printf '%s' -d) "$branch"
    fi
  fi
  if [ "$json" = true ]; then
    jq -n --arg branch "$branch" --arg path "$path" \
      '{deleted: true, branch: (if $branch|length > 0 then $branch else null end), path: $path}'
  fi
}

megabrain_worktree_list() {
  local repo_selector="" arg shared_root repo_filter path branch in_superset workspaces_json json=false entry entries
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --repo) repo_selector="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) megabrain_usage_show worktree-list; return 0 ;;
      *) megabrain_error "unknown worktree list option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  shared_root="$(megabrain_worktree_root)" || return 1
  if [ -n "$repo_selector" ]; then
    repo_filter="$(megabrain_repo_from_orca "$repo_selector")" || return 1
    repo_filter="$(git -C "$repo_filter" rev-parse --git-common-dir | xargs realpath 2>/dev/null || true)"
  fi
  workspaces_json='[]'
  if megabrain_superset_available; then
    workspaces_json="$(megabrain_superset_workspaces_json || printf '[]')"
  fi
  entries=''
  if [ "$json" != true ]; then
    printf '%-52s %-32s %s\n' PATH BRANCH IN_SUPERSET
  fi
  for path in "$shared_root"/*; do
    [ -d "$path" ] || continue
    git -C "$path" rev-parse --show-toplevel >/dev/null 2>&1 || continue
    [ -z "$repo_filter" ] || [ "$(git -C "$path" rev-parse --git-common-dir | xargs realpath 2>/dev/null || true)" = "$repo_filter" ] || continue
    path="$(git -C "$path" rev-parse --show-toplevel)"
    branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')"
    in_superset="no"
    if printf '%s' "$workspaces_json" | jq -e --arg path "$path" 'any((if type == "array" then . else (.result.workspaces? // .workspaces? // .result? // []) end)[]?; (.worktreePath // .path // .worktree.path // "") == $path)' >/dev/null 2>&1; then
      in_superset="yes"
    fi
    if [ "$json" = true ]; then
      if [ "$in_superset" = yes ]; then
        entry="$(jq -n --arg path "$path" --arg branch "$branch" '{path: $path, branch: $branch, inSuperset: true}')"
      else
        entry="$(jq -n --arg path "$path" --arg branch "$branch" '{path: $path, branch: $branch, inSuperset: false}')"
      fi
      entries="${entries}${entry}"$'\n'
    else
      printf '%-52s %-32s %s\n' "$path" "$branch" "$in_superset"
    fi
  done
  if [ "$json" = true ]; then
    printf '%s' "$entries" | jq -s .
  fi
}

megabrain_worktree_adopt() {
  local target="" arg shared_root path repo_path branch slug project_id workspace_id json=false
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      -h|--help) megabrain_usage_show worktree-adopt; return 0 ;;
      *)
        [ -z "$target" ] || { megabrain_error "unknown worktree adopt option: $arg"; return "$MEGABRAIN_USAGE_ERROR"; }
        target="$arg"
        shift
        ;;
    esac
  done
  [ -n "$target" ] || { megabrain_usage_fail worktree-adopt; return "$MEGABRAIN_USAGE_ERROR"; }
  shared_root="$(megabrain_worktree_root)" || return 1
  if [ -d "$target" ]; then
    path="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)"
  else
    path="$(megabrain_find_worktree_path "$target" "$shared_root" 2>/dev/null || true)"
  fi
  [ -n "$path" ] || { megabrain_error "physical worktree not found: $target"; return 1; }
  case "$path" in
    "$shared_root"/*) ;;
    *) megabrain_error "worktree is outside Superset's shared root: $path"; return 1 ;;
  esac
  repo_path="$(megabrain_repo_from_orca "$path")" || return 1
  branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [ -n "$branch" ] || { megabrain_error "cannot adopt detached worktree: $path"; return 1; }
  if [ -n "$(megabrain_workspace_id_for_target "$path")" ]; then
    megabrain_error "worktree is already registered in Superset: $path"
    return 1
  fi
  slug="$(basename "$path")"
  project_id="$(megabrain_ensure_superset_project "$repo_path")" || return 1
  workspace_id="$(megabrain_workspace_create "$project_id" "$branch" "$slug")" || return 1
  if [ "$json" = true ]; then
    jq -n --arg worktree "$path" --arg branch "$branch" --arg workspace "$workspace_id" \
      '{worktree: $worktree, branch: $branch, workspace: $workspace}'
  else
    printf 'worktree: %s\nbranch: %s\nworkspace: %s\n' "$path" "$branch" "$workspace_id"
  fi
}

command_worktree() {
  local subcommand="${1:-}"
  shift || true
  case "$subcommand" in
    create) megabrain_worktree_create "$@" ;;
    finish) megabrain_worktree_finish "$@" ;;
    list) megabrain_worktree_list "$@" ;;
    adopt) megabrain_worktree_adopt "$@" ;;
    -h|--help|"")
      megabrain_usage_show worktree
      ;;
    *) megabrain_error "unknown worktree command: $subcommand"; return "$MEGABRAIN_USAGE_ERROR" ;;
  esac
}

command_terminal() {
  local subcommand="${1:-}"
  shift || true
  case "$subcommand" in
    create) megabrain_terminal_create "$@" ;;
    -h|--help|"")
      megabrain_usage_show terminal-create
      printf 'Superset tabs are not titled; only Orca tabs are.\n'
      ;;
    *) megabrain_error "unknown terminal command: $subcommand"; return "$MEGABRAIN_USAGE_ERROR" ;;
  esac
}

module_worktree_doctor() {
  if ! megabrain_superset_available; then
    megabrain_set_status missing "superset CLI is not on PATH and $HOME/.superset/bin/superset is unavailable"
    return 1
  fi
  if ! megabrain_require_command orca; then
    megabrain_set_status missing "orca CLI is not on PATH"
    return 1
  fi
  local root
  root="$(megabrain_worktree_root --read-only 2>/dev/null || true)"
  if [ -z "$root" ]; then
    megabrain_set_status misconfigured "Superset worktreeBaseDir is unset or unreadable"
    return 1
  fi
  megabrain_set_status ok "$root"
  return 0
}

module_worktree_install() {
  module_worktree_doctor
}
