#!/usr/bin/env bash

DEVKIT_USAGE_ERROR=2
DEVKIT_STATE_DIR="${DEVKIT_STATE_DIR:-$HOME/.devkit}"
DEVKIT_STATE_FILE="$DEVKIT_STATE_DIR/state.json"
DEVKIT_DISPATCH_DIR="$DEVKIT_STATE_DIR/dispatches"
DEVKIT_SHARED_ROOT=""
DEVKIT_SESSION_ID=""
DEVKIT_SESSION_HOST=""
MODULE_STATUS=""
MODULE_REASON=""
MODULE_DETAILS=""
MODULE_UNCERTAIN_DISPATCHES=0
MODULE_RETAINED_TERMINALS=0

devkit_error() {
  printf 'devkit: %s\n' "$*" >&2
}

devkit_info() {
  printf '%s\n' "$*"
}

devkit_require_command() {
  command -v "$1" >/dev/null 2>&1
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
  DEVKIT_SESSION_ID=""
  DEVKIT_SESSION_HOST="unknown"
  if [ -n "${SUPERSET_TERMINAL_ID:-}" ]; then
    DEVKIT_SESSION_ID="$SUPERSET_TERMINAL_ID"
    DEVKIT_SESSION_HOST="superset"
  elif [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
    DEVKIT_SESSION_ID="$ORCA_TERMINAL_HANDLE"
    DEVKIT_SESSION_HOST="orca"
  fi
  printf '%s\n' "$DEVKIT_SESSION_ID"
}

devkit_json_value() {
  local expression="$1"
  jq -r "$expression // empty" 2>/dev/null
}

devkit_state_init() {
  mkdir -p "$DEVKIT_STATE_DIR" || return 1
  if [ ! -f "$DEVKIT_STATE_FILE" ]; then
    printf '{}\n' >"$DEVKIT_STATE_FILE"
  elif ! jq empty "$DEVKIT_STATE_FILE" >/dev/null 2>&1; then
    devkit_error "state file is not valid JSON: $DEVKIT_STATE_FILE"
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
  tmp="$(mktemp "$DEVKIT_STATE_DIR/state.XXXXXX")" || return 1
  if ! jq --arg module "$module" \
    --argjson installed "$installed" \
    --arg configuredAt "$configured_at" \
    --arg details "$details" \
    '.[$module] = {installed: $installed, configuredAt: $configuredAt, details: $details}' \
    "$DEVKIT_STATE_FILE" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$DEVKIT_STATE_FILE"
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
  [ -f "$DEVKIT_STATE_FILE" ] || return 1
  jq -e '."tmux-runtime".installed == true' "$DEVKIT_STATE_FILE" >/dev/null 2>&1
}
