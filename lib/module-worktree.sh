#!/usr/bin/env bash

devkit_worktree_root() {
  local raw read_only=false
  if [ "${1:-}" = --read-only ]; then
    read_only=true
  fi
  if ! devkit_superset_available; then
    devkit_error "superset CLI is required for shared worktrees"
    return 1
  fi
  raw="$(devkit_superset settings get worktreeBaseDir 2>/dev/null || true)"
  raw="$(printf '%s\n' "$raw" | devkit_trim)"
  if [ -n "$raw" ] && [ "$raw" != "null" ]; then
    raw="$(printf '%s' "$raw" | jq -r 'if type == "object" then (.value // .result.value // .path // .result.path // empty) elif type == "string" then . else empty end' 2>/dev/null || printf '%s' "$raw")"
    raw="$(printf '%s\n' "$raw" | devkit_trim)"
  fi
  if [ -z "$raw" ]; then
    if [ "$read_only" = true ] || [ ! -t 0 ]; then
      devkit_error "Superset worktreeBaseDir is unset; run superset settings set worktreeBaseDir <path>"
      return 1
    fi
    read -r -p "Shared worktree root: " raw
    [ -n "$raw" ] || { devkit_error "worktree root cannot be empty"; return 1; }
    devkit_superset settings set worktreeBaseDir "$raw" >/dev/null || return 1
  fi
  raw="${raw/#\~/$HOME}"
  if [ "${raw#/}" = "$raw" ]; then
    raw="$PWD/$raw"
  fi
  DEVKIT_SHARED_ROOT="$(cd "$raw" 2>/dev/null && pwd -P || true)"
  if [ -z "$DEVKIT_SHARED_ROOT" ]; then
    DEVKIT_SHARED_ROOT="$raw"
  fi
  printf '%s\n' "$DEVKIT_SHARED_ROOT"
}

devkit_repo_from_orca() {
  local selector="$1"
  local selector_lower path display_name display_lower base_name
  selector_lower="$(devkit_lower "$selector")"
  if [ -d "$selector" ] && git -C "$selector" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$selector" rev-parse --show-toplevel
    return 0
  fi
  if [ -f "$selector" ] && git -C "$(dirname "$selector")" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$(dirname "$selector")" rev-parse --show-toplevel
    return 0
  fi
  if ! devkit_require_command orca; then
    devkit_error "repo must be a git path when orca is not installed"
    return 1
  fi
  while IFS=$'\t' read -r display_name path; do
    [ -n "$path" ] || continue
    display_lower="$(devkit_lower "$display_name")"
    base_name="$(devkit_lower "$(basename "$path")")"
    if [ "$selector_lower" = "$display_lower" ] || [ "$selector_lower" = "$base_name" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(orca repo list --json 2>/dev/null | jq -r '.result.repos[]? | [(.displayName // ""), (.path // "")] | @tsv' 2>/dev/null)
  devkit_error "repo not found: $selector"
  return 1
}

devkit_repo_default_base() {
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

devkit_slug_from_branch() {
  local branch="$1"
  branch="${branch//\//-}"
  if [ -z "$branch" ] || [ "$branch" = "." ] || [ "$branch" = ".." ] || [[ "$branch" == *"/"* ]] || [[ "$branch" == *$'\n'* ]]; then
    return 1
  fi
  printf '%s\n' "$branch"
}

devkit_superset_projects_json() {
  devkit_superset projects list --json 2>/dev/null
}

devkit_superset_workspaces_json() {
  devkit_superset workspaces list --local --json 2>/dev/null
}

devkit_project_id_for_path() {
  local repo_path="$1"
  devkit_superset_projects_json | jq -r --arg path "$repo_path" '
    (if type == "array" then . else (.result.projects? // .projects? // .result? // []) end)[]? |
    select((.path // .localPath // .repoPath // "") == $path) |
    (.id // .projectId // .project.id // empty)' 2>/dev/null | head -n 1
}

devkit_project_name_for_path() {
  local repo_path="$1"
  local name
  name="$(orca repo list --json 2>/dev/null | jq -r --arg path "$repo_path" '.result.repos[]? | select(.path == $path) | .displayName' 2>/dev/null | head -n 1)"
  if [ -z "$name" ]; then
    name="$(basename "$repo_path")"
  fi
  printf '%s\n' "$name"
}

devkit_ensure_superset_project() {
  local repo_path="$1"
  local project_id project_name response
  project_id="$(devkit_project_id_for_path "$repo_path")"
  if [ -n "$project_id" ]; then
    printf '%s\n' "$project_id"
    return 0
  fi
  project_name="$(devkit_project_name_for_path "$repo_path")"
  response="$(devkit_superset projects create --local --import "$repo_path" --name "$project_name" --json 2>/dev/null || true)"
  project_id="$(printf '%s' "$response" | jq -r '.result.project.id // .result.id // .project.id // .id // empty' 2>/dev/null)"
  if [ -z "$project_id" ]; then
    project_id="$(devkit_project_id_for_path "$repo_path")"
  fi
  [ -n "$project_id" ] || { devkit_error "could not register Superset project for $repo_path"; return 1; }
  printf '%s\n' "$project_id"
}

devkit_workspace_id_for_target() {
  local target="$1"
  devkit_superset_workspaces_json | jq -r --arg target "$target" '
    (if type == "array" then . else (.result.workspaces? // .workspaces? // .result? // []) end)[]? |
    select((.branch // .git.branch // "" | sub("^refs/heads/"; "")) == $target or
           (.worktreePath // .path // .worktree.path // "") == $target or
           (.name // "") == $target) |
    (.id // .workspaceId // .workspace.id // empty)' 2>/dev/null | head -n 1
}

devkit_workspace_path_for_target() {
  local target="$1"
  devkit_superset_workspaces_json | jq -r --arg target "$target" '
    (if type == "array" then . else (.result.workspaces? // .workspaces? // .result? // []) end)[]? |
    select((.branch // .git.branch // "" | sub("^refs/heads/"; "")) == $target or
           (.worktreePath // .path // .worktree.path // "") == $target or
           (.name // "") == $target) |
    (.worktreePath // .path // .worktree.path // empty)' 2>/dev/null | head -n 1
}

devkit_workspace_create() {
  local project_id="$1" branch="$2" slug="$3"
  local response id
  response="$(devkit_superset workspaces create --local --project "$project_id" --branch "$branch" --name "$slug" --json 2>/dev/null || true)"
  id="$(printf '%s' "$response" | jq -r '.result.workspace.id // .result.id // .workspace.id // .id // empty' 2>/dev/null)"
  if [ -z "$id" ]; then
    id="$(devkit_workspace_id_for_target "$branch")"
  fi
  [ -n "$id" ] || { devkit_error "could not create or find Superset workspace for $branch"; return 1; }
  printf '%s\n' "$id"
}

devkit_agent_command() {
  local agent="$1" model="$2" effort="$3" prompt="$4"
  local -a command_parts
  command_parts=("$agent")
  [ -n "$model" ] && command_parts+=(--model "$model")
  [ -n "$effort" ] && command_parts+=(--effort "$effort")
  [ -n "$prompt" ] && command_parts+=("$prompt")
  printf '%q ' "${command_parts[@]}"
}

devkit_launch_agent() {
  local worktree_path="$1" workspace_id="$2" agent="$3" model="$4" effort="$5" prompt="$6"
  local context command_text
  context="$(devkit_context_detect)"
  command_text="$(devkit_agent_command "$agent" "$model" "$effort" "$prompt")"
  case "$context" in
    orca)
      devkit_require_command orca || { devkit_error "orca CLI is not available"; return 1; }
      orca terminal create --worktree "path:$worktree_path" --title "$agent $worktree_path" --command "$command_text" --json
      ;;
    superset)
      devkit_superset_available || { devkit_error "superset CLI is not available"; return 1; }
      if devkit_superset terminals create --help >/dev/null 2>&1; then
        devkit_superset terminals create --workspace "$workspace_id" --command "$command_text" --json
      else
        devkit_error "Superset CLI has no terminals create command; agent launch is unavailable"
        return 1
      fi
      ;;
    *)
      devkit_error "cannot launch agent from unknown orchestration host"
      return 1
      ;;
  esac
}

devkit_terminal_create() {
  local worktree_selector="" command_text="" title="" json=false arg worktree_path host workspace_id response
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --worktree) worktree_selector="${2:-}"; shift 2 ;;
      --command) command_text="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help)
        printf 'Usage: devkit terminal create [--worktree <path>] --command <cmd> [--title <text>] [--json]\n'
        printf 'Superset tabs are not titled; only Orca tabs are.\n'
        return 0
        ;;
      *) devkit_error "unknown terminal create option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  [ -n "$command_text" ] || { devkit_error "--command is required"; return "$DEVKIT_USAGE_ERROR"; }
  if [ -n "$worktree_selector" ]; then
    if [ -d "$worktree_selector" ]; then
      worktree_path="$(git -C "$worktree_selector" rev-parse --show-toplevel 2>/dev/null || true)"
    else
      devkit_error "worktree path is not a Git directory: $worktree_selector"
      return 1
    fi
  else
    worktree_path="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  [ -n "$worktree_path" ] || { devkit_error "could not resolve a Git worktree from ${worktree_selector:-$PWD}"; return 1; }
  host="$(devkit_context_detect)"
  case "$host" in
    orca)
      devkit_require_command orca || { devkit_error "orca CLI is not available"; return 1; }
      if [ -n "$title" ]; then
        response="$(orca terminal create --worktree "path:$worktree_path" --title "$title" --command "$command_text" --json)" || return 1
      else
        response="$(orca terminal create --worktree "path:$worktree_path" --command "$command_text" --json)" || return 1
      fi
      ;;
    superset)
      devkit_superset_available || { devkit_error "superset CLI is not available"; return 1; }
      workspace_id="$(devkit_workspace_id_for_target "$worktree_path")"
      if [ -z "$workspace_id" ]; then
        devkit_error "no Superset workspace is registered for $worktree_path; run devkit worktree adopt $worktree_path first"
        return 1
      fi
      response="$(devkit_superset terminals create --workspace "$workspace_id" --command "$command_text" --json)" || return 1
      ;;
    *)
      devkit_error "cannot create terminal from unknown orchestration host"
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

devkit_worktree_create() {
  local repo_selector="" branch="" base="" slug="" agent="" model="" effort="" prompt="" orchestrate=false json=false
  local arg repo_path shared_root worktree_path project_id workspace_id
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
      --orchestrate) orchestrate=true; shift ;;
      --json) json=true; shift ;;
      -h|--help)
        printf 'Usage: devkit worktree create --repo <name|path> --branch <branch> [--base <ref>] [--name <slug>] [--agent <id>] [--model <id>] [--effort <level>] [--prompt <text>] [--json]\n'
        return 0
        ;;
      *) devkit_error "unknown worktree create option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  [ -n "$repo_selector" ] || { devkit_error "--repo is required"; return "$DEVKIT_USAGE_ERROR"; }
  [ -n "$branch" ] || { devkit_error "--branch is required"; return "$DEVKIT_USAGE_ERROR"; }
  if [ "$orchestrate" = true ]; then
    [ -n "$agent" ] || { devkit_error "--agent is required for orchestrate spawn"; return "$DEVKIT_USAGE_ERROR"; }
    [ -n "$model" ] || { devkit_error "--model is required for orchestrate spawn"; return "$DEVKIT_USAGE_ERROR"; }
    [ -n "$effort" ] || { devkit_error "--effort is required for orchestrate spawn"; return "$DEVKIT_USAGE_ERROR"; }
    [ -n "$prompt" ] || { devkit_error "--prompt is required for orchestrate spawn"; return "$DEVKIT_USAGE_ERROR"; }
  fi
  [ -n "$agent" ] && ! devkit_require_command "$agent" && { devkit_error "agent is not on PATH: $agent"; return 1; }
  repo_path="$(devkit_repo_from_orca "$repo_selector")" || return 1
  shared_root="$(devkit_worktree_root)" || return 1
  [ -n "$base" ] || base="$(devkit_repo_default_base "$repo_path")"
  [ -n "$slug" ] || slug="$(devkit_slug_from_branch "$branch")" || { devkit_error "branch cannot produce a safe slug"; return 1; }
  case "$slug" in
    .|..|*/*|*"$'\n'"*) devkit_error "invalid worktree name: $slug"; return 1 ;;
  esac
  worktree_path="$shared_root/$slug"
  [ ! -e "$worktree_path" ] || { devkit_error "worktree path already exists: $worktree_path"; return 1; }
  mkdir -p "$shared_root" || return 1
  if [ "$json" = true ]; then
    git -C "$repo_path" worktree add "$worktree_path" -b "$branch" "$base" >/dev/null || {
      devkit_error "could not create git worktree"
      return 1
    }
  elif ! git -C "$repo_path" worktree add "$worktree_path" -b "$branch" "$base"; then
    devkit_error "could not create git worktree"
    return 1
  fi
  project_id="$(devkit_ensure_superset_project "$repo_path")" || {
    git -C "$repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    git -C "$repo_path" branch -D "$branch" >/dev/null 2>&1 || true
    return 1
  }
  workspace_id="$(devkit_workspace_create "$project_id" "$branch" "$slug")" || {
    git -C "$repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    git -C "$repo_path" branch -D "$branch" >/dev/null 2>&1 || true
    return 1
  }
  if [ "$json" != true ]; then
    printf 'worktree: %s\nbranch: %s\nworkspace: %s\n' "$worktree_path" "$branch" "$workspace_id"
  fi
  if [ -n "$agent" ]; then
    if [ "$json" = true ]; then
      devkit_launch_agent "$worktree_path" "$workspace_id" "$agent" "$model" "$effort" "$prompt" >/dev/null || return 1
    else
      devkit_launch_agent "$worktree_path" "$workspace_id" "$agent" "$model" "$effort" "$prompt" || return 1
    fi
  fi
  if [ "$orchestrate" = true ] && [ "$json" != true ]; then
    devkit_info "host: $(devkit_context_detect)"
  fi
  if [ "$json" = true ]; then
    jq -n --arg worktree "$worktree_path" --arg branch "$branch" --arg workspace "$workspace_id" \
      '{worktree: $worktree, branch: $branch, workspace: (if $workspace|length > 0 then $workspace else null end)}'
  fi
  return 0
}

devkit_git_worktree_info() {
  local root="$1"
  git -C "$root" worktree list --porcelain 2>/dev/null
}

devkit_find_worktree_path() {
  local target="$1" shared_root="$2" path branch line current_path current_branch
  if [ -d "$target" ] && git -C "$target" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$target" rev-parse --show-toplevel
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

devkit_worktree_finish() {
  local target="" delete_branch=false force=false json=false arg shared_root path workspace_id repo_path branch base merged
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      --delete-branch) delete_branch=true; shift ;;
      --force) force=true; shift ;;
      -h|--help) printf 'Usage: devkit worktree finish <branch|path|slug> [--delete-branch] [--force] [--json]\n'; return 0 ;;
      *)
        [ -z "$target" ] || { devkit_error "unknown worktree finish option: $arg"; return "$DEVKIT_USAGE_ERROR"; }
        target="$arg"
        shift
        ;;
    esac
  done
  [ -n "$target" ] || { devkit_error "Usage: devkit worktree finish <branch|path|slug> [--delete-branch] [--force] [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shared_root="$(devkit_worktree_root 2>/dev/null || true)"
  path=""
  if devkit_superset_available; then
    path="$(devkit_workspace_path_for_target "$target")"
    workspace_id="$(devkit_workspace_id_for_target "$target")"
  fi
  if [ -z "$path" ] && [ -n "$shared_root" ]; then
    path="$(devkit_find_worktree_path "$target" "$shared_root" 2>/dev/null || true)"
  fi
  if [ -z "$path" ]; then
    devkit_error "worktree not found: $target"
    return 1
  fi
  repo_path="$(git -C "$path" rev-parse --git-common-dir)"
  case "$repo_path" in
    /*) ;;
    *) repo_path="$path/$repo_path" ;;
  esac
  repo_path="$(dirname "$(realpath "$repo_path")")"
  branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -n "$workspace_id" ]; then
    local -a delete_args
    delete_args=(workspaces delete "$workspace_id" --local --json)
    if [ "$json" = true ]; then
      devkit_superset "${delete_args[@]}" >/dev/null || return 1
    else
      devkit_superset "${delete_args[@]}" || return 1
    fi
  elif devkit_require_command orca; then
    if [ "$json" = true ]; then
      orca worktree rm --worktree "path:$path" $([ "$force" = true ] && printf '%s' --force) --json >/dev/null || return 1
    else
      orca worktree rm --worktree "path:$path" $([ "$force" = true ] && printf '%s' --force) --json || return 1
    fi
  else
    if [ "$json" = true ]; then
      git -C "$repo_path" worktree remove $([ "$force" = true ] && printf '%s' --force) "$path" >/dev/null || return 1
    else
      git -C "$repo_path" worktree remove $([ "$force" = true ] && printf '%s' --force) "$path" || return 1
    fi
  fi
  if [ "$delete_branch" = true ] && [ -n "$branch" ]; then
    base="$(devkit_repo_default_base "$repo_path")"
    if [ "$force" != true ]; then
      merged="$(git -C "$repo_path" branch --merged "$base" 2>/dev/null || true)"
      if ! printf '%s\n' "$merged" | sed 's/^..//' | awk '{print $1}' | grep -Fx "$branch" >/dev/null; then
        devkit_error "refusing to delete unmerged branch: $branch (use --force to override)"
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

devkit_worktree_list() {
  local repo_selector="" arg shared_root repo_filter path branch in_superset workspaces_json json=false entry entries
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --repo) repo_selector="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit worktree list [--repo <name|path>] [--json]\n'; return 0 ;;
      *) devkit_error "unknown worktree list option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  shared_root="$(devkit_worktree_root)" || return 1
  if [ -n "$repo_selector" ]; then
    repo_filter="$(devkit_repo_from_orca "$repo_selector")" || return 1
    repo_filter="$(git -C "$repo_filter" rev-parse --git-common-dir | xargs realpath 2>/dev/null || true)"
  fi
  workspaces_json='[]'
  if devkit_superset_available; then
    workspaces_json="$(devkit_superset_workspaces_json || printf '[]')"
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

devkit_worktree_adopt() {
  local target="" arg shared_root path repo_path branch slug project_id workspace_id json=false
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit worktree adopt <path|branch> [--json]\n'; return 0 ;;
      *)
        [ -z "$target" ] || { devkit_error "unknown worktree adopt option: $arg"; return "$DEVKIT_USAGE_ERROR"; }
        target="$arg"
        shift
        ;;
    esac
  done
  [ -n "$target" ] || { devkit_error "Usage: devkit worktree adopt <path|branch> [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shared_root="$(devkit_worktree_root)" || return 1
  if [ -d "$target" ]; then
    path="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)"
  else
    path="$(devkit_find_worktree_path "$target" "$shared_root" 2>/dev/null || true)"
  fi
  [ -n "$path" ] || { devkit_error "physical worktree not found: $target"; return 1; }
  case "$path" in
    "$shared_root"/*) ;;
    *) devkit_error "worktree is outside Superset's shared root: $path"; return 1 ;;
  esac
  repo_path="$(git -C "$path" rev-parse --show-toplevel)"
  branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [ -n "$branch" ] || { devkit_error "cannot adopt detached worktree: $path"; return 1; }
  if [ -n "$(devkit_workspace_id_for_target "$path")" ]; then
    devkit_error "worktree is already registered in Superset: $path"
    return 1
  fi
  slug="$(basename "$path")"
  project_id="$(devkit_ensure_superset_project "$repo_path")" || return 1
  workspace_id="$(devkit_workspace_create "$project_id" "$branch" "$slug")" || return 1
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
    create) devkit_worktree_create "$@" ;;
    finish) devkit_worktree_finish "$@" ;;
    list) devkit_worktree_list "$@" ;;
    adopt) devkit_worktree_adopt "$@" ;;
    -h|--help|"")
      printf 'Usage: devkit worktree create|finish|list|adopt ...\n'
      ;;
    *) devkit_error "unknown worktree command: $subcommand"; return "$DEVKIT_USAGE_ERROR" ;;
  esac
}

command_terminal() {
  local subcommand="${1:-}"
  shift || true
  case "$subcommand" in
    create) devkit_terminal_create "$@" ;;
    -h|--help|"")
      printf 'Usage: devkit terminal create [--worktree <path>] --command <cmd> [--title <text>] [--json]\n'
      printf 'Superset tabs are not titled; only Orca tabs are.\n'
      ;;
    *) devkit_error "unknown terminal command: $subcommand"; return "$DEVKIT_USAGE_ERROR" ;;
  esac
}

module_worktree_doctor() {
  if ! devkit_superset_available; then
    devkit_set_status missing "superset CLI is not on PATH and $HOME/.superset/bin/superset is unavailable"
    return 1
  fi
  if ! devkit_require_command orca; then
    devkit_set_status missing "orca CLI is not on PATH"
    return 1
  fi
  local root
  root="$(devkit_worktree_root --read-only 2>/dev/null || true)"
  if [ -z "$root" ]; then
    devkit_set_status misconfigured "Superset worktreeBaseDir is unset or unreadable"
    return 1
  fi
  devkit_set_status ok "$root"
  return 0
}

module_worktree_install() {
  module_worktree_doctor
}
