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
  tmux new-session -A -s "devkit-${agent}-$$" "$cmd" \; set -g mouse on \; set -g status off
}
claude() { _devkit_tmux_wrap claude "$@" }
codex()  { _devkit_tmux_wrap codex  "$@" }
agy()    { _devkit_tmux_wrap agy    "$@" }
