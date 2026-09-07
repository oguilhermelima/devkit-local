#!/usr/bin/env bash

set -u

REPOSITORY_URL="https://github.com/oguilhermelima/devkit-local"
REPOSITORY_REF="main"
TARBALL_URL="$REPOSITORY_URL/archive/refs/heads/$REPOSITORY_REF.tar.gz"
INSTALL_ROOT="$HOME/.devkit-local"
SKILL_MODE=""
AGENTS_MODE=""
AGENTS_REQUEST=""
AVAILABLE_AGENTS=""
SELECTED_AGENTS=""
ASSUME_YES=false
SOURCE_ROOT=""
SUMMARY_LINES=()

installer_error() {
  printf 'install.sh: %s\n' "$*" >&2
}

installer_summary() {
  SUMMARY_LINES+=("$*")
}

installer_usage() {
  cat <<'EOF'
Usage: ./install.sh [--agents claude,codex,agy|none] [--skill none|global|project]
                    [--agents-md none|global|project] [--yes]

--agents selects installed agent CLIs to configure. With --skill global, Claude is
registered as a user-level marketplace plugin; --skill project keeps the legacy
project-local bare skill copy because Claude plugins have no project scope.
EOF
}

installer_parse_args() {
  local arg value
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --skill|--agents-md)
        [ "$#" -gt 1 ] || { installer_error "$arg requires none, global, or project"; return 2; }
        value="$2"
        case "$value" in
          none|global|project) ;;
          *) installer_error "$arg must be none, global, or project"; return 2 ;;
        esac
        if [ "$arg" = --skill ]; then
          SKILL_MODE="$value"
        else
          AGENTS_MODE="$value"
        fi
        shift 2
        ;;
      --agents)
        [ "$#" -gt 1 ] || { installer_error "$arg requires a comma-separated list of claude, codex, agy, or none"; return 2; }
        AGENTS_REQUEST="$2"
        shift 2
        ;;
      --yes) ASSUME_YES=true; shift ;;
      -h|--help) installer_usage; exit 0 ;;
      *) installer_error "unknown option: $arg"; installer_usage >&2; return 2 ;;
    esac
  done
}

installer_detect_agents() {
  local agent
  AVAILABLE_AGENTS=""
  for agent in claude codex agy; do
    if command -v "$agent" >/dev/null 2>&1; then
      if [ -n "$AVAILABLE_AGENTS" ]; then
        AVAILABLE_AGENTS="$AVAILABLE_AGENTS,$agent"
      else
        AVAILABLE_AGENTS="$agent"
      fi
    fi
  done
}

installer_list_contains() {
  local list="$1" candidate="$2" item
  [ -n "$list" ] || return 1
  IFS=',' read -r -a _installer_items <<<"$list"
  for item in "${_installer_items[@]}"; do
    [ "$item" = "$candidate" ] && return 0
  done
  return 1
}

installer_select_agents() {
  local raw="$AGENTS_REQUEST" token normalized
  local -a requested=()
  SELECTED_AGENTS=""
  if [ -z "$raw" ]; then
    if [ -z "$AVAILABLE_AGENTS" ]; then
      installer_error "no supported agent CLI (claude, codex, or agy) is installed; pass --agents none or install one"
      return 1
    fi
    if [ -t 0 ]; then
      read -r -p "Configure agent CLIs [$AVAILABLE_AGENTS,none] (default: $AVAILABLE_AGENTS): " raw || return 1
    elif [ -r /dev/tty ]; then
      read -r -p "Configure agent CLIs [$AVAILABLE_AGENTS,none] (default: $AVAILABLE_AGENTS): " raw </dev/tty || return 1
    else
      installer_error "agent selection requires --agents in a non-interactive shell"
      return 1
    fi
    [ -n "$raw" ] || raw="$AVAILABLE_AGENTS"
  fi
  IFS=',' read -r -a requested <<<"$raw"
  for token in "${requested[@]}"; do
    normalized="$(printf '%s' "$token" | tr -d '[:space:]')"
    case "$normalized" in
      none)
        [ "${#requested[@]}" -eq 1 ] || { installer_error "none cannot be combined with another agent"; return 2; }
        SELECTED_AGENTS=""
        return 0
        ;;
      claude|codex|agy)
        installer_list_contains "$AVAILABLE_AGENTS" "$normalized" || {
          installer_error "$normalized is not installed or is not available on PATH"
          return 1
        }
        if ! installer_list_contains "$SELECTED_AGENTS" "$normalized"; then
          if [ -n "$SELECTED_AGENTS" ]; then
            SELECTED_AGENTS="$SELECTED_AGENTS,$normalized"
          else
            SELECTED_AGENTS="$normalized"
          fi
        fi
        ;;
      *)
        installer_error "unsupported agent '$normalized'; choose from claude, codex, agy, or none"
        return 2
        ;;
    esac
  done
  [ -n "$SELECTED_AGENTS" ] || { installer_error "choose at least one installed agent or none"; return 2; }
}

installer_source_root() {
  local script_dir="" checkout_dir="$INSTALL_ROOT" temp_dir archive extract_dir payload
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  fi
  if [ -n "$script_dir" ] && [ -x "$script_dir/devkit" ] && [ -d "$script_dir/lib" ]; then
    SOURCE_ROOT="$script_dir"
    return 0
  fi
  if [ -x "$checkout_dir/devkit" ] && [ -d "$checkout_dir/lib" ]; then
    SOURCE_ROOT="$checkout_dir"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { installer_error "curl is required to install from curl"; return 1; }
  command -v tar >/dev/null 2>&1 || { installer_error "tar is required to install from curl"; return 1; }
  if [ -x "$checkout_dir/devkit" ] && [ -d "$checkout_dir/lib" ]; then
    SOURCE_ROOT="$checkout_dir"
    return 0
  fi
  [ ! -e "$checkout_dir" ] || { installer_error "install path exists but is not a devkit install: $checkout_dir"; return 1; }
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/devkit-local.XXXXXX")" || { installer_error "could not create a temporary directory"; return 1; }
  archive="$temp_dir/devkit-local.tar.gz"
  extract_dir="$temp_dir/extract"
  mkdir -p "$extract_dir" || { rm -rf "$temp_dir"; return 1; }
  if ! curl -fsSL -o "$archive" "$TARBALL_URL"; then
    rm -rf "$temp_dir"
    installer_error "could not download $TARBALL_URL"
    return 1
  fi
  if ! tar -xzf "$archive" -C "$extract_dir"; then
    rm -rf "$temp_dir"
    installer_error "could not extract $TARBALL_URL"
    return 1
  fi
  payload="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [ -n "$payload" ] || { rm -rf "$temp_dir"; installer_error "downloaded archive has no top-level directory"; return 1; }
  mkdir -p "$checkout_dir" || { rm -rf "$temp_dir"; installer_error "could not create $checkout_dir"; return 1; }
  cp -R "$payload/." "$checkout_dir/" || { rm -rf "$temp_dir"; installer_error "could not install extracted archive at $checkout_dir"; return 1; }
  rm -rf "$temp_dir"
  SOURCE_ROOT="$checkout_dir"
}

installer_prompt_mode() {
  local label="$1" value=""
  while true; do
    if [ -t 0 ]; then
      read -r -p "$label [none/global/project]: " value || return 1
    elif [ -r /dev/tty ]; then
      read -r -p "$label [none/global/project]: " value </dev/tty || return 1
    else
      installer_error "$label requires --skill or --agents-md in a non-interactive shell"
      return 1
    fi
    case "$value" in
      none|global|project) PROMPT_MODE="$value"; return 0 ;;
      *) installer_error "choose none, global, or project" ;;
    esac
  done
}

installer_warn_path() {
  local bin_dir="$HOME/.local/bin"
  case ":${PATH:-}:" in
    *:"$bin_dir":*) return 0 ;;
  esac
  printf 'Warning: %s is not on PATH. Add it with:\n' "$bin_dir" >&2
  printf 'export PATH="%s:$PATH"\n' "$bin_dir" >&2
  installer_summary "PATH warning displayed for $bin_dir"
  if [ "$ASSUME_YES" = false ] && [ -t 0 ]; then
    read -r -p 'Press Enter to continue: ' _ || true
  fi
}

installer_link_devkit() {
  local bin_dir="$HOME/.local/bin" link="$HOME/.local/bin/devkit"
  mkdir -p "$bin_dir" || { installer_error "could not create $bin_dir"; return 1; }
  if [ -d "$link" ] && [ ! -L "$link" ]; then
    installer_error "refusing to replace directory: $link"
    return 1
  fi
  rm -f "$link" || { installer_error "could not replace $link"; return 1; }
  ln -s "$SOURCE_ROOT/devkit" "$link" || { installer_error "could not link $link"; return 1; }
  installer_summary "symlinked $link to $SOURCE_ROOT/devkit"
  installer_warn_path
}

installer_copy_skill() {
  local destination="$1" existing="" result=""
  existing="$destination/SKILL.md"
  if [ -f "$existing" ]; then
    if cmp -s "$SOURCE_ROOT/skills/devkit/SKILL.md" "$existing"; then
      result="already current"
    else
      result="updated differing existing skill"
    fi
  else
    result="installed"
  fi
  mkdir -p "$destination" || { installer_error "could not create $destination"; return 1; }
  cp -R "$SOURCE_ROOT/skills/devkit/." "$destination/" || { installer_error "could not copy the Claude Code skill"; return 1; }
  installer_summary "Claude Code skill $result at $destination"
}

installer_remove_stale_claude_skill() {
  local stale="$HOME/.claude/skills/devkit"
  if [ -e "$stale" ] || [ -L "$stale" ]; then
    rm -rf "$stale" || { installer_error "could not remove stale Claude skill directory: $stale"; return 1; }
    installer_summary "removed stale Claude skills-dir plugin at $stale"
  fi
}

installer_verify_plugin() {
  local cli="$1"
  case "$cli" in
    claude)
      claude plugin list 2>/dev/null | grep -Eq 'devkit@devkit-local|❯ devkit@devkit-local' || return 1
      ;;
    codex)
      codex plugin list 2>/dev/null | grep -Eq 'devkit@devkit-local[[:space:]]+installed, enabled' || return 1
      ;;
    agy)
      agy plugin list 2>/dev/null | grep -Eq '"name"[[:space:]]*:[[:space:]]*"devkit"' || return 1
      ;;
  esac
}

installer_install_claude() {
  case "$SKILL_MODE" in
    global)
      claude plugin marketplace add "$SOURCE_ROOT" || { installer_error "could not register the Claude marketplace"; return 1; }
      claude plugin install "devkit@devkit-local" || { installer_error "could not install devkit from the Claude marketplace"; return 1; }
      installer_remove_stale_claude_skill || return 1
      installer_verify_plugin claude || { installer_error "Claude plugin list did not show devkit installed and enabled"; return 1; }
      installer_summary "installed Claude plugin devkit@devkit-local"
      ;;
    project)
      installer_copy_skill "$PWD/.claude/skills/devkit"
      ;;
    none)
      installer_summary "skipped Claude plugin installation (--skill none)"
      ;;
  esac
}

installer_install_codex() {
  codex plugin marketplace add "$SOURCE_ROOT" || { installer_error "could not register the Codex marketplace"; return 1; }
  codex plugin add "devkit@devkit-local" || { installer_error "could not install devkit from the Codex marketplace"; return 1; }
  installer_verify_plugin codex || { installer_error "Codex plugin list did not show devkit installed and enabled"; return 1; }
  installer_summary "installed Codex plugin devkit@devkit-local"
}

installer_install_agy() {
  agy plugin install "$SOURCE_ROOT" || { installer_error "could not install the agy plugin from $SOURCE_ROOT"; return 1; }
  installer_verify_plugin agy || { installer_error "agy plugin list did not show devkit installed"; return 1; }
  installer_summary "installed agy plugin from $SOURCE_ROOT"
}

installer_install_plugins() {
  local agent
  [ -n "$SELECTED_AGENTS" ] || return 0
  IFS=',' read -r -a _installer_selected_agents <<<"$SELECTED_AGENTS"
  for agent in "${_installer_selected_agents[@]}"; do
    case "$agent" in
      claude) installer_install_claude || return 1 ;;
      codex) installer_install_codex || return 1 ;;
      agy) installer_install_agy || return 1 ;;
    esac
  done
}

installer_pointer_paragraph() {
  awk 'NF { print; exit }' "$SOURCE_ROOT/AGENTS.md"
}

installer_append_pointer() {
  local file="$1" paragraph="$2" replace_old="${3:-false}" temp
  mkdir -p "$(dirname "$file")" || return 1
  if [ -f "$file" ] && grep -Fqx "$paragraph" "$file"; then
    installer_summary "AGENTS.md pointer already present in $file"
    return 0
  fi
  if [ "$replace_old" = true ] && [ -f "$file" ] && grep -Fq 'Workspaces/local/stack/local/devkit' "$file"; then
    temp="$(mktemp "${file}.XXXXXX")" || return 1
    awk -v old='Workspaces/local/stack/local/devkit' -v replacement="$paragraph" '
      index($0, old) { if (!replaced) { print replacement; replaced = 1 } next }
      { print }
    ' "$file" >"$temp" && mv "$temp" "$file" || { rm -f "$temp"; return 1; }
    installer_summary "replaced old AGENTS.md pointer in $file"
    return 0
  fi
  if [ -s "$file" ] && [ "$(tail -c 1 "$file" | wc -l | tr -d ' ')" -eq 0 ]; then
    printf '\n' >>"$file"
  fi
  printf '%s\n' "$paragraph" >>"$file"
  installer_summary "appended AGENTS.md pointer to $file"
}

installer_install_agents() {
  local paragraph
  paragraph="$(installer_pointer_paragraph)"
  [ -n "$paragraph" ] || { installer_error "could not read the AGENTS.md pointer paragraph"; return 1; }
  case "$AGENTS_MODE" in
    global)
      installer_append_pointer "$HOME/.codex/AGENTS.md" "$paragraph" true || return 1
      installer_append_pointer "$HOME/.agy/AGENTS.md" "$paragraph" true || return 1
      ;;
    project)
      installer_append_pointer "$PWD/AGENTS.md" "$paragraph" || return 1
      ;;
    none) installer_summary "skipped AGENTS.md snippet" ;;
  esac
}

installer_main() {
  installer_parse_args "$@" || return $?
  installer_source_root || return 1
  [ -x "$SOURCE_ROOT/devkit" ] && [ -d "$SOURCE_ROOT/lib" ] || { installer_error "devkit checkout is incomplete: $SOURCE_ROOT"; return 1; }
  [ -f "$SOURCE_ROOT/skills/devkit/SKILL.md" ] || { installer_error "devkit skill is missing from $SOURCE_ROOT"; return 1; }
  [ -f "$SOURCE_ROOT/AGENTS.md" ] || { installer_error "AGENTS.md is missing from $SOURCE_ROOT"; return 1; }
  [ -f "$SOURCE_ROOT/.claude-plugin/plugin.json" ] || { installer_error "Claude plugin manifest is missing from $SOURCE_ROOT"; return 1; }
  [ -f "$SOURCE_ROOT/.codex-plugin/plugin.json" ] || { installer_error "Codex plugin manifest is missing from $SOURCE_ROOT"; return 1; }
  installer_link_devkit || return 1
  installer_detect_agents
  installer_select_agents || return $?
  installer_summary "selected agent CLIs: ${SELECTED_AGENTS:-none}"
  if installer_list_contains "$SELECTED_AGENTS" claude && [ -z "$SKILL_MODE" ]; then
    installer_prompt_mode 'Install the Claude Code skill?' || return 1
    SKILL_MODE="$PROMPT_MODE"
  fi
  installer_install_plugins || return 1
  if [ -z "$AGENTS_MODE" ]; then
    installer_prompt_mode 'Install the AGENTS.md snippet?' || return 1
    AGENTS_MODE="$PROMPT_MODE"
  fi
  installer_install_agents || return 1
  printf '\nInstallation summary:\n'
  printf '%s\n' "${SUMMARY_LINES[@]}"
}

installer_main "$@"
