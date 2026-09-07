#!/usr/bin/env bash

DEVKIT_TMUX_SETTLE_ATTEMPTS="${DEVKIT_TMUX_SETTLE_ATTEMPTS:-20}"
DEVKIT_TMUX_SETTLE_SECONDS="${DEVKIT_TMUX_SETTLE_SECONDS:-0.1}"
DEVKIT_TMUX_ENTER_RETRIES="${DEVKIT_TMUX_ENTER_RETRIES:-3}"
DEVKIT_TMUX_ENTER_WAIT="${DEVKIT_TMUX_ENTER_WAIT:-0.5}"

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
