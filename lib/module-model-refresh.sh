#!/usr/bin/env bash

devkit_model_refresh_agy() {
  local raw ids registry models tmp id levels_json
  devkit_model_init || return 1
  raw="$(agy models 2>&1)" || {
    devkit_error "could not refresh agy models: agy models failed"
    return 1
  }
  ids="$(printf '%s\n' "$raw" | awk '{for (i = 1; i <= NF; i++) { gsub(/[^[:alnum:]_.-]/, "", $i); if ($i ~ /^(gemini|claude|gpt-oss)-[[:alnum:]_.-]+$/) print $i }}' | sort -u)"
  [ -n "$ids" ] || { devkit_error "could not refresh agy models: agy models returned no model ids"; return 1; }
  models='[]'
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in
      *-high) levels_json='["high"]' ;;
      *-medium) levels_json='["medium"]' ;;
      *-low) levels_json='["low"]' ;;
      *) levels_json='["none"]' ;;
    esac
    models="$(printf '%s' "$models" | jq --arg model "$id" --argjson levels "$levels_json" \
      --arg obtainedAt "$(devkit_iso_now)" \
      '. + [{agent: "agy", model: $model, reasoning: {separateAxis: false, levels: $levels}, provenance: {kind: "live", command: "agy models", obtainedAt: $obtainedAt}}]')"
  done <<EOF
$ids
EOF
  registry="$(devkit_model_read)" || return 1
  tmp="$(mktemp "$DEVKIT_STATE_DIR/models.XXXXXX")" || return 1
  if ! printf '%s' "$registry" | jq --argjson models "$models" '.models = ([.models[] | select(.agent != "agy")] + $models)' >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$DEVKIT_MODEL_FILE"
  printf 'model registry refreshed: agy (%s models)\n' "$(printf '%s' "$models" | jq 'length')"
}

command_model_refresh() {
  local agent="${1:-}" arg
  [ -n "$agent" ] || { devkit_error 'Usage: devkit model refresh <agent>'; return "$DEVKIT_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) shift ;;
      -h|--help) printf 'Usage: devkit model refresh <agent>\n'; return 0 ;;
      *) devkit_error "unknown model refresh option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  case "$agent" in
    agy) devkit_model_refresh_agy ;;
    codex|claude) devkit_error "$agent has no live model listing; its registry entries remain manually curated"; return 1 ;;
    *) devkit_error "unknown agent: $agent"; return 1 ;;
  esac
}
