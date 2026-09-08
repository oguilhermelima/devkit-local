#!/usr/bin/env bash

DEVKIT_TMUX_SETTLE_ATTEMPTS="${DEVKIT_TMUX_SETTLE_ATTEMPTS:-20}"
DEVKIT_TMUX_SETTLE_SECONDS="${DEVKIT_TMUX_SETTLE_SECONDS:-0.1}"
DEVKIT_TMUX_ENTER_RETRIES="${DEVKIT_TMUX_ENTER_RETRIES:-3}"
DEVKIT_TMUX_ENTER_WAIT="${DEVKIT_TMUX_ENTER_WAIT:-0.5}"
DEVKIT_TMUX_ENTER_TIMEOUT_SECONDS="${DEVKIT_TMUX_ENTER_TIMEOUT_SECONDS:-30}"
DEVKIT_TMUX_MAIN_PANE_PERCENT=50
DEVKIT_TMUX_MAIN_SPLIT_FLAG='-h'
DEVKIT_TMUX_CHILD_SPLIT_FLAG='-v'
DEVKIT_TMUX_TUNE_START='# >>> devkit tmux tuning >>>'
DEVKIT_TMUX_TUNE_END='# <<< devkit tmux tuning <<<'
DEVKIT_TMUX_TUNE_SOURCE='source-file ~/.devkit/tmux/devkit.tmux.conf'
DEVKIT_TMUX_WRAPPER_START='# >>> devkit tmux wrapper >>>'
DEVKIT_TMUX_WRAPPER_END='# <<< devkit tmux wrapper <<<'
DEVKIT_TMUX_WRAPPER_SOURCE='source ~/.devkit/zsh/devkit-agent-tmux.zsh'

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

devkit_tmux_set_state_dir() {
  local session="$1"
  [ -n "$session" ] || return 1
  tmux set-environment -t "$session" DEVKIT_STATE_DIR "$DEVKIT_STATE_DIR"
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
  local pane="$1" attempt current
  for ((attempt = 1; attempt <= DEVKIT_TMUX_SETTLE_ATTEMPTS; attempt++)); do
    current="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)"
    case "$current" in
      bash|zsh|sh|dash|fish|ksh|tcsh|login|-zsh|-bash|"") ;;
      *) return 0 ;;
    esac
    sleep "$DEVKIT_TMUX_SETTLE_SECONDS"
  done
  devkit_error "tmux pane $pane did not start an agent within ${DEVKIT_TMUX_SETTLE_ATTEMPTS} checks"
  return 1
}

devkit_tmux_session_registry_remove() {
  local session="$1"
  [ -n "$session" ] || return 1
  rm -f "$DEVKIT_TMUX_SESSION_DIR/$session.json"
}

devkit_tmux_session_registry_prune() {
  local record_path record session
  for record_path in "$DEVKIT_TMUX_SESSION_DIR"/*.json; do
    [ -f "$record_path" ] || continue
    record="$(cat "$record_path" 2>/dev/null || true)"
    session="$(printf '%s' "$record" | jq -r '.tmuxSession // empty' 2>/dev/null || true)"
    if [ -z "$session" ] || ! devkit_tmux_session_exists "$session"; then
      rm -f "$record_path"
    fi
  done
}

devkit_tmux_registry_session_for_worktree() {
  local worktree_path="$1" target record_path record session directory role
  target="$(cd "$worktree_path" 2>/dev/null && pwd -P || printf '%s' "$worktree_path")"
  devkit_tmux_session_registry_prune
  for record_path in "$DEVKIT_TMUX_SESSION_DIR"/*.json; do
    [ -f "$record_path" ] || continue
    record="$(cat "$record_path" 2>/dev/null || true)"
    session="$(printf '%s' "$record" | jq -r '.tmuxSession // empty' 2>/dev/null || true)"
    directory="$(printf '%s' "$record" | jq -r '.workingDirectory // empty' 2>/dev/null || true)"
    role="$(printf '%s' "$record" | jq -r '.role // empty' 2>/dev/null || true)"
    [ "$role" = main ] || continue
    [ -n "$session" ] && [ -n "$directory" ] || continue
    directory="$(cd "$directory" 2>/dev/null && pwd -P || printf '%s' "$directory")"
    if [ "$directory" = "$target" ] && devkit_tmux_session_exists "$session"; then
      printf '%s\n' "$session"
      return 0
    fi
  done
  return 1
}

devkit_tmux_registry_main_pane_for_session() {
  local session="$1" record_path record pane role
  devkit_tmux_session_exists "$session" || return 1
  devkit_tmux_session_registry_prune
  for record_path in "$DEVKIT_TMUX_SESSION_DIR"/*.json; do
    [ -f "$record_path" ] || continue
    record="$(cat "$record_path" 2>/dev/null || true)"
    role="$(printf '%s' "$record" | jq -r '.role // empty' 2>/dev/null || true)"
    [ "$role" = main ] || continue
    pane="$(printf '%s' "$record" | jq -r --arg session "$session" 'select(.tmuxSession == $session) | .tmuxPane // empty' 2>/dev/null || true)"
    [ -n "$pane" ] || continue
    if tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | grep -Fx "$pane" >/dev/null 2>&1; then
      printf '%s\n' "$pane"
      return 0
    fi
  done
  return 1
}

devkit_tmux_registry_agent_for_session() {
  local session="$1" record_path record agent role
  devkit_tmux_session_exists "$session" || return 1
  devkit_tmux_session_registry_prune
  for record_path in "$DEVKIT_TMUX_SESSION_DIR"/*.json; do
    [ -f "$record_path" ] || continue
    record="$(cat "$record_path" 2>/dev/null || true)"
    role="$(printf '%s' "$record" | jq -r '.role // empty' 2>/dev/null || true)"
    [ "$role" = main ] || continue
    agent="$(printf '%s' "$record" | jq -r --arg session "$session" 'select(.tmuxSession == $session) | .agent // empty' 2>/dev/null || true)"
    [ -n "$agent" ] || continue
    printf '%s\n' "$agent"
    return 0
  done
  return 1
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
  session="$(devkit_tmux_registry_session_for_worktree "$worktree_path" 2>/dev/null || true)"
  if [ -n "$session" ]; then
    DEVKIT_TMUX_EXISTING_SESSION="$session"
    return 0
  fi
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

devkit_tmux_main_pane_width() {
  local session="$1" window_width
  window_width="$(tmux display-message -p -t "$session" '#{window_width}' 2>/dev/null)" || return 1
  [[ "$window_width" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((window_width * DEVKIT_TMUX_MAIN_PANE_PERCENT / 100))"
}

devkit_tmux_resize_main_pane() {
  local session="$1" main_pane width
  main_pane="$(devkit_tmux_registry_main_pane_for_session "$session")" || return 1
  width="$(devkit_tmux_main_pane_width "$session")" || return 1
  # Each split lets tmux redistribute the window, so restore the main chat width.
  tmux resize-pane -t "$main_pane" -x "$width"
}

devkit_tmux_last_right_pane() {
  local session="$1" main_pane main_left
  main_pane="$(devkit_tmux_registry_main_pane_for_session "$session")" || return 1
  main_left="$(tmux display-message -p -t "$main_pane" '#{pane_left}' 2>/dev/null)" || return 1
  [[ "$main_left" =~ ^[0-9]+$ ]] || return 1
  tmux list-panes -t "$session" -F '#{pane_id} #{pane_left} #{pane_top} #{pane_index}' 2>/dev/null |
    awk -v main_left="$main_left" '
      $2 > main_left &&
      (!found || $2 > right_left || ($2 == right_left && $3 > right_top) || ($2 == right_left && $3 == right_top && $4 > right_index)) {
        pane = $1
        right_left = $2
        right_top = $3
        right_index = $4
        found = 1
      }
      END { if (found) print pane }
    '
}

devkit_tmux_split_pane() {
  local session="$1" worktree_path main_pane right_pane target split_flag pane
  worktree_path="$2"
  main_pane="$(devkit_tmux_registry_main_pane_for_session "$session" 2>/dev/null || true)"
  if [ -z "$main_pane" ]; then
    tmux split-window -t "$session" -c "$worktree_path" -P -F '#{pane_id}' 2>/dev/null
    return
  fi
  right_pane="$(devkit_tmux_last_right_pane "$session" 2>/dev/null || true)"
  if [ -n "$right_pane" ]; then
    target="$right_pane"
    split_flag="$DEVKIT_TMUX_CHILD_SPLIT_FLAG"
    pane="$(tmux split-window "$split_flag" -t "$target" -c "$worktree_path" -P -F '#{pane_id}' 2>/dev/null)" || return 1
  else
    target="$main_pane"
    split_flag="$DEVKIT_TMUX_MAIN_SPLIT_FLAG"
    pane="$(tmux split-window "$split_flag" -p "$DEVKIT_TMUX_MAIN_PANE_PERCENT" -t "$target" -c "$worktree_path" -P -F '#{pane_id}' 2>/dev/null)" || return 1
  fi
  devkit_tmux_resize_main_pane "$session" || return 1
  printf '%s\n' "$pane"
}

devkit_tmux_send_agent() {
  local pane="$1" command_text="$2" mode="${3:-command}" attempt=0 current started now elapsed
  if [ "$mode" = prompt ]; then
    devkit_tmux_send_text "$pane" "$command_text"
    return $?
  fi
  tmux send-keys -t "$pane" -l "$command_text" || return 1
  # Enter is deliberately a separate call; some host terminal layers lose it when combined with text.
  case "$DEVKIT_TMUX_ENTER_TIMEOUT_SECONDS" in
    ''|*[!0-9]*) devkit_error "tmux agent launch timeout must be a non-negative number of seconds"; return 1 ;;
  esac
  started="$(date +%s)"
  while :; do
    tmux send-keys -t "$pane" Enter || return 1
    attempt=$((attempt + 1))
    sleep "$DEVKIT_TMUX_ENTER_WAIT"
    current="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)"
    case "$current" in
      bash|zsh|sh|dash|fish|ksh|tcsh|login|-zsh|-bash) : ;;
      *) return 0 ;;
    esac
    now="$(date +%s)"
    elapsed=$((now - started))
    if [ "$elapsed" -ge "$DEVKIT_TMUX_ENTER_TIMEOUT_SECONDS" ]; then
      devkit_error "tmux did not submit the agent command in pane $pane after $attempt Enter attempts and ${DEVKIT_TMUX_ENTER_TIMEOUT_SECONDS}s"
      return 1
    fi
  done
}

devkit_tmux_capture_pane() {
  local pane="$1" start="${2:--2000}"
  tmux capture-pane -p -t "$pane" -S "$start"
}

devkit_tmux_model_substitution_report() {
  local pane="$1" output report
  output="$(devkit_tmux_capture_pane "$pane" -200 2>/dev/null || true)"
  report="$(printf '%s\n' "$output" | grep -iE 'not supported.*model|substitut|using .* instead' | tail -n 1 || true)"
  [ -n "$report" ] || return 1
  printf '%s\n' "$report"
}

devkit_tmux_agent_output_clean() {
  local pane="$1" output
  output="$(devkit_tmux_capture_pane "$pane" -200 2>/dev/null || true)"
  case "$output" in
    *'0;276;0c'*|*xterm.js*) return 1 ;;
  esac
}

devkit_tmux_send_text() {
  local pane="$1" text="$2"
  tmux send-keys -t "$pane" -l "$text" || return 1
  tmux send-keys -t "$pane" Enter
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

devkit_tmux_wrapper_repo_path() {
  printf '%s/zsh/devkit-agent-tmux.zsh\n' "$DEVKIT_ROOT"
}

devkit_tmux_wrapper_install_path() {
  printf '%s/.devkit/zsh/devkit-agent-tmux.zsh\n' "$HOME"
}

devkit_tmux_wrapper_config_path() {
  printf '%s/.zshrc\n' "$HOME"
}

devkit_tmux_wrapper_validate_config() {
  local config="$1" starts ends
  [ -e "$config" ] || return 0
  [ -f "$config" ] || {
    devkit_error "zsh config exists but is not a regular file: $config"
    return 1
  }
  starts="$(grep -Fxc "$DEVKIT_TMUX_WRAPPER_START" "$config" 2>/dev/null || true)"
  ends="$(grep -Fxc "$DEVKIT_TMUX_WRAPPER_END" "$config" 2>/dev/null || true)"
  if [ "$starts" -ne "$ends" ]; then
    devkit_error "zsh config has an incomplete devkit tmux wrapper block: $config"
    return 1
  fi
}

devkit_tmux_wrapper_block_present() {
  local config="$1" starts ends source_lines
  [ -f "$config" ] || return 1
  starts="$(grep -Fxc "$DEVKIT_TMUX_WRAPPER_START" "$config" 2>/dev/null || true)"
  ends="$(grep -Fxc "$DEVKIT_TMUX_WRAPPER_END" "$config" 2>/dev/null || true)"
  source_lines="$(grep -Fxc "$DEVKIT_TMUX_WRAPPER_SOURCE" "$config" 2>/dev/null || true)"
  [ "$starts" -eq 1 ] && [ "$ends" -eq 1 ] && [ "$source_lines" -eq 1 ]
}

devkit_tmux_wrapper_installed_current() {
  cmp -s "$(devkit_tmux_wrapper_repo_path)" "$(devkit_tmux_wrapper_install_path)"
}

devkit_tmux_wrapper_next_backup_path() {
  local config="$1" stamp path suffix=1
  [ -f "$config" ] || return 0
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  path="${config}.devkit-backup-${stamp}"
  while [ -e "$path" ]; do
    path="${config}.devkit-backup-${stamp}-${suffix}"
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$path"
}

devkit_tmux_wrapper_backup_paths() {
  local path
  for path in "$HOME"/.zshrc.devkit-backup-*; do
    [ -f "$path" ] || continue
    printf '%s\n' "$path"
  done
}

devkit_tmux_wrapper_backup_paths_json() {
  devkit_tmux_wrapper_backup_paths | jq -Rsc 'split("\n") | map(select(length > 0))'
}

devkit_tmux_wrapper_install_file() {
  local repo="$1" install_path temp
  install_path="$(devkit_tmux_wrapper_install_path)"
  mkdir -p "$(dirname "$install_path")" || return 1
  temp="$(mktemp "${install_path}.XXXXXX")" || return 1
  if ! cp "$repo" "$temp" || ! mv -f "$temp" "$install_path"; then
    rm -f "$temp"
    return 1
  fi
}

devkit_tmux_wrapper_write_config() {
  local config="$1" temp
  temp="$(mktemp "${config}.XXXXXX")" || return 1
  if [ -f "$config" ]; then
    set -- "$config"
  else
    set -- /dev/null
  fi
  if ! awk -v start="$DEVKIT_TMUX_WRAPPER_START" \
    -v end="$DEVKIT_TMUX_WRAPPER_END" \
    -v source="$DEVKIT_TMUX_WRAPPER_SOURCE" '
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

devkit_tmux_wrapper_remove_block() {
  local config="$1" temp
  temp="$(mktemp "${config}.XXXXXX")" || return 1
  if ! awk -v start="$DEVKIT_TMUX_WRAPPER_START" -v end="$DEVKIT_TMUX_WRAPPER_END" '
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

devkit_tmux_wrapper_apply() {
  local config repo install_path backup_path="${1:-}"
  config="$(devkit_tmux_wrapper_config_path)"
  repo="$(devkit_tmux_wrapper_repo_path)"
  install_path="$(devkit_tmux_wrapper_install_path)"
  [ -f "$repo" ] || { devkit_error "tmux wrapper file is missing: $repo"; return 1; }
  devkit_tmux_wrapper_validate_config "$config" || return 1
  if [ -f "$config" ]; then
    [ -n "$backup_path" ] || backup_path="$(devkit_tmux_wrapper_next_backup_path "$config")"
    while [ -e "$backup_path" ]; do
      backup_path="$(devkit_tmux_wrapper_next_backup_path "$config")"
    done
    cp -p "$config" "$backup_path" || {
      devkit_error "could not back up $config to $backup_path"
      return 1
    }
  fi
  devkit_tmux_wrapper_install_file "$repo" || {
    devkit_error "could not install tmux wrapper file at $install_path"
    return 1
  }
  if ! devkit_tmux_wrapper_write_config "$config"; then
    devkit_error "could not update $config"
    return 1
  fi
  DEVKIT_TMUX_WRAPPER_BACKUP_PATH="$backup_path"
}

devkit_tmux_wrapper_revert() {
  local config
  config="$(devkit_tmux_wrapper_config_path)"
  [ -e "$config" ] || return 0
  devkit_tmux_wrapper_validate_config "$config" || return 1
  devkit_tmux_wrapper_block_present "$config" || return 0
  devkit_tmux_wrapper_remove_block "$config" || {
    devkit_error "could not remove the devkit tmux wrapper block from $config"
    return 1
  }
  DEVKIT_TMUX_WRAPPER_REVERTED=true
}

devkit_tmux_wrapper_print_plan() {
  local config="$1" backup_path="$2"
  printf 'Recommended tmux agent wrapper:\n'
  printf '  - install the wrapper file at %s\n' "$(devkit_tmux_wrapper_install_path)"
  printf '  - add a source block to %s\n' "$config"
  printf 'Warning: this defines shell functions named claude, codex and agy that take over those commands in every new interactive zsh. DEVKIT_NO_TMUX=1 or "command claude" bypasses them.\n'
  if [ -n "$backup_path" ]; then
    printf '  - back up %s to %s\n' "$config" "$backup_path"
  else
    printf '  - no backup: %s does not exist\n' "$config"
  fi
}

devkit_tmux_wrapper() {
  local yes=false dry_run=false revert=false json=false arg config backup_path answer input
  local block_present=false installed_current=false
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --yes) yes=true; shift ;;
      --dry-run) dry_run=true; shift ;;
      --revert) revert=true; shift ;;
      --json) json=true; shift ;;
      -h|--help)
        printf 'Usage: devkit tmux wrapper [--yes] [--dry-run] [--revert] [--json]\n'
        return 0
        ;;
      *)
        devkit_error "unknown tmux wrapper option: $arg"
        return "$DEVKIT_USAGE_ERROR"
        ;;
    esac
  done
  if [ "$dry_run" = true ] && [ "$revert" = true ]; then
    devkit_error '--dry-run and --revert cannot be combined'
    return "$DEVKIT_USAGE_ERROR"
  fi
  config="$(devkit_tmux_wrapper_config_path)"
  devkit_tmux_wrapper_block_present "$config" && block_present=true
  devkit_tmux_wrapper_installed_current && installed_current=true
  if [ "$dry_run" = true ]; then
    if [ "$json" = true ]; then
      jq -n --arg config "$config" --arg installed "$(devkit_tmux_wrapper_install_path)" \
        --argjson block "$block_present" --argjson installedCurrent "$installed_current" \
        '{ok: true, action: "dry-run", changed: false, wouldChange: (($block | not) or ($installedCurrent | not)), configPath: $config, installedPath: $installed, blockPresent: $block, installedCurrent: $installedCurrent}'
    else
      devkit_tmux_wrapper_print_plan "$config" "$(devkit_tmux_wrapper_next_backup_path "$config")"
      printf '  - dry-run: no files will change\n'
    fi
    return 0
  fi
  if [ "$revert" = true ]; then
    if ! devkit_tmux_wrapper_revert; then
      [ "$json" = true ] && jq -n '{ok: false, action: "revert", error: "could not revert tmux wrapper"}'
      return 1
    fi
    if [ "$json" = true ]; then
      jq -n --arg config "$config" --argjson backups "$(devkit_tmux_wrapper_backup_paths_json)" \
        --argjson changed "${DEVKIT_TMUX_WRAPPER_REVERTED:-false}" \
        '{ok: true, action: "revert", changed: $changed, configPath: $config, backupPaths: $backups}'
    else
      printf 'tmux agent wrapper reverted from %s\n' "$config"
      printf 'backups remain available:\n'
      devkit_tmux_wrapper_backup_paths | sed 's/^/  /'
    fi
    return 0
  fi
  if [ "$yes" != true ]; then
    backup_path="$(devkit_tmux_wrapper_next_backup_path "$config")"
    if [ "$json" = true ]; then
      jq -n --arg config "$config" --arg installed "$(devkit_tmux_wrapper_install_path)" \
        '{ok: true, action: "apply", status: "confirmation-required", changed: false, configPath: $config, installedPath: $installed}'
      return 0
    fi
    if [ -t 0 ]; then
      input=/dev/stdin
    elif [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then
      input=/dev/tty
    else
      printf 'tmux agent wrapper skipped (non-interactive); run: devkit tmux wrapper --yes\n'
      return 0
    fi
    devkit_tmux_wrapper_print_plan "$config" "$backup_path"
    printf 'Apply tmux agent wrapper? [y/N] '
    read -r answer <"$input" || answer=''
    case "$answer" in
      y|Y|yes|YES|Yes) ;;
      *) printf 'tmux agent wrapper skipped; run: devkit tmux wrapper --yes\n'; return 0 ;;
    esac
  fi
  if ! devkit_tmux_wrapper_apply "${backup_path:-}"; then
    [ "$json" = true ] && jq -n '{ok: false, action: "apply", error: "could not apply tmux wrapper"}'
    return 1
  fi
  if [ "$json" = true ]; then
    jq -n --arg config "$config" --arg installed "$(devkit_tmux_wrapper_install_path)" \
      --arg backup "${DEVKIT_TMUX_WRAPPER_BACKUP_PATH:-}" \
      '{ok: true, action: "apply", changed: true, configPath: $config, installedPath: $installed, backupPath: (if $backup == "" then null else $backup end)}'
  else
    printf 'tmux agent wrapper applied\n'
    if [ -n "${DEVKIT_TMUX_WRAPPER_BACKUP_PATH:-}" ]; then
      printf 'backup: %s\n' "$DEVKIT_TMUX_WRAPPER_BACKUP_PATH"
    else
      printf 'backup: none (%s did not exist)\n' "$config"
    fi
  fi
}

command_tmux() {
  local subcommand="${1:-}"
  shift || true
  case "$subcommand" in
    tune) devkit_tmux_tune "$@" ;;
    wrapper) devkit_tmux_wrapper "$@" ;;
    -h|--help|"")
      printf 'Usage: devkit tmux tune [--yes] [--dry-run] [--revert] [--json]\n'
      printf '       devkit tmux wrapper [--yes] [--dry-run] [--revert] [--json]\n'
      ;;
    *) devkit_error "unknown tmux command: $subcommand"; return "$DEVKIT_USAGE_ERROR" ;;
  esac
}

module_tmux_runtime_doctor() {
  local version enabled detail tuning_block=false tuning_file=false wrapper_block=false wrapper_file=false server_running=false server_rgb=false
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
  devkit_tmux_tuning_block_present "$(devkit_tmux_tuning_config_path)" && tuning_block=true
  devkit_tmux_tuning_installed_current && tuning_file=true
  devkit_tmux_wrapper_block_present "$(devkit_tmux_wrapper_config_path)" && wrapper_block=true
  devkit_tmux_wrapper_installed_current && wrapper_file=true
  if devkit_tmux_tuning_server_running; then
    server_running=true
    devkit_tmux_tuning_server_has_rgb && server_rgb=true
  fi
  detail="$version; runtime $enabled; tuning block $tuning_block; tuning file current $tuning_file; wrapper block in zshrc $wrapper_block; wrapper file current $wrapper_file"
  if [ "$server_running" = true ]; then
    detail="$detail; running server RGB $server_rgb"
  else
    detail="$detail; running server none"
  fi
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

module_tmux_runtime_offer_tuning() {
  local assume_yes="${1:-false}"
  if [ "$assume_yes" = true ]; then
    devkit_tmux_tune --yes
    return $?
  fi
  if [ -t 0 ] || { [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; }; then
    devkit_tmux_tune
  else
    printf 'tmux tuning skipped (non-interactive); run: devkit tmux tune --yes\n'
  fi
}

module_tmux_runtime_offer_wrapper() {
  local assume_yes="${1:-false}"
  if [ "$assume_yes" = true ]; then
    devkit_tmux_wrapper --yes
    return $?
  fi
  if [ -t 0 ] || { [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; }; then
    devkit_tmux_wrapper
  else
    printf 'tmux agent wrapper skipped (non-interactive); run: devkit tmux wrapper --yes\n'
  fi
}

module_tmux_runtime_install() {
  if devkit_tmux_available; then
    module_tmux_runtime_offer_tuning "${1:-false}" || return 1
    module_tmux_runtime_offer_wrapper "${1:-false}" || return 1
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
  module_tmux_runtime_offer_tuning "${1:-false}" || return 1
  module_tmux_runtime_offer_wrapper "${1:-false}" || return 1
  devkit_state_set tmux-runtime true "tmux runtime enabled" || return 1
  module_tmux_runtime_doctor
}
