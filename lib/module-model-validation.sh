#!/usr/bin/env bash

devkit_model_error_unknown() {
  local agent="$1" model="$2" id
  devkit_error "unknown model '$model' for agent '$agent'. Valid model ids:"
  while IFS= read -r id; do
    [ -n "$id" ] && devkit_error "  $id"
  done < <(devkit_model_list_ids "$agent")
}

devkit_model_error_embedded_effort() {
  local agent="$1" model="$2" level id ids
  devkit_error "model '$model' for agent '$agent' has effort as part of the model id; do not supply effort"
  devkit_error 'Model ids by embedded reasoning level:'
  for level in low medium high xhigh max ultra; do
    ids="$(devkit_model_read | jq -r --arg agent "$agent" --arg level "$level" '.models[] | select(.agent == $agent and .reasoning.separateAxis == false and (.reasoning.levels | index($level))) | .model')"
    [ -n "$ids" ] || continue
    devkit_error "$level:"
    while IFS= read -r id; do
      [ -n "$id" ] && devkit_error "  $id"
    done <<EOF
$ids
EOF
  done
}

devkit_model_validate_reasoning() {
  local agent="$1" model="$2" effort="$3" entry levels separate_axis
  entry="$(devkit_model_entry "$agent" "$model")"
  [ -n "$entry" ] || return 1
  separate_axis="$(printf '%s' "$entry" | jq -r '.reasoning.separateAxis')"
  if [ "$separate_axis" = false ]; then
    if [ -n "$effort" ]; then
      devkit_model_error_embedded_effort "$agent" "$model"
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
    devkit_error "model '$model' for agent '$agent' does not support reasoning level '$effort'. Supported reasoning levels:"
    if [ -n "$levels" ]; then
      while IFS= read -r level; do
        [ -n "$level" ] && devkit_error "  $level"
      done <<EOF
$levels
EOF
    else
      devkit_error '  none'
    fi
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
