#!/usr/bin/env bash

MEGABRAIN_PLAYWRIGHT_NAME="playwright"
MEGABRAIN_PLAYWRIGHT_COMMAND="@playwright/mcp@latest"

megabrain_playwright_ready() {
  npx -y "$MEGABRAIN_PLAYWRIGHT_COMMAND" --version >/dev/null 2>&1
}

megabrain_agent_mcp_registered() {
  local agent="$1"
  case "$agent" in
    claude)
      claude mcp list 2>/dev/null | grep -Eiq "(^|[[:space:]])$MEGABRAIN_PLAYWRIGHT_NAME([[:space:]]|$).*playwright/mcp|playwright/mcp.*(^|[[:space:]])$MEGABRAIN_PLAYWRIGHT_NAME([[:space:]]|$)"
      ;;
    codex)
      codex mcp list --json 2>/dev/null | jq -e --arg name "$MEGABRAIN_PLAYWRIGHT_NAME" --arg command "$MEGABRAIN_PLAYWRIGHT_COMMAND" 'any(.[]?; .name == $name and ((.transport.command // "") == "npx" or ((.transport.args // []) | join(" ") | contains($command))))' >/dev/null 2>&1
      ;;
    agy)
      agy mcp list 2>/dev/null | grep -Eiq "(^|[[:space:]])$MEGABRAIN_PLAYWRIGHT_NAME([[:space:]]|$).*playwright/mcp|playwright/mcp.*(^|[[:space:]])$MEGABRAIN_PLAYWRIGHT_NAME([[:space:]]|$)"
      ;;
    *) return 1 ;;
  esac
}

megabrain_present_agents() {
  local agent
  for agent in claude codex agy; do
    megabrain_require_command "$agent" && printf '%s\n' "$agent"
  done
}

module_simulator_web_doctor() {
  local agent missing=0
  if ! megabrain_require_command npx; then
    megabrain_set_status missing "npx is not on PATH"
    return 1
  fi
  if ! megabrain_playwright_ready; then
    megabrain_set_status missing "@playwright/mcp could not be executed by npx"
    return 1
  fi
  for agent in $(megabrain_present_agents); do
    case "$agent" in
      codex)
        if ! megabrain_agent_mcp_registered "$agent"; then
          megabrain_set_status misconfigured "playwright MCP is not registered with codex"
          missing=1
        fi
        ;;
      *)
        if ! megabrain_agent_mcp_registered "$agent"; then
          megabrain_set_status misconfigured "playwright MCP is not registered with $agent"
          missing=1
        fi
        ;;
    esac
  done
  if [ "$missing" -ne 0 ]; then
    return 1
  fi
  megabrain_set_status ok "Playwright MCP is runnable and registered with installed agent CLIs"
  return 0
}

megabrain_register_playwright() {
  local agent="$1"
  if megabrain_agent_mcp_registered "$agent"; then
    megabrain_info "$agent: playwright MCP already registered"
    return 0
  fi
  case "$agent" in
    claude)
      claude mcp add --scope user "$MEGABRAIN_PLAYWRIGHT_NAME" npx -y "$MEGABRAIN_PLAYWRIGHT_COMMAND"
      ;;
    codex)
      codex mcp add "$MEGABRAIN_PLAYWRIGHT_NAME" -- npx -y "$MEGABRAIN_PLAYWRIGHT_COMMAND"
      ;;
    agy)
      agy mcp add "$MEGABRAIN_PLAYWRIGHT_NAME" npx -y "$MEGABRAIN_PLAYWRIGHT_COMMAND"
      ;;
    *) return 1 ;;
  esac
}

module_simulator_web_install() {
  local agent rc=0 doctor_rc
  if ! megabrain_playwright_ready; then
    megabrain_error "@playwright/mcp could not be executed by npx"
    megabrain_set_status missing "@playwright/mcp could not be executed by npx"
    return 1
  fi
  for agent in $(megabrain_present_agents); do
    megabrain_register_playwright "$agent" || rc=1
  done
  module_simulator_web_doctor
  doctor_rc=$?
  [ "$rc" -eq 0 ] && [ "$doctor_rc" -eq 0 ]
}
