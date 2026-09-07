#!/usr/bin/env bash

devkit_hooks_agent_available() {
  case "$1" in
    claude|codex|agy) devkit_require_command "$1" ;;
    cursor) devkit_require_command cursor || devkit_require_command cursor-agent ;;
    *) return 1 ;;
  esac
}

devkit_hooks_config_path() {
  case "$1" in
    claude) printf '%s/.claude/settings.json\n' "$HOME" ;;
    codex) printf '%s/.codex/hooks.json\n' "$HOME" ;;
    agy) printf '%s/.agy/hooks.json\n' "$HOME" ;;
    cursor) printf '%s/.cursor/hooks.json\n' "$HOME" ;;
    *) return 1 ;;
  esac
}

devkit_hooks_event() {
  case "$1" in
    cursor) printf 'afterAgentResponse\n' ;;
    claude|codex|agy) printf 'Stop\n' ;;
    *) return 1 ;;
  esac
}

devkit_hooks_command() {
  local agent="$1" root="${DEVKIT_ROOT:-}"
  if [ -z "$root" ]; then
    root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)" || return 1
  fi
  [ -x "$root/hooks/devkit-turn-end.sh" ] || return 1
  printf 'DEVKIT_HOOK_AGENT=%s %q\n' "$agent" "$root/hooks/devkit-turn-end.sh"
}

devkit_hooks_config_has_entry() {
  local agent="$1" path="$2"
  case "$agent" in
    cursor)
      jq -e '
        def devkit_entry: ((.command? // "") | test("(^|/)devkit-turn-end[.]sh($|[[:space:]])"));
        (.hooks? | type == "object") and
        ((.hooks.afterAgentResponse? // []) | type == "array") and
        any(.hooks.afterAgentResponse[]?; devkit_entry)
      ' "$path" >/dev/null 2>&1
      ;;
    claude|codex|agy)
      jq -e '
        def devkit_entry: ((.command? // "") | test("(^|/)devkit-turn-end[.]sh($|[[:space:]])"));
        (.hooks? | type == "object") and
        ((.hooks.Stop? // []) | type == "array") and
        any(.hooks.Stop[]?; (.hooks? | type == "array") and any(.hooks[]?; devkit_entry))
      ' "$path" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

devkit_hooks_trust_detail() {
  case "$1" in
    codex) printf 'Codex shows a "Hooks need review" prompt on its next launch' ;;
    claude) printf 'a trust prompt can appear on its next launch' ;;
    agy) printf 'a trust prompt can appear on its next launch' ;;
    cursor) printf 'a hook review prompt can appear on its next launch' ;;
    *) printf 'a trust prompt can appear on its next launch' ;;
  esac
}

devkit_hooks_trust_warning() {
  local agent="$1"
  if [ "$agent" = codex ]; then
    devkit_hooks_codex_trust_note
    return 0
  fi
  devkit_info "Warning: $agent may require a one-time human trust action for the devkit hook; $(devkit_hooks_trust_detail "$agent")."
}

devkit_hooks_codex_trust_note() {
  devkit_info ""
  devkit_info "CODEX ACTION REQUIRED: the devkit hook needs one-time trust in Codex."
  devkit_info "Open a plain terminal, run codex, and choose \"Trust all and continue\"."
  devkit_info "Opening Codex through Superset will not complete this step because Superset passes --dangerously-bypass-hook-trust."
}

devkit_hooks_write_config() {
  local agent="$1" path command tmp
  path="$(devkit_hooks_config_path "$agent")" || return 1
  command="$(devkit_hooks_command "$agent")" || return 1
  mkdir -p "$(dirname "$path")" || return 1
  if [ -f "$path" ] && ! jq empty "$path" >/dev/null 2>&1; then
    devkit_error "$agent config is not valid JSON: $path"
    return 1
  fi
  tmp="$(mktemp "${path}.XXXXXX")" || return 1
  if [ "$agent" = cursor ] && [ ! -f "$path" ]; then
    if ! jq -n --arg command "$command" '{hooks: {afterAgentResponse: [{command: $command, timeout: 10}]}, version: 1}' >"$tmp"; then
      rm -f "$tmp"
      return 1
    fi
  elif [ "$agent" = cursor ]; then
    if ! jq --arg command "$command" '
      def devkit_entry: ((.command? // "") | test("(^|/)devkit-turn-end[.]sh($|[[:space:]])"));
      (.hooks // {}) as $hooks |
      if ($hooks | type) != "object" then error("hooks must be an object")
      elif (($hooks.afterAgentResponse // []) | type) != "array" then error("hooks.afterAgentResponse must be an array")
      else
        .hooks = $hooks |
        .hooks.afterAgentResponse = (reduce (($hooks.afterAgentResponse // [])[]) as $entry
          ({seen: false, entries: []};
            if ($entry | devkit_entry) then
              if .seen then . else .entries += [$entry + {command: $command, timeout: 10}] | .seen = true end
            else .entries += [$entry]
            end) | if .seen then .entries else .entries + [{command: $command, timeout: 10}] end) |
        .version = (.version // 1)
      end
    ' "$path" 2>/dev/null >"$tmp"; then
      rm -f "$tmp"
      devkit_error "could not update $agent hooks: $path"
      return 1
    fi
  elif [ ! -f "$path" ]; then
    if ! jq -n --arg command "$command" '{hooks: {Stop: [{hooks: [{type: "command", command: $command}]}]}}' >"$tmp"; then
      rm -f "$tmp"
      return 1
    fi
  elif ! jq --arg command "$command" '
    def devkit_entry: ((.command? // "") | test("(^|/)devkit-turn-end[.]sh($|[[:space:]])"));
    (.hooks // {}) as $hooks |
    if ($hooks | type) != "object" then error("hooks must be an object")
    elif (($hooks.Stop // []) | type) != "array" then error("hooks.Stop must be an array")
    else
      .hooks = $hooks |
      .hooks.Stop = (reduce (($hooks.Stop // [])[]) as $group
        ({seen: false, entries: []};
          ($group.hooks // []) as $nested |
          if ([ $nested[]? | select(devkit_entry) ] | length) == 0 then
            .entries += [$group]
          elif .seen then .
          else
            .entries += [($group | .hooks = (reduce ($nested[]) as $entry
              ({seen: false, entries: []};
                if ($entry | devkit_entry) then
                  if .seen then . else .entries += [$entry + {type: "command", command: $command}] | .seen = true end
                else .entries += [$entry]
                end) | .entries))] |
            .seen = true
          end) | if .seen then .entries else .entries + [{hooks: [{type: "command", command: $command}]}] end)
    end
  ' "$path" 2>/dev/null >"$tmp"; then
    rm -f "$tmp"
    devkit_error "could not update $agent hooks: $path"
    return 1
  fi
  mv -f "$tmp" "$path"
}

devkit_hooks_agent_status() {
  local agent="$1" path command
  if ! devkit_hooks_agent_available "$agent"; then
    printf '%s: not-installed' "$agent"
    return 0
  fi
  path="$(devkit_hooks_config_path "$agent")"
  command="$(devkit_hooks_command "$agent")" || {
    printf '%s: hook-unavailable' "$agent"
    return 1
  }
  if [ ! -f "$path" ]; then
    printf '%s: entry-missing (config absent)' "$agent"
    return 1
  fi
  if ! jq empty "$path" >/dev/null 2>&1; then
    printf '%s: config-invalid' "$agent"
    return 1
  fi
  if devkit_hooks_config_has_entry "$agent" "$path" "$command"; then
    printf '%s: entry-present' "$agent"
    return 0
  fi
  printf '%s: entry-missing' "$agent"
  return 1
}

module_orchestration_hooks_doctor() {
  local agent status details='' rc=0 codex_present=false
  for agent in claude codex agy cursor; do
    status="$(devkit_hooks_agent_status "$agent")" || rc=1
    [ "$status" = 'codex: entry-present' ] && codex_present=true
    if [ -n "$details" ]; then details="$details; "; fi
    details="$details$status"
  done
  [ "$codex_present" = true ] && devkit_hooks_codex_trust_note
  if [ "$rc" -eq 0 ]; then
    devkit_set_status ok "$details; Codex caveat: $(devkit_hooks_trust_detail codex)."
  else
    devkit_set_status misconfigured "$details; Codex caveat: $(devkit_hooks_trust_detail codex)."
  fi
  return "$rc"
}

module_orchestration_hooks_install() {
  local agent codex_present=false
  for agent in claude codex agy cursor; do
    devkit_hooks_agent_available "$agent" || continue
    devkit_hooks_write_config "$agent" || return 1
    if [ "$agent" = codex ]; then
      codex_present=true
    else
      devkit_hooks_trust_warning "$agent"
    fi
  done
  [ "$codex_present" = true ] && devkit_hooks_codex_trust_note
  return 0
}
