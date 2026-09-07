#!/usr/bin/env bash

DEVKIT_CHAIN_AGENTS='codex claude agy'
DEVKIT_CHAIN_WINDOWS='5h weekly'

devkit_chain_seed() {
  cat <<'EOF'
{
  "chains": {
    "claude": {
      "when": {"parentAgent": "claude"},
      "steps": [
        {"agent": "codex", "model": "gpt-5.6-luna", "effort": "high", "until": {"usedPercent": 95, "window": "5h"}},
        {"agent": "agy", "model": "gemini-2.5-pro", "effort": "high"}
      ]
    },
    "codex": {
      "when": {"parentAgent": "codex"},
      "steps": [
        {"agent": "claude", "model": "claude-sonnet-4-5", "effort": "high"},
        {"agent": "agy", "model": "gemini-2.5-pro", "effort": "high"}
      ]
    },
    "agy": {
      "when": {"parentAgent": "agy"},
      "steps": [
        {"agent": "codex", "model": "gpt-5.6-luna", "effort": "high", "until": {"usedPercent": 95, "window": "5h"}},
        {"agent": "claude", "model": "claude-sonnet-4-5", "effort": "high"}
      ]
    }
  },
  "defaultSteps": []
}
EOF
}

devkit_chain_init() {
  local tmp
  mkdir -p "$DEVKIT_STATE_DIR" || return 1
  if [ ! -f "$DEVKIT_CHAIN_FILE" ]; then
    tmp="$(mktemp "$DEVKIT_STATE_DIR/chains.XXXXXX")" || return 1
    if ! devkit_chain_seed >"$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    mv -f "$tmp" "$DEVKIT_CHAIN_FILE"
  elif ! jq empty "$DEVKIT_CHAIN_FILE" >/dev/null 2>&1; then
    devkit_error "chain file is not valid JSON: $DEVKIT_CHAIN_FILE"
    return 1
  fi
}

devkit_chain_read() {
  devkit_chain_init || return 1
  cat "$DEVKIT_CHAIN_FILE"
}

devkit_chain_agent_known() {
  case "$1" in
    codex|claude|agy) return 0 ;;
    *) return 1 ;;
  esac
}

devkit_chain_window_known() {
  case "$1" in
    5h|weekly) return 0 ;;
    *) return 1 ;;
  esac
}

devkit_chain_name_valid() {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

devkit_chain_validate_selector() {
  local chain="$1" selector="$2" key value
  if ! jq -e 'type == "object" and length > 0' >/dev/null 2>&1 <<EOF
$selector
EOF
  then
    devkit_error "invalid chain $chain selector: expected a non-empty object"
    return 1
  fi
  while IFS= read -r key; do
    case "$key" in
      parentAgent|parentModel|parentEffort) ;;
      *)
        devkit_error "invalid chain $chain selector: unsupported field $key"
        return 1
        ;;
    esac
    value="$(printf '%s' "$selector" | jq -r --arg key "$key" '.[$key] // empty')"
    [ -n "$value" ] || {
      devkit_error "invalid chain $chain selector field $key: value cannot be empty"
      return 1
    }
    if [ "$key" = parentAgent ] && ! devkit_chain_agent_known "$value"; then
      devkit_error "invalid chain $chain selector field parentAgent: unknown agent $value"
      return 1
    fi
  done < <(printf '%s' "$selector" | jq -r 'keys_unsorted[]')
}

devkit_chain_validate_step() {
  local chain="$1" index="$2" step="$3" key agent model effort until_json used_percent window
  if ! printf '%s' "$step" | jq -e 'type == "object"' >/dev/null 2>&1; then
    devkit_error "invalid chain $chain step $index: expected an object"
    return 1
  fi
  while IFS= read -r key; do
    case "$key" in
      agent|model|effort|until) ;;
      *)
        devkit_error "invalid chain $chain step $index: unsupported field $key"
        return 1
        ;;
    esac
  done < <(printf '%s' "$step" | jq -r 'keys_unsorted[]')
  agent="$(printf '%s' "$step" | jq -r '.agent // empty')"
  model="$(printf '%s' "$step" | jq -r '.model // empty')"
  effort="$(printf '%s' "$step" | jq -r '.effort // empty')"
  [ -n "$agent" ] || { devkit_error "invalid chain $chain step $index: agent is required"; return 1; }
  devkit_chain_agent_known "$agent" || { devkit_error "invalid chain $chain step $index: unknown agent $agent"; return 1; }
  [ -n "$model" ] || { devkit_error "invalid chain $chain step $index: model is required"; return 1; }
  [ -n "$effort" ] || { devkit_error "invalid chain $chain step $index: effort is required"; return 1; }
  if printf '%s' "$step" | jq -e 'has("until")' >/dev/null 2>&1; then
    until_json="$(printf '%s' "$step" | jq -c '.until')"
    if ! printf '%s' "$until_json" | jq -e 'type == "object" and ((keys | sort) == ["usedPercent", "window"])' >/dev/null 2>&1; then
      devkit_error "invalid chain $chain step $index until: expected usedPercent and window"
      return 1
    fi
    used_percent="$(printf '%s' "$until_json" | jq -r '.usedPercent // empty')"
    window="$(printf '%s' "$until_json" | jq -r '.window // empty')"
    if ! printf '%s' "$until_json" | jq -e '.usedPercent | type == "number" and . >= 0 and . <= 100' >/dev/null 2>&1; then
      devkit_error "invalid chain $chain step $index until.usedPercent: expected a number from 0 to 100"
      return 1
    fi
    devkit_chain_window_known "$window" || { devkit_error "invalid chain $chain step $index until.window: unsupported window $window"; return 1; }
  fi
}

devkit_chain_validate_config() {
  local config="$1" chain selector steps step index
  if ! printf '%s' "$config" | jq -e 'type == "object" and (.chains | type == "object") and (.defaultSteps | type == "array")' >/dev/null 2>&1; then
    devkit_error "invalid chain config: expected chains object and defaultSteps array"
    return 1
  fi
  while IFS= read -r chain; do
    devkit_chain_name_valid "$chain" || { devkit_error "invalid chain name: $chain"; return 1; }
    selector="$(printf '%s' "$config" | jq -c --arg chain "$chain" '.chains[$chain].when // empty')"
    devkit_chain_validate_selector "$chain" "$selector" || return 1
    steps="$(printf '%s' "$config" | jq -c --arg chain "$chain" '.chains[$chain].steps // empty')"
    if ! printf '%s' "$steps" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
      devkit_error "invalid chain $chain: steps cannot be empty"
      return 1
    fi
    index=0
    while IFS= read -r step; do
      index=$((index + 1))
      devkit_chain_validate_step "$chain" "$index" "$step" || return 1
    done < <(printf '%s' "$steps" | jq -c '.[]')
  done < <(printf '%s' "$config" | jq -r '.chains | keys[]')
  index=0
  while IFS= read -r step; do
    index=$((index + 1))
    devkit_chain_validate_step default "$index" "$step" || return 1
  done < <(printf '%s' "$config" | jq -c '.defaultSteps[]')
}

devkit_chain_write() {
  local config="$1" tmp
  tmp="$(mktemp "$DEVKIT_STATE_DIR/chains.XXXXXX")" || return 1
  if ! printf '%s' "$config" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$DEVKIT_CHAIN_FILE"
}

devkit_chain_format_list() {
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
      -h|--help) printf 'Usage: devkit chain list [--json]\n'; return 0 ;;
      *) devkit_error "unknown chain list option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  config="$(devkit_chain_read)" || return 1
  devkit_chain_validate_config "$config" || return 1
  devkit_chain_format_list "$config" "$json"
}

command_chain_add() {
  local name="" when_json='{}' steps_json='[]' json=false arg value chain config result
  [ "$#" -gt 0 ] || { devkit_error 'Usage: devkit chain add <name> --when <json> --steps <json> [--json]'; return "$DEVKIT_USAGE_ERROR"; }
  name="$1"
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --when) value="${2:-}"; [ -n "$value" ] || { devkit_error '--when requires a value'; return "$DEVKIT_USAGE_ERROR"; }; when_json="$value"; shift 2 ;;
      --steps) value="${2:-}"; [ -n "$value" ] || { devkit_error '--steps requires a value'; return "$DEVKIT_USAGE_ERROR"; }; steps_json="$value"; shift 2 ;;
      --step) value="${2:-}"; [ -n "$value" ] || { devkit_error '--step requires a value'; return "$DEVKIT_USAGE_ERROR"; }; steps_json="$(printf '%s' "$steps_json" | jq --argjson step "$value" '. + [$step]' 2>/dev/null)" || { devkit_error 'invalid --step JSON'; return 1; }; shift 2 ;;
      --parent-agent|--parent-model|--parent-effort)
        value="${2:-}"; [ -n "$value" ] || { devkit_error "$arg requires a value"; return "$DEVKIT_USAGE_ERROR"; }
        case "$arg" in
          --parent-agent) when_json="$(printf '%s' "$when_json" | jq --arg value "$value" '. + {parentAgent: $value}')" ;;
          --parent-model) when_json="$(printf '%s' "$when_json" | jq --arg value "$value" '. + {parentModel: $value}')" ;;
          --parent-effort) when_json="$(printf '%s' "$when_json" | jq --arg value "$value" '. + {parentEffort: $value}')" ;;
        esac
        shift 2
        ;;
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit chain add <name> --when <json> --steps <json> [--json]\n'; return 0 ;;
      *) devkit_error "unknown chain add option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  devkit_chain_name_valid "$name" || { devkit_error "invalid chain name: $name"; return 1; }
  config="$(devkit_chain_read)" || return 1
  if printf '%s' "$config" | jq -e --arg name "$name" '.chains | has($name)' >/dev/null 2>&1; then
    devkit_error "chain already exists: $name"
    return 1
  fi
  if ! result="$(jq -n --argjson when "$when_json" --argjson steps "$steps_json" '{when: $when, steps: $steps}' 2>/dev/null)"; then
    devkit_error "chain $name has invalid JSON definition"
    return 1
  fi
  config="$(printf '%s' "$config" | jq --arg name "$name" --argjson chain "$result" '.chains[$name] = $chain')"
  devkit_chain_validate_config "$config" || return 1
  devkit_chain_write "$config" || return 1
  if [ "$json" = true ]; then
    printf '%s\n' "$result" | jq -c --arg name "$name" '. + {name: $name}'
  else
    printf 'chain added: %s\n' "$name"
  fi
}

command_chain_edit() {
  local name="" json=false arg config tmp edited editor
  [ "$#" -gt 0 ] || { devkit_error 'Usage: devkit chain edit <name> [--json]'; return "$DEVKIT_USAGE_ERROR"; }
  name="$1"
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit chain edit <name> [--json]\n'; return 0 ;;
      *) devkit_error "unknown chain edit option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  config="$(devkit_chain_read)" || return 1
  if ! printf '%s' "$config" | jq -e --arg name "$name" '.chains | has($name)' >/dev/null 2>&1; then
    devkit_error "chain not found: $name"
    return 1
  fi
  tmp="$(mktemp "$DEVKIT_STATE_DIR/chains-edit.XXXXXX")" || return 1
  printf '%s\n' "$config" >"$tmp"
  editor="${EDITOR:-vi}"
  if ! "$editor" "$tmp"; then
    rm -f "$tmp"
    devkit_error "editor failed while editing chain $name"
    return 1
  fi
  if cmp -s "$DEVKIT_CHAIN_FILE" "$tmp"; then
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
  devkit_chain_validate_config "$edited" || return 1
  if ! printf '%s' "$edited" | jq -e --arg name "$name" '.chains | has($name)' >/dev/null 2>&1; then
    devkit_error "edited chain not found: $name"
    return 1
  fi
  devkit_chain_write "$edited" || return 1
  if [ "$json" = true ]; then
    printf '%s' "$edited" | jq -c --arg name "$name" '.chains[$name] + {name: $name, changed: true}'
  else
    printf 'chain edited: %s\n' "$name"
  fi
}

command_chain_delete() {
  local name="" json=false arg config names result
  [ "$#" -gt 0 ] || { devkit_error 'Usage: devkit chain delete <name> [--json]'; return "$DEVKIT_USAGE_ERROR"; }
  name="$1"
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit chain delete <name> [--json]\n'; return 0 ;;
      *) devkit_error "unknown chain delete option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  config="$(devkit_chain_read)" || return 1
  if ! printf '%s' "$config" | jq -e --arg name "$name" '.chains | has($name)' >/dev/null 2>&1; then
    names="$(printf '%s' "$config" | jq -r '.chains | keys | join(", ")')"
    devkit_error "chain not found: $name; available chains: $names"
    return 1
  fi
  result="$(printf '%s' "$config" | jq --arg name "$name" 'del(.chains[$name])')"
  devkit_chain_validate_config "$result" || return 1
  devkit_chain_write "$result" || return 1
  if [ "$json" = true ]; then
    jq -n --arg name "$name" '{deleted: true, name: $name}'
  else
    printf 'chain deleted: %s\n' "$name"
  fi
}

DEVKIT_CHAIN_LIMIT_STATUS="unknown"
DEVKIT_CHAIN_LIMIT_USED=""
DEVKIT_CHAIN_LIMIT_RESETS=""
DEVKIT_CHAIN_LIMIT_REASON=""
DEVKIT_CHAIN_LIMIT_SOURCE=""

devkit_chain_limit_capability() {
  case "$1" in
    codex) printf 'disk\n' ;;
    claude|agy) printf 'unknown\n' ;;
    *) printf 'unsupported\n' ;;
  esac
}

devkit_chain_latest_codex_rollout() {
  local root="$HOME/.codex/sessions" path mtime latest="" latest_mtime=0
  [ -d "$root" ] || return 1
  while IFS= read -r path; do
    [ -f "$path" ] || continue
    mtime="$(stat -f '%m' "$path" 2>/dev/null || stat -c '%Y' "$path" 2>/dev/null || printf '0')"
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$mtime" -ge "$latest_mtime" ]; then
      latest_mtime="$mtime"
      latest="$path"
    fi
  done < <(find "$root" -type f -name 'rollout-*.jsonl' -print 2>/dev/null)
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

devkit_chain_limit_read() {
  local agent="$1" window="$2" rollout snapshot field expected_minutes now
  DEVKIT_CHAIN_LIMIT_STATUS=unknown
  DEVKIT_CHAIN_LIMIT_USED=""
  DEVKIT_CHAIN_LIMIT_RESETS=""
  DEVKIT_CHAIN_LIMIT_REASON=""
  DEVKIT_CHAIN_LIMIT_SOURCE=""
  case "$agent" in
    claude|agy)
      DEVKIT_CHAIN_LIMIT_REASON="$agent $window window unknown (provider unavailable)"
      return 0
      ;;
    codex) ;;
    *)
      DEVKIT_CHAIN_LIMIT_REASON="$agent $window window unknown (unsupported provider)"
      return 0
      ;;
  esac
  rollout="$(devkit_chain_latest_codex_rollout 2>/dev/null || true)"
  if [ -z "$rollout" ]; then
    DEVKIT_CHAIN_LIMIT_REASON="codex $window window unknown (no rollout snapshot)"
    return 0
  fi
  snapshot="$(jq -c 'select(.rate_limits? != null) | .rate_limits' "$rollout" 2>/dev/null | tail -n 1)"
  if [ -z "$snapshot" ] || ! printf '%s' "$snapshot" | jq -e 'type == "object"' >/dev/null 2>&1; then
    DEVKIT_CHAIN_LIMIT_REASON="codex $window window unknown (rollout has no rate limit snapshot)"
    return 0
  fi
  case "$window" in
    5h) field=primary; expected_minutes=300 ;;
    weekly) field=secondary; expected_minutes=10080 ;;
    *)
      DEVKIT_CHAIN_LIMIT_REASON="codex $window window unknown (unsupported window)"
      return 0
      ;;
  esac
  if ! printf '%s' "$snapshot" | jq -e --arg field "$field" --argjson minutes "$expected_minutes" '.[$field] | type == "object" and (.window_minutes == $minutes)' >/dev/null 2>&1; then
    DEVKIT_CHAIN_LIMIT_REASON="codex $window window unknown (matching snapshot unavailable)"
    return 0
  fi
  DEVKIT_CHAIN_LIMIT_USED="$(printf '%s' "$snapshot" | jq -r --arg field "$field" '.[$field].used_percent // empty')"
  DEVKIT_CHAIN_LIMIT_RESETS="$(printf '%s' "$snapshot" | jq -r --arg field "$field" '.[$field].resets_at // empty')"
  if [ -z "$DEVKIT_CHAIN_LIMIT_USED" ] || [ -z "$DEVKIT_CHAIN_LIMIT_RESETS" ]; then
    DEVKIT_CHAIN_LIMIT_REASON="codex $window window unknown (snapshot is incomplete)"
    return 0
  fi
  now="$(date +%s)"
  # A rollout is a response snapshot; its limit is stale after the provider reset.
  if [ "$DEVKIT_CHAIN_LIMIT_RESETS" -le "$now" ]; then
    DEVKIT_CHAIN_LIMIT_REASON="codex $window window unknown (snapshot stale; reset $DEVKIT_CHAIN_LIMIT_RESETS)"
    DEVKIT_CHAIN_LIMIT_USED=""
    DEVKIT_CHAIN_LIMIT_RESETS=""
    return 0
  fi
  DEVKIT_CHAIN_LIMIT_STATUS=current
  DEVKIT_CHAIN_LIMIT_SOURCE="$rollout"
  DEVKIT_CHAIN_LIMIT_REASON="codex $window window at $DEVKIT_CHAIN_LIMIT_USED percent"
}

command_chain() {
  local subcommand="${1:-}"
  shift || true
  case "$subcommand" in
    list) command_chain_list "$@" ;;
    add) command_chain_add "$@" ;;
    edit) command_chain_edit "$@" ;;
    delete) command_chain_delete "$@" ;;
    run) command_chain_run "$@" ;;
    -h|--help|"")
      printf 'Usage: devkit chain list|add|edit|delete|run ...\n'
      ;;
    *) devkit_error "unknown chain command: $subcommand"; return "$DEVKIT_USAGE_ERROR" ;;
  esac
}
