#!/usr/bin/env bash

DEVKIT_SUPERSET_PROTOCOL="This is a managed devkit dispatch. If you need coordinator input, run devkit ask \"your question\" and stop until the coordinator replies. When the requested work is complete, run devkit done \"short outcome summary\". Do not print protocol markers and do not continue past an unanswered question."
DEVKIT_LAST_DISPATCH=""
DEVKIT_DISPATCH_CLOSE_LAST_PANE=false
DEVKIT_DISPATCH_DELIVERY_BATCH_CAP="${DEVKIT_DISPATCH_DELIVERY_BATCH_CAP:-50}"
DEVKIT_PROMPT_BUDGET_ARGV_BYTES=262144
DEVKIT_PROMPT_BUDGET_TMUX_BYTES=12000

devkit_dispatch_transition_allowed() {
  local axis="$1" from="$2" to="$3"
  case "$axis:$from:$to" in
    dispatch:spawning:spawning|dispatch:spawning:running|dispatch:spawning:failed|dispatch:spawning:closed) return 0 ;;
    dispatch:running:running|dispatch:running:waiting_for_reply|dispatch:running:done|dispatch:running:failed|dispatch:running:orphaned|dispatch:running:stalled|dispatch:running:timeout|dispatch:running:closed) return 0 ;;
    dispatch:waiting_for_reply:waiting_for_reply|dispatch:waiting_for_reply:running|dispatch:waiting_for_reply:done|dispatch:waiting_for_reply:failed|dispatch:waiting_for_reply:orphaned|dispatch:waiting_for_reply:stalled|dispatch:waiting_for_reply:timeout|dispatch:waiting_for_reply:closed) return 0 ;;
    dispatch:done:done|dispatch:done:failed|dispatch:done:orphaned|dispatch:done:closed) return 0 ;;
    dispatch:failed:failed|dispatch:failed:circuit_broken|dispatch:failed:closed) return 0 ;;
    dispatch:orphaned:orphaned|dispatch:orphaned:running|dispatch:orphaned:failed|dispatch:orphaned:circuit_broken|dispatch:orphaned:closed) return 0 ;;
    dispatch:stalled:stalled|dispatch:stalled:failed|dispatch:stalled:circuit_broken|dispatch:stalled:closed) return 0 ;;
    dispatch:timeout:timeout|dispatch:timeout:failed|dispatch:timeout:circuit_broken|dispatch:timeout:closed) return 0 ;;
    dispatch:closed:closed|dispatch:circuit_broken:circuit_broken) return 0 ;;
    process:starting:starting|process:starting:running|process:starting:start-unproven|process:starting:failed|process:starting:stopping|process:starting:stopped|process:starting:stop-unproven|process:starting:abandoned) return 0 ;;
    process:start-unproven:start-unproven|process:start-unproven:running|process:start-unproven:failed|process:start-unproven:stopping|process:start-unproven:stopped|process:start-unproven:stop-unproven|process:start-unproven:abandoned) return 0 ;;
    process:running:running|process:running:succeeded|process:running:failed|process:running:stopping|process:running:stopped|process:running:abandoned) return 0 ;;
    process:stopping:stopping|process:stopping:stopped|process:stopping:stop-unproven|process:stopping:running|process:stopping:failed|process:stopping:abandoned) return 0 ;;
    process:stop-unproven:stop-unproven|process:stop-unproven:failed|process:stop-unproven:stopped|process:stop-unproven:abandoned) return 0 ;;
    process:succeeded:succeeded|process:failed:failed|process:stopped:stopped|process:abandoned:abandoned) return 0 ;;
    terminal:owned:owned|terminal:owned:missing|terminal:owned:retained|terminal:owned:released) return 0 ;;
    terminal:retained:retained|terminal:retained:missing|terminal:retained:released) return 0 ;;
    terminal:missing:missing|terminal:missing:retained|terminal:missing:released|terminal:released:released) return 0 ;;
    *) return 1 ;;
  esac
}

devkit_dispatch_validate_transition() {
  local axis="$1" from="$2" to="$3"
  if ! devkit_dispatch_transition_allowed "$axis" "$from" "$to"; then
    devkit_error "illegal $axis state transition: $from -> $to"
    return 1
  fi
}

devkit_prompt_byte_length() {
  LC_ALL=C printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

devkit_validate_prompt_budget() {
  local text="$1" path="${2:-argv}" label="${3:-prompt}" actual limit
  case "$path" in
    argv) limit="$DEVKIT_PROMPT_BUDGET_ARGV_BYTES" ;;
    tmux) limit="$DEVKIT_PROMPT_BUDGET_TMUX_BYTES" ;;
    *) devkit_error "unknown prompt delivery path: $path"; return 1 ;;
  esac
  actual="$(devkit_prompt_byte_length "$text")"
  if [ "$actual" -gt "$limit" ]; then
    devkit_error "$label is too large for $path delivery: $actual bytes (limit: $limit bytes)"
    return 1
  fi
}

devkit_dispatch_new_id() {
  local candidate suffix counter=0
  suffix="$(date -u '+%Y%m%d%H%M%S')-$$-${RANDOM:-0}"
  candidate="dispatch-$suffix"
  while [ -e "$DEVKIT_DISPATCH_DIR/$candidate" ]; do
    counter=$((counter + 1))
    candidate="dispatch-$suffix-$counter"
  done
  printf '%s\n' "$candidate"
}

devkit_dispatch_default_label() {
  local user_name host_name timestamp
  user_name="${USER:-$(id -un 2>/dev/null || true)}"
  host_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
  timestamp="$(devkit_iso_now)"
  if [ -n "$user_name" ] && [ -n "$host_name" ]; then
    printf '%s@%s %s\n' "$user_name" "$host_name" "$timestamp"
  elif [ -n "$timestamp" ]; then
    printf 'devkit-dispatch-%s\n' "$timestamp"
  else
    printf 'devkit-dispatch\n'
  fi
}

devkit_dispatch_dir() {
  local dispatch_id="$1"
  case "$dispatch_id" in
    ""|*[!A-Za-z0-9._-]*)
      devkit_error "invalid dispatch id: $dispatch_id"
      return 1
      ;;
  esac
  printf '%s/%s\n' "$DEVKIT_DISPATCH_DIR" "$dispatch_id"
}

devkit_dispatch_meta_path() { printf '%s/meta.json\n' "$(devkit_dispatch_dir "$1")"; }
devkit_dispatch_messages_dir() { printf '%s/messages\n' "$(devkit_dispatch_dir "$1")"; }
devkit_dispatch_cursor_path() { printf '%s/cursor.json\n' "$(devkit_dispatch_dir "$1")"; }
devkit_dispatch_deliveries_dir() { printf '%s/deliveries\n' "$(devkit_dispatch_dir "$1")"; }

devkit_dispatch_delivery_path() {
  local dispatch_id="$1" delivery_id="$2"
  case "$delivery_id" in
    ""|*[!A-Za-z0-9._-]*)
      devkit_error "invalid delivery id: $delivery_id"
      return 1
      ;;
  esac
  printf '%s/%s.json\n' "$(devkit_dispatch_deliveries_dir "$dispatch_id")" "$delivery_id"
}

devkit_dispatch_new_delivery_id() {
  local dispatch_id="$1" candidate suffix counter=0 deliveries_dir
  deliveries_dir="$(devkit_dispatch_deliveries_dir "$dispatch_id")" || return 1
  mkdir -p "$deliveries_dir" || return 1
  suffix="$(date -u '+%Y%m%d%H%M%S')-$$-${RANDOM:-0}"
  candidate="delivery-$suffix"
  while [ -e "$deliveries_dir/$candidate.json" ]; do
    counter=$((counter + 1))
    candidate="delivery-$suffix-$counter"
  done
  printf '%s\n' "$candidate"
}

devkit_dispatch_delivery_write() {
  local dispatch_id="$1" delivery_id="$2" consumer="$3" generation="$4" message_seqs="$5"
  local deliveries_dir path tmp now
  deliveries_dir="$(devkit_dispatch_deliveries_dir "$dispatch_id")" || return 1
  mkdir -p "$deliveries_dir" || return 1
  path="$(devkit_dispatch_delivery_path "$dispatch_id" "$delivery_id")" || return 1
  now="$(devkit_iso_now)"
  tmp="$(mktemp "$deliveries_dir/.delivery.XXXXXX")" || return 1
  if ! jq -n \
    --arg id "$delivery_id" --arg dispatchId "$dispatch_id" --arg consumer "$consumer" \
    --argjson generation "$generation" --argjson messageSeqs "$message_seqs" \
    --arg now "$now" \
    '{id: $id, dispatchId: $dispatchId, consumer: $consumer, consumerGeneration: $generation, messageSeqs: $messageSeqs, status: "outstanding", createdAt: $now, updatedAt: $now, acknowledgedAt: null, fencedAt: null}' \
    >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path"
}

devkit_dispatch_meta_write() {
  local dispatch_id="$1" parent_session="$2" parent_host="$3" child_host="$4"
  local workspace_id="$5" terminal_id="$6" worktree_path="$7" branch="$8"
  local agent="$9" label="${10}" state="${11}" model="${12:-}" model_honored="${13:-false}"
  local agent_id="${14:-$agent}" tmux_session="${15:-}" tmux_pane="${16:-}" runtime="${17:-host}" dispatch_dir tmp
  dispatch_dir="$(devkit_dispatch_dir "$dispatch_id")" || return 1
  mkdir -p "$dispatch_dir/messages" "$dispatch_dir/deliveries" || return 1
  devkit_dispatch_cursor_write "$dispatch_id" 0 || return 1
  tmp="$(mktemp "$dispatch_dir/.meta.XXXXXX")" || return 1
  if ! jq -n \
    --arg dispatchId "$dispatch_id" --arg parentSessionId "$parent_session" \
    --arg parentHost "$parent_host" --arg childHost "$child_host" \
    --arg workspaceId "$workspace_id" --arg terminalId "$terminal_id" \
    --arg worktreePath "$worktree_path" --arg branch "$branch" \
    --arg agent "$agent" --arg label "$label" --arg state "$state" \
    --arg model "$model" --arg agentId "$agent_id" --arg runtime "$runtime" \
    --arg tmuxSession "$tmux_session" --arg tmuxPane "$tmux_pane" \
    --argjson modelHonored "$(devkit_bool_json "$model_honored")" \
    --arg now "$(devkit_iso_now)" \
    '{dispatchId: $dispatchId, parentSessionId: $parentSessionId, parentHost: $parentHost, childHost: $childHost, workspaceId: $workspaceId, terminalId: $terminalId, worktreePath: $worktreePath, branch: $branch, agent: $agent, agentId: $agentId, model: $model, modelHonored: $modelHonored, runtime: $runtime, tmuxSession: (if $tmuxSession == "" then null else $tmuxSession end), tmuxPane: (if $tmuxPane == "" then null else $tmuxPane end), label: $label, state: $state, processState: (if $state == "spawning" then "starting" elif $state == "running" then "running" elif $state == "done" then "succeeded" elif $state == "failed" then "failed" elif $state == "closed" then "stopped" else "start-unproven" end), terminalState: "owned", terminalReason: null, failureCount: 0, stage: null, reason: null, reconcileOutcome: null, createdAt: $now, updatedAt: $now}' \
    >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$(devkit_dispatch_meta_path "$dispatch_id")"
  printf '%s\n' "$dispatch_id"
}

devkit_dispatch_meta_read() {
  local dispatch_id="$1" path
  path="$(devkit_dispatch_meta_path "$dispatch_id")" || return 1
  if [ ! -f "$path" ]; then
    devkit_error "dispatch not found: $dispatch_id"
    return 1
  fi
  jq -e . "$path" >/dev/null 2>&1 || { devkit_error "dispatch metadata is not valid JSON: $dispatch_id"; return 1; }
  cat "$path"
}

devkit_dispatch_meta_update_state() {
  local dispatch_id="$1" state="$2" path current_state
  path="$(devkit_dispatch_meta_path "$dispatch_id")" || return 1
  devkit_dispatch_meta_normalize "$dispatch_id" || return 1
  current_state="$(jq -r '.state // empty' "$path" 2>/dev/null || true)"
  [ -n "$current_state" ] || { devkit_error "dispatch state is missing: $dispatch_id"; return 1; }
  devkit_dispatch_validate_transition dispatch "$current_state" "$state" || return 1
  devkit_dispatch_meta_update_fields "$dispatch_id" "$state" "__keep__" "__keep__" "__keep__" "__keep__" "__keep__" "__keep__" "__keep__"
}

devkit_dispatch_meta_update_fields() {
  local dispatch_id="$1" state="$2" process_state="$3" terminal_state="$4"
  local stage="$5" reason="$6" outcome="$7" terminal_reason="$8" failure_count="$9"
  local path current_state current_process current_terminal tmp
  path="$(devkit_dispatch_meta_path "$dispatch_id")" || return 1
  current_state="$(jq -r '.state // empty' "$path" 2>/dev/null || true)"
  current_process="$(jq -r '.processState // empty' "$path" 2>/dev/null || true)"
  current_terminal="$(jq -r '.terminalState // empty' "$path" 2>/dev/null || true)"
  [ "$state" = __keep__ ] || devkit_dispatch_validate_transition dispatch "$current_state" "$state" || return 1
  [ "$process_state" = __keep__ ] || devkit_dispatch_validate_transition process "$current_process" "$process_state" || return 1
  [ "$terminal_state" = __keep__ ] || devkit_dispatch_validate_transition terminal "$current_terminal" "$terminal_state" || return 1
  tmp="$(mktemp "$(devkit_dispatch_dir "$dispatch_id")/.meta.XXXXXX")" || return 1
  if ! jq \
    --arg state "$state" --arg processState "$process_state" --arg terminalState "$terminal_state" \
    --arg stage "$stage" --arg reason "$reason" --arg outcome "$outcome" \
    --arg terminalReason "$terminal_reason" --arg failureCount "$failure_count" --arg now "$(devkit_iso_now)" '
      . as $before
      | if $state == "__keep__" then . else .state = $state end
      | if $processState == "__keep__" then . else .processState = $processState end
      | if $terminalState == "__keep__" then . else .terminalState = $terminalState end
      | if $stage == "__keep__" then . elif $stage == "__clear__" then .stage = null else .stage = $stage end
      | if $reason == "__keep__" then . elif $reason == "__clear__" then .reason = null else .reason = $reason end
      | if $outcome == "__keep__" then . elif $outcome == "__clear__" then .reconcileOutcome = null else .reconcileOutcome = $outcome end
      | if $terminalReason == "__keep__" then . elif $terminalReason == "__clear__" then .terminalReason = null else .terminalReason = $terminalReason end
      | if $failureCount == "__keep__" then . else .failureCount = ($failureCount | tonumber) end
      | if . == $before then . else .updatedAt = $now end
    ' "$path" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path"
}

devkit_dispatch_meta_update_process_state() {
  local dispatch_id="$1" process_state="$2"
  devkit_dispatch_meta_update_fields "$dispatch_id" __keep__ "$process_state" __keep__ __keep__ __keep__ __keep__ __keep__ __keep__
}

devkit_dispatch_meta_update_terminal_state() {
  local dispatch_id="$1" terminal_state="$2"
  devkit_dispatch_meta_update_fields "$dispatch_id" __keep__ __keep__ "$terminal_state" __keep__ __keep__ __keep__ __keep__ __keep__
}

devkit_dispatch_meta_normalize() {
  local dispatch_id="$1" path tmp
  path="$(devkit_dispatch_meta_path "$dispatch_id")" || return 1
  tmp="$(mktemp "$(devkit_dispatch_dir "$dispatch_id")/.meta.XXXXXX")" || return 1
  if ! jq '
    .processState //= (if .state == "spawning" then "starting" elif .state == "running" then "running" elif .state == "done" then "succeeded" elif .state == "failed" then "failed" elif .state == "closed" then "stopped" else "start-unproven" end)
    | .terminalState //= "owned"
    | .terminalReason //= null
    | .failureCount //= 0
    | .stage //= null
    | .reason //= null
    | .reconcileOutcome //= null
  ' "$path" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$path"
  fi
}

devkit_dispatch_reconcile_one() {
  local dispatch_id="$1" meta state process_state terminal_status parent_status failure_count next_state next_process
  local stage reason outcome terminal_state
  DEVKIT_RECONCILE_OUTCOME=unchanged
  devkit_dispatch_meta_normalize "$dispatch_id" || return 1
  meta="$(devkit_dispatch_meta_read "$dispatch_id")" || return 1
  state="$(printf '%s' "$meta" | jq -r '.state')"
  process_state="$(printf '%s' "$meta" | jq -r '.processState')"
  [ "$state" != closed ] || return 0
  [ "$state" != circuit_broken ] || return 0
  devkit_dispatch_terminal_status "$meta"
  terminal_status="${DEVKIT_TERMINAL_STATUS:-unknown}"
  case "$terminal_status" in
    missing)
      failure_count="$(printf '%s' "$meta" | jq -r '.failureCount // 0')"
      failure_count=$((failure_count + 1))
      next_state=failed
      [ "$failure_count" -ge 3 ] && next_state=circuit_broken
      next_process=abandoned
      case "$process_state" in
        succeeded|failed|stopped|abandoned) next_process=__keep__ ;;
      esac
      devkit_dispatch_meta_update_fields "$dispatch_id" "$next_state" "$next_process" missing terminal-missing terminal-missing terminal-missing terminal-missing "$failure_count" || return 1
      DEVKIT_RECONCILE_OUTCOME=terminal-missing
      ;;
    proven)
      devkit_dispatch_parent_status "$meta"
      parent_status="${DEVKIT_PARENT_STATUS:-unknown}"
      case "$parent_status" in
        gone)
          next_state=__keep__
          case "$process_state:$state" in
            starting:*|start-unproven:*|running:*|stopping:*|stop-unproven:*) next_state=orphaned ;;
          esac
          devkit_dispatch_meta_update_fields "$dispatch_id" "$next_state" __keep__ __keep__ parent-missing parent-missing orphaned __keep__ __keep__ || return 1
          DEVKIT_RECONCILE_OUTCOME=orphaned
          ;;
        alive)
          next_state=__keep__
          next_process=__keep__
          [ "$state" = spawning ] || [ "$state" = orphaned ] && next_state=running
          case "$process_state" in
            starting|start-unproven) next_process=running ;;
          esac
          devkit_dispatch_meta_update_fields "$dispatch_id" "$next_state" "$next_process" __keep__ terminal-proven identity-proven adopted __keep__ __keep__ || return 1
          DEVKIT_RECONCILE_OUTCOME=adopted
          ;;
        *)
          devkit_dispatch_meta_update_fields "$dispatch_id" __keep__ __keep__ __keep__ parent-unproven parent-unproven parent-unproven __keep__ __keep__ || return 1
          DEVKIT_RECONCILE_OUTCOME=parent-unproven
          ;;
      esac
      ;;
    *)
      next_process=__keep__
      [ "$process_state" = starting ] && next_process=start-unproven
      devkit_dispatch_meta_update_fields "$dispatch_id" __keep__ "$next_process" __keep__ identity-unproven identity-unproven identity-unproven __keep__ __keep__ || return 1
      DEVKIT_RECONCILE_OUTCOME=identity-unproven
      ;;
  esac
}

devkit_dispatch_reconcile() {
  local dispatch_id="" all=false json=false arg meta_path meta entries='[]' outcome
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --all) all=true; shift ;;
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit orchestrate reconcile <dispatch-id> [--json]\n'; return 0 ;;
      *)
        [ -z "$dispatch_id" ] || { devkit_error "unknown reconcile option: $arg"; return "$DEVKIT_USAGE_ERROR"; }
        dispatch_id="$arg"
        shift
        ;;
    esac
  done
  if [ "$all" = true ]; then
    for meta_path in "$DEVKIT_DISPATCH_DIR"/*/meta.json; do
      [ -f "$meta_path" ] || continue
      dispatch_id="$(jq -r '.dispatchId' "$meta_path")"
      devkit_dispatch_reconcile_one "$dispatch_id" || return 1
      meta="$(devkit_dispatch_meta_read "$dispatch_id")" || return 1
      outcome="${DEVKIT_RECONCILE_OUTCOME:-unchanged}"
      entries="$(jq --argjson item "$meta" --arg outcome "$outcome" '. + [$item + {reconcileResult: $outcome}]' <<<"$entries")" || return 1
    done
  else
    [ -n "$dispatch_id" ] || { devkit_error 'Usage: devkit orchestrate reconcile <dispatch-id> [--json]'; return "$DEVKIT_USAGE_ERROR"; }
    devkit_dispatch_reconcile_one "$dispatch_id" || return 1
    meta="$(devkit_dispatch_meta_read "$dispatch_id")" || return 1
    outcome="${DEVKIT_RECONCILE_OUTCOME:-unchanged}"
    entries="$(jq --argjson item "$meta" --arg outcome "$outcome" '. + [$item + {reconcileResult: $outcome}]' <<<"$entries")" || return 1
  fi
  if [ "$json" = true ]; then
    printf '%s\n' "$entries" | jq 'if length == 1 then .[0] else . end'
  else
    printf '%s\n' "$entries" | jq -r '.[] | [.dispatchId, .reconcileResult, .state, .processState, .terminalState] | @tsv' | while IFS=$'\t' read -r dispatch outcome state process terminal; do
      printf 'dispatch: %s\nresult: %s\nstate: %s\nprocess: %s\nterminal: %s\n' "$dispatch" "$outcome" "$state" "$process" "$terminal"
    done
  fi
}

devkit_dispatch_health_counts() {
  local meta_path meta records='[]'
  MODULE_UNCERTAIN_DISPATCHES=0
  MODULE_RETAINED_TERMINALS=0
  for meta_path in "$DEVKIT_DISPATCH_DIR"/*/meta.json; do
    [ -f "$meta_path" ] || continue
    meta="$(cat "$meta_path" 2>/dev/null || true)"
    printf '%s' "$meta" | jq -e . >/dev/null 2>&1 || continue
    records="$(jq --argjson item "$meta" '. + [$item]' <<<"$records")" || continue
  done
  MODULE_UNCERTAIN_DISPATCHES="$(printf '%s' "$records" | jq '[.[] | select((.processState // "") == "start-unproven" or (.processState // "") == "stop-unproven" or (.processState // "") == "abandoned")] | length')"
  MODULE_RETAINED_TERMINALS="$(printf '%s' "$records" | jq '[.[] | select((.terminalState // "") == "retained")] | length')"
}

devkit_dispatch_cursor_read() {
  local dispatch_id="$1" path value
  path="$(devkit_dispatch_cursor_path "$dispatch_id")" || return 1
  if [ ! -f "$path" ]; then
    printf '{"lastReadSeq":0}\n' >"$path" || return 1
  fi
  value="$(jq -r '.lastReadSeq // 0' "$path" 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+$ ]] || { devkit_error "dispatch cursor is invalid: $dispatch_id"; return 1; }
  printf '%s\n' "$value"
}

devkit_dispatch_cursor_write() {
  local dispatch_id="$1" seq="$2" path tmp
  path="$(devkit_dispatch_cursor_path "$dispatch_id")" || return 1
  tmp="$(mktemp "$(devkit_dispatch_dir "$dispatch_id")/.cursor.XXXXXX")" || return 1
  jq -n --argjson seq "$seq" '{lastReadSeq: $seq}' >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

devkit_dispatch_message_append() {
  local dispatch_id="$1" from="$2" type="$3" text="$4" session_id="$5"
  local messages_dir lock path tmp seq file_name
  messages_dir="$(devkit_dispatch_messages_dir "$dispatch_id")" || return 1
  lock="$messages_dir/.lock"
  while ! mkdir "$lock" 2>/dev/null; do sleep 0.02; done
  seq="$(find "$messages_dir" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | sed 's|.*/||; s|-.*||' | sort -n | tail -n 1)"
  [ -n "$seq" ] || seq=0
  seq=$((10#$seq + 1))
  file_name="$(printf '%04d-%s-%s.json' "$seq" "$from" "$type")"
  path="$messages_dir/$file_name"
  tmp="$(mktemp "$messages_dir/.message.XXXXXX")" || { rmdir "$lock"; return 1; }
  if ! jq -n --argjson seq "$seq" --arg from "$from" --arg type "$type" --arg text "$text" \
    --arg createdAt "$(devkit_iso_now)" --arg sessionId "$session_id" \
    '{seq: $seq, from: $from, type: $type, text: $text, createdAt: $createdAt, sessionId: $sessionId}' >"$tmp"; then
    rm -f "$tmp"
    rmdir "$lock"
    return 1
  fi
  mv -f "$tmp" "$path"
  rmdir "$lock"
  DEVKIT_LAST_MESSAGE_SEQ="$seq"
  printf '%s\n' "$seq"
}

devkit_dispatch_message_paths() {
  local messages_dir="$1" path seq
  for path in "$messages_dir"/*.json; do
    [ -f "$path" ] || continue
    seq="$(jq -r '.seq // 0' "$path" 2>/dev/null || true)"
    [[ "$seq" =~ ^[0-9]+$ ]] || continue
    printf '%s\t%s\n' "$seq" "$path"
  done | sort -n -k1,1
}

devkit_dispatch_seq_acknowledged() {
  local deliveries_dir="$1" seq="$2" path
  for path in "$deliveries_dir"/*.json; do
    [ -f "$path" ] || continue
    if jq -e --argjson seq "$seq" '.status == "acknowledged" and ((.messageSeqs // []) | index($seq) != null)' "$path" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

devkit_dispatch_delivery_fence() {
  local path="$1" tmp now
  now="$(devkit_iso_now)"
  tmp="$(mktemp "$(dirname "$path")/.delivery.XXXXXX")" || return 1
  if ! jq --arg now "$now" '.status = "fenced" | .fencedAt = $now | .updatedAt = $now' "$path" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path"
}

devkit_dispatch_delivery_report() {
  local dispatch_id="$1" delivery_id="$2" replayed="$3" json="$4"
  local record messages_dir deliveries_dir message_seqs messages='[]' path seq from type text status='done'
  record="$(cat "$(devkit_dispatch_delivery_path "$dispatch_id" "$delivery_id")")" || return 1
  messages_dir="$(devkit_dispatch_messages_dir "$dispatch_id")"
  deliveries_dir="$(devkit_dispatch_deliveries_dir "$dispatch_id")"
  message_seqs="$(printf '%s' "$record" | jq -c '.messageSeqs')"
  while IFS=$'\t' read -r seq path; do
    [ -n "$path" ] || continue
    if ! jq -n -e --argjson seqs "$message_seqs" --argjson seq "$seq" '$seqs | index($seq) != null' >/dev/null 2>&1; then
      continue
    fi
    messages="$(jq --argjson item "$(cat "$path")" '. + [$item]' <<<"$messages")" || return 1
  done < <(devkit_dispatch_message_paths "$messages_dir")
  type="$(printf '%s' "$messages" | jq -r '.[0].type // empty')"
  case "$type" in
    ask) status=waiting_for_reply ;;
    done) status=done ;;
    stalled) status=stalled ;;
    *) status=done ;;
  esac
  if [ "$json" = true ]; then
    jq -n --arg dispatchId "$dispatch_id" --arg deliveryId "$delivery_id" \
      --argjson replayed "$(devkit_bool_json "$replayed")" --arg status "$status" \
      --argjson messageSeqs "$message_seqs" --argjson messages "$messages" \
      '{dispatchId: $dispatchId, deliveryId: $deliveryId, replayed: $replayed, status: $status, messageSeqs: $messageSeqs, messages: $messages, text: ($messages | map(.text // "") | join("\n"))}'
  else
    printf 'delivery: %s\nreplayed: %s\nstatus: %s\n' "$delivery_id" "$replayed" "$status"
    printf '%s\n' "$messages" | jq -r '.[] | "[" + (.seq|tostring) + "] " + (.type // "message") + ": " + (.text // "")'
  fi
}

devkit_dispatch_empty_delivery_report() {
  local dispatch_id="$1" json="$2"
  if [ "$json" = true ]; then
    jq -n --arg dispatchId "$dispatch_id" \
      '{dispatchId: $dispatchId, deliveryId: null, replayed: false, status: "timeout", messageSeqs: [], messages: [], text: ""}'
  else
    devkit_dispatch_report "$dispatch_id" timeout "" false
  fi
}

devkit_dispatch_require_session() {
  devkit_session_id >/dev/null
  if [ -z "${DEVKIT_SESSION_ID:-}" ]; then
    devkit_error "this command requires a managed terminal identity; run it inside an Orca or Superset terminal"
    return 1
  fi
}

devkit_dispatch_require_parent() {
  local dispatch_id="$1" meta expected_id expected_host
  devkit_dispatch_require_session || return 1
  meta="$(devkit_dispatch_meta_read "$dispatch_id")" || return 1
  expected_id="$(printf '%s' "$meta" | jq -r '.parentSessionId // empty')"
  expected_host="$(printf '%s' "$meta" | jq -r '.parentHost // empty')"
  if [ "$DEVKIT_SESSION_ID" != "$expected_id" ] || [ "$DEVKIT_SESSION_HOST" != "$expected_host" ]; then
    devkit_error "dispatch $dispatch_id is owned by $expected_host/$expected_id, not $DEVKIT_SESSION_HOST/$DEVKIT_SESSION_ID"
    return 1
  fi
  printf '%s\n' "$meta"
}

devkit_dispatch_find_child() {
  local meta_path meta dispatch_id expected_dispatch
  DEVKIT_FOUND_DISPATCH=""
  devkit_dispatch_require_session || return 1
  expected_dispatch="${DEVKIT_DISPATCH_ID:-}"
  if [ -n "$expected_dispatch" ]; then
    meta_path="$(devkit_dispatch_meta_path "$expected_dispatch")" || return 1
    if [ -f "$meta_path" ]; then
      meta="$(cat "$meta_path")"
      if printf '%s' "$meta" | jq -e --arg id "$DEVKIT_SESSION_ID" --arg host "$DEVKIT_SESSION_HOST" \
        '.childHost == $host and .terminalId == $id' >/dev/null 2>&1; then
        DEVKIT_FOUND_DISPATCH="$expected_dispatch"
        return 0
      fi
    fi
  fi
  for meta_path in "$DEVKIT_DISPATCH_DIR"/*/meta.json; do
    [ -f "$meta_path" ] || continue
    meta="$(cat "$meta_path")"
    if printf '%s' "$meta" | jq -e --arg id "$DEVKIT_SESSION_ID" --arg host "$DEVKIT_SESSION_HOST" \
      '.terminalId == $id and .childHost == $host' >/dev/null 2>&1; then
      dispatch_id="$(printf '%s' "$meta" | jq -r '.dispatchId')"
      if [ -n "$DEVKIT_FOUND_DISPATCH" ]; then
        devkit_error "terminal identity matches multiple dispatches"
        return 1
      fi
      DEVKIT_FOUND_DISPATCH="$dispatch_id"
    fi
  done
  [ -n "$DEVKIT_FOUND_DISPATCH" ] || { devkit_error "no managed dispatch belongs to $DEVKIT_SESSION_HOST/$DEVKIT_SESSION_ID"; return 1; }
}

devkit_dispatch_native_send() {
  local meta="$1" text="$2" host workspace_id terminal_id runtime tmux_session tmux_pane
  host="$(printf '%s' "$meta" | jq -r '.childHost')"
  workspace_id="$(printf '%s' "$meta" | jq -r '.workspaceId // empty')"
  terminal_id="$(printf '%s' "$meta" | jq -r '.terminalId')"
  runtime="$(printf '%s' "$meta" | jq -r '.runtime // "host"')"
  if [ "$runtime" = tmux ]; then
    tmux_session="$(printf '%s' "$meta" | jq -r '.tmuxSession // empty')"
    tmux_pane="$(printf '%s' "$meta" | jq -r '.tmuxPane // empty')"
    [ -n "$tmux_session" ] && [ -n "$tmux_pane" ] || { devkit_error "tmux dispatch metadata has no session or pane"; return 1; }
    devkit_tmux_session_exists "$tmux_session" || { devkit_error "tmux session is no longer available: $tmux_session"; return 1; }
    devkit_tmux_send_text "$tmux_pane" "$text"
    return $?
  fi
  case "$host" in
    superset) devkit_superset terminals send --workspace "$workspace_id" --terminal "$terminal_id" --text "$text" --json >/dev/null ;;
    orca) orca terminal send --terminal "$terminal_id" --text "$text" --enter --json >/dev/null ;;
    *) devkit_error "unsupported child host: $host"; return 1 ;;
  esac
}

devkit_dispatch_native_close() {
  local meta="$1" host workspace_id terminal_id runtime tmux_session tmux_pane pane_count close_rc=0
  DEVKIT_DISPATCH_CLOSE_LAST_PANE=false
  host="$(printf '%s' "$meta" | jq -r '.childHost')"
  workspace_id="$(printf '%s' "$meta" | jq -r '.workspaceId // empty')"
  terminal_id="$(printf '%s' "$meta" | jq -r '.terminalId')"
  runtime="$(printf '%s' "$meta" | jq -r '.runtime // "host"')"
  if [ "$runtime" = tmux ]; then
    tmux_session="$(printf '%s' "$meta" | jq -r '.tmuxSession // empty')"
    tmux_pane="$(printf '%s' "$meta" | jq -r '.tmuxPane // empty')"
    [ -n "$tmux_session" ] && [ -n "$tmux_pane" ] || { devkit_error "tmux dispatch metadata has no session or pane"; return 1; }
    if ! devkit_tmux_session_exists "$tmux_session"; then
      DEVKIT_DISPATCH_CLOSE_LAST_PANE=true
      pane_count=0
    else
      pane_count="$(tmux list-panes -t "$tmux_session" 2>/dev/null | wc -l | tr -d ' ')"
    fi
    if [ "$pane_count" -gt 1 ]; then
      tmux kill-pane -t "$tmux_pane"
      return $?
    fi
    DEVKIT_DISPATCH_CLOSE_LAST_PANE=true
    tmux kill-session -t "$tmux_session" >/dev/null 2>&1 || true
    case "$host" in
      superset) devkit_superset terminals close --workspace "$workspace_id" --terminal "$terminal_id" --json >/dev/null 2>&1 || close_rc=$? ;;
      orca) orca terminal close --terminal "$terminal_id" --json >/dev/null 2>&1 || close_rc=$? ;;
      *) devkit_error "unsupported child host: $host"; return 1 ;;
    esac
    return "$close_rc"
  fi
  case "$host" in
    superset) devkit_superset terminals close --workspace "$workspace_id" --terminal "$terminal_id" --json >/dev/null ;;
    orca) orca terminal close --terminal "$terminal_id" --json >/dev/null ;;
    *) devkit_error "unsupported child host: $host"; return 1 ;;
  esac
}

devkit_dispatch_read() {
  local dispatch_id="${1:-}" lines=200 json=false arg meta runtime pane output
  [ -n "$dispatch_id" ] || { devkit_error "Usage: devkit orchestrate read <dispatch-id> [--lines <count>] [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --lines) lines="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit orchestrate read <dispatch-id> [--lines <count>] [--json]\n'; return 0 ;;
      *) devkit_error "unknown orchestrate read option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  [[ "$lines" =~ ^[1-9][0-9]*$ ]] || { devkit_error "--lines must be a positive number"; return "$DEVKIT_USAGE_ERROR"; }
  meta="$(devkit_dispatch_require_parent "$dispatch_id")" || return 1
  runtime="$(printf '%s' "$meta" | jq -r '.runtime // "host"')"
  [ "$runtime" = tmux ] || { devkit_error "dispatch $dispatch_id does not use tmux-runtime"; return 1; }
  pane="$(printf '%s' "$meta" | jq -r '.tmuxPane // empty')"
  output="$(devkit_tmux_capture_pane "$pane" "-$lines")" || { devkit_error "could not read tmux pane $pane"; return 1; }
  if [ "$json" = true ]; then
    jq -n --arg dispatchId "$dispatch_id" --arg pane "$pane" --arg output "$output" \
      '{dispatchId: $dispatchId, pane: $pane, text: $output}'
  else
    printf '%s\n' "$output"
  fi
}

devkit_dispatch_report() {
  local dispatch_id="$1" status="$2" text="$3" json="$4"
  if [ "$json" = true ]; then
    jq -n --arg dispatchId "$dispatch_id" --arg status "$status" --arg text "$text" '{dispatchId: $dispatchId, status: $status, text: $text}'
  else
    printf 'status: %s\n%s\n' "$status" "$text"
  fi
}

devkit_dispatch_watch() {
  local dispatch_id="${1:-}" timeout=120 poll_interval=3 json=false arg meta start_time now
  local consumer="${DEVKIT_CONSUMER_ID:-}" generation="${DEVKIT_CONSUMER_GENERATION:-1}"
  local messages_dir deliveries_dir lock path seq from type message_seqs delivery_id outstanding_path outstanding_consumer outstanding_generation
  [ -n "$dispatch_id" ] || { devkit_error "Usage: devkit orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --timeout) timeout="${2:-}"; shift 2 ;;
      --poll-interval) poll_interval="${2:-}"; shift 2 ;;
      --consumer) consumer="${2:-}"; shift 2 ;;
      --generation) generation="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--consumer <id>] [--generation <number>] [--json]\n'; return 0 ;;
      *) devkit_error "unknown orchestrate watch option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  [[ "$timeout" =~ ^[0-9]+$ ]] || { devkit_error "--timeout must be a non-negative number of seconds"; return "$DEVKIT_USAGE_ERROR"; }
  [[ "$poll_interval" =~ ^[0-9]+$ ]] || { devkit_error "--poll-interval must be a non-negative number of seconds"; return "$DEVKIT_USAGE_ERROR"; }
  [[ "$generation" =~ ^[1-9][0-9]*$ ]] || { devkit_error "--generation must be a positive number"; return "$DEVKIT_USAGE_ERROR"; }
  [[ "$DEVKIT_DISPATCH_DELIVERY_BATCH_CAP" =~ ^[1-9][0-9]*$ ]] || { devkit_error "delivery batch cap is invalid"; return 1; }
  meta="$(devkit_dispatch_meta_read "$dispatch_id")" || return 1
  [ -n "$consumer" ] || consumer="$DEVKIT_SESSION_HOST/$DEVKIT_SESSION_ID"
  [ -n "$consumer" ] || { devkit_error "consumer identity is empty"; return 1; }
  messages_dir="$(devkit_dispatch_messages_dir "$dispatch_id")"
  deliveries_dir="$(devkit_dispatch_deliveries_dir "$dispatch_id")"
  mkdir -p "$deliveries_dir" || return 1
  lock="$messages_dir/.lock"
  start_time="$(date +%s)"
  while true; do
    while ! mkdir "$lock" 2>/dev/null; do sleep 0.02; done
    outstanding_path=""
    for path in "$deliveries_dir"/*.json; do
      [ -f "$path" ] || continue
      if [ "$(jq -r '.status // empty' "$path" 2>/dev/null || true)" = outstanding ]; then
        outstanding_path="$path"
        break
      fi
    done
    if [ -n "$outstanding_path" ]; then
      outstanding_consumer="$(jq -r '.consumer // empty' "$outstanding_path")"
      outstanding_generation="$(jq -r '.consumerGeneration // empty' "$outstanding_path")"
      delivery_id="$(jq -r '.id // empty' "$outstanding_path")"
      if [ "$outstanding_consumer" = "$consumer" ] && [ "$outstanding_generation" = "$generation" ]; then
        rmdir "$lock"
        devkit_dispatch_delivery_report "$dispatch_id" "$delivery_id" true "$json"
        return $?
      fi
      devkit_dispatch_delivery_fence "$outstanding_path" || { rmdir "$lock"; return 1; }
    fi
    message_seqs='[]'
    while IFS=$'\t' read -r seq path; do
      [ -n "$path" ] || continue
      from="$(jq -r '.from // empty' "$path")"
      type="$(jq -r '.type // empty' "$path")"
      [ "$from" = child ] || continue
      case "$type" in ask|done|stalled) ;; *) continue ;; esac
      devkit_dispatch_seq_acknowledged "$deliveries_dir" "$seq" && continue
      message_seqs="$(jq --argjson seq "$seq" '. + [$seq]' <<<"$message_seqs")" || { rmdir "$lock"; return 1; }
      [ "$(jq 'length' <<<"$message_seqs")" -ge "$DEVKIT_DISPATCH_DELIVERY_BATCH_CAP" ] && break
    done < <(devkit_dispatch_message_paths "$messages_dir")
    if [ "$(jq 'length' <<<"$message_seqs")" -gt 0 ]; then
      delivery_id="$(devkit_dispatch_new_delivery_id "$dispatch_id")" || { rmdir "$lock"; return 1; }
      devkit_dispatch_delivery_write "$dispatch_id" "$delivery_id" "$consumer" "$generation" "$message_seqs" || { rmdir "$lock"; return 1; }
      rmdir "$lock"
      devkit_dispatch_delivery_report "$dispatch_id" "$delivery_id" false "$json"
      return $?
    fi
    rmdir "$lock"
    now="$(date +%s)"
    if [ $((now - start_time)) -ge "$timeout" ]; then
      devkit_dispatch_empty_delivery_report "$dispatch_id" "$json"
      return 0
    fi
    sleep "$poll_interval"
  done
}

devkit_dispatch_ack() {
  local dispatch_id="${1:-}" delivery_id="${2:-}" consumer="${DEVKIT_CONSUMER_ID:-}" generation="${DEVKIT_CONSUMER_GENERATION:-1}"
  local json=false arg meta path status record_consumer record_generation lock tmp now message_seqs
  [ -n "$dispatch_id" ] && [ -n "$delivery_id" ] || { devkit_error "Usage: devkit orchestrate ack <dispatch-id> <delivery-id> [--consumer <id>] [--generation <number>] [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shift 2
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --consumer) consumer="${2:-}"; shift 2 ;;
      --generation) generation="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit orchestrate ack <dispatch-id> <delivery-id> [--consumer <id>] [--generation <number>] [--json]\n'; return 0 ;;
      *) devkit_error "unknown orchestrate ack option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  [[ "$generation" =~ ^[1-9][0-9]*$ ]] || { devkit_error "--generation must be a positive number"; return "$DEVKIT_USAGE_ERROR"; }
  meta="$(devkit_dispatch_require_parent "$dispatch_id")" || return 1
  [ -n "$consumer" ] || consumer="$DEVKIT_SESSION_HOST/$DEVKIT_SESSION_ID"
  [ -n "$consumer" ] || { devkit_error "consumer identity is empty"; return 1; }
  path="$(devkit_dispatch_delivery_path "$dispatch_id" "$delivery_id")" || return 1
  [ -f "$path" ] || { devkit_error "delivery $delivery_id refused: delivery is unknown"; return 1; }
  lock="$(devkit_dispatch_messages_dir "$dispatch_id")/.lock"
  while ! mkdir "$lock" 2>/dev/null; do sleep 0.02; done
  status="$(jq -r '.status // empty' "$path")"
  case "$status" in
    acknowledged)
      # Idempotent acknowledgement makes retries safe after a lost connection.
      message_seqs="$(jq -c '.messageSeqs // []' "$path")"
      rmdir "$lock"
      if [ "$json" = true ]; then
        jq -n --arg dispatchId "$dispatch_id" --arg deliveryId "$delivery_id" --argjson messageSeqs "$message_seqs" \
          '{dispatchId: $dispatchId, deliveryId: $deliveryId, acknowledged: true, duplicate: true, status: "acknowledged", messageSeqs: $messageSeqs}'
      else
        printf 'acknowledged: %s\nduplicate: true\n' "$delivery_id"
      fi
      return 0
      ;;
    fenced)
      # A fenced delivery must stay refused so an old generation cannot acknowledge a replacement batch.
      rmdir "$lock"
      devkit_error "delivery $delivery_id refused: delivery is fenced"
      return 1
      ;;
    outstanding) ;;
    *)
      rmdir "$lock"
      devkit_error "delivery $delivery_id refused: status is invalid ($status)"
      return 1
      ;;
  esac
  record_consumer="$(jq -r '.consumer // empty' "$path")"
  record_generation="$(jq -r '.consumerGeneration // empty' "$path")"
  if [ "$record_consumer" != "$consumer" ] || [ "$record_generation" != "$generation" ]; then
    rmdir "$lock"
    devkit_error "delivery $delivery_id refused: outstanding delivery belongs to consumer $record_consumer generation $record_generation"
    return 1
  fi
  now="$(devkit_iso_now)"
  tmp="$(mktemp "$(dirname "$path")/.delivery.XXXXXX")" || { rmdir "$lock"; return 1; }
  if ! jq --arg now "$now" '.status = "acknowledged" | .acknowledgedAt = $now | .updatedAt = $now' "$path" >"$tmp"; then
    rm -f "$tmp"
    rmdir "$lock"
    return 1
  fi
  mv -f "$tmp" "$path"
  message_seqs="$(jq -c '.messageSeqs // []' "$path")"
  rmdir "$lock"
  if [ "$json" = true ]; then
    jq -n --arg dispatchId "$dispatch_id" --arg deliveryId "$delivery_id" --argjson messageSeqs "$message_seqs" \
      '{dispatchId: $dispatchId, deliveryId: $deliveryId, acknowledged: true, duplicate: false, status: "acknowledged", messageSeqs: $messageSeqs}'
  else
    printf 'acknowledged: %s\nduplicate: false\n' "$delivery_id"
  fi
}

devkit_dispatch_reply() {
  local dispatch_id="${1:-}" answer="" json=false arg meta state
  [ -n "$dispatch_id" ] || { devkit_error "Usage: devkit orchestrate reply <dispatch-id> --text <answer> [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --text) answer="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit orchestrate reply <dispatch-id> --text <answer> [--json]\n'; return 0 ;;
      *) devkit_error "unknown orchestrate reply option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  [ -n "$answer" ] || { devkit_error "--text is required"; return "$DEVKIT_USAGE_ERROR"; }
  meta="$(devkit_dispatch_require_parent "$dispatch_id")" || return 1
  state="$(printf '%s' "$meta" | jq -r '.state // empty')"
  [ "$state" = waiting_for_reply ] || { devkit_error "dispatch $dispatch_id is not waiting_for_reply (state: $state)"; return 1; }
  devkit_dispatch_native_send "$meta" "$answer" || { devkit_error "could not deliver reply to dispatch $dispatch_id"; return 1; }
  devkit_dispatch_message_append "$dispatch_id" parent reply "$answer" "$DEVKIT_SESSION_ID" >/dev/null || return 1
  devkit_dispatch_meta_update_state "$dispatch_id" running || return 1
  if [ "$json" = true ]; then
    jq -n --arg dispatchId "$dispatch_id" '{dispatchId: $dispatchId, status: "replied"}'
  else
    printf 'replied: %s\n' "$dispatch_id"
  fi
}

devkit_dispatch_close() {
  local dispatch_id="${1:-}" json=false arg meta runtime child_host
  [ -n "$dispatch_id" ] || { devkit_error "Usage: devkit orchestrate close <dispatch-id> [--json]"; return "$DEVKIT_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: devkit orchestrate close <dispatch-id> [--json]\n'; return 0 ;;
      *) devkit_error "unknown orchestrate close option: $arg"; return "$DEVKIT_USAGE_ERROR" ;;
    esac
  done
  meta="$(devkit_dispatch_require_parent "$dispatch_id")" || return 1
  runtime="$(printf '%s' "$meta" | jq -r '.runtime // "host"')"
  child_host="$(printf '%s' "$meta" | jq -r '.childHost')"
  devkit_dispatch_native_close "$meta" || { devkit_error "could not close dispatch $dispatch_id"; return 1; }
  devkit_dispatch_meta_update_state "$dispatch_id" closed || return 1
  if [ "$json" = true ]; then
    if [ "$runtime" = tmux ] && [ "$DEVKIT_DISPATCH_CLOSE_LAST_PANE" = true ]; then
      jq -n --arg dispatchId "$dispatch_id" '{dispatchId: $dispatchId, status: "closed", message: "last tmux pane and the host terminal tab were closed."}'
    elif [ "$runtime" = tmux ]; then
      jq -n --arg dispatchId "$dispatch_id" '{dispatchId: $dispatchId, status: "closed", message: "tmux pane removed; the host terminal tab remains available for sibling panes or manual use."}'
    elif [ "$child_host" = superset ]; then
      jq -n --arg dispatchId "$dispatch_id" '{dispatchId: $dispatchId, status: "closed", message: "Superset leaves the pane visible as Desconectado until the human dismisses it with the pane X."}'
    else
      jq -n --arg dispatchId "$dispatch_id" '{dispatchId: $dispatchId, status: "closed"}'
    fi
  else
    printf 'closed: %s\n' "$dispatch_id"
    if [ "$runtime" = tmux ] && [ "$DEVKIT_DISPATCH_CLOSE_LAST_PANE" = true ]; then
      printf 'last tmux pane and the host terminal tab were closed.\n'
    elif [ "$runtime" = tmux ]; then
      printf 'tmux pane removed; the host terminal tab remains available for sibling panes or manual use.\n'
    elif [ "$child_host" = superset ]; then
      printf 'Superset leaves the pane visible as Desconectado until the human dismisses it with the pane X.\n'
    fi
  fi
}

devkit_dispatch_child_message() {
  local type="$1" text="$2" dispatch_id
  case "$type" in
    ask|done) ;;
    *) devkit_error "unsupported child message type: $type"; return "$DEVKIT_USAGE_ERROR" ;;
  esac
  devkit_dispatch_find_child || return 1
  dispatch_id="$DEVKIT_FOUND_DISPATCH"
  devkit_dispatch_message_append "$dispatch_id" child "$type" "$text" "$DEVKIT_SESSION_ID" >/dev/null || return 1
  if [ "$type" = ask ]; then
    devkit_dispatch_meta_update_state "$dispatch_id" waiting_for_reply || return 1
  else
    devkit_dispatch_meta_update_state "$dispatch_id" done || return 1
  fi
  printf '%s sent: %s\n' "$type" "$dispatch_id"
}

command_ask() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || { devkit_error 'Usage: devkit ask "question"'; return "$DEVKIT_USAGE_ERROR"; }
  devkit_dispatch_child_message ask "$1"
}

command_done() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || { devkit_error 'Usage: devkit done "summary"'; return "$DEVKIT_USAGE_ERROR"; }
  devkit_dispatch_child_message done "$1"
}
