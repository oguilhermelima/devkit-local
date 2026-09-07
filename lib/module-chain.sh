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
  cp "$DEVKIT_CHAIN_FILE" "$tmp" || { rm -f "$tmp"; return 1; }
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
DEVKIT_CHAIN_LIMIT_RESULT=""
DEVKIT_CHAIN_LIMIT_FETCHED_AT=""

devkit_chain_limit_capability() {
  case "$1" in
    codex) printf 'disk\n' ;;
    claude|agy) printf 'provider\n' ;;
    *) printf 'unsupported\n' ;;
  esac
}

devkit_chain_codex_rollouts() {
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

devkit_chain_latest_codex_rollout() {
  devkit_chain_codex_rollouts | LC_ALL=C sort -k1,1nr -k2,2r | cut -f2- | head -n 1
}

devkit_chain_limit_unknown() {
  local agent="$1" window="$2" reason="$3"
  DEVKIT_CHAIN_LIMIT_STATUS=unknown
  DEVKIT_CHAIN_LIMIT_USED=""
  DEVKIT_CHAIN_LIMIT_RESETS=""
  DEVKIT_CHAIN_LIMIT_SOURCE=unknown
  DEVKIT_CHAIN_LIMIT_RESULT=""
  DEVKIT_CHAIN_LIMIT_FETCHED_AT=""
  DEVKIT_CHAIN_LIMIT_REASON="$agent $window window unknown ($reason)"
}

devkit_chain_limit_apply() {
  local result="$1" agent="$2" window="$3" source="$4" entry
  entry="$(printf '%s' "$result" | jq -c --arg window "$window" '
    [.windows[]? | select(.name == $window)] | first // empty
  ' 2>/dev/null)"
  DEVKIT_CHAIN_LIMIT_RESULT="$result"
  DEVKIT_CHAIN_LIMIT_FETCHED_AT="$(printf '%s' "$result" | jq -r '.fetchedAt // empty' 2>/dev/null)"
  DEVKIT_CHAIN_LIMIT_SOURCE="$source"
  if [ -z "$entry" ] || ! printf '%s' "$entry" | jq -e '
    (.usedPercent | type == "number") and
    (.remainingPercent | type == "number") and
    (.resetsAt | type == "string") and (.resetsAt | length > 0)
  ' >/dev/null 2>&1; then
    devkit_chain_limit_unknown "$agent" "$window" 'provider response has no usable window'
    DEVKIT_CHAIN_LIMIT_RESULT="$result"
    DEVKIT_CHAIN_LIMIT_FETCHED_AT="$(printf '%s' "$result" | jq -r '.fetchedAt // empty' 2>/dev/null)"
    return 0
  fi
  DEVKIT_CHAIN_LIMIT_USED="$(printf '%s' "$entry" | jq -r '.usedPercent')"
  DEVKIT_CHAIN_LIMIT_RESETS="$(printf '%s' "$entry" | jq -r '.resetsAt')"
  DEVKIT_CHAIN_LIMIT_STATUS=current
  DEVKIT_CHAIN_LIMIT_REASON="$agent $window window at $DEVKIT_CHAIN_LIMIT_USED percent"
}

devkit_chain_limit_result_codex() {
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

devkit_chain_limit_read() {
  local agent="$1" window="$2" rollout snapshot field expected_minutes now fetched_at result
  DEVKIT_CHAIN_LIMIT_STATUS=unknown
  DEVKIT_CHAIN_LIMIT_USED=""
  DEVKIT_CHAIN_LIMIT_RESETS=""
  DEVKIT_CHAIN_LIMIT_REASON=""
  DEVKIT_CHAIN_LIMIT_SOURCE=""
  DEVKIT_CHAIN_LIMIT_RESULT=""
  DEVKIT_CHAIN_LIMIT_FETCHED_AT=""
  case "$agent" in
    claude|agy)
      devkit_chain_limit_unknown "$agent" "$window" 'provider reader not installed'
      return 0
      ;;
    codex) ;;
    *)
      DEVKIT_CHAIN_LIMIT_REASON="$agent $window window unknown (unsupported provider)"
      return 0
      ;;
  esac
  case "$window" in
    5h) field=primary; expected_minutes=300 ;;
    weekly) field=secondary; expected_minutes=10080 ;;
    *)
      DEVKIT_CHAIN_LIMIT_REASON="codex $window window unknown (unsupported window)"
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
  done < <(devkit_chain_codex_rollouts 2>/dev/null | LC_ALL=C sort -k1,1nr -k2,2r | cut -f2- || true)
  if [ -z "$snapshot" ]; then
    devkit_chain_limit_unknown codex "$window" 'rollout has no rate limit snapshot'
    return 0
  fi
  DEVKIT_CHAIN_LIMIT_USED="$(printf '%s' "$snapshot" | jq -r --arg field "$field" '.[$field].used_percent // empty')"
  DEVKIT_CHAIN_LIMIT_RESETS="$(printf '%s' "$snapshot" | jq -r --arg field "$field" '.[$field].resets_at // empty')"
  if [ -z "$DEVKIT_CHAIN_LIMIT_USED" ] || [ -z "$DEVKIT_CHAIN_LIMIT_RESETS" ]; then
    devkit_chain_limit_unknown codex "$window" 'snapshot is incomplete'
    return 0
  fi
  now="$(date +%s)"
  # WHY: current Codex snapshots nest rate_limits under payload.
  if [ "$DEVKIT_CHAIN_LIMIT_RESETS" -le "$now" ]; then
    devkit_chain_limit_unknown codex "$window" "snapshot stale; reset $DEVKIT_CHAIN_LIMIT_RESETS"
    return 0
  fi
  fetched_at="$(stat -f '%m' "$rollout" 2>/dev/null || stat -c '%Y' "$rollout" 2>/dev/null || printf '%s' "$now")"
  case "$fetched_at" in
    ''|*[!0-9]*) fetched_at="$now" ;;
  esac
  result="$(devkit_chain_limit_result_codex "$snapshot" "$fetched_at")"
  DEVKIT_CHAIN_LIMIT_RESULT="$result"
  DEVKIT_CHAIN_LIMIT_FETCHED_AT="$fetched_at"
  DEVKIT_CHAIN_LIMIT_STATUS=current
  DEVKIT_CHAIN_LIMIT_SOURCE=disk
  DEVKIT_CHAIN_LIMIT_REASON="codex $window window at $DEVKIT_CHAIN_LIMIT_USED percent"
}

DEVKIT_CHAIN_SELECTED_NAME=""
DEVKIT_CHAIN_SELECTED_STEPS="[]"
DEVKIT_CHAIN_SELECTION_REASON=""
DEVKIT_CHAIN_SELECTION_DEFAULT=false

devkit_chain_select() {
  local config="$1" explicit_name="${2:-}" parent_agent="${3:-}" parent_model="${4:-}" parent_effort="${5:-}"
  local chain selector field required actual matched specificity best_specificity=-1 candidates='' count=0
  DEVKIT_CHAIN_SELECTED_NAME=""
  DEVKIT_CHAIN_SELECTED_STEPS='[]'
  DEVKIT_CHAIN_SELECTION_REASON=""
  DEVKIT_CHAIN_SELECTION_DEFAULT=false
  if [ -n "$explicit_name" ]; then
    if ! printf '%s' "$config" | jq -e --arg name "$explicit_name" '.chains | has($name)' >/dev/null 2>&1; then
      devkit_error "chain not found: $explicit_name"
      return 1
    fi
    DEVKIT_CHAIN_SELECTED_NAME="$explicit_name"
    DEVKIT_CHAIN_SELECTED_STEPS="$(printf '%s' "$config" | jq -c --arg name "$explicit_name" '.chains[$name].steps')"
    DEVKIT_CHAIN_SELECTION_REASON="explicit name given"
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
    devkit_error "chain selection is ambiguous: candidates: $candidates"
    return 1
  fi
  if [ "$count" -eq 1 ]; then
    DEVKIT_CHAIN_SELECTED_NAME="$candidates"
    DEVKIT_CHAIN_SELECTED_STEPS="$(printf '%s' "$config" | jq -c --arg name "$candidates" '.chains[$name].steps')"
    DEVKIT_CHAIN_SELECTION_REASON="selector match with $best_specificity field(s)"
    return 0
  fi
  DEVKIT_CHAIN_SELECTION_DEFAULT=true
  DEVKIT_CHAIN_SELECTION_REASON="no selector matched; using defaultSteps"
  DEVKIT_CHAIN_SELECTED_STEPS="$(printf '%s' "$config" | jq -c '.defaultSteps')"
}

devkit_chain_run_spawn() {
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
  spawn_args+=(--agent "$agent" --model "$model" --effort "$effort" --prompt "$prompt" --json)
  [ -n "$label" ] && spawn_args+=(--label "$label")
  [ -n "$tmux_choice" ] && spawn_args+=(--tmux "$tmux_choice")
  if [ "${#agent_args[@]}" -gt 0 ]; then
    for arg in "${agent_args[@]}"; do
      spawn_args+=(--agent-arg "$arg")
    done
  fi
  command_orchestrate spawn "${spawn_args[@]}"
}

devkit_chain_reset_display() {
  local reset_at="$1"
  date -u -r "$reset_at" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$reset_at"
}

devkit_chain_clear_dispatch_context() {
  DEVKIT_CHAIN_NAME=""
  DEVKIT_CHAIN_STEP=""
  DEVKIT_CHAIN_TOTAL=""
  DEVKIT_CHAIN_REASON=""
  DEVKIT_CHAIN_DEFAULT=false
}

command_chain_run() {
  local explicit_name="" parent_agent="${SUPERSET_AGENT_ID:-}" parent_model="${SUPERSET_AGENT_MODEL:-}" parent_effort="${SUPERSET_AGENT_EFFORT:-}"
  local repo="" branch="" base="" slug="" worktree="" prompt="" label="" tmux_choice="" json=false arg config step_count index step agent model effort until_json threshold window
  local spawn_output spawn_json spawn_error error_file reason limit_reason reset_text failure_reason final_reason report_chain reasons_json spawn_succeeded
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
        [ "$#" -ge 2 ] && [ -n "${2:-}" ] || { devkit_error '--agent-arg requires a non-empty value'; return "$DEVKIT_USAGE_ERROR"; }
        agent_args+=("$2")
        shift 2
        ;;
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit chain run [name] [--parent-agent <agent>] [--parent-model <model>] [--parent-effort <effort>] [spawn options] [--json]\n'; return 0 ;;
      *) devkit_error "unknown chain run option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  [ -n "$prompt" ] || { devkit_error '--prompt is required for chain run'; return "$DEVKIT_USAGE_ERROR"; }
  if [ -z "$worktree" ]; then
    [ -n "$repo" ] || { devkit_error '--repo is required for chain run unless --worktree is used'; return "$DEVKIT_USAGE_ERROR"; }
    [ -n "$branch" ] || { devkit_error '--branch is required for chain run unless --worktree is used'; return "$DEVKIT_USAGE_ERROR"; }
  fi
  config="$(devkit_chain_read)" || return 1
  devkit_chain_validate_config "$config" || return 1
  devkit_chain_select "$config" "$explicit_name" "$parent_agent" "$parent_model" "$parent_effort" || return 1
  step_count="$(printf '%s' "$DEVKIT_CHAIN_SELECTED_STEPS" | jq 'length')"
  report_chain="$DEVKIT_CHAIN_SELECTED_NAME"
  [ "$DEVKIT_CHAIN_SELECTION_DEFAULT" = true ] && report_chain=defaultSteps
  reasons_json='[]'
  error_file="$(mktemp "$DEVKIT_STATE_DIR/chain-run.XXXXXX")" || return 1
  index=0
  while IFS= read -r step; do
    index=$((index + 1))
    agent="$(printf '%s' "$step" | jq -r '.agent')"
    model="$(printf '%s' "$step" | jq -r '.model')"
    effort="$(printf '%s' "$step" | jq -r '.effort')"
    until_json="$(printf '%s' "$step" | jq -c '.until // empty')"
    limit_reason=""
    DEVKIT_CHAIN_LIMIT_RESETS=""
    if [ -n "$until_json" ]; then
      threshold="$(printf '%s' "$until_json" | jq -r '.usedPercent')"
      window="$(printf '%s' "$until_json" | jq -r '.window')"
      devkit_chain_limit_read "$agent" "$window"
      limit_reason="$DEVKIT_CHAIN_LIMIT_REASON"
      if [ "$DEVKIT_CHAIN_LIMIT_STATUS" = current ] && awk -v used="$DEVKIT_CHAIN_LIMIT_USED" -v threshold="$threshold" 'BEGIN { exit !(used >= threshold) }'; then
        reset_text=""
        [ -n "$DEVKIT_CHAIN_LIMIT_RESETS" ] && reset_text="; resets at $(devkit_chain_reset_display "$DEVKIT_CHAIN_LIMIT_RESETS")"
        reason="$DEVKIT_CHAIN_LIMIT_REASON$reset_text"
        reasons_json="$(printf '%s' "$reasons_json" | jq --argjson step "$index" --arg agent "$agent" --arg reason "$reason" '. + [{step: $step, agent: $agent, kind: "limit", reason: $reason}]')"
        continue
      fi
    fi
    final_reason="$(printf '%s' "$reasons_json" | jq -r '[.[].reason] | join("; ")')"
    [ -n "$final_reason" ] || final_reason="no earlier steps skipped"
    if [ "$DEVKIT_CHAIN_SELECTION_DEFAULT" = true ]; then
      final_reason="used defaultSteps; $final_reason"
    else
      final_reason="$final_reason; $DEVKIT_CHAIN_SELECTION_REASON"
    fi
    [ -n "$limit_reason" ] && [ "$DEVKIT_CHAIN_LIMIT_STATUS" = unknown ] && final_reason="$final_reason; $limit_reason"
    DEVKIT_CHAIN_NAME="$report_chain"
    DEVKIT_CHAIN_STEP="$index"
    DEVKIT_CHAIN_TOTAL="$step_count"
    DEVKIT_CHAIN_REASON="$final_reason"
    DEVKIT_CHAIN_DEFAULT="$DEVKIT_CHAIN_SELECTION_DEFAULT"
    spawn_succeeded=false
    if [ "${#agent_args[@]}" -gt 0 ]; then
      if spawn_output="$(devkit_chain_run_spawn "$worktree" "$repo" "$branch" "$base" "$slug" "$prompt" "$label" "$tmux_choice" "$model" "$effort" "$agent" "${agent_args[@]}" 2>"$error_file")"; then
        spawn_succeeded=true
      fi
    else
      if spawn_output="$(devkit_chain_run_spawn "$worktree" "$repo" "$branch" "$base" "$slug" "$prompt" "$label" "$tmux_choice" "$model" "$effort" "$agent" 2>"$error_file")"; then
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
      if [ "$json" = true ]; then
        jq -cn --arg chain "$report_chain" --argjson step "$index" --argjson total "$step_count" --arg reason "$final_reason" --argjson skipped "$reasons_json" --arg agent "$agent" --argjson spawn "$spawn_json" '{ok: true, chain: $chain, step: $step, totalSteps: $total, agent: $agent, reason: $reason, skipped: $skipped, dispatch: $spawn}'
      else
        printf 'chain %s, step %s of %s, reason: %s\n' "$report_chain" "$index" "$step_count" "$final_reason"
        printf '%s\n' "$spawn_output"
      fi
      rm -f "$error_file"
      devkit_chain_clear_dispatch_context
      return 0
    fi
    spawn_error="$(cat "$error_file")"
    [ -n "$spawn_error" ] || spawn_error="launch failed"
    failure_reason="$agent launch failed: $spawn_error"
    [ -n "$limit_reason" ] && [ "$DEVKIT_CHAIN_LIMIT_STATUS" = unknown ] && failure_reason="$failure_reason; $limit_reason"
    reasons_json="$(printf '%s' "$reasons_json" | jq --argjson step "$index" --arg agent "$agent" --arg reason "$failure_reason" '. + [{step: $step, agent: $agent, kind: "failure", reason: $reason}]')"
  done < <(printf '%s' "$DEVKIT_CHAIN_SELECTED_STEPS" | jq -c '.[]')
  rm -f "$error_file"
  devkit_chain_clear_dispatch_context
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
