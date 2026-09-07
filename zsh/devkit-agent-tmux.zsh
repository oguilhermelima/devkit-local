_devkit_tmux_wrap() {
  local agent=$1; shift
  # Orca types the prompt after launch, so tmux startup would race it.
  if [[ -n $TMUX || -n $DEVKIT_NO_TMUX || -n $ORCA_AGENT_LAUNCH_TOKEN || ! -t 0 ]]; then
    command $agent "$@"
    return
  fi
  local a
  for a in "$@"; do
    case $a in
      -p|--print|--output-format|--input-format|exec|--version|-v|--help|-h)
        command $agent "$@"; return ;;
    esac
  done
  local bin=${commands[$agent]}
  [[ -n $bin ]] || { command $agent "$@"; return }
  local -a parts=("$bin" "$@")
  # Join the quoted array so every argument stays in the child command.
  local cmd="${(j: :)${(@q)parts}}"
  local session="devkit-${agent}-$$"
  local pane cwd state_dir sessions_dir record_path temp host
  if ! tmux new-session -d -A -s "$session" -c "$PWD" "$cmd" \; set -g mouse on \; set -g status off; then
    command $agent "$@"
    return
  fi
  pane="$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | head -n 1)"
  cwd="$(pwd -P 2>/dev/null || true)"
  state_dir="${DEVKIT_STATE_DIR:-$HOME/.devkit}"
  sessions_dir="$state_dir/sessions"
  record_path="$sessions_dir/$session.json"
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
  # Registration is best effort so state permissions never block the agent launch.
  if [[ -n $pane && -n $cwd && -n $host ]] && mkdir -p "$sessions_dir" 2>/dev/null; then
    temp="$(mktemp "$sessions_dir/.session.XXXXXX" 2>/dev/null || true)"
    if [[ -n $temp ]] && jq -n \
      --arg tmuxSession "$session" --arg agent "$agent" --arg workingDirectory "$cwd" \
      --arg tmuxPane "$pane" --arg host "$host" --arg createdAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      '{tmuxSession: $tmuxSession, agent: $agent, workingDirectory: $workingDirectory, tmuxPane: $tmuxPane, role: "main", host: $host, createdAt: $createdAt}' \
      >"$temp" 2>/dev/null; then
      mv -f "$temp" "$record_path" 2>/dev/null || rm -f "$temp"
    elif [[ -n $temp ]]; then
      rm -f "$temp"
    fi
  fi
  tmux attach-session -t "$session"
}
claude() {
  if typeset -f _devkit_tmux_wrap >/dev/null 2>&1; then
    _devkit_tmux_wrap claude "$@"
  else
    command claude "$@"
  fi
}
codex() {
  if typeset -f _devkit_tmux_wrap >/dev/null 2>&1; then
    _devkit_tmux_wrap codex "$@"
  else
    command codex "$@"
  fi
}
agy() {
  if typeset -f _devkit_tmux_wrap >/dev/null 2>&1; then
    _devkit_tmux_wrap agy "$@"
  else
    command agy "$@"
  fi
}
