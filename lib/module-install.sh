#!/usr/bin/env bash

megabrain_module_doctor() {
  local module="$1"
  case "$module" in
    orchestration) module_orchestration_doctor ;;
    orchestration-hooks) module_orchestration_hooks_doctor ;;
    worktree) module_worktree_doctor ;;
    simulator-web) module_simulator_web_doctor ;;
    simulator-native) module_simulator_native_doctor ;;
    simulator-tv) module_simulator_tv_doctor ;;
    tv-adb) module_tv_adb_doctor ;;
    tmux-runtime) module_tmux_runtime_doctor ;;
    *) megabrain_set_status missing "unknown module"; return 1 ;;
  esac
}

megabrain_module_install() {
  local module="$1"
  case "$module" in
    orchestration) module_orchestration_install ;;
    orchestration-hooks) module_orchestration_hooks_install ;;
    worktree) module_worktree_install ;;
    simulator-web) module_simulator_web_install "${2:-false}" "${3:-both}" ;;
    simulator-native) module_simulator_native_install ;;
    simulator-tv) module_simulator_tv_install ;;
    tv-adb) module_tv_adb_install ;;
    tmux-runtime) module_tmux_runtime_install "${2:-false}" ;;
    *) megabrain_error "unknown module: $module"; return "$MEGABRAIN_USAGE_ERROR" ;;
  esac
}

megabrain_module_revert() {
  local module="$1"
  case "$module" in
    orchestration-hooks) module_orchestration_hooks_revert ;;
    *) megabrain_error "module cannot be reverted: $module"; return "$MEGABRAIN_USAGE_ERROR" ;;
  esac
}

megabrain_install_one() {
  local module="$1"
  local assume_yes="${2:-false}" browser="${3:-both}" install_rc doctor_rc
  MODULE_UNCERTAIN_REASONS='[]'
  MODULE_RETAINED_REASONS='[]'
  megabrain_module_install "$module" "$assume_yes" "$browser"
  install_rc=$?
  megabrain_module_doctor "$module"
  doctor_rc=$?
  if [ "$doctor_rc" -eq 0 ] && [ "$install_rc" -eq 0 ]; then
    megabrain_state_set "$module" true "$MODULE_DETAILS" || return 1
    megabrain_status_line "$module" "$MODULE_STATUS" "$MODULE_REASON"
    return 0
  fi
  megabrain_state_set "$module" false "$MODULE_DETAILS" || return 1
  megabrain_status_line "$module" "$MODULE_STATUS" "$MODULE_REASON"
  return 1
}

megabrain_doctor_one() {
  local module="$1"
  local json="${2:-false}"
  local observed_installed=false
  MODULE_UNCERTAIN_DISPATCHES=0
  MODULE_RETAINED_TERMINALS=0
  MODULE_PRUNABLE_DISPATCHES=0
  MODULE_UNCERTAIN_REASONS='[]'
  MODULE_RETAINED_REASONS='[]'
  megabrain_module_doctor "$module"
  local rc=$?
  [ "$rc" -eq 0 ] && observed_installed=true
  if ! megabrain_state_reconcile "$module" "$observed_installed" "$MODULE_DETAILS"; then
    MODULE_REASON="$MODULE_REASON; state reconciliation failed"
    MODULE_DETAILS="$MODULE_REASON"
    rc=1
  elif [ -n "$MEGABRAIN_STATE_RECONCILIATION" ]; then
    MODULE_REASON="$MODULE_REASON; $MEGABRAIN_STATE_RECONCILIATION"
  fi
  if [ "$json" = true ]; then
    jq -n --arg moduleName "$module" --arg status "$MODULE_STATUS" --arg reason "$MODULE_REASON" \
      --argjson uncertainDispatches "${MODULE_UNCERTAIN_DISPATCHES:-0}" \
      --argjson retainedTerminals "${MODULE_RETAINED_TERMINALS:-0}" \
      --argjson prunableDispatches "${MODULE_PRUNABLE_DISPATCHES:-0}" \
      --argjson uncertainReasons "${MODULE_UNCERTAIN_REASONS:-[]}" \
      --argjson retainedReasons "${MODULE_RETAINED_REASONS:-[]}" \
      '{module: $moduleName, status: $status, reason: $reason, uncertainDispatches: $uncertainDispatches, uncertainReasons: $uncertainReasons, retainedTerminals: $retainedTerminals, retainedReasons: $retainedReasons, prunableDispatches: $prunableDispatches}'
  else
    megabrain_status_line "$module" "$MODULE_STATUS" "$MODULE_REASON"
  fi
  return "$rc"
}

megabrain_interactive_modules() {
  local index module selected
  local -a ids
  ids=()
  while IFS= read -r module; do
    ids+=("$module")
  done < <(megabrain_module_ids)
  printf 'Select modules to install (numbers separated by spaces, or all):\n'
  index=1
  if [ "${#ids[@]}" -gt 0 ]; then
    for module in "${ids[@]}"; do
      printf '  [%d] %s\n' "$index" "$module"
      index=$((index + 1))
    done
  fi
  read -r -p 'Modules: ' selected || return 1
  if [ "$selected" = all ]; then
    if [ "${#ids[@]}" -gt 0 ]; then
      printf '%s\n' "${ids[@]}"
    fi
    return 0
  fi
  for index in $selected; do
    case "$index" in
      '') megabrain_error "invalid module selection: $index"; return 1 ;;
      *)
        if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "${#ids[@]}" ]; then
          printf '%s\n' "${ids[$((index - 1))]}"
        else
          megabrain_error "invalid module selection: $index"
          return 1
        fi
        ;;
    esac
  done
}

command_install() {
  local module="" selected selected_modules rc=0 assume_yes=false revert=false browser=both arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --yes) assume_yes=true; shift ;;
      --revert) revert=true; shift ;;
      --browser)
        [ "$#" -gt 1 ] || { megabrain_usage_fail install; return "$MEGABRAIN_USAGE_ERROR"; }
        browser="$2"
        shift 2
        ;;
      -h|--help)
        megabrain_usage_show install
        return 0
        ;;
      *)
        if [ -n "$module" ]; then
          megabrain_error "install accepts at most one module id"
          return "$MEGABRAIN_USAGE_ERROR"
        fi
        module="$arg"
        shift
        ;;
    esac
  done
  if [ -n "$module" ]; then
    megabrain_validate_module "$module" || { megabrain_error "unknown module: $module"; return "$MEGABRAIN_USAGE_ERROR"; }
    if [ "$revert" = true ]; then
      megabrain_module_revert "$module"
      return $?
    fi
    megabrain_install_one "$module" "$assume_yes" "$browser"
    return $?
  fi
  if [ ! -t 0 ]; then
    megabrain_error "install without a module id requires an interactive terminal"
    return 1
  fi
  selected_modules="$(megabrain_interactive_modules)" || return 1
  while IFS= read -r selected; do
    megabrain_install_one "$selected" "$assume_yes" "$browser" || rc=1
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
        megabrain_usage_show doctor
        return 0
        ;;
      *)
        if [ -n "$module" ]; then
          megabrain_error "doctor accepts at most one module id"
          return "$MEGABRAIN_USAGE_ERROR"
        fi
        module="$arg"
        shift
        ;;
    esac
  done
  if [ -n "$module" ]; then
    megabrain_validate_module "$module" || { megabrain_error "unknown module: $module"; return "$MEGABRAIN_USAGE_ERROR"; }
    megabrain_doctor_one "$module" "$json"
    return $?
  fi
  results=''
  while IFS= read -r current; do
    if [ "$json" = true ]; then
      result="$(megabrain_doctor_one "$current" true)" || rc=1
      results="${results}${result}
"
    else
      megabrain_doctor_one "$current" || rc=1
    fi
  done < <(megabrain_module_ids)
  if [ "$json" = true ]; then
    printf '%s' "$results" | jq -s .
  fi
  return "$rc"
}

module_orchestration_doctor() {
  local orca_status superset_status counts_suffix tmux_runtime=false
  megabrain_dispatch_health_counts
  counts_suffix="; uncertain dispatches: $MODULE_UNCERTAIN_DISPATCHES (run megabrain orchestrate list --uncertain); retained terminals: $MODULE_RETAINED_TERMINALS; prunable dispatches: $MODULE_PRUNABLE_DISPATCHES"
  if [ "${MODULE_UNCERTAIN_DISPATCHES:-0}" -gt 0 ]; then
    counts_suffix="$counts_suffix; unresolved reasons: $(printf '%s' "${MODULE_UNCERTAIN_REASONS:-[]}" | jq -r '[.[].reason] | unique | join(", ")')"
  fi
  if [ "${MODULE_RETAINED_TERMINALS:-0}" -gt 0 ]; then
    counts_suffix="$counts_suffix; retained reasons: $(printf '%s' "${MODULE_RETAINED_REASONS:-[]}" | jq -r '[.[].reason] | unique | join(", ")')"
  fi
  if [ "${MODULE_UNCERTAIN_DISPATCHES:-0}" -gt 0 ] || [ "${MODULE_RETAINED_TERMINALS:-0}" -gt 0 ]; then
    megabrain_set_status misconfigured "dispatch state requires reconciliation$counts_suffix"
    return 1
  fi
  if megabrain_runtime_enabled && megabrain_tmux_available; then
    tmux_runtime=true
  fi
  if ! megabrain_require_command orca; then
    if [ "$tmux_runtime" = true ]; then
      orca_status=optional
    else
      megabrain_set_status missing "orca CLI is not on PATH$counts_suffix"
      return 1
    fi
  elif ! orca status --json >/dev/null 2>&1; then
    megabrain_set_status misconfigured "orca status --json failed$counts_suffix"
    return 1
  else
    orca_status=ok
  fi
  if ! megabrain_superset_available; then
    if [ "$tmux_runtime" = true ]; then
      superset_status=optional
    else
      megabrain_set_status missing "superset CLI is not on PATH and $HOME/.superset/bin/superset is unavailable$counts_suffix"
      return 1
    fi
  elif ! megabrain_superset workspaces list --json >/dev/null 2>&1; then
    megabrain_set_status misconfigured "superset workspaces list --json failed$counts_suffix"
    return 1
  else
    superset_status=ok
  fi
  if [ "$tmux_runtime" = true ] && { [ "$orca_status" = optional ] || [ "$superset_status" = optional ]; }; then
    megabrain_set_status ok "tmux runtime is usable; missing orchestrator CLIs are optional$counts_suffix"
    return 0
  fi
  megabrain_set_status ok "orca and superset status checks passed$counts_suffix"
  return 0
}

module_orchestration_install() {
  module_orchestration_doctor
}
