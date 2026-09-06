#!/usr/bin/env bash

DEVKIT_APPIUM_PORT="${DEVKIT_APPIUM_PORT:-4723}"
DEVKIT_APPIUM_PIDFILE="$DEVKIT_STATE_DIR/appium.pid"
DEVKIT_APPIUM_LOG="$DEVKIT_STATE_DIR/appium.log"

devkit_appium_driver_ready() {
  devkit_require_command appium || return 1
  appium driver list --installed 2>/dev/null | grep -Eiq 'xcuitest([[:space:]]|$)'
}

module_simulator_native_doctor() {
  if [ "$(uname -s 2>/dev/null || printf unknown)" != Darwin ]; then
    devkit_set_status unsupported "macOS only"
    return 1
  fi
  if ! devkit_require_command appium; then
    devkit_set_status missing "appium is not on PATH"
    return 1
  fi
  if ! devkit_appium_driver_ready; then
    devkit_set_status misconfigured "appium-xcuitest-driver is not installed"
    return 1
  fi
  devkit_set_status ok "appium and xcuitest driver are installed"
  return 0
}

module_simulator_native_install() {
  module_simulator_native_doctor >/dev/null
  if [ "$?" -ne 0 ] && [ "$MODULE_STATUS" = unsupported ]; then
    devkit_error "simulator-native is macOS only"
    return 1
  fi
  if ! devkit_require_command appium; then
    npm install -g appium || return 1
  fi
  appium driver list --installed 2>/dev/null | grep -Eiq 'xcuitest([[:space:]]|$)' || appium driver install xcuitest || return 1
  module_simulator_native_doctor
}

devkit_appium_pid() {
  local pid=""
  if [ -f "$DEVKIT_APPIUM_PIDFILE" ]; then
    pid="$(sed -n '1p' "$DEVKIT_APPIUM_PIDFILE")"
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      printf '%s\n' "$pid"
      return 0
    fi
  fi
  lsof -tiTCP:"$DEVKIT_APPIUM_PORT" -sTCP:LISTEN 2>/dev/null | head -n 1
}

devkit_appium_status() {
  local pid command_line
  pid="$(devkit_appium_pid)"
  if [ -z "$pid" ]; then
    printf 'appium: down (port %s)\n' "$DEVKIT_APPIUM_PORT"
    return 1
  fi
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  if [ -n "$command_line" ] && [[ "$command_line" != *appium* ]]; then
    printf 'appium: occupied (port %s, pid %s)\n' "$DEVKIT_APPIUM_PORT" "$pid"
    return 1
  fi
  printf 'appium: up (port %s, pid %s)\n' "$DEVKIT_APPIUM_PORT" "$pid"
  return 0
}

devkit_appium_start() {
  local pid
  if devkit_appium_status >/dev/null 2>&1; then
    devkit_appium_status
    return 0
  fi
  module_simulator_native_doctor >/dev/null || {
    devkit_error "appium is not ready; run devkit install simulator-native"
    return 1
  }
  mkdir -p "$DEVKIT_STATE_DIR" || return 1
  nohup appium --port "$DEVKIT_APPIUM_PORT" >"$DEVKIT_APPIUM_LOG" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >"$DEVKIT_APPIUM_PIDFILE"
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.2
    if devkit_appium_status >/dev/null 2>&1; then
      devkit_appium_status
      return 0
    fi
  done
  devkit_error "appium did not start on port $DEVKIT_APPIUM_PORT; see $DEVKIT_APPIUM_LOG"
  return 1
}

devkit_appium_stop() {
  local pid command_line
  pid="$(devkit_appium_pid)"
  if [ -z "$pid" ]; then
    rm -f "$DEVKIT_APPIUM_PIDFILE"
    printf 'appium: already stopped\n'
    return 0
  fi
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  if [ -n "$command_line" ] && [[ "$command_line" != *appium* ]]; then
    devkit_error "refusing to stop non-Appium process $pid on port $DEVKIT_APPIUM_PORT"
    return 1
  fi
  kill "$pid" >/dev/null 2>&1 || true
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" >/dev/null 2>&1 || break
    sleep 0.2
  done
  rm -f "$DEVKIT_APPIUM_PIDFILE"
  printf 'appium: stopped (pid %s)\n' "$pid"
}

command_native() {
  local family="${1:-}" operation="${2:-}" arg
  shift || true
  shift || true
  case "$family" in
    appium)
      [ "$#" -eq 0 ] || { devkit_error "unknown native appium option: $1"; return "$DEVKIT_USAGE_ERROR"; }
      case "$operation" in
        start) devkit_appium_start ;;
        stop) devkit_appium_stop ;;
        status) devkit_appium_status ;;
        -h|--help|"") printf 'Usage: devkit native appium start|stop|status\n' ;;
        *) devkit_error "unknown appium operation: $operation"; return "$DEVKIT_USAGE_ERROR" ;;
      esac
      ;;
    -h|--help|"") printf 'Usage: devkit native appium start|stop|status\n' ;;
    *) devkit_error "unknown native command: $family"; return "$DEVKIT_USAGE_ERROR" ;;
  esac
}

module_simulator_tv_doctor() {
  module_simulator_native_doctor
  if [ "$?" -eq 0 ]; then
    devkit_set_status ok "Apple TV simulator uses the shared Appium xcuitest toolchain"
    return 0
  fi
  return 1
}

module_simulator_tv_install() {
  module_simulator_native_install
}
