#!/usr/bin/env bash

megabrain_model_level_known() {
  case "$1" in
    none|low|medium|high|xhigh) return 0 ;;
    *) return 1 ;;
  esac
}

megabrain_model_levels_json() {
  local levels="$1" level
  printf '%s' "$levels" | tr ',' '\n' | while IFS= read -r level; do
    [ -n "$level" ] && printf '%s\n' "$level"
  done | jq -Rsc 'split("\n") | map(select(length > 0))'
}

megabrain_model_add() {
  local agent="$1" model="$2" levels="$3" registry tmp levels_json level
  case "$agent" in
    codex|claude|agy) ;;
    *) megabrain_error "unknown agent: $agent"; return 1 ;;
  esac
  [ -n "$model" ] || { megabrain_error "model id cannot be empty"; return "$MEGABRAIN_USAGE_ERROR"; }
  [ -n "$levels" ] || { megabrain_error "reasoning levels cannot be empty"; return "$MEGABRAIN_USAGE_ERROR"; }
  while IFS= read -r level; do
    [ -n "$level" ] || { megabrain_error "reasoning levels cannot contain empty values"; return 1; }
    megabrain_model_level_known "$level" || { megabrain_error "unknown reasoning level: $level"; return 1; }
  done < <(printf '%s' "$levels" | tr ',' '\n')
  registry="$(megabrain_model_read)" || return 1
  if printf '%s' "$registry" | jq -e --arg agent "$agent" --arg model "$model" \
    '.models[] | select(.agent == $agent and .model == $model)' >/dev/null 2>&1; then
    megabrain_error "model already registered for agent '$agent': $model"
    return 1
  fi
  levels_json="$(megabrain_model_levels_json "$levels")" || return 1
  tmp="$(mktemp "$MEGABRAIN_STATE_DIR/models.XXXXXX")" || return 1
  if ! printf '%s' "$registry" | jq \
    --arg agent "$agent" --arg model "$model" --argjson levels "$levels_json" \
    --arg obtainedAt "$(megabrain_iso_now)" \
    '.models += [{agent: $agent, model: $model, reasoning: {separateAxis: true, levels: $levels}, provenance: {kind: "curated", method: "manual curation", obtainedAt: $obtainedAt}}]' >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$MEGABRAIN_MODEL_FILE"
  printf 'model added: %s/%s\n' "$agent" "$model"
}

command_model_add() {
  local agent="${1:-}" model="${2:-}" levels="" arg
  case "$agent" in
    -h|--help) megabrain_usage_show model-add; return 0 ;;
  esac
  [ "$#" -ge 2 ] || { megabrain_usage_fail model-add; return "$MEGABRAIN_USAGE_ERROR"; }
  shift 2
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --reasoning|--reasonings|--reasoning-levels|--levels)
        levels="${2:-}"
        [ -n "$levels" ] || { megabrain_error "$arg requires a value"; return "$MEGABRAIN_USAGE_ERROR"; }
        shift 2
        ;;
      -h|--help) megabrain_usage_show model-add; return 0 ;;
      *) megabrain_error "unknown model add option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  megabrain_model_add "$agent" "$model" "$levels"
}
