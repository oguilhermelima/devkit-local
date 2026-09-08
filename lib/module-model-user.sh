#!/usr/bin/env bash

devkit_model_level_known() {
  case "$1" in
    none|low|medium|high|xhigh) return 0 ;;
    *) return 1 ;;
  esac
}

devkit_model_levels_json() {
  local levels="$1" level
  printf '%s' "$levels" | tr ',' '\n' | while IFS= read -r level; do
    [ -n "$level" ] && printf '%s\n' "$level"
  done | jq -Rsc 'split("\n") | map(select(length > 0))'
}

devkit_model_add() {
  local agent="$1" model="$2" levels="$3" registry tmp levels_json level
  case "$agent" in
    codex|claude|agy) ;;
    *) devkit_error "unknown agent: $agent"; return 1 ;;
  esac
  [ -n "$model" ] || { devkit_error "model id cannot be empty"; return "$DEVKIT_USAGE_ERROR"; }
  [ -n "$levels" ] || { devkit_error "reasoning levels cannot be empty"; return "$DEVKIT_USAGE_ERROR"; }
  while IFS= read -r level; do
    [ -n "$level" ] || { devkit_error "reasoning levels cannot contain empty values"; return 1; }
    devkit_model_level_known "$level" || { devkit_error "unknown reasoning level: $level"; return 1; }
  done < <(printf '%s' "$levels" | tr ',' '\n')
  registry="$(devkit_model_read)" || return 1
  if printf '%s' "$registry" | jq -e --arg agent "$agent" --arg model "$model" \
    '.models[] | select(.agent == $agent and .model == $model)' >/dev/null 2>&1; then
    devkit_error "model already registered for agent '$agent': $model"
    return 1
  fi
  levels_json="$(devkit_model_levels_json "$levels")" || return 1
  tmp="$(mktemp "$DEVKIT_STATE_DIR/models.XXXXXX")" || return 1
  if ! printf '%s' "$registry" | jq \
    --arg agent "$agent" --arg model "$model" --argjson levels "$levels_json" \
    --arg obtainedAt "$(devkit_iso_now)" \
    '.models += [{agent: $agent, model: $model, reasoning: {separateAxis: true, levels: $levels}, provenance: {kind: "curated", method: "manual curation", obtainedAt: $obtainedAt}}]' >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$DEVKIT_MODEL_FILE"
  printf 'model added: %s/%s\n' "$agent" "$model"
}

command_model_add() {
  local agent="${1:-}" model="${2:-}" levels="" arg
  [ "$#" -ge 2 ] || { devkit_error 'Usage: megabrain model add <agent> <model> --reasoning <levels>'; return "$DEVKIT_USAGE_ERROR"; }
  shift 2
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --reasoning|--reasonings|--reasoning-levels|--levels)
        levels="${2:-}"
        [ -n "$levels" ] || { devkit_error "$arg requires a value"; return "$DEVKIT_USAGE_ERROR"; }
        shift 2
        ;;
      -h|--help) printf 'Usage: megabrain model add <agent> <model> --reasoning <levels>\n'; return 0 ;;
      *) devkit_error "unknown model add option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  devkit_model_add "$agent" "$model" "$levels"
}
