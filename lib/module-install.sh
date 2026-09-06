#!/usr/bin/env bash

devkit_module_doctor() {
  local module="$1"
  case "$module" in
    orchestration) module_orchestration_doctor ;;
    orchestration-hooks) module_orchestration_hooks_doctor ;;
    worktree) module_worktree_doctor ;;
    simulator-web) module_simulator_web_doctor ;;
    simulator-native) module_simulator_native_doctor ;;
    simulator-tv) module_simulator_tv_doctor ;;
    tv-adb) module_tv_adb_doctor ;;
    *) devkit_set_status missing "unknown module"; return 1 ;;
  esac
}

devkit_module_install() {
  local module="$1"
  case "$module" in
    orchestration) module_orchestration_install ;;
    orchestration-hooks) module_orchestration_hooks_install ;;
    worktree) module_worktree_install ;;
    simulator-web) module_simulator_web_install ;;
    simulator-native) module_simulator_native_install ;;
    simulator-tv) module_simulator_tv_install ;;
    tv-adb) module_tv_adb_install ;;
    *) devkit_error "unknown module: $module"; return "$DEVKIT_USAGE_ERROR" ;;
  esac
}

devkit_install_one() {
  local module="$1"
  local install_rc doctor_rc
  devkit_module_install "$module"
  install_rc=$?
  devkit_module_doctor "$module"
  doctor_rc=$?
  if [ "$doctor_rc" -eq 0 ] && [ "$install_rc" -eq 0 ]; then
    devkit_state_set "$module" true "$MODULE_DETAILS" || return 1
    devkit_status_line "$module" "$MODULE_STATUS" "$MODULE_REASON"
    return 0
  fi
  devkit_state_set "$module" false "$MODULE_DETAILS" || return 1
  devkit_status_line "$module" "$MODULE_STATUS" "$MODULE_REASON"
  return 1
}

devkit_doctor_one() {
  local module="$1"
  local json="${2:-false}"
  devkit_module_doctor "$module"
  local rc=$?
  if [ "$json" = true ]; then
    jq -n --arg module "$module" --arg status "$MODULE_STATUS" --arg reason "$MODULE_REASON" \
      '{module: $module, status: $status, reason: $reason}'
  else
    devkit_status_line "$module" "$MODULE_STATUS" "$MODULE_REASON"
  fi
  return "$rc"
}

devkit_interactive_modules() {
  local index module selected
  local -a ids
  ids=()
  while IFS= read -r module; do
    ids+=("$module")
  done < <(devkit_module_ids)
  printf 'Select modules to install (numbers separated by spaces, or all):\n'
  index=1
  for module in "${ids[@]}"; do
    printf '  [%d] %s\n' "$index" "$module"
    index=$((index + 1))
  done
  read -r -p 'Modules: ' selected || return 1
  if [ "$selected" = all ]; then
    printf '%s\n' "${ids[@]}"
    return 0
  fi
  for index in $selected; do
    case "$index" in
      '') devkit_error "invalid module selection: $index"; return 1 ;;
      *)
        if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "${#ids[@]}" ]; then
          printf '%s\n' "${ids[$((index - 1))]}"
        else
          devkit_error "invalid module selection: $index"
          return 1
        fi
        ;;
    esac
  done
}

command_install() {
  local module="${1:-}" selected selected_modules rc=0
  if [ "$#" -gt 1 ]; then
    devkit_error "install accepts at most one module id"
    return "$DEVKIT_USAGE_ERROR"
  fi
  if [ -n "$module" ]; then
    devkit_validate_module "$module" || { devkit_error "unknown module: $module"; return "$DEVKIT_USAGE_ERROR"; }
    devkit_install_one "$module"
    return $?
  fi
  if [ ! -t 0 ]; then
    devkit_error "install without a module id requires an interactive terminal"
    return 1
  fi
  selected_modules="$(devkit_interactive_modules)" || return 1
  while IFS= read -r selected; do
    devkit_install_one "$selected" || rc=1
  done <<EOF
$selected_modules
EOF
  return "$rc"
}

command_doctor() {
  local module="" rc=0 current json=false arg result results
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      -h|--help)
        printf 'Usage: devkit doctor [module-id] [--json]\n'
        return 0
        ;;
      *)
        if [ -n "$module" ]; then
          devkit_error "doctor accepts at most one module id"
          return "$DEVKIT_USAGE_ERROR"
        fi
        module="$arg"
        shift
        ;;
    esac
  done
  if [ -n "$module" ]; then
    devkit_validate_module "$module" || { devkit_error "unknown module: $module"; return "$DEVKIT_USAGE_ERROR"; }
    devkit_doctor_one "$module" "$json"
    return $?
  fi
  results=''
  while IFS= read -r current; do
    if [ "$json" = true ]; then
      result="$(devkit_doctor_one "$current" true)" || rc=1
      results="${results}${result}
"
    else
      devkit_doctor_one "$current" || rc=1
    fi
  done < <(devkit_module_ids)
  if [ "$json" = true ]; then
    printf '%s' "$results" | jq -s .
  fi
  return "$rc"
}

module_orchestration_doctor() {
  local orca_status superset_status
  if ! devkit_require_command orca; then
    devkit_set_status missing "orca CLI is not on PATH"
    return 1
  fi
  if ! orca status --json >/dev/null 2>&1; then
    devkit_set_status misconfigured "orca status --json failed"
    return 1
  fi
  if ! devkit_superset_available; then
    devkit_set_status missing "superset CLI is not on PATH and $HOME/.superset/bin/superset is unavailable"
    return 1
  fi
  if ! devkit_superset workspaces list --json >/dev/null 2>&1; then
    devkit_set_status misconfigured "superset workspaces list --json failed"
    return 1
  fi
  devkit_set_status ok "orca and superset status checks passed"
  return 0
}

module_orchestration_install() {
  module_orchestration_doctor
}
