#!/usr/bin/env bash

MEGABRAIN_USAGE_ERROR=2
MEGABRAIN_STATE_DIR_EXPLICIT=false
MEGABRAIN_STATE_DIR_LEGACY=""
MEGABRAIN_STATE_DIR_LEGACY_EXPLICIT=false
if [ "${MEGABRAIN_STATE_DIR+x}" = x ]; then
  MEGABRAIN_STATE_DIR_EXPLICIT=true
  if [ "${DEVKIT_STATE_DIR+x}" = x ]; then
    printf 'DEVKIT_STATE_DIR is deprecated and ignored because MEGABRAIN_STATE_DIR is set.\n' >&2
    unset DEVKIT_STATE_DIR
  fi
elif [ "${DEVKIT_STATE_DIR+x}" = x ]; then
  MEGABRAIN_STATE_DIR_EXPLICIT=true
  MEGABRAIN_STATE_DIR_LEGACY_EXPLICIT=true
  MEGABRAIN_STATE_DIR_LEGACY="$DEVKIT_STATE_DIR"
  MEGABRAIN_STATE_DIR="$DEVKIT_STATE_DIR"
  printf 'DEVKIT_STATE_DIR is deprecated; use MEGABRAIN_STATE_DIR instead.\n' >&2
  unset DEVKIT_STATE_DIR
else
  MEGABRAIN_STATE_DIR="$HOME/.megabrain"
fi
MEGABRAIN_STATE_FILE="$MEGABRAIN_STATE_DIR/state.json"
MEGABRAIN_CHAIN_FILE="$MEGABRAIN_STATE_DIR/chains.json"
MEGABRAIN_DISPATCH_DIR="$MEGABRAIN_STATE_DIR/dispatches"
MEGABRAIN_TMUX_SESSION_DIR="$MEGABRAIN_STATE_DIR/sessions"
MEGABRAIN_SHARED_ROOT=""
MEGABRAIN_SESSION_ID=""
MEGABRAIN_SESSION_HOST=""
MODULE_STATUS=""
MODULE_REASON=""
MODULE_DETAILS=""
MODULE_UNCERTAIN_DISPATCHES=0
MODULE_RETAINED_TERMINALS=0

devkit_error() {
  printf 'megabrain: %s\n' "$*" >&2
}

devkit_info() {
  printf '%s\n' "$*"
}

# WHY: advice is not a result. Keeping it off stdout is what lets --json callers
# capture a module's output without a human sentence landing inside the JSON.
devkit_notice() {
  printf '%s\n' "$*" >&2
}

devkit_require_command() {
  command -v "$1" >/dev/null 2>&1
}

# WHY: the plugin manifest is the version the marketplaces publish, and it ships
# next to this script, so reading it keeps one number instead of two that drift.
devkit_version() {
  local manifest="${MEGABRAIN_ROOT:-}/.claude-plugin/plugin.json" version=''
  [ -f "$manifest" ] && version="$(jq -r '.version // empty' "$manifest" 2>/dev/null || true)"
  printf 'megabrain %s\n' "${version:-unknown}"
}

devkit_superset_binary() {
  local path
  path="$(type -P superset 2>/dev/null || true)"
  if [ -n "$path" ]; then
    printf '%s\n' "$path"
  elif [ -x "$HOME/.superset/bin/superset" ]; then
    printf '%s\n' "$HOME/.superset/bin/superset"
  fi
}

devkit_superset_available() {
  [ -n "$(devkit_superset_binary)" ]
}

devkit_superset() {
  local binary
  binary="$(devkit_superset_binary)"
  [ -n "$binary" ] || return 127
  "$binary" "$@"
}

devkit_iso_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

devkit_session_id() {
  MEGABRAIN_SESSION_ID=""
  MEGABRAIN_SESSION_HOST="unknown"
  if [ -n "${SUPERSET_TERMINAL_ID:-}" ]; then
    MEGABRAIN_SESSION_ID="$SUPERSET_TERMINAL_ID"
    MEGABRAIN_SESSION_HOST="superset"
  elif [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
    MEGABRAIN_SESSION_ID="$ORCA_TERMINAL_HANDLE"
    MEGABRAIN_SESSION_HOST="orca"
  fi
  printf '%s\n' "$MEGABRAIN_SESSION_ID"
}

devkit_json_value() {
  local expression="$1"
  jq -r "$expression // empty" 2>/dev/null
}

devkit_state_init() {
  mkdir -p "$MEGABRAIN_STATE_DIR" || return 1
  if [ ! -f "$MEGABRAIN_STATE_FILE" ]; then
    printf '{}\n' >"$MEGABRAIN_STATE_FILE"
  elif ! jq empty "$MEGABRAIN_STATE_FILE" >/dev/null 2>&1; then
    devkit_error "state file is not valid JSON: $MEGABRAIN_STATE_FILE"
    return 1
  fi
}

devkit_state_set() {
  local module="$1"
  local installed="$2"
  local details="$3"
  local configured_at
  local tmp

  devkit_state_init || return 1
  configured_at="$(devkit_iso_now)"
  tmp="$(mktemp "$MEGABRAIN_STATE_DIR/state.XXXXXX")" || return 1
  if ! jq --arg module "$module" \
    --argjson installed "$installed" \
    --arg configuredAt "$configured_at" \
    --arg details "$details" \
    '.[$module] = {installed: $installed, configuredAt: $configuredAt, details: $details}' \
    "$MEGABRAIN_STATE_FILE" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$MEGABRAIN_STATE_FILE"
}

devkit_set_status() {
  MODULE_STATUS="$1"
  MODULE_REASON="$2"
  MODULE_DETAILS="${3:-$2}"
}

devkit_status_line() {
  printf '%-18s %s: %s\n' "$1" "$2" "$3"
}

devkit_bool_json() {
  case "$1" in
    true|1|yes) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

devkit_trim() {
  awk '{$1=$1; print}'
}

devkit_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

devkit_json_ok() {
  jq -e '.ok == true' >/dev/null 2>&1
}

devkit_json_result() {
  jq -c '.result // .' 2>/dev/null
}

devkit_orca_json() {
  orca "$@" --json 2>/dev/null
}

devkit_superset_json() {
  devkit_superset "$@" --json 2>/dev/null
}

devkit_validate_module() {
  case "$1" in
    orchestration|orchestration-hooks|worktree|simulator-web|simulator-native|simulator-tv|tv-adb|tmux-runtime) return 0 ;;
    *) return 1 ;;
  esac
}

devkit_module_ids() {
  printf '%s\n' orchestration orchestration-hooks worktree simulator-web simulator-native simulator-tv tv-adb tmux-runtime
}

devkit_runtime_enabled() {
  [ -f "$MEGABRAIN_STATE_FILE" ] || return 1
  jq -e '."tmux-runtime".installed == true' "$MEGABRAIN_STATE_FILE" >/dev/null 2>&1
}

devkit_backup_path() {
  local path="$1" stamp suffix=1 backup
  [ -f "$path" ] || return 0
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  backup="${path}.megabrain-backup-${stamp}"
  while [ -e "$backup" ]; do
    backup="${path}.megabrain-backup-${stamp}-${suffix}"
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$backup"
}

devkit_backup_file() {
  local path="$1" backup
  [ -f "$path" ] || return 0
  backup="$(devkit_backup_path "$path")"
  cp -p "$path" "$backup" || return 1
  MEGABRAIN_LAST_BACKUP_PATH="$backup"
  printf '%s\n' "$backup"
}

devkit_latest_backup() {
  local path="$1" candidate latest=''
  for candidate in "${path}.megabrain-backup-"*; do
    [ -f "$candidate" ] || continue
    [ -z "$latest" ] || [ "$candidate" ">" "$latest" ] || continue
    latest="$candidate"
  done
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}
