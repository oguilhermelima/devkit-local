#!/usr/bin/env bash

devkit_model_error_unknown() {
  local agent="$1" model="$2" ids
  ids="$(devkit_model_list_ids "$agent" | paste -sd ', ' -)"
  devkit_error "unknown model '$model' for agent '$agent'. Valid model ids: $ids"
}

devkit_model_validate_reasoning() {
  local agent="$1" model="$2" effort="$3" entry levels separate_axis
  entry="$(devkit_model_entry "$agent" "$model")"
  [ -n "$entry" ] || return 1
  separate_axis="$(printf '%s' "$entry" | jq -r '.reasoning.separateAxis')"
  if [ "$separate_axis" = false ]; then
    if [ -n "$effort" ]; then
      devkit_error "model '$model' for agent '$agent' has effort in its model id; do not supply effort"
      return 1
    fi
    return 0
  fi
  [ -n "$effort" ] || {
    devkit_error "model '$model' for agent '$agent' requires a separate reasoning level"
    return 1
  }
  levels="$(printf '%s' "$entry" | jq -r '.reasoning.levels[]?')"
  if ! printf '%s\n' "$levels" | grep -Fx -- "$effort" >/dev/null 2>&1; then
    [ -n "$levels" ] && levels="$(printf '%s\n' "$levels" | paste -sd ', ' -)" || levels=none
    devkit_error "model '$model' for agent '$agent' does not support reasoning level '$effort'. Supported reasoning levels: $levels"
    return 1
  fi
}

devkit_model_effort_separate() {
  local entry
  entry="$(devkit_model_entry "$1" "$2")"
  [ -n "$entry" ] || return 1
  [ "$(printf '%s' "$entry" | jq -r '.reasoning.separateAxis')" = true ]
}

devkit_model_validate_step() {
  local chain="$1" index="$2" agent="$3" model="$4" effort="$5"
  if ! devkit_model_known "$agent" "$model"; then
    devkit_model_error_unknown "$agent" "$model"
    devkit_error "invalid chain $chain step $index: model '$model' is not registered for agent '$agent'"
    return 1
  fi
  devkit_model_validate_reasoning "$agent" "$model" "$effort" || {
    devkit_error "invalid chain $chain step $index: unsupported reasoning level '$effort' for model '$model'"
    return 1
  }
}
