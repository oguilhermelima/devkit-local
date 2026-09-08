#!/usr/bin/env bash

module_tv_adb_doctor() {
  if ! devkit_require_command adb; then
    devkit_set_status missing "adb is not on PATH"
    return 1
  fi
  if ! adb version >/dev/null 2>&1; then
    devkit_set_status misconfigured "adb version failed"
    return 1
  fi
  devkit_set_status ok "adb is available"
  return 0
}

module_tv_adb_install() {
  if devkit_require_command adb; then
    module_tv_adb_doctor
    return $?
  fi
  if devkit_require_command brew; then
    devkit_info "adb is missing. Install Android platform-tools with: brew install android-platform-tools"
  else
    devkit_info "adb is missing. Install Android platform-tools with your OS package manager (for example: apt-get install adb)"
  fi
  devkit_set_status missing "adb is not on PATH"
  return 1
}

devkit_tv_device_state() {
  local serial="$1"
  adb devices | awk -v serial="$serial" '$1 == serial {print $2; exit}'
}

command_tv() {
  local operation="${1:-}" ip="" port=5555 arg serial state
  shift || true
  case "$operation" in
    connect)
      case "${1:-}" in
        -h|--help) printf 'Usage: megabrain tv connect <ip> [--port 5555]\n'; return 0 ;;
      esac
      ip="${1:-}"
      [ -n "$ip" ] || { devkit_error "Usage: megabrain tv connect <ip> [--port 5555]"; return "$MEGABRAIN_USAGE_ERROR"; }
      shift
      while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
          --port) port="${2:-}"; shift 2 ;;
          -h|--help) printf 'Usage: megabrain tv connect <ip> [--port 5555]\n'; return 0 ;;
          *) devkit_error "unknown tv connect option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
        esac
      done
      module_tv_adb_doctor >/dev/null || return 1
      serial="$ip:$port"
      adb connect "$serial" >/dev/null 2>&1 || true
      state="$(devkit_tv_device_state "$serial")"
      if [ "$state" = device ]; then
        printf 'tv: connected (%s)\n' "$serial"
        return 0
      fi
      printf 'tv: not ready (%s: %s)\n' "$serial" "${state:-not listed}"
      return 1
      ;;
    disconnect)
      case "${1:-}" in
        -h|--help) printf 'Usage: megabrain tv disconnect [<ip>]\n'; return 0 ;;
      esac
      ip="${1:-}"
      if [ "$#" -gt 0 ]; then
        shift
        [ "$#" -eq 0 ] || { devkit_error "Usage: megabrain tv disconnect [<ip>]"; return "$MEGABRAIN_USAGE_ERROR"; }
        module_tv_adb_doctor >/dev/null || return 1
        adb disconnect "$ip"
      else
        module_tv_adb_doctor >/dev/null || return 1
        adb disconnect
      fi
      ;;
    -h|--help|"") printf 'Usage: megabrain tv connect <ip> [--port 5555] | megabrain tv disconnect [<ip>]\n' ;;
    *) devkit_error "unknown tv command: $operation"; return "$MEGABRAIN_USAGE_ERROR" ;;
  esac
}
