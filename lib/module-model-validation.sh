#!/usr/bin/env bash

megabrain_model_error_unknown() {
  local agent="$1" model="$2" id
  megabrain_error "unknown model '$model' for agent '$agent'. Valid model ids:"
  while IFS= read -r id; do
    [ -n "$id" ] && megabrain_error "  $id"
  done < <(megabrain_model_list_ids "$agent")
}

megabrain_model_error_embedded_effort() {
  local agent="$1" model="$2" level id ids
  megabrain_error "model '$model' for agent '$agent' has effort as part of the model id; do not supply effort"
  megabrain_error 'Model ids by embedded reasoning level:'
  for level in low medium high xhigh max ultra; do
    ids="$(megabrain_model_read | jq -r --arg agent "$agent" --arg level "$level" '.models[] | select(.agent == $agent and .reasoning.separateAxis == false and (.reasoning.levels | index($level))) | .model')"
    [ -n "$ids" ] || continue
    megabrain_error "$level:"
    while IFS= read -r id; do
      [ -n "$id" ] && megabrain_error "  $id"
    done <<EOF
$ids
EOF
  done
}

megabrain_model_validate_reasoning() {
  local agent="$1" model="$2" effort="$3" entry levels separate_axis
  entry="$(megabrain_model_entry "$agent" "$model")"
  [ -n "$entry" ] || return 1
  separate_axis="$(printf '%s' "$entry" | jq -r '.reasoning.separateAxis')"
  if [ "$separate_axis" = false ]; then
    if [ -n "$effort" ]; then
      megabrain_model_error_embedded_effort "$agent" "$model"
      return 1
    fi
    return 0
  fi
  [ -n "$effort" ] || {
    megabrain_error "model '$model' for agent '$agent' requires a separate reasoning level"
    return 1
  }
  levels="$(printf '%s' "$entry" | jq -r '.reasoning.levels[]?')"
  if ! printf '%s\n' "$levels" | grep -Fx -- "$effort" >/dev/null 2>&1; then
    megabrain_error "model '$model' for agent '$agent' does not support reasoning level '$effort'. Supported reasoning levels:"
    if [ -n "$levels" ]; then
      while IFS= read -r level; do
        [ -n "$level" ] && megabrain_error "  $level"
      done <<EOF
$levels
EOF
    else
      megabrain_error '  none'
    fi
    return 1
  fi
}

megabrain_model_effort_separate() {
  local entry
  entry="$(megabrain_model_entry "$1" "$2")"
  [ -n "$entry" ] || return 1
  [ "$(printf '%s' "$entry" | jq -r '.reasoning.separateAxis')" = true ]
}

megabrain_model_warn_lifecycle() {
  local agent="$1" model="$2" entry status retirement_date
  entry="$(megabrain_model_entry "$agent" "$model")"
  status="$(printf '%s' "$entry" | jq -r '.status // "active"')"
  case "$status" in
    retired|deprecated)
      retirement_date="$(printf '%s' "$entry" | jq -r '.retirementDate // empty')"
      if [ -n "$retirement_date" ]; then
        megabrain_error "Warning: model '$model' for agent '$agent' is $status (retirement date: $retirement_date)."
      else
        megabrain_error "Warning: model '$model' for agent '$agent' is $status."
      fi
      ;;
  esac
}

megabrain_model_validate_step() {
  local chain="$1" index="$2" agent="$3" model="$4" effort="$5"
  if ! megabrain_model_known "$agent" "$model"; then
    megabrain_model_error_unknown "$agent" "$model"
    megabrain_error "invalid chain $chain step $index: model '$model' is not registered for agent '$agent'"
    return 1
  fi
  megabrain_model_warn_lifecycle "$agent" "$model"
  megabrain_model_validate_reasoning "$agent" "$model" "$effort" || {
    megabrain_error "invalid chain $chain step $index: unsupported reasoning level '$effort' for model '$model'"
    return 1
  }
}
