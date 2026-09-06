#!/usr/bin/env bash

set -u

REPOSITORY_URL="https://github.com/oguilhermelima/devkit-local.git"
SKILL_MODE=""
AGENTS_MODE=""
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
Usage: ./install.sh [--skill none|global|project] [--agents-md none|global|project] [--yes]
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
      --yes) ASSUME_YES=true; shift ;;
      -h|--help) installer_usage; exit 0 ;;
      *) installer_error "unknown option: $arg"; installer_usage >&2; return 2 ;;
    esac
  done
}

installer_source_root() {
  local script_dir="" checkout_dir="$HOME/.devkit-local"
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
  command -v git >/dev/null 2>&1 || { installer_error "git is required to install from curl"; return 1; }
  [ ! -e "$checkout_dir" ] || { installer_error "checkout path exists but is not a devkit checkout: $checkout_dir"; return 1; }
  git clone "$REPOSITORY_URL" "$checkout_dir" || { installer_error "could not clone $REPOSITORY_URL"; return 1; }
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
    if cmp -s "$SOURCE_ROOT/.claude/skills/devkit/SKILL.md" "$existing"; then
      result="already current"
    else
      result="updated differing existing skill"
    fi
  else
    result="installed"
  fi
  mkdir -p "$destination" || { installer_error "could not create $destination"; return 1; }
  cp -R "$SOURCE_ROOT/.claude/skills/devkit/." "$destination/" || { installer_error "could not copy the Claude Code skill"; return 1; }
  installer_summary "Claude Code skill $result at $destination"
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
  [ -f "$SOURCE_ROOT/.claude/skills/devkit/SKILL.md" ] || { installer_error "Claude Code skill is missing from $SOURCE_ROOT"; return 1; }
  [ -f "$SOURCE_ROOT/AGENTS.md" ] || { installer_error "AGENTS.md is missing from $SOURCE_ROOT"; return 1; }
  installer_link_devkit || return 1
  if [ -z "$SKILL_MODE" ]; then
    installer_prompt_mode 'Install the Claude Code skill?' || return 1
    SKILL_MODE="$PROMPT_MODE"
  fi
  case "$SKILL_MODE" in
    global) installer_copy_skill "$HOME/.claude/skills/devkit" || return 1 ;;
    project) installer_copy_skill "$PWD/.claude/skills/devkit" || return 1 ;;
    none) installer_summary "skipped Claude Code skill" ;;
  esac
  if [ -z "$AGENTS_MODE" ]; then
    installer_prompt_mode 'Install the AGENTS.md snippet?' || return 1
    AGENTS_MODE="$PROMPT_MODE"
  fi
  installer_install_agents || return 1
  printf '\nInstallation summary:\n'
  printf '%s\n' "${SUMMARY_LINES[@]}"
}

installer_main "$@"
