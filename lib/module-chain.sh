#!/usr/bin/env bash

if ! declare -F megabrain_model_init >/dev/null 2>&1; then
  # shellcheck source=local/devkit/lib/module-model.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/module-model.sh"
fi

MEGABRAIN_CHAIN_AGENTS='codex claude agy'
MEGABRAIN_CHAIN_WINDOWS='5h weekly'

megabrain_chain_seed() {
  cat <<'EOF'
{
  "chains": {
    "claude": {
      "when": {"parentAgent": "claude"},
      "steps": [
        {"agent": "codex", "model": "gpt-5.6-luna", "effort": "high", "until": {"usedPercent": 95, "window": "5h"}},
        {"agent": "agy", "model": "gemini-3.8-flash-high"}
      ]
    },
    "codex": {
      "when": {"parentAgent": "codex"},
      "steps": [
        {"agent": "claude", "model": "claude-sonnet-5", "effort": "high"},
        {"agent": "agy", "model": "gemini-3.8-flash-high"}
      ]
    },
    "agy": {
      "when": {"parentAgent": "agy"},
      "steps": [
        {"agent": "codex", "model": "gpt-5.6-luna", "effort": "high", "until": {"usedPercent": 95, "window": "5h"}},
        {"agent": "claude", "model": "claude-sonnet-5", "effort": "high"}
      ]
    }
  },
  "defaultSteps": [],
  "usageLimits": {
    "liveProviders": [],
    "cacheTtlSeconds": 30,
    "timeoutSeconds": 5,
    "notice": {"enabled": false, "intervalSeconds": 3600}
  }
}
EOF
}

megabrain_chain_init() {
  local tmp seed
  mkdir -p "$MEGABRAIN_STATE_DIR" || return 1
  megabrain_model_init || return 1
  if [ ! -f "$MEGABRAIN_CHAIN_FILE" ]; then
    tmp="$(mktemp "$MEGABRAIN_STATE_DIR/chains.XXXXXX")" || return 1
    seed="$(megabrain_chain_seed)" || return 1
    megabrain_chain_validate_config "$seed" true || return 1
    if ! printf '%s\n' "$seed" >"$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    mv -f "$tmp" "$MEGABRAIN_CHAIN_FILE"
  elif ! jq empty "$MEGABRAIN_CHAIN_FILE" >/dev/null 2>&1; then
    megabrain_error "chain file is not valid JSON: $MEGABRAIN_CHAIN_FILE"
    return 1
  fi
}

megabrain_chain_read() {
  megabrain_chain_init || return 1
  cat "$MEGABRAIN_CHAIN_FILE"
}

megabrain_chain_agent_known() {
  case "$1" in
    codex|claude|agy) return 0 ;;
    *) return 1 ;;
  esac
}

megabrain_chain_window_known() {
  case "$1" in
    5h|weekly) return 0 ;;
    *) return 1 ;;
  esac
}

megabrain_chain_name_valid() {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

megabrain_chain_validate_selector() {
  local chain="$1" selector="$2" key value
  if ! jq -e 'type == "object" and length > 0' >/dev/null 2>&1 <<EOF
$selector
EOF
  then
    megabrain_error "invalid chain $chain selector: expected a non-empty object"
    return 1
  fi
  while IFS= read -r key; do
    case "$key" in
      parentAgent|parentModel|parentEffort) ;;
      *)
        megabrain_error "invalid chain $chain selector: unsupported field $key"
        return 1
        ;;
    esac
    value="$(printf '%s' "$selector" | jq -r --arg key "$key" '.[$key] // empty')"
    [ -n "$value" ] || {
      megabrain_error "invalid chain $chain selector field $key: value cannot be empty"
      return 1
    }
    if [ "$key" = parentAgent ] && ! megabrain_chain_agent_known "$value"; then
      megabrain_error "invalid chain $chain selector field parentAgent: unknown agent $value"
      return 1
    fi
  done < <(printf '%s' "$selector" | jq -r 'keys_unsorted[]')
}

megabrain_chain_validate_step() {
  local chain="$1" index="$2" step="$3" strict="${4:-false}" key agent model effort until_json used_percent window unvalidated has_effort
  if ! printf '%s' "$step" | jq -e 'type == "object"' >/dev/null 2>&1; then
    megabrain_error "invalid chain $chain step $index: expected an object"
    return 1
  fi
  while IFS= read -r key; do
    case "$key" in
      agent|model|effort|until|unvalidated) ;;
      *)
        megabrain_error "invalid chain $chain step $index: unsupported field $key"
        return 1
        ;;
    esac
  done < <(printf '%s' "$step" | jq -r 'keys_unsorted[]')
  agent="$(printf '%s' "$step" | jq -r '.agent // empty')"
  model="$(printf '%s' "$step" | jq -r '.model // empty')"
  effort="$(printf '%s' "$step" | jq -r '.effort // empty')"
  has_effort="$(printf '%s' "$step" | jq -r 'has("effort")')"
  unvalidated="$(printf '%s' "$step" | jq -r '.unvalidated // false')"
  [ -n "$agent" ] || { megabrain_error "invalid chain $chain step $index: agent is required"; return 1; }
  megabrain_chain_agent_known "$agent" || { megabrain_error "invalid chain $chain step $index: unknown agent $agent"; return 1; }
  [ -n "$model" ] || { megabrain_error "invalid chain $chain step $index: model is required"; return 1; }
  if [ "$unvalidated" != true ] && ! megabrain_model_known "$agent" "$model"; then
    if [ "$strict" = true ]; then
      megabrain_model_validate_step "$chain" "$index" "$agent" "$model" "$effort" || return 1
    else
      megabrain_model_error_unknown "$agent" "$model"
      megabrain_error "chain migration required: chain $chain step $index uses unknown model '$model' for agent '$agent'; run megabrain chain repair $chain --step $index --model <valid-id> --effort <level>"
    fi
  elif [ "$unvalidated" != true ]; then
    megabrain_model_warn_lifecycle "$agent" "$model"
    if [ "$has_effort" = true ] && ! megabrain_model_effort_separate "$agent" "$model"; then
      megabrain_model_validate_reasoning "$agent" "$model" __supplied__ || return 1
    else
      megabrain_model_validate_reasoning "$agent" "$model" "$effort" || return 1
    fi
  fi
  if printf '%s' "$step" | jq -e 'has("until")' >/dev/null 2>&1; then
    until_json="$(printf '%s' "$step" | jq -c '.until')"
    if ! printf '%s' "$until_json" | jq -e 'type == "object" and ((keys | sort) == ["usedPercent", "window"])' >/dev/null 2>&1; then
      megabrain_error "invalid chain $chain step $index until: expected usedPercent and window"
      return 1
    fi
    used_percent="$(printf '%s' "$until_json" | jq -r '.usedPercent // empty')"
    window="$(printf '%s' "$until_json" | jq -r '.window // empty')"
    if ! printf '%s' "$until_json" | jq -e '.usedPercent | type == "number" and . >= 0 and . <= 100' >/dev/null 2>&1; then
      megabrain_error "invalid chain $chain step $index until.usedPercent: expected a number from 0 to 100"
      return 1
    fi
    megabrain_chain_window_known "$window" || { megabrain_error "invalid chain $chain step $index until.window: unsupported window $window"; return 1; }
  fi
}

megabrain_chain_validate_config() {
  local config="$1" strict="${2:-false}" chain selector steps step index live_provider field rc=0
  if ! printf '%s' "$config" | jq -e 'type == "object" and (.chains | type == "object") and (.defaultSteps | type == "array")' >/dev/null 2>&1; then
    megabrain_error "invalid chain config: expected chains object and defaultSteps array"
    return 1
  fi
  if printf '%s' "$config" | jq -e 'has("usageLimits")' >/dev/null 2>&1; then
    if ! printf '%s' "$config" | jq -e '.usageLimits | type == "object"' >/dev/null 2>&1; then
      megabrain_error 'invalid usageLimits: expected an object'
      return 1
    fi
    if ! printf '%s' "$config" | jq -e '(.usageLimits.liveProviders // []) | type == "array"' >/dev/null 2>&1; then
      megabrain_error 'invalid usageLimits.liveProviders: expected an array'
      return 1
    fi
    while IFS= read -r live_provider; do
      megabrain_chain_agent_known "$live_provider" || { megabrain_error "invalid usageLimits.liveProviders provider: $live_provider"; return 1; }
    done < <(printf '%s' "$config" | jq -r '.usageLimits.liveProviders[]?')
    for field in cacheTtlSeconds timeoutSeconds; do
      if ! printf '%s' "$config" | jq -e --arg field "$field" '.usageLimits[$field] // 0 | type == "number" and . >= 1 and . <= 3600 and floor == .' >/dev/null 2>&1; then
        megabrain_error "invalid usageLimits.$field: expected an integer from 1 to 3600"
        return 1
      fi
    done
    if printf '%s' "$config" | jq -e '.usageLimits | has("notice")' >/dev/null 2>&1 && ! printf '%s' "$config" | jq -e '.usageLimits.notice | type == "object" and (.enabled | type == "boolean") and (.intervalSeconds | type == "number" and . >= 1 and . <= 604800 and floor == .)' >/dev/null 2>&1; then
      megabrain_error 'invalid usageLimits.notice: expected enabled and intervalSeconds'
      return 1
    fi
  fi
  while IFS= read -r chain; do
    megabrain_chain_name_valid "$chain" || { megabrain_error "invalid chain name: $chain"; return 1; }
    selector="$(printf '%s' "$config" | jq -c --arg chain "$chain" '.chains[$chain].when // empty')"
    megabrain_chain_validate_selector "$chain" "$selector" || return 1
    steps="$(printf '%s' "$config" | jq -c --arg chain "$chain" '.chains[$chain].steps // empty')"
    if ! printf '%s' "$steps" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
      megabrain_error "invalid chain $chain: steps cannot be empty"
      return 1
    fi
    index=0
    while IFS= read -r step; do
      index=$((index + 1))
      megabrain_chain_validate_step "$chain" "$index" "$step" "$strict" || rc=1
    done < <(printf '%s' "$steps" | jq -c '.[]')
  done < <(printf '%s' "$config" | jq -r '.chains | keys[]')
  index=0
  while IFS= read -r step; do
    index=$((index + 1))
    megabrain_chain_validate_step default "$index" "$step" "$strict" || rc=1
  done < <(printf '%s' "$config" | jq -c '.defaultSteps[]')
  return "$rc"
}

megabrain_chain_write() {
  local config="$1" tmp
  tmp="$(mktemp "$MEGABRAIN_STATE_DIR/chains.XXXXXX")" || return 1
  if ! printf '%s' "$config" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$MEGABRAIN_CHAIN_FILE"
}

megabrain_chain_format_list() {
  local config="$1" json="$2"
  if [ "$json" = true ]; then
    printf '%s' "$config" | jq -c '{chains: ([.chains | to_entries[] | .value + {name: .key}]), defaultSteps: .defaultSteps}'
  else
    printf '%-20s %-36s %s\n' NAME SELECTOR STEPS
    printf '%s' "$config" | jq -r '.chains | to_entries[] | [.key, (.value.when | tojson), (.value.steps | length)] | @tsv' |
      while IFS=$'\t' read -r chain selector count; do
        printf '%-20s %-36s %s\n' "$chain" "$selector" "$count"
      done
  fi
}

command_chain_list() {
  local json=false arg config
  for arg in "$@"; do
    case "$arg" in
      --json) json=true ;;
      -h|--help) megabrain_usage_show chain-list; return 0 ;;
      *) megabrain_error "unknown chain list option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  config="$(megabrain_chain_read)" || return 1
  megabrain_chain_validate_config "$config" true || return 1
  megabrain_chain_format_list "$config" "$json"
}

command_chain_add() {
  local name="" when_json='{}' steps_json='[]' json=false allow_unknown=false arg value chain config result registry
  case "${1:-}" in
    -h|--help) megabrain_usage_show chain-add; return 0 ;;
  esac
  [ "$#" -gt 0 ] || { megabrain_usage_fail chain-add; return "$MEGABRAIN_USAGE_ERROR"; }
  name="$1"
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --when) value="${2:-}"; [ -n "$value" ] || { megabrain_error '--when requires a value'; return "$MEGABRAIN_USAGE_ERROR"; }; when_json="$value"; shift 2 ;;
      --steps) value="${2:-}"; [ -n "$value" ] || { megabrain_error '--steps requires a value'; return "$MEGABRAIN_USAGE_ERROR"; }; steps_json="$value"; shift 2 ;;
      --step) value="${2:-}"; [ -n "$value" ] || { megabrain_error '--step requires a value'; return "$MEGABRAIN_USAGE_ERROR"; }; steps_json="$(printf '%s' "$steps_json" | jq --argjson step "$value" '. + [$step]' 2>/dev/null)" || { megabrain_error 'invalid --step JSON'; return 1; }; shift 2 ;;
      --parent-agent|--parent-model|--parent-effort)
        value="${2:-}"; [ -n "$value" ] || { megabrain_error "$arg requires a value"; return "$MEGABRAIN_USAGE_ERROR"; }
        case "$arg" in
          --parent-agent) when_json="$(printf '%s' "$when_json" | jq --arg value "$value" '. + {parentAgent: $value}')" ;;
          --parent-model) when_json="$(printf '%s' "$when_json" | jq --arg value "$value" '. + {parentModel: $value}')" ;;
          --parent-effort) when_json="$(printf '%s' "$when_json" | jq --arg value "$value" '. + {parentEffort: $value}')" ;;
        esac
        shift 2
        ;;
      --allow-unknown-model) allow_unknown=true; shift ;;
      --json) json=true; shift ;;
      -h|--help) megabrain_usage_show chain-add; return 0 ;;
      *) megabrain_error "unknown chain add option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  megabrain_chain_name_valid "$name" || { megabrain_error "invalid chain name: $name"; return 1; }
  config="$(megabrain_chain_read)" || return 1
  if printf '%s' "$config" | jq -e --arg name "$name" '.chains | has($name)' >/dev/null 2>&1; then
    megabrain_error "chain already exists: $name"
    return 1
  fi
  if ! result="$(jq -n --argjson when "$when_json" --argjson steps "$steps_json" '{when: $when, steps: $steps}' 2>/dev/null)"; then
    megabrain_error "chain $name has invalid JSON definition"
    return 1
  fi
  if [ "$allow_unknown" = true ]; then
    registry="$(megabrain_model_read)" || return 1
    result="$(printf '%s' "$result" | jq --argjson models "$(printf '%s' "$registry" | jq '.models')" ' .steps |= map(. as $step | if any($models[]; .agent == $step.agent and .model == $step.model) then . else . + {unvalidated: true} end)')"
  fi
  config="$(printf '%s' "$config" | jq --arg name "$name" --argjson chain "$result" '.chains[$name] = $chain')"
  megabrain_chain_validate_config "$config" true || return 1
  megabrain_chain_write "$config" || return 1
  if [ "$json" = true ]; then
    printf '%s\n' "$result" | jq -c --arg name "$name" '. + {name: $name}'
  else
    printf 'chain added: %s\n' "$name"
  fi
}

command_chain_edit() {
  local name="" json=false allow_unknown=false arg config tmp edited editor registry
  case "${1:-}" in
    -h|--help) megabrain_usage_show chain-edit; return 0 ;;
  esac
  [ "$#" -gt 0 ] || { megabrain_usage_fail chain-edit; return "$MEGABRAIN_USAGE_ERROR"; }
  name="$1"
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      --allow-unknown-model) allow_unknown=true; shift ;;
      -h|--help) megabrain_usage_show chain-edit; return 0 ;;
      *) megabrain_error "unknown chain edit option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  config="$(megabrain_chain_read)" || return 1
  if ! printf '%s' "$config" | jq -e --arg name "$name" '.chains | has($name)' >/dev/null 2>&1; then
    megabrain_error "chain not found: $name"
    return 1
  fi
  tmp="$(mktemp "$MEGABRAIN_STATE_DIR/chains-edit.XXXXXX")" || return 1
  cp "$MEGABRAIN_CHAIN_FILE" "$tmp" || { rm -f "$tmp"; return 1; }
  editor="${EDITOR:-vi}"
  if ! "$editor" "$tmp"; then
    rm -f "$tmp"
    megabrain_error "editor failed while editing chain $name"
    return 1
  fi
  if cmp -s "$MEGABRAIN_CHAIN_FILE" "$tmp"; then
    rm -f "$tmp"
    if [ "$json" = true ]; then
      jq -n --arg name "$name" '{changed: false, name: $name}'
    else
      printf 'chain unchanged: %s\n' "$name"
    fi
    return 0
  fi
  edited="$(cat "$tmp")"
  rm -f "$tmp"
  if [ "$allow_unknown" = true ]; then
    registry="$(megabrain_model_read)" || return 1
    edited="$(printf '%s' "$edited" | jq --arg name "$name" --argjson models "$(printf '%s' "$registry" | jq '.models')" ' .chains[$name].steps |= map(. as $step | if any($models[]; .agent == $step.agent and .model == $step.model) then . else . + {unvalidated: true} end)')"
  fi
  megabrain_chain_validate_config "$edited" true || return 1
  if ! printf '%s' "$edited" | jq -e --arg name "$name" '.chains | has($name)' >/dev/null 2>&1; then
    megabrain_error "edited chain not found: $name"
    return 1
  fi
  megabrain_chain_write "$edited" || return 1
  if [ "$json" = true ]; then
    printf '%s' "$edited" | jq -c --arg name "$name" '.chains[$name] + {name: $name, changed: true}'
  else
    printf 'chain edited: %s\n' "$name"
  fi
}

command_chain_delete() {
  local name="" json=false arg config names result
  case "${1:-}" in
    -h|--help) megabrain_usage_show chain-delete; return 0 ;;
  esac
  [ "$#" -gt 0 ] || { megabrain_usage_fail chain-delete; return "$MEGABRAIN_USAGE_ERROR"; }
  name="$1"
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      -h|--help) megabrain_usage_show chain-delete; return 0 ;;
      *) megabrain_error "unknown chain delete option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  config="$(megabrain_chain_read)" || return 1
  if ! printf '%s' "$config" | jq -e --arg name "$name" '.chains | has($name)' >/dev/null 2>&1; then
    names="$(printf '%s' "$config" | jq -r '.chains | keys | join(", ")')"
    megabrain_error "chain not found: $name; available chains: $names"
    return 1
  fi
  result="$(printf '%s' "$config" | jq --arg name "$name" 'del(.chains[$name])')"
  megabrain_chain_validate_config "$result" || return 1
  megabrain_chain_write "$result" || return 1
  if [ "$json" = true ]; then
    jq -n --arg name "$name" '{deleted: true, name: $name}'
  else
    printf 'chain deleted: %s\n' "$name"
  fi
}

command_chain_repair() {
  local name="${1:-}" step_number="" model="" effort="" json=false has_effort=false arg config result step agent
  case "$name" in
    -h|--help) megabrain_usage_show chain-repair; return 0 ;;
  esac
  [ -n "$name" ] || { megabrain_usage_fail chain-repair; return "$MEGABRAIN_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --step) step_number="${2:-}"; shift 2 ;;
      --model) model="${2:-}"; shift 2 ;;
      --effort) effort="${2:-}"; has_effort=true; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) megabrain_usage_show chain-repair; return 0 ;;
      *) megabrain_error "unknown chain repair option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  case "$step_number" in
    ''|*[!0-9]*|0) megabrain_error 'chain repair requires a positive --step number'; return "$MEGABRAIN_USAGE_ERROR" ;;
  esac
  [ -n "$model" ] || { megabrain_error '--model is required for chain repair'; return "$MEGABRAIN_USAGE_ERROR"; }
  config="$(megabrain_chain_read)" || return 1
  step="$(printf '%s' "$config" | jq -c --arg name "$name" --argjson index "$step_number" '.chains[$name].steps[$index - 1] // empty')"
  [ -n "$step" ] || { megabrain_error "chain step not found: $name step $step_number"; return 1; }
  agent="$(printf '%s' "$step" | jq -r '.agent')"
  megabrain_model_validate_step "$name" "$step_number" "$agent" "$model" "$effort" || return 1
  result="$(printf '%s' "$config" | jq --arg name "$name" --argjson index "$step_number" --arg model "$model" --arg effort "$effort" --argjson hasEffort "$has_effort" '.chains[$name].steps[$index - 1] |= (.model = $model | if $hasEffort then .effort = $effort else del(.effort) end | del(.unvalidated))')"
  megabrain_chain_validate_config "$result" || return 1
  megabrain_chain_write "$result" || return 1
  if [ "$json" = true ]; then
    printf '%s' "$result" | jq -c --arg name "$name" --argjson index "$step_number" '{repaired: true, chain: $name, step: $index, value: .chains[$name].steps[$index - 1]}'
  else
    printf 'chain repaired: %s step %s\n' "$name" "$step_number"
  fi
}

megabrain_chain_limits_update_providers() {
  local config="$1" action="$2" providers="$3" provider result
  result="$config"
  for provider in $(printf '%s' "$providers" | tr ',' ' '); do
    [ -n "$provider" ] || continue
    megabrain_chain_agent_known "$provider" || { megabrain_error "unknown provider: $provider"; return 1; }
    if [ "$action" = enable ]; then
      result="$(printf '%s' "$result" | jq --arg provider "$provider" '
        .usageLimits = ((.usageLimits // {}) + {liveProviders: ((.usageLimits.liveProviders // []) + [$provider] | unique), cacheTtlSeconds: (.usageLimits.cacheTtlSeconds // 30), timeoutSeconds: (.usageLimits.timeoutSeconds // 5), notice: (.usageLimits.notice // {enabled: false, intervalSeconds: 3600})})
      ')"
    else
      result="$(printf '%s' "$result" | jq --arg provider "$provider" '
        .usageLimits = ((.usageLimits // {}) + {liveProviders: ((.usageLimits.liveProviders // []) - [$provider]), cacheTtlSeconds: (.usageLimits.cacheTtlSeconds // 30), timeoutSeconds: (.usageLimits.timeoutSeconds // 5), notice: (.usageLimits.notice // {enabled: false, intervalSeconds: 3600})})
      ')"
    fi
  done
  printf '%s' "$result"
}

megabrain_chain_limits_print_rows() {
  local agent="$1" result="$2" source="$3" fetched_at="$4" reason="$5" requested_window="${6:-}" window used reset bucket
  if [ -n "$result" ]; then
    while IFS=$'\t' read -r window bucket used reset; do
      if [ "${MEGABRAIN_CHAIN_LIMIT_STATUS:-unknown}" = current ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t%s\n' "$agent" "$window" current "$used" "$reset" "$source" "$fetched_at" "$bucket"
      else
        printf '%s\t%s\tunknown\t\t\tunknown\t%s\t%s\t\n' "$agent" "$window" "$fetched_at" "$reason"
      fi
    done < <(printf '%s' "$result" | jq -r '.windows[]? | [.name, (.bucket // "default"), .usedPercent, .resetsAt] | @tsv')
  else
    if [ -n "$requested_window" ]; then
      printf '%s\t%s\tunknown\t\t\tunknown\t%s\t%s\t\n' "$agent" "$requested_window" "$fetched_at" "$reason"
    else
      for window in 5h weekly; do
        printf '%s\t%s\tunknown\t\t\tunknown\t%s\t%s\t\n' "$agent" "$window" "$fetched_at" "$reason"
      done
    fi
  fi
}

command_chain_limits() {
  local json=false enable="" disable="" notice_on=false notice_off=false notice_interval="" arg config result agent window rows line tmp_file first_reason
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true ;;
      --enable) enable="${2:-}"; shift 2 ;;
      --disable) disable="${2:-}"; shift 2 ;;
      --notice-on) notice_on=true ;;
      --notice-off) notice_off=true ;;
      --notice-interval) notice_interval="${2:-}"; shift 2 ;;
      -h|--help) megabrain_usage_show chain-limits; return 0 ;;
      *) megabrain_error "unknown chain limits option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
    [ "$arg" = --enable ] || [ "$arg" = --disable ] || [ "$arg" = --notice-interval ] || shift
  done
  config="$(megabrain_chain_read)" || return 1
  megabrain_chain_validate_config "$config" || return 1
  result="$config"
  if [ -n "$enable" ]; then
    result="$(megabrain_chain_limits_update_providers "$result" enable "$enable")" || return 1
  fi
  if [ -n "$disable" ]; then
    result="$(megabrain_chain_limits_update_providers "$result" disable "$disable")" || return 1
  fi
  if [ "$notice_on" = true ] || [ "$notice_off" = true ] || [ -n "$notice_interval" ]; then
    if [ "$notice_on" = true ] && [ "$notice_off" = true ]; then
      megabrain_error 'cannot enable and disable the usage notice together'
      return "$MEGABRAIN_USAGE_ERROR"
    fi
    result="$(printf '%s' "$result" | jq --argjson turnOn "$( [ "$notice_on" = true ] && printf true || printf false )" --argjson turnOff "$( [ "$notice_off" = true ] && printf true || printf false )" --arg interval "$notice_interval" '
      .usageLimits = ((.usageLimits // {}) + {liveProviders: (.usageLimits.liveProviders // []), cacheTtlSeconds: (.usageLimits.cacheTtlSeconds // 30), timeoutSeconds: (.usageLimits.timeoutSeconds // 5), notice: {enabled: (if $turnOn then true elif $turnOff then false else (.usageLimits.notice.enabled // false) end), intervalSeconds: (if $interval == "" then (.usageLimits.notice.intervalSeconds // 3600) else ($interval | tonumber) end)}})
    ')" || return 1
  fi
  if [ "$result" != "$config" ]; then
    megabrain_chain_validate_config "$result" || return 1
    megabrain_chain_write "$result" || return 1
    config="$result"
  fi
  tmp_file="$(mktemp "$MEGABRAIN_STATE_DIR/chain-limits.XXXXXX")" || return 1
  for agent in codex claude agy; do
    megabrain_chain_limit_read "$agent" 5h
    if [ -n "$MEGABRAIN_CHAIN_LIMIT_RESULT" ]; then
      megabrain_chain_limits_print_rows "$agent" "$MEGABRAIN_CHAIN_LIMIT_RESULT" "$MEGABRAIN_CHAIN_LIMIT_SOURCE" "$MEGABRAIN_CHAIN_LIMIT_FETCHED_AT" "$MEGABRAIN_CHAIN_LIMIT_REASON" >>"$tmp_file"
    else
      first_reason="$MEGABRAIN_CHAIN_LIMIT_REASON"
      megabrain_chain_limit_read "$agent" weekly
      megabrain_chain_limits_print_rows "$agent" '' unknown "$MEGABRAIN_CHAIN_LIMIT_FETCHED_AT" "$first_reason" 5h >>"$tmp_file"
      megabrain_chain_limits_print_rows "$agent" '' unknown "$MEGABRAIN_CHAIN_LIMIT_FETCHED_AT" "$MEGABRAIN_CHAIN_LIMIT_REASON" weekly >>"$tmp_file"
    fi
  done
  if [ "$json" = true ]; then
    jq -Rn '[inputs | split("\t") | {provider: .[0], window: .[1], status: .[2], usedPercent: (if .[3] == "" then null else (.[3] | tonumber) end), resetsAt: (if .[4] == "" then null else .[4] end), source: .[5], fetchedAt: (if .[6] == "" then null else (.[6] | tonumber) end), reason: (if .[7] == "" then null else .[7] end), bucket: (if .[8] == "" then null else .[8] end)}]' "$tmp_file"
  else
    printf '%-8s %-8s %-9s %-12s %-28s %-8s %s\n' PROVIDER WINDOW STATUS USED RESET SOURCE REASON
    while IFS=$'\t' read -r agent window line used reset result fetched_at reason; do
      printf '%-8s %-8s %-9s %-12s %-28s %-8s %s\n' "$agent" "$window" "$line" "${used:--}" "${reset:--}" "$result" "${reason:--}"
    done <"$tmp_file"
  fi
  rm -f "$tmp_file"
}

MEGABRAIN_CHAIN_LIMIT_STATUS="unknown"
MEGABRAIN_CHAIN_LIMIT_USED=""
MEGABRAIN_CHAIN_LIMIT_RESETS=""
MEGABRAIN_CHAIN_LIMIT_REASON=""
MEGABRAIN_CHAIN_LIMIT_SOURCE=""
MEGABRAIN_CHAIN_LIMIT_RESULT=""
MEGABRAIN_CHAIN_LIMIT_FETCHED_AT=""

megabrain_chain_limit_capability() {
  case "$1" in
    codex) printf 'disk\n' ;;
    claude|agy) printf 'provider\n' ;;
    *) printf 'unsupported\n' ;;
  esac
}

megabrain_chain_codex_rollouts() {
  local root="$HOME/.codex/sessions" path mtime
  [ -d "$root" ] || return 1
  while IFS= read -r path; do
    [ -f "$path" ] || continue
    mtime="$(stat -f '%m' "$path" 2>/dev/null || stat -c '%Y' "$path" 2>/dev/null || printf '0')"
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    printf '%s\t%s\n' "$mtime" "$path"
  done < <(find "$root" -type f -name 'rollout-*.jsonl' -print 2>/dev/null)
}

megabrain_chain_latest_codex_rollout() {
  megabrain_chain_codex_rollouts | LC_ALL=C sort -k1,1nr -k2,2r | cut -f2- | head -n 1
}

megabrain_chain_limit_unknown() {
  local agent="$1" window="$2" reason="$3"
  MEGABRAIN_CHAIN_LIMIT_STATUS=unknown
  MEGABRAIN_CHAIN_LIMIT_USED=""
  MEGABRAIN_CHAIN_LIMIT_RESETS=""
  MEGABRAIN_CHAIN_LIMIT_SOURCE=unknown
  MEGABRAIN_CHAIN_LIMIT_RESULT=""
  MEGABRAIN_CHAIN_LIMIT_FETCHED_AT=""
  MEGABRAIN_CHAIN_LIMIT_REASON="$agent $window window unknown ($reason)"
}

megabrain_chain_limit_config() {
  megabrain_chain_init || return 1
  cat "$MEGABRAIN_CHAIN_FILE"
}

megabrain_chain_live_enabled() {
  local agent="$1" config
  config="$(megabrain_chain_limit_config)" || return 1
  printf '%s' "$config" | jq -e --arg agent "$agent" '(.usageLimits.liveProviders // []) | index($agent) != null' >/dev/null 2>&1
}

megabrain_chain_limit_ttl() {
  local config value
  if [ -n "${MEGABRAIN_CHAIN_LIMIT_TTL_SECONDS:-}" ]; then
    printf '%s\n' "$MEGABRAIN_CHAIN_LIMIT_TTL_SECONDS"
    return 0
  fi
  config="$(megabrain_chain_limit_config)" || return 1
  value="$(printf '%s' "$config" | jq -r '.usageLimits.cacheTtlSeconds // 30')"
  printf '%s\n' "$value"
}

megabrain_chain_limit_timeout() {
  local config value
  if [ -n "${MEGABRAIN_CHAIN_LIMIT_TIMEOUT_SECONDS:-}" ]; then
    printf '%s\n' "$MEGABRAIN_CHAIN_LIMIT_TIMEOUT_SECONDS"
    return 0
  fi
  config="$(megabrain_chain_limit_config)" || return 1
  value="$(printf '%s' "$config" | jq -r '.usageLimits.timeoutSeconds // 5')"
  printf '%s\n' "$value"
}

megabrain_chain_limit_cache_path() {
  printf '%s/usage-limits-%s.json\n' "$MEGABRAIN_STATE_DIR" "$1"
}

megabrain_chain_limit_cache_read() {
  local agent="$1" window="$2" path now fetched_at ttl cached
  path="$(megabrain_chain_limit_cache_path "$agent")"
  [ -f "$path" ] || return 1
  cached="$(cat "$path" 2>/dev/null || true)"
  printf '%s' "$cached" | jq -e --arg provider "$agent" '.provider == $provider and (.fetchedAt | type == "number") and (.windows | type == "array")' >/dev/null 2>&1 || return 1
  fetched_at="$(printf '%s' "$cached" | jq -r '.fetchedAt')"
  now="$(date +%s)"
  ttl="$(megabrain_chain_limit_ttl)"
  case "$fetched_at:$ttl" in
    ''|*[!0-9:]*) return 1 ;;
  esac
  [ "$fetched_at" -le "$now" ] && [ $((now - fetched_at)) -lt "$ttl" ] || return 1
  megabrain_chain_limit_apply "$cached" "$agent" "$window" cache
  [ "$MEGABRAIN_CHAIN_LIMIT_STATUS" = current ]
}

megabrain_chain_limit_cache_write() {
  local agent="$1" result="$2" path tmp
  mkdir -p "$MEGABRAIN_STATE_DIR" || return 1
  path="$(megabrain_chain_limit_cache_path "$agent")"
  tmp="$(mktemp "$MEGABRAIN_STATE_DIR/usage-limits.XXXXXX")" || return 1
  if ! printf '%s' "$result" | jq -e --arg provider "$agent" '.provider == $provider and (.fetchedAt | type == "number") and (.windows | type == "array")' >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  if ! printf '%s' "$result" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path"
}

megabrain_chain_usage_notice_config() {
  local config
  config="$(megabrain_chain_limit_config)" || return 1
  printf '%s' "$config" | jq -c '.usageLimits.notice // {enabled: false, intervalSeconds: 3600}'
}

megabrain_chain_usage_notice_report() {
  local agent result summary report="Usage limits:"
  for agent in codex claude agy; do
    megabrain_chain_limit_read "$agent" 5h
    result="$MEGABRAIN_CHAIN_LIMIT_RESULT"
    if [ -n "$result" ]; then
      summary="$(printf '%s' "$result" | jq -r '[.windows[] | ((.bucket // "default") + " " + .name + " " + (.usedPercent | tostring) + "% used, resets " + .resetsAt)] | join("; ")')"
    else
      summary="unknown (${MEGABRAIN_CHAIN_LIMIT_REASON#* window unknown (}"
      summary="${summary%)}"
    fi
    report="$report $agent $summary;"
  done
  printf '%s\n' "$report"
}

megabrain_chain_usage_notice_state_path() {
  printf '%s/usage-limit-notice.json\n' "$MEGABRAIN_STATE_DIR"
}

megabrain_chain_usage_notice_due() {
  local notice="$1" path now sent_at interval
  printf '%s' "$notice" | jq -e '.enabled == true' >/dev/null 2>&1 || return 1
  interval="$(printf '%s' "$notice" | jq -r '.intervalSeconds // 3600')"
  path="$(megabrain_chain_usage_notice_state_path)"
  sent_at=0
  if [ -f "$path" ]; then
    sent_at="$(jq -r '.sentAt // 0' "$path" 2>/dev/null || printf '0')"
  fi
  now="$(date +%s)"
  case "$sent_at:$interval" in
    ''|*[!0-9:]*) return 1 ;;
  esac
  [ "$sent_at" -gt "$now" ] || [ $((now - sent_at)) -ge "$interval" ]
}

megabrain_chain_usage_notice_mark() {
  local path tmp now
  mkdir -p "$MEGABRAIN_STATE_DIR" || return 1
  path="$(megabrain_chain_usage_notice_state_path)"
  tmp="$(mktemp "$MEGABRAIN_STATE_DIR/usage-limit-notice.XXXXXX")" || return 1
  now="$(date +%s)"
  jq -n --argjson sentAt "$now" '{sentAt: $sentAt}' >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

megabrain_chain_usage_notice_maybe() {
  local dispatch_id="$1" notice meta report
  notice="$(megabrain_chain_usage_notice_config)" || return 0
  megabrain_chain_usage_notice_due "$notice" || return 0
  report="$(megabrain_chain_usage_notice_report)" || return 0
  meta="$(megabrain_dispatch_meta_read "$dispatch_id" 2>/dev/null || true)"
  [ -n "$meta" ] || return 0
  megabrain_dispatch_message_append "$dispatch_id" devkit usage "$report" "${MEGABRAIN_SESSION_ID:-devkit}" >/dev/null 2>&1 || return 0
  megabrain_parent_notify_dispatch "$meta" >/dev/null 2>&1 || true
  megabrain_chain_usage_notice_mark >/dev/null 2>&1 || true
}

megabrain_chain_limit_apply() {
  local result="$1" agent="$2" window="$3" source="$4" entry
  entry="$(printf '%s' "$result" | jq -c --arg window "$window" '
    [.windows[]? | select(.name == $window)] | first // empty
  ' 2>/dev/null)"
  MEGABRAIN_CHAIN_LIMIT_RESULT="$result"
  MEGABRAIN_CHAIN_LIMIT_FETCHED_AT="$(printf '%s' "$result" | jq -r '.fetchedAt // empty' 2>/dev/null)"
  MEGABRAIN_CHAIN_LIMIT_SOURCE="$source"
  if [ -z "$entry" ] || ! printf '%s' "$entry" | jq -e '
    (.usedPercent | type == "number") and
    (.remainingPercent | type == "number") and
    (.resetsAt | type == "string") and (.resetsAt | length > 0)
  ' >/dev/null 2>&1; then
    megabrain_chain_limit_unknown "$agent" "$window" 'provider response has no usable window'
    MEGABRAIN_CHAIN_LIMIT_RESULT="$result"
    MEGABRAIN_CHAIN_LIMIT_FETCHED_AT="$(printf '%s' "$result" | jq -r '.fetchedAt // empty' 2>/dev/null)"
    return 0
  fi
  MEGABRAIN_CHAIN_LIMIT_USED="$(printf '%s' "$entry" | jq -r '.usedPercent')"
  MEGABRAIN_CHAIN_LIMIT_RESETS="$(printf '%s' "$entry" | jq -r '.resetsAt')"
  MEGABRAIN_CHAIN_LIMIT_STATUS=current
  MEGABRAIN_CHAIN_LIMIT_REASON="$agent $window window at $MEGABRAIN_CHAIN_LIMIT_USED percent"
}

megabrain_chain_limit_result_codex() {
  local snapshot="$1" fetched_at="$2"
  jq -cn --argjson snapshot "$snapshot" --argjson fetchedAt "$fetched_at" '
    {provider: "codex", fetchedAt: $fetchedAt, windows: [
      {name: "5h", bucket: "default", usedPercent: $snapshot.primary.used_percent,
       remainingPercent: (100 - $snapshot.primary.used_percent),
       resetsAt: ($snapshot.primary.resets_at | tostring)},
      {name: "weekly", bucket: "default", usedPercent: $snapshot.secondary.used_percent,
       remainingPercent: (100 - $snapshot.secondary.used_percent),
       resetsAt: ($snapshot.secondary.resets_at | tostring)}
    ]}
  '
}

megabrain_chain_claude_credentials() {
  local credentials
  credentials="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null)" || return 1
  MEGABRAIN_CHAIN_CLAUDE_TOKEN="$(printf '%s' "$credentials" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
  MEGABRAIN_CHAIN_CLAUDE_EXPIRES="$(printf '%s' "$credentials" | jq -r '.claudeAiOauth.expiresAt // empty' 2>/dev/null)"
  unset credentials
  [ -n "$MEGABRAIN_CHAIN_CLAUDE_TOKEN" ] || return 2
  return 0
}

megabrain_chain_claude_usage() {
  local requested_window="$1" response http_status curl_rc=0 url result now expires credential_rc timeout
  MEGABRAIN_CHAIN_CLAUDE_TOKEN=""
  MEGABRAIN_CHAIN_CLAUDE_EXPIRES=""
  if megabrain_chain_claude_credentials; then
    credential_rc=0
  else
    credential_rc=$?
  fi
  if [ "$credential_rc" -ne 0 ]; then
    case "$credential_rc" in
      1) megabrain_chain_limit_unknown claude "$requested_window" 'Keychain item is missing' ;;
      *) megabrain_chain_limit_unknown claude "$requested_window" 'Keychain credential has no access token' ;;
    esac
    return 0
  fi
  now="$(date +%s)"
  expires="$MEGABRAIN_CHAIN_CLAUDE_EXPIRES"
  if [ -n "$expires" ]; then
    case "$expires" in
      *[!0-9]*)
        megabrain_chain_limit_unknown claude "$requested_window" 'credential expiry is malformed'
        unset MEGABRAIN_CHAIN_CLAUDE_TOKEN MEGABRAIN_CHAIN_CLAUDE_EXPIRES
        return 0
        ;;
      *) [ "$expires" -gt 100000000000 ] && expires=$((expires / 1000)) ;;
    esac
    if [ "$expires" -le "$now" ]; then
      megabrain_chain_limit_unknown claude "$requested_window" "credential is expired at $expires; refreshing requires a separate OAuth flow"
      unset MEGABRAIN_CHAIN_CLAUDE_TOKEN MEGABRAIN_CHAIN_CLAUDE_EXPIRES
      return 0
    fi
  fi
  timeout="$(megabrain_chain_limit_timeout)" || timeout=5
  url="${MEGABRAIN_CHAIN_CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
  response="$(curl -sS --connect-timeout "$timeout" --max-time "$timeout" \
    -H "Authorization: Bearer $MEGABRAIN_CHAIN_CLAUDE_TOKEN" \
    -H 'anthropic-beta: oauth-2025-04-20' -H 'anthropic-version: 2023-06-01' \
    -w '\nMEGABRAIN_HTTP_STATUS:%{http_code}' "$url" 2>/dev/null)" || curl_rc=$?
  unset MEGABRAIN_CHAIN_CLAUDE_TOKEN MEGABRAIN_CHAIN_CLAUDE_EXPIRES
  http_status="${response##*MEGABRAIN_HTTP_STATUS:}"
  response="${response%$'\n'MEGABRAIN_HTTP_STATUS:*}"
  if [ "$curl_rc" -eq 28 ]; then
    megabrain_chain_limit_unknown claude "$requested_window" 'request timed out'
    return 0
  fi
  if [ "$curl_rc" -ne 0 ] || [ "$http_status" = 000 ]; then
    megabrain_chain_limit_unknown claude "$requested_window" 'network request failed'
    return 0
  fi
  if [ "$http_status" -lt 200 ] || [ "$http_status" -ge 300 ]; then
    megabrain_chain_limit_unknown claude "$requested_window" "provider returned HTTP $http_status"
    return 0
  fi
  now="$(date +%s)"
  result="$(printf '%s' "$response" | jq -c --argjson fetchedAt "$now" '
    [(.five_hour // empty), (.seven_day // empty)] |
    to_entries |
    map(select((.value | type) == "object") |
      select((.value.utilization | type) == "number") |
      select((.value.resets_at | type) == "string" and (.value.resets_at | length) > 0) |
      {name: (if .key == 0 then "5h" else "weekly" end), bucket: "default",
       usedPercent: .value.utilization,
       remainingPercent: (100 - .value.utilization), resetsAt: .value.resets_at}) |
    {provider: "claude", fetchedAt: $fetchedAt, windows: .}
  ' 2>/dev/null)" || result=""
  if [ -z "$result" ] || ! printf '%s' "$result" | jq -e '.windows | length > 0' >/dev/null 2>&1; then
    megabrain_chain_limit_unknown claude "$requested_window" 'response body is unparseable or incomplete'
    return 0
  fi
  MEGABRAIN_CHAIN_LIMIT_RESULT="$result"
  MEGABRAIN_CHAIN_LIMIT_FETCHED_AT="$now"
}

megabrain_chain_agy_credentials() {
  local credentials encoded
  credentials="$(security find-generic-password -s gemini -w 2>/dev/null)" || return 1
  case "$credentials" in
    go-keyring-base64:*) encoded="${credentials#go-keyring-base64:}" ;;
    *) unset credentials; return 2 ;;
  esac
  credentials="$(printf '%s' "$encoded" | base64 -D 2>/dev/null)" || { unset encoded; return 2; }
  MEGABRAIN_CHAIN_AGY_TOKEN="$(printf '%s' "$credentials" | jq -r '.token // empty' 2>/dev/null)"
  unset credentials encoded
  [ -n "$MEGABRAIN_CHAIN_AGY_TOKEN" ] || return 3
  return 0
}

megabrain_chain_agy_usage() {
  local requested_window="$1" response http_status curl_rc=0 url result now credential_rc timeout
  MEGABRAIN_CHAIN_AGY_TOKEN=""
  if megabrain_chain_agy_credentials; then
    credential_rc=0
  else
    credential_rc=$?
  fi
  if [ "$credential_rc" -ne 0 ]; then
    case "$credential_rc" in
      1) megabrain_chain_limit_unknown agy "$requested_window" 'Keychain item is missing' ;;
      2) megabrain_chain_limit_unknown agy "$requested_window" 'Keychain credential wrapper is unsupported' ;;
      *) megabrain_chain_limit_unknown agy "$requested_window" 'Keychain credential has no token' ;;
    esac
    return 0
  fi
  timeout="$(megabrain_chain_limit_timeout)" || timeout=5
  url="${MEGABRAIN_CHAIN_AGY_USAGE_URL:-https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary}"
  # WHY: this is an undocumented client endpoint and its response contract can change.
  response="$(curl -sS --connect-timeout "$timeout" --max-time "$timeout" \
    -X POST -H "Authorization: Bearer $MEGABRAIN_CHAIN_AGY_TOKEN" -H 'Content-Type: application/json' \
    -d '{}' -w '\nMEGABRAIN_HTTP_STATUS:%{http_code}' "$url" 2>/dev/null)" || curl_rc=$?
  unset MEGABRAIN_CHAIN_AGY_TOKEN
  http_status="${response##*MEGABRAIN_HTTP_STATUS:}"
  response="${response%$'\n'MEGABRAIN_HTTP_STATUS:*}"
  if [ "$curl_rc" -eq 28 ]; then
    megabrain_chain_limit_unknown agy "$requested_window" 'request timed out'
    return 0
  fi
  if [ "$curl_rc" -ne 0 ] || [ "$http_status" = 000 ]; then
    megabrain_chain_limit_unknown agy "$requested_window" 'network request failed'
    return 0
  fi
  if [ "$http_status" -lt 200 ] || [ "$http_status" -ge 300 ]; then
    megabrain_chain_limit_unknown agy "$requested_window" "provider returned HTTP $http_status"
    return 0
  fi
  now="$(date +%s)"
  result="$(printf '%s' "$response" | jq -c --argjson fetchedAt "$now" '
    def reset_at:
      (.reset_at // .resets_at // .reset_time // .resetTime // empty) as $reset |
      if ($reset | type) == "string" then $reset
      elif ($reset | type) == "object" and ($reset.seconds? | type) == "number" then ($reset.seconds | todateiso8601)
      else empty end;
    def quota_entries($bucket):
      to_entries |
      map(select((.value.remaining_fraction | type) == "number") |
        select((.value | reset_at) != "") |
        {name: (if (.key | endswith("-5h")) then "5h" elif (.key | endswith("-weekly")) then "weekly" else empty end),
         bucket: $bucket,
         usedPercent: ((100 - (.value.remaining_fraction * 100)) | if . < 0 then 0 elif . > 100 then 100 else . end),
         remainingPercent: ((.value.remaining_fraction * 100) | if . < 0 then 0 elif . > 100 then 100 else . end),
         resetsAt: (.value | reset_at)}) |
      map(select(.name != null));
    ((.quota // {}) | if type == "object" then quota_entries("default") else [] end) as $legacy |
    (if (.buckets? | type) == "array" then
       [.buckets[] | . as $group | (($group.quota // $group) | if type == "object" then quota_entries($group.displayName // $group.name // "unknown") else [] end)] | add
     else [] end) as $groups |
    {provider: "agy", fetchedAt: $fetchedAt, windows: ($legacy + $groups)}
  ' 2>/dev/null)" || result=""
  if [ -z "$result" ] || ! printf '%s' "$result" | jq -e '.windows | length > 0' >/dev/null 2>&1; then
    megabrain_chain_limit_unknown agy "$requested_window" 'response body is unparseable or incomplete'
    return 0
  fi
  MEGABRAIN_CHAIN_LIMIT_RESULT="$result"
  MEGABRAIN_CHAIN_LIMIT_FETCHED_AT="$now"
}

megabrain_chain_limit_read() {
  local agent="$1" window="$2" rollout snapshot field expected_minutes now fetched_at result
  MEGABRAIN_CHAIN_LIMIT_STATUS=unknown
  MEGABRAIN_CHAIN_LIMIT_USED=""
  MEGABRAIN_CHAIN_LIMIT_RESETS=""
  MEGABRAIN_CHAIN_LIMIT_REASON=""
  MEGABRAIN_CHAIN_LIMIT_SOURCE=""
  MEGABRAIN_CHAIN_LIMIT_RESULT=""
  MEGABRAIN_CHAIN_LIMIT_FETCHED_AT=""
  case "$agent" in
    claude|agy)
      if ! megabrain_chain_live_enabled "$agent"; then
        megabrain_chain_limit_unknown "$agent" "$window" 'live provider is not enabled'
        return 0
      fi
      if megabrain_chain_limit_cache_read "$agent" "$window"; then
        return 0
      fi
      if [ "$agent" = claude ]; then
        megabrain_chain_claude_usage "$window"
        if [ -n "$MEGABRAIN_CHAIN_LIMIT_RESULT" ]; then
          megabrain_chain_limit_apply "$MEGABRAIN_CHAIN_LIMIT_RESULT" claude "$window" live
          [ "$MEGABRAIN_CHAIN_LIMIT_STATUS" = current ] && megabrain_chain_limit_cache_write claude "$MEGABRAIN_CHAIN_LIMIT_RESULT" >/dev/null 2>&1 || true
        else
          [ -n "$MEGABRAIN_CHAIN_LIMIT_REASON" ] || megabrain_chain_limit_unknown claude "$window" 'provider reader returned no result'
        fi
      else
        megabrain_chain_agy_usage "$window"
        if [ -n "$MEGABRAIN_CHAIN_LIMIT_RESULT" ]; then
          megabrain_chain_limit_apply "$MEGABRAIN_CHAIN_LIMIT_RESULT" agy "$window" live
          [ "$MEGABRAIN_CHAIN_LIMIT_STATUS" = current ] && megabrain_chain_limit_cache_write agy "$MEGABRAIN_CHAIN_LIMIT_RESULT" >/dev/null 2>&1 || true
        else
          [ -n "$MEGABRAIN_CHAIN_LIMIT_REASON" ] || megabrain_chain_limit_unknown agy "$window" 'provider reader returned no result'
        fi
      fi
      return 0
      ;;
    codex) ;;
    *)
      MEGABRAIN_CHAIN_LIMIT_REASON="$agent $window window unknown (unsupported provider)"
      return 0
      ;;
  esac
  case "$window" in
    5h) field=primary; expected_minutes=300 ;;
    weekly) field=secondary; expected_minutes=10080 ;;
    *)
      MEGABRAIN_CHAIN_LIMIT_REASON="codex $window window unknown (unsupported window)"
      return 0
      ;;
  esac
  while IFS= read -r rollout; do
    snapshot="$(jq -c --arg field "$field" --argjson minutes "$expected_minutes" '
      (.payload.rate_limits? // .rate_limits?) as $limits |
      select(($limits | type) == "object") |
      select(($limits[$field] | type) == "object") |
      select($limits[$field].window_minutes == $minutes) |
      select(($limits[$field].used_percent | type) == "number") |
      select(($limits[$field].resets_at | type) == "number") |
      $limits
    ' "$rollout" 2>/dev/null | tail -n 1)"
    if [ -n "$snapshot" ]; then
      break
    fi
    rollout=""
  done < <(megabrain_chain_codex_rollouts 2>/dev/null | LC_ALL=C sort -k1,1nr -k2,2r | cut -f2- || true)
  if [ -z "$snapshot" ]; then
    megabrain_chain_limit_unknown codex "$window" 'rollout has no rate limit snapshot'
    return 0
  fi
  MEGABRAIN_CHAIN_LIMIT_USED="$(printf '%s' "$snapshot" | jq -r --arg field "$field" '.[$field].used_percent // empty')"
  MEGABRAIN_CHAIN_LIMIT_RESETS="$(printf '%s' "$snapshot" | jq -r --arg field "$field" '.[$field].resets_at // empty')"
  if [ -z "$MEGABRAIN_CHAIN_LIMIT_USED" ] || [ -z "$MEGABRAIN_CHAIN_LIMIT_RESETS" ]; then
    megabrain_chain_limit_unknown codex "$window" 'snapshot is incomplete'
    return 0
  fi
  now="$(date +%s)"
  # WHY: current Codex snapshots nest rate_limits under payload.
  if [ "$MEGABRAIN_CHAIN_LIMIT_RESETS" -le "$now" ]; then
    megabrain_chain_limit_unknown codex "$window" "snapshot stale; reset $MEGABRAIN_CHAIN_LIMIT_RESETS"
    return 0
  fi
  fetched_at="$(stat -f '%m' "$rollout" 2>/dev/null || stat -c '%Y' "$rollout" 2>/dev/null || printf '%s' "$now")"
  case "$fetched_at" in
    ''|*[!0-9]*) fetched_at="$now" ;;
  esac
  result="$(megabrain_chain_limit_result_codex "$snapshot" "$fetched_at")"
  MEGABRAIN_CHAIN_LIMIT_RESULT="$result"
  MEGABRAIN_CHAIN_LIMIT_FETCHED_AT="$fetched_at"
  MEGABRAIN_CHAIN_LIMIT_STATUS=current
  MEGABRAIN_CHAIN_LIMIT_SOURCE=disk
  MEGABRAIN_CHAIN_LIMIT_REASON="codex $window window at $MEGABRAIN_CHAIN_LIMIT_USED percent"
}

MEGABRAIN_CHAIN_SELECTED_NAME=""
MEGABRAIN_CHAIN_SELECTED_STEPS="[]"
MEGABRAIN_CHAIN_SELECTION_REASON=""
MEGABRAIN_CHAIN_SELECTION_DEFAULT=false

megabrain_chain_select() {
  local config="$1" explicit_name="${2:-}" parent_agent="${3:-}" parent_model="${4:-}" parent_effort="${5:-}"
  local chain selector field required actual matched specificity best_specificity=-1 candidates='' count=0
  MEGABRAIN_CHAIN_SELECTED_NAME=""
  MEGABRAIN_CHAIN_SELECTED_STEPS='[]'
  MEGABRAIN_CHAIN_SELECTION_REASON=""
  MEGABRAIN_CHAIN_SELECTION_DEFAULT=false
  if [ -n "$explicit_name" ]; then
    if ! printf '%s' "$config" | jq -e --arg name "$explicit_name" '.chains | has($name)' >/dev/null 2>&1; then
      megabrain_error "chain not found: $explicit_name"
      return 1
    fi
    MEGABRAIN_CHAIN_SELECTED_NAME="$explicit_name"
    MEGABRAIN_CHAIN_SELECTED_STEPS="$(printf '%s' "$config" | jq -c --arg name "$explicit_name" '.chains[$name].steps')"
    MEGABRAIN_CHAIN_SELECTION_REASON="explicit name given"
    return 0
  fi
  while IFS= read -r chain; do
    selector="$(printf '%s' "$config" | jq -c --arg chain "$chain" '.chains[$chain].when')"
    matched=true
    specificity=0
    for field in parentAgent parentModel parentEffort; do
      required="$(printf '%s' "$selector" | jq -r --arg field "$field" '.[$field] // empty')"
      [ -n "$required" ] || continue
      specificity=$((specificity + 1))
      case "$field" in
        parentAgent) actual="$parent_agent" ;;
        parentModel) actual="$parent_model" ;;
        parentEffort) actual="$parent_effort" ;;
      esac
      if [ -z "$actual" ] || [ "$actual" != "$required" ]; then
        matched=false
      fi
    done
    [ "$matched" = true ] || continue
    if [ "$specificity" -gt "$best_specificity" ]; then
      best_specificity="$specificity"
      candidates="$chain"
      count=1
    elif [ "$specificity" -eq "$best_specificity" ]; then
      candidates="$candidates, $chain"
      count=$((count + 1))
    fi
  done < <(printf '%s' "$config" | jq -r '.chains | keys[]')
  if [ "$count" -gt 1 ]; then
    megabrain_error "chain selection is ambiguous: candidates: $candidates"
    return 1
  fi
  if [ "$count" -eq 1 ]; then
    MEGABRAIN_CHAIN_SELECTED_NAME="$candidates"
    MEGABRAIN_CHAIN_SELECTED_STEPS="$(printf '%s' "$config" | jq -c --arg name "$candidates" '.chains[$name].steps')"
    MEGABRAIN_CHAIN_SELECTION_REASON="selector match with $best_specificity field(s)"
    return 0
  fi
  MEGABRAIN_CHAIN_SELECTION_DEFAULT=true
  MEGABRAIN_CHAIN_SELECTION_REASON="no selector matched; using defaultSteps"
  MEGABRAIN_CHAIN_SELECTED_STEPS="$(printf '%s' "$config" | jq -c '.defaultSteps')"
}

megabrain_chain_run_spawn() {
  local worktree="$1" repo="$2" branch="$3" base="$4" slug="$5" prompt="$6" label="$7" tmux_choice="$8" model="$9" effort="${10}" agent="${11}"
  local -a agent_args=() spawn_args=() arg
  shift 11
  [ "$#" -eq 0 ] || agent_args=("$@")
  if [ -n "$worktree" ]; then
    spawn_args+=(--worktree "$worktree")
  else
    spawn_args+=(--repo "$repo" --branch "$branch")
    [ -n "$base" ] && spawn_args+=(--base "$base")
    [ -n "$slug" ] && spawn_args+=(--name "$slug")
  fi
  spawn_args+=(--agent "$agent" --model "$model")
  [ -n "$effort" ] && spawn_args+=(--effort "$effort")
  spawn_args+=(--prompt "$prompt" --json)
  [ -n "$label" ] && spawn_args+=(--label "$label")
  [ -n "$tmux_choice" ] && spawn_args+=(--tmux "$tmux_choice")
  if [ "${#agent_args[@]}" -gt 0 ]; then
    for arg in "${agent_args[@]}"; do
      spawn_args+=(--agent-arg "$arg")
    done
  fi
  command_orchestrate spawn "${spawn_args[@]}"
}

megabrain_chain_reset_display() {
  local reset_at="$1"
  date -u -r "$reset_at" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$reset_at"
}

megabrain_chain_clear_dispatch_context() {
  MEGABRAIN_CHAIN_NAME=""
  MEGABRAIN_CHAIN_STEP=""
  MEGABRAIN_CHAIN_TOTAL=""
  MEGABRAIN_CHAIN_REASON=""
  MEGABRAIN_CHAIN_DEFAULT=false
}

command_chain_run() {
  local explicit_name="" parent_agent="${SUPERSET_AGENT_ID:-}" parent_model="${SUPERSET_AGENT_MODEL:-}" parent_effort="${SUPERSET_AGENT_EFFORT:-}"
  local repo="" branch="" base="" slug="" worktree="" prompt="" label="" tmux_choice="" json=false arg config step_count index step agent model effort until_json threshold window
  local spawn_output spawn_json spawn_error error_file reason limit_reason reset_text failure_reason final_reason report_chain reasons_json spawn_succeeded dispatch_id
  local -a agent_args=()
  if [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; then
    explicit_name="$1"
    shift
  fi
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --parent-agent) parent_agent="${2:-}"; shift 2 ;;
      --parent-model) parent_model="${2:-}"; shift 2 ;;
      --parent-effort) parent_effort="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --branch) branch="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --name) slug="${2:-}"; shift 2 ;;
      --worktree) worktree="${2:-}"; shift 2 ;;
      --prompt) prompt="${2:-}"; shift 2 ;;
      --label) label="${2:-}"; shift 2 ;;
      --tmux) tmux_choice="${2:-}"; shift 2 ;;
      --agent-arg)
        [ "$#" -ge 2 ] && [ -n "${2:-}" ] || { megabrain_error '--agent-arg requires a non-empty value'; return "$MEGABRAIN_USAGE_ERROR"; }
        agent_args+=("$2")
        shift 2
        ;;
      --json) json=true; shift ;;
      -h|--help) megabrain_usage_show chain-run; return 0 ;;
      *) megabrain_error "unknown chain run option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  [ -n "$prompt" ] || { megabrain_error '--prompt is required for chain run'; return "$MEGABRAIN_USAGE_ERROR"; }
  if [ -z "$worktree" ]; then
    [ -n "$repo" ] || { megabrain_error '--repo is required for chain run unless --worktree is used'; return "$MEGABRAIN_USAGE_ERROR"; }
    [ -n "$branch" ] || { megabrain_error '--branch is required for chain run unless --worktree is used'; return "$MEGABRAIN_USAGE_ERROR"; }
  fi
  config="$(megabrain_chain_read)" || return 1
  megabrain_chain_validate_config "$config" || return 1
  megabrain_chain_select "$config" "$explicit_name" "$parent_agent" "$parent_model" "$parent_effort" || return 1
  step_count="$(printf '%s' "$MEGABRAIN_CHAIN_SELECTED_STEPS" | jq 'length')"
  report_chain="$MEGABRAIN_CHAIN_SELECTED_NAME"
  [ "$MEGABRAIN_CHAIN_SELECTION_DEFAULT" = true ] && report_chain=defaultSteps
  reasons_json='[]'
  error_file="$(mktemp "$MEGABRAIN_STATE_DIR/chain-run.XXXXXX")" || return 1
  index=0
  while IFS= read -r step; do
    index=$((index + 1))
    agent="$(printf '%s' "$step" | jq -r '.agent')"
    model="$(printf '%s' "$step" | jq -r '.model')"
    effort="$(printf '%s' "$step" | jq -r '.effort // empty')"
    until_json="$(printf '%s' "$step" | jq -c '.until // empty')"
    limit_reason=""
    MEGABRAIN_CHAIN_LIMIT_RESETS=""
    if [ -n "$until_json" ]; then
      threshold="$(printf '%s' "$until_json" | jq -r '.usedPercent')"
      window="$(printf '%s' "$until_json" | jq -r '.window')"
      megabrain_chain_limit_read "$agent" "$window"
      limit_reason="$MEGABRAIN_CHAIN_LIMIT_REASON"
      if [ "$MEGABRAIN_CHAIN_LIMIT_STATUS" = current ] && awk -v used="$MEGABRAIN_CHAIN_LIMIT_USED" -v threshold="$threshold" 'BEGIN { exit !(used >= threshold) }'; then
        reset_text=""
        [ -n "$MEGABRAIN_CHAIN_LIMIT_RESETS" ] && reset_text="; resets at $(megabrain_chain_reset_display "$MEGABRAIN_CHAIN_LIMIT_RESETS")"
        reason="$MEGABRAIN_CHAIN_LIMIT_REASON$reset_text"
        reasons_json="$(printf '%s' "$reasons_json" | jq --argjson step "$index" --arg agent "$agent" --arg reason "$reason" '. + [{step: $step, agent: $agent, kind: "limit", reason: $reason}]')"
        continue
      fi
    fi
    final_reason="$(printf '%s' "$reasons_json" | jq -r '[.[].reason] | join("; ")')"
    [ -n "$final_reason" ] || final_reason="no earlier steps skipped"
    if [ "$MEGABRAIN_CHAIN_SELECTION_DEFAULT" = true ]; then
      final_reason="used defaultSteps; $final_reason"
    else
      final_reason="$final_reason; $MEGABRAIN_CHAIN_SELECTION_REASON"
    fi
    [ -n "$limit_reason" ] && [ "$MEGABRAIN_CHAIN_LIMIT_STATUS" = unknown ] && final_reason="$final_reason; $limit_reason"
    MEGABRAIN_CHAIN_NAME="$report_chain"
    MEGABRAIN_CHAIN_STEP="$index"
    MEGABRAIN_CHAIN_TOTAL="$step_count"
    MEGABRAIN_CHAIN_REASON="$final_reason"
    MEGABRAIN_CHAIN_DEFAULT="$MEGABRAIN_CHAIN_SELECTION_DEFAULT"
    spawn_succeeded=false
    if [ "${#agent_args[@]}" -gt 0 ]; then
      if spawn_output="$(megabrain_chain_run_spawn "$worktree" "$repo" "$branch" "$base" "$slug" "$prompt" "$label" "$tmux_choice" "$model" "$effort" "$agent" "${agent_args[@]}" 2>"$error_file")"; then
        spawn_succeeded=true
      fi
    else
      if spawn_output="$(megabrain_chain_run_spawn "$worktree" "$repo" "$branch" "$base" "$slug" "$prompt" "$label" "$tmux_choice" "$model" "$effort" "$agent" 2>"$error_file")"; then
        spawn_succeeded=true
      fi
    fi
    if [ "$spawn_succeeded" = true ]; then
      cat "$error_file" >&2
      if printf '%s' "$spawn_output" | jq -e . >/dev/null 2>&1; then
        spawn_json="$spawn_output"
      else
        spawn_json=null
      fi
      dispatch_id="$(printf '%s' "$spawn_json" | jq -r '.dispatch // empty' 2>/dev/null)"
      if [ -n "$dispatch_id" ]; then
        megabrain_chain_usage_notice_maybe "$dispatch_id"
      fi
      if [ "$json" = true ]; then
        jq -cn --arg chain "$report_chain" --argjson step "$index" --argjson total "$step_count" --arg reason "$final_reason" --argjson skipped "$reasons_json" --arg agent "$agent" --argjson spawn "$spawn_json" '{ok: true, chain: $chain, step: $step, totalSteps: $total, agent: $agent, reason: $reason, skipped: $skipped, dispatch: $spawn}'
      else
        printf 'chain %s, step %s of %s, reason: %s\n' "$report_chain" "$index" "$step_count" "$final_reason"
        printf '%s\n' "$spawn_output"
      fi
      rm -f "$error_file"
      megabrain_chain_clear_dispatch_context
      return 0
    fi
    spawn_error="$(cat "$error_file")"
    [ -n "$spawn_error" ] || spawn_error="launch failed"
    failure_reason="$agent launch failed: $spawn_error"
    [ -n "$limit_reason" ] && [ "$MEGABRAIN_CHAIN_LIMIT_STATUS" = unknown ] && failure_reason="$failure_reason; $limit_reason"
    reasons_json="$(printf '%s' "$reasons_json" | jq --argjson step "$index" --arg agent "$agent" --arg reason "$failure_reason" '. + [{step: $step, agent: $agent, kind: "failure", reason: $reason}]')"
  done < <(printf '%s' "$MEGABRAIN_CHAIN_SELECTED_STEPS" | jq -c '.[]')
  rm -f "$error_file"
  megabrain_chain_clear_dispatch_context
  final_reason="$(printf '%s' "$reasons_json" | jq -r '[.[].reason] | join("; ")')"
  [ -n "$final_reason" ] || final_reason="chain has no usable steps"
  if [ "$json" = true ]; then
    jq -cn --arg chain "$report_chain" --argjson total "$step_count" --arg reason "$final_reason" --argjson skipped "$reasons_json" '{ok: false, chain: $chain, totalSteps: $total, reason: $reason, skipped: $skipped}'
  else
    printf 'chain %s failed after %s steps, reason: %s\n' "$report_chain" "$step_count" "$final_reason"
  fi
  return 1
}

command_chain() {
  local subcommand="${1:-}"
  shift || true
  case "$subcommand" in
    list) command_chain_list "$@" ;;
    limits) command_chain_limits "$@" ;;
    add) command_chain_add "$@" ;;
    edit) command_chain_edit "$@" ;;
    delete) command_chain_delete "$@" ;;
    run) command_chain_run "$@" ;;
    repair) command_chain_repair "$@" ;;
    -h|--help|"")
      megabrain_usage_show chain
      ;;
    *) megabrain_error "unknown chain command: $subcommand"; return "$MEGABRAIN_USAGE_ERROR" ;;
  esac
}
