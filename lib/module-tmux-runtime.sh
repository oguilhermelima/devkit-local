#!/usr/bin/env bash

DEVKIT_TMUX_SETTLE_ATTEMPTS="${DEVKIT_TMUX_SETTLE_ATTEMPTS:-20}"
DEVKIT_TMUX_SETTLE_SECONDS="${DEVKIT_TMUX_SETTLE_SECONDS:-0.1}"
DEVKIT_TMUX_ENTER_RETRIES="${DEVKIT_TMUX_ENTER_RETRIES:-3}"
DEVKIT_TMUX_ENTER_WAIT="${DEVKIT_TMUX_ENTER_WAIT:-0.5}"
DEVKIT_TMUX_TUNE_START='# >>> devkit tmux tuning >>>'
DEVKIT_TMUX_TUNE_END='# <<< devkit tmux tuning <<<'
DEVKIT_TMUX_TUNE_SOURCE='source-file ~/.devkit/tmux/devkit.tmux.conf'

devkit_tmux_available() {
  devkit_require_command tmux
}

devkit_tmux_version() {
  tmux -V 2>/dev/null
}

devkit_tmux_session_exists() {
  local session="$1"
  tmux has-session -t "$session" 2>/dev/null
}

devkit_tmux_wait_for_session() {
  local session="$1" attempt
  for ((attempt = 1; attempt <= DEVKIT_TMUX_SETTLE_ATTEMPTS; attempt++)); do
    devkit_tmux_session_exists "$session" && return 0
    sleep "$DEVKIT_TMUX_SETTLE_SECONDS"
  done
  return 1
}

devkit_tmux_first_pane() {
  local session="$1"
  tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | head -n 1
}

devkit_tmux_settle_pane() {
  local pane="$1" attempt
  for ((attempt = 1; attempt <= DEVKIT_TMUX_SETTLE_ATTEMPTS; attempt++)); do
    tmux display-message -p -t "$pane" '#{pane_current_command}' >/dev/null 2>&1 || return 1
    sleep "$DEVKIT_TMUX_SETTLE_SECONDS"
  done
}

devkit_tmux_existing_session_for_worktree() {
  local worktree_path="$1" meta_path meta session state
  DEVKIT_TMUX_EXISTING_SESSION=""
  for meta_path in "$DEVKIT_DISPATCH_DIR"/*/meta.json; do
    [ -f "$meta_path" ] || continue
    meta="$(cat "$meta_path")"
    session="$(printf '%s' "$meta" | jq -r --arg path "$worktree_path" '
      select(.runtime == "tmux" and .worktreePath == $path and .state != "closed") | .tmuxSession // empty' 2>/dev/null)"
    [ -n "$session" ] || continue
    state="$(printf '%s' "$meta" | jq -r '.state // empty')"
    case "$state" in failed|orphaned) continue ;; esac
    if devkit_tmux_session_exists "$session"; then
      DEVKIT_TMUX_EXISTING_SESSION="$session"
      return 0
    fi
  done
  return 1
}

devkit_tmux_host_terminal_for_session() {
  local session="$1" meta_path meta
  for meta_path in "$DEVKIT_DISPATCH_DIR"/*/meta.json; do
    [ -f "$meta_path" ] || continue
    meta="$(cat "$meta_path")"
    if printf '%s' "$meta" | jq -e --arg session "$session" '.runtime == "tmux" and .tmuxSession == $session' >/dev/null 2>&1; then
      printf '%s\n' "$(printf '%s' "$meta" | jq -r '.terminalId // empty')"
      return 0
    fi
  done
  return 1
}

devkit_tmux_split_pane() {
  local session="$1" worktree_path
  worktree_path="$2"
  tmux split-window -t "$session" -c "$worktree_path" -P -F '#{pane_id}' 2>/dev/null
}

devkit_tmux_send_agent() {
  local pane="$1" command_text="$2" attempt current
  tmux send-keys -t "$pane" -l "$command_text" || return 1
  # Enter is deliberately a separate call; some host terminal layers lose it when combined with text.
  for ((attempt = 1; attempt <= DEVKIT_TMUX_ENTER_RETRIES; attempt++)); do
    tmux send-keys -t "$pane" Enter || return 1
    sleep "$DEVKIT_TMUX_ENTER_WAIT"
    current="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)"
    case "$current" in
      bash|zsh|sh|dash|fish|ksh|tcsh|login|-zsh|-bash) : ;;
      *) return 0 ;;
    esac
  done
  devkit_error "tmux did not submit the agent command in pane $pane after $DEVKIT_TMUX_ENTER_RETRIES Enter attempts"
  return 1
}

devkit_tmux_capture_pane() {
  local pane="$1" start="${2:--2000}"
  tmux capture-pane -p -t "$pane" -S "$start"
}

devkit_tmux_agent_output_clean() {
  local pane="$1" output
  output="$(devkit_tmux_capture_pane "$pane" -200 2>/dev/null || true)"
  case "$output" in
    *'0;276;0c'*|*xterm.js*) return 1 ;;
  esac
}

devkit_tmux_send_text() {
  local pane="$1" text="$2" attempt before after
  before="$(devkit_tmux_capture_pane "$pane" -20 2>/dev/null || true)"
  tmux send-keys -t "$pane" -l "$text" || return 1
  # Keep Enter separate and retry only after checking that the composer changed.
  for ((attempt = 1; attempt <= DEVKIT_TMUX_ENTER_RETRIES; attempt++)); do
    tmux send-keys -t "$pane" Enter || return 1
    sleep "$DEVKIT_TMUX_ENTER_WAIT"
    after="$(devkit_tmux_capture_pane "$pane" -20 2>/dev/null || true)"
    [ "$after" != "$before" ] && return 0
  done
  devkit_error "tmux did not submit input in pane $pane after $DEVKIT_TMUX_ENTER_RETRIES Enter attempts"
  return 1
}

devkit_tmux_apply_config() {
  local session="$1"
  devkit_tmux_session_exists "$session" || return 1
  tmux set-option -t "$session" mouse on >/dev/null || return 1
  tmux set-option -t "$session" status off >/dev/null || return 1
  tmux set-option -t "$session" pane-active-border-style 'fg=green,bold' >/dev/null || return 1
  tmux set-option -t "$session" escape-time 0 >/dev/null || return 1
}

devkit_tmux_config_applied() {
  local session option value
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    case "$session" in devkit-*) ;; *) continue ;; esac
    option="$(tmux show-options -t "$session" -v mouse 2>/dev/null || true)"
    [ "$option" = on ] || continue
    option="$(tmux show-options -t "$session" -v status 2>/dev/null || true)"
    [ "$option" = off ] || continue
    option="$(tmux show-options -t "$session" -v escape-time 2>/dev/null || true)"
    [ "$option" = 0 ] || continue
    value="$(tmux show-options -t "$session" -v pane-active-border-style 2>/dev/null || true)"
    [ -n "$value" ] && return 0
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
  return 1
}

devkit_tmux_tuning_repo_path() {
  printf '%s/tmux/devkit.tmux.conf\n' "$DEVKIT_ROOT"
}

devkit_tmux_tuning_install_path() {
  printf '%s/.devkit/tmux/devkit.tmux.conf\n' "$HOME"
}

devkit_tmux_tuning_config_path() {
  printf '%s/.tmux.conf\n' "$HOME"
}

devkit_tmux_tuning_validate_config() {
  local config="$1" starts ends
  [ -e "$config" ] || return 0
  [ -f "$config" ] || {
    devkit_error "tmux config exists but is not a regular file: $config"
    return 1
  }
  starts="$(grep -Fxc "$DEVKIT_TMUX_TUNE_START" "$config" 2>/dev/null || true)"
  ends="$(grep -Fxc "$DEVKIT_TMUX_TUNE_END" "$config" 2>/dev/null || true)"
  if [ "$starts" -ne "$ends" ]; then
    devkit_error "tmux config has an incomplete devkit tuning block: $config"
    return 1
  fi
}

devkit_tmux_tuning_block_present() {
  local config="$1" starts ends source_lines
  [ -f "$config" ] || return 1
  starts="$(grep -Fxc "$DEVKIT_TMUX_TUNE_START" "$config" 2>/dev/null || true)"
  ends="$(grep -Fxc "$DEVKIT_TMUX_TUNE_END" "$config" 2>/dev/null || true)"
  source_lines="$(grep -Fxc "$DEVKIT_TMUX_TUNE_SOURCE" "$config" 2>/dev/null || true)"
  [ "$starts" -eq 1 ] && [ "$ends" -eq 1 ] && [ "$source_lines" -eq 1 ]
}

devkit_tmux_tuning_installed_current() {
  cmp -s "$(devkit_tmux_tuning_repo_path)" "$(devkit_tmux_tuning_install_path)"
}

devkit_tmux_tuning_next_backup_path() {
  local config="$1" stamp path suffix=1
  [ -f "$config" ] || return 0
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  path="${config}.devkit-backup-${stamp}"
  # Never overwrite an existing backup from an earlier apply.
  while [ -e "$path" ]; do
    path="${config}.devkit-backup-${stamp}-${suffix}"
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$path"
}

devkit_tmux_tuning_backup_paths() {
  local path
  for path in "$HOME"/.tmux.conf.devkit-backup-*; do
    [ -f "$path" ] || continue
    printf '%s\n' "$path"
  done
}

devkit_tmux_tuning_backup_paths_json() {
  devkit_tmux_tuning_backup_paths | jq -Rsc 'split("\n") | map(select(length > 0))'
}

devkit_tmux_tuning_server_running() {
  devkit_require_command tmux || return 1
  tmux list-sessions >/dev/null 2>&1
}

devkit_tmux_tuning_server_has_rgb() {
  local features
  features="$(tmux show-options -gqv terminal-features 2>/dev/null || true)"
  printf '%s\n' "$features" | tr ',' '\n' | grep -Eq '(^|:)RGB($|:)'
}

devkit_tmux_tuning_install_file() {
  local repo="$1" install_path temp
  install_path="$(devkit_tmux_tuning_install_path)"
  mkdir -p "$(dirname "$install_path")" || return 1
  temp="$(mktemp "${install_path}.XXXXXX")" || return 1
  if ! cp "$repo" "$temp" || ! mv -f "$temp" "$install_path"; then
    rm -f "$temp"
    return 1
  fi
}

devkit_tmux_tuning_write_config() {
  local config="$1" temp
  temp="$(mktemp "${config}.XXXXXX")" || return 1
  if [ -f "$config" ]; then
    set -- "$config"
  else
    set -- /dev/null
  fi
  if ! awk -v start="$DEVKIT_TMUX_TUNE_START" \
    -v end="$DEVKIT_TMUX_TUNE_END" \
    -v source="$DEVKIT_TMUX_TUNE_SOURCE" '
    $0 == start {
      if (!replaced) {
        print start
        print source
        print end
        replaced = 1
      }
      in_block = 1
      next
    }
    in_block && $0 == end { in_block = 0; next }
    !in_block { print }
    END {
      if (!replaced) {
        print start
        print source
        print end
      }
    }
  ' "$1" >"$temp"; then
    rm -f "$temp"
    return 1
  fi
  if ! mv -f "$temp" "$config"; then
    rm -f "$temp"
    return 1
  fi
}

devkit_tmux_tuning_remove_block() {
  local config="$1" temp
  temp="$(mktemp "${config}.XXXXXX")" || return 1
  if ! awk -v start="$DEVKIT_TMUX_TUNE_START" -v end="$DEVKIT_TMUX_TUNE_END" '
    $0 == start { in_block = 1; next }
    in_block && $0 == end { in_block = 0; next }
    !in_block { print }
  ' "$config" >"$temp"; then
    rm -f "$temp"
    return 1
  fi
  if ! mv -f "$temp" "$config"; then
    rm -f "$temp"
    return 1
  fi
}

devkit_tmux_tuning_apply() {
  local config repo install_path backup_path="${1:-}" server_applied=false
  config="$(devkit_tmux_tuning_config_path)"
  repo="$(devkit_tmux_tuning_repo_path)"
  install_path="$(devkit_tmux_tuning_install_path)"
  [ -f "$repo" ] || { devkit_error "tmux tuning file is missing: $repo"; return 1; }
  devkit_tmux_tuning_validate_config "$config" || return 1
  if [ -f "$config" ]; then
    [ -n "$backup_path" ] || backup_path="$(devkit_tmux_tuning_next_backup_path "$config")"
    while [ -e "$backup_path" ]; do
      backup_path="$(devkit_tmux_tuning_next_backup_path "$config")"
    done
    cp -p "$config" "$backup_path" || {
      devkit_error "could not back up $config to $backup_path"
      return 1
    }
  fi
  devkit_tmux_tuning_install_file "$repo" || {
    devkit_error "could not install tmux tuning file at $install_path"
    return 1
  }
  if ! devkit_tmux_tuning_write_config "$config"; then
    devkit_error "could not update $config"
    return 1
  fi
  if devkit_tmux_tuning_server_running; then
    if tmux source-file "$install_path" >/dev/null 2>&1; then
      server_applied=true
    else
      devkit_error "could not apply tmux tuning to the running server"
      return 1
    fi
  fi
  DEVKIT_TMUX_TUNE_BACKUP_PATH="$backup_path"
  DEVKIT_TMUX_TUNE_SERVER_APPLIED="$server_applied"
}

devkit_tmux_tuning_revert() {
  local config
  config="$(devkit_tmux_tuning_config_path)"
  [ -e "$config" ] || return 0
  devkit_tmux_tuning_validate_config "$config" || return 1
  devkit_tmux_tuning_block_present "$config" || return 0
  devkit_tmux_tuning_remove_block "$config" || {
    devkit_error "could not remove the devkit tuning block from $config"
    return 1
  }
  DEVKIT_TMUX_TUNE_REVERTED=true
}

devkit_tmux_tuning_print_plan() {
  local config="$1" backup_path="$2"
  printf 'Recommended tmux tuning:\n'
  printf '  - enable RGB and host-terminal parity options\n'
  printf '  - raise history, enable focus, passthrough, clipboard, mouse, and titles\n'
  printf '  - make splits and new windows inherit the current pane path\n'
  printf '  - install the shared tuning file at %s\n' "$(devkit_tmux_tuning_install_path)"
  if [ -n "$backup_path" ]; then
    printf '  - back up %s to %s\n' "$config" "$backup_path"
  else
    printf '  - no backup: %s does not exist\n' "$config"
  fi
}

devkit_tmux_tune() {
  local yes=false dry_run=false revert=false json=false arg config backup_path answer input
  local block_present=false installed_current=false server_running=false server_rgb=false
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --yes) yes=true; shift ;;
      --dry-run) dry_run=true; shift ;;
      --revert) revert=true; shift ;;
      --json) json=true; shift ;;
      -h|--help)
        printf 'Usage: devkit tmux tune [--yes] [--dry-run] [--revert] [--json]\n'
        return 0
        ;;
      *)
        devkit_error "unknown tmux tune option: $arg"
        return "$DEVKIT_USAGE_ERROR"
        ;;
    esac
  done
  if [ "$dry_run" = true ] && [ "$revert" = true ]; then
    devkit_error '--dry-run and --revert cannot be combined'
    return "$DEVKIT_USAGE_ERROR"
  fi
  config="$(devkit_tmux_tuning_config_path)"
  devkit_tmux_tuning_block_present "$config" && block_present=true
  devkit_tmux_tuning_installed_current && installed_current=true
  if devkit_tmux_tuning_server_running; then
    server_running=true
    devkit_tmux_tuning_server_has_rgb && server_rgb=true
  fi
  if [ "$dry_run" = true ]; then
    if [ "$json" = true ]; then
      jq -n --arg config "$config" --arg installed "$(devkit_tmux_tuning_install_path)" \
        --argjson block "$block_present" --argjson installedCurrent "$installed_current" \
        --argjson serverRunning "$server_running" --argjson serverRgb "$server_rgb" \
        '{ok: true, action: "dry-run", changed: false, wouldChange: (($block | not) or ($installedCurrent | not)), configPath: $config, installedPath: $installed, blockPresent: $block, installedCurrent: $installedCurrent, serverRunning: $serverRunning, serverRgb: $serverRgb}'
    else
      devkit_tmux_tuning_print_plan "$config" "$(devkit_tmux_tuning_next_backup_path "$config")"
      printf '  - dry-run: no files or tmux server options will change\n'
    fi
    return 0
  fi
  if [ "$revert" = true ]; then
    if ! devkit_tmux_tuning_revert; then
      [ "$json" = true ] && jq -n --arg action revert '{ok: false, action: $action, error: "could not revert tmux tuning"}'
      return 1
    fi
    if [ "$json" = true ]; then
      jq -n --arg config "$config" --argjson backups "$(devkit_tmux_tuning_backup_paths_json)" \
        --argjson changed "${DEVKIT_TMUX_TUNE_REVERTED:-false}" \
        '{ok: true, action: "revert", changed: $changed, configPath: $config, backupPaths: $backups}'
    else
      printf 'tmux tuning reverted from %s\n' "$config"
      printf 'backups remain available:\n'
      devkit_tmux_tuning_backup_paths | sed 's/^/  /'
    fi
    return 0
  fi
  if [ "$yes" != true ]; then
    backup_path="$(devkit_tmux_tuning_next_backup_path "$config")"
    if [ "$json" = true ]; then
      jq -n --arg action apply '{ok: true, action: $action, status: "confirmation-required", changed: false}'
      return 0
    fi
    if [ -t 0 ]; then
      input=/dev/stdin
    elif [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then
      input=/dev/tty
    else
      printf 'tmux tuning skipped (non-interactive); run: devkit tmux tune --yes\n'
      return 0
    fi
    devkit_tmux_tuning_print_plan "$config" "$backup_path"
    printf 'Apply recommended tmux tuning? [y/N] '
    read -r answer <"$input" || answer=''
    case "$answer" in
      y|Y|yes|YES|Yes) ;;
      *) printf 'tmux tuning skipped; run: devkit tmux tune --yes\n'; return 0 ;;
    esac
  fi
  if ! devkit_tmux_tuning_apply "${backup_path:-}"; then
    [ "$json" = true ] && jq -n --arg action apply '{ok: false, action: $action, error: "could not apply tmux tuning"}'
    return 1
  fi
  if [ "$json" = true ]; then
    jq -n --arg config "$config" --arg installed "$(devkit_tmux_tuning_install_path)" \
      --arg backup "${DEVKIT_TMUX_TUNE_BACKUP_PATH:-}" \
      --argjson serverApplied "${DEVKIT_TMUX_TUNE_SERVER_APPLIED:-false}" \
      '{ok: true, action: "apply", changed: true, configPath: $config, installedPath: $installed, backupPath: (if $backup == "" then null else $backup end), serverApplied: $serverApplied}'
  else
    printf 'tmux tuning applied\n'
    if [ -n "${DEVKIT_TMUX_TUNE_BACKUP_PATH:-}" ]; then
      printf 'backup: %s\n' "$DEVKIT_TMUX_TUNE_BACKUP_PATH"
    else
      printf 'backup: none (%s did not exist)\n' "$config"
    fi
    if [ "${DEVKIT_TMUX_TUNE_SERVER_APPLIED:-false}" = true ]; then
      printf 'running tmux server: updated\n'
    else
      printf 'running tmux server: none\n'
    fi
  fi
}

command_tmux() {
  local subcommand="${1:-}"
  shift || true
  case "$subcommand" in
    tune) devkit_tmux_tune "$@" ;;
    -h|--help|"")
      printf 'Usage: devkit tmux tune [--yes] [--dry-run] [--revert] [--json]\n'
      ;;
    *) devkit_error "unknown tmux command: $subcommand"; return "$DEVKIT_USAGE_ERROR" ;;
  esac
}

module_tmux_runtime_doctor() {
  local version enabled detail
  if ! devkit_tmux_available; then
    devkit_set_status missing "tmux is not on PATH"
    return 1
  fi
  version="$(devkit_tmux_version)"
  if devkit_runtime_enabled; then
    enabled="enabled"
  else
    enabled="disabled"
  fi
  detail="$version; runtime $enabled"
  if devkit_tmux_config_applied; then
    detail="$detail; devkit session config applied"
  else
    detail="$detail; devkit session config will apply when a session launches"
  fi
  if [ "$enabled" = enabled ]; then
    devkit_set_status ok "$detail"
    return 0
  fi
  devkit_set_status misconfigured "$detail; install tmux-runtime to enable it"
  return 1
}

module_tmux_runtime_install() {
  if devkit_tmux_available; then
    devkit_state_set tmux-runtime true "tmux runtime enabled" || return 1
    module_tmux_runtime_doctor
    return $?
  fi
  case "$(uname -s 2>/dev/null || printf unknown)" in
    Darwin)
      if devkit_require_command brew; then
        brew install tmux || return 1
      else
        devkit_error "tmux is missing. Install it with: brew install tmux"
        devkit_set_status missing "tmux is not on PATH"
        return 1
      fi
      ;;
    Linux)
      devkit_error "tmux is missing. Install it with your package manager, for example: sudo apt-get install tmux"
      devkit_set_status missing "tmux is not on PATH"
      return 1
      ;;
    *)
      devkit_error "tmux is missing. Install tmux with your operating system package manager"
      devkit_set_status missing "tmux is not on PATH"
      return 1
      ;;
  esac
  devkit_state_set tmux-runtime true "tmux runtime enabled" || return 1
  module_tmux_runtime_doctor
}
