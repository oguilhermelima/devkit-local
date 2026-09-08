#!/usr/bin/env bash

MEGABRAIN_HOOK_RESPONSE='{}'
[ "${MEGABRAIN_HOOK_AGENT:-}" = cursor ] && MEGABRAIN_HOOK_RESPONSE='{"continue":true}'

megabrain_hook_finish() {
  printf '%s\n' "$MEGABRAIN_HOOK_RESPONSE"
  exit 0
}

[ -n "${SUPERSET_TERMINAL_ID:-}" ] || [ -n "${ORCA_TERMINAL_HANDLE:-}" ] || megabrain_hook_finish

MEGABRAIN_HOOK_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)" || megabrain_hook_finish
source "$MEGABRAIN_HOOK_ROOT/lib/common.sh" >/dev/null 2>&1 || megabrain_hook_finish
source "$MEGABRAIN_HOOK_ROOT/lib/module-orchestrate.sh" >/dev/null 2>&1 || megabrain_hook_finish
source "$MEGABRAIN_HOOK_ROOT/lib/module-context.sh" >/dev/null 2>&1 || megabrain_hook_finish
source "$MEGABRAIN_HOOK_ROOT/lib/module-parent-notify.sh" >/dev/null 2>&1 || megabrain_hook_finish

devkit_session_id >/dev/null 2>&1 || megabrain_hook_finish
[ -n "${MEGABRAIN_SESSION_ID:-}" ] || megabrain_hook_finish
devkit_dispatch_find_child >/dev/null 2>&1 || megabrain_hook_finish

MEGABRAIN_HOOK_DISPATCH="$MEGABRAIN_FOUND_DISPATCH"
MEGABRAIN_HOOK_META="$(devkit_dispatch_meta_read "$MEGABRAIN_HOOK_DISPATCH" 2>/dev/null)" || megabrain_hook_finish
MEGABRAIN_HOOK_STATE="$(printf '%s' "$MEGABRAIN_HOOK_META" | jq -r '.state // empty' 2>/dev/null)"
case "$MEGABRAIN_HOOK_STATE" in
  waiting_for_reply|done|stalled|closed|orphaned) megabrain_hook_finish ;;
esac

devkit_dispatch_terminal_status "$MEGABRAIN_HOOK_META"
case "${MEGABRAIN_TERMINAL_STATUS:-unknown}" in
  proven) megabrain_hook_finish ;;
  missing) ;;
  *) devkit_dispatch_has_recent_child_activity "$MEGABRAIN_HOOK_DISPATCH" && megabrain_hook_finish ;;
esac

if [ -n "${1:-}" ]; then
  MEGABRAIN_HOOK_PAYLOAD="$1"
else
  MEGABRAIN_HOOK_PAYLOAD="$(cat 2>/dev/null)"
fi

MEGABRAIN_HOOK_TEXT="$(printf '%s' "$MEGABRAIN_HOOK_PAYLOAD" | jq -r '.last_assistant_message // .lastAssistantMessage // empty' 2>/dev/null)"
MEGABRAIN_HOOK_TRANSCRIPT="$(printf '%s' "$MEGABRAIN_HOOK_PAYLOAD" | jq -r '.transcript_path // .transcriptPath // empty' 2>/dev/null)"
if [ -z "$MEGABRAIN_HOOK_TEXT" ] && [ -r "$MEGABRAIN_HOOK_TRANSCRIPT" ]; then
  MEGABRAIN_HOOK_TEXT="$(tail -n 20 "$MEGABRAIN_HOOK_TRANSCRIPT" 2>/dev/null | tail -c 8000)"
fi
[ -n "$MEGABRAIN_HOOK_TEXT" ] || MEGABRAIN_HOOK_TEXT='child turn ended without ask or done'

devkit_dispatch_message_append "$MEGABRAIN_HOOK_DISPATCH" child stalled "$MEGABRAIN_HOOK_TEXT" "$MEGABRAIN_SESSION_ID" >/dev/null 2>&1 || megabrain_hook_finish
devkit_dispatch_meta_update_state "$MEGABRAIN_HOOK_DISPATCH" stalled >/dev/null 2>&1 || true
devkit_parent_notify_dispatch "$MEGABRAIN_HOOK_META" >/dev/null 2>&1 || true
megabrain_hook_finish
