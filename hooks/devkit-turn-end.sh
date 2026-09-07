#!/usr/bin/env bash

DEVKIT_HOOK_RESPONSE='{}'
[ "${DEVKIT_HOOK_AGENT:-}" = cursor ] && DEVKIT_HOOK_RESPONSE='{"continue":true}'

devkit_hook_finish() {
  printf '%s\n' "$DEVKIT_HOOK_RESPONSE"
  exit 0
}

[ -n "${SUPERSET_TERMINAL_ID:-}" ] || [ -n "${ORCA_TERMINAL_HANDLE:-}" ] || devkit_hook_finish

DEVKIT_HOOK_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)" || devkit_hook_finish
source "$DEVKIT_HOOK_ROOT/lib/common.sh" >/dev/null 2>&1 || devkit_hook_finish
source "$DEVKIT_HOOK_ROOT/lib/module-orchestrate.sh" >/dev/null 2>&1 || devkit_hook_finish
source "$DEVKIT_HOOK_ROOT/lib/module-parent-notify.sh" >/dev/null 2>&1 || devkit_hook_finish

devkit_session_id >/dev/null 2>&1 || devkit_hook_finish
[ -n "${DEVKIT_SESSION_ID:-}" ] || devkit_hook_finish
devkit_dispatch_find_child >/dev/null 2>&1 || devkit_hook_finish

DEVKIT_HOOK_DISPATCH="$DEVKIT_FOUND_DISPATCH"
DEVKIT_HOOK_META="$(devkit_dispatch_meta_read "$DEVKIT_HOOK_DISPATCH" 2>/dev/null)" || devkit_hook_finish
DEVKIT_HOOK_STATE="$(printf '%s' "$DEVKIT_HOOK_META" | jq -r '.state // empty' 2>/dev/null)"
case "$DEVKIT_HOOK_STATE" in
  waiting_for_reply|done|stalled|closed|orphaned) devkit_hook_finish ;;
esac

devkit_dispatch_terminal_status "$DEVKIT_HOOK_META"
case "${DEVKIT_TERMINAL_STATUS:-unknown}" in
  proven) devkit_hook_finish ;;
  missing) ;;
  *) devkit_dispatch_has_recent_child_activity "$DEVKIT_HOOK_DISPATCH" && devkit_hook_finish ;;
esac

if [ -n "${1:-}" ]; then
  DEVKIT_HOOK_PAYLOAD="$1"
else
  DEVKIT_HOOK_PAYLOAD="$(cat 2>/dev/null)"
fi

DEVKIT_HOOK_TEXT="$(printf '%s' "$DEVKIT_HOOK_PAYLOAD" | jq -r '.last_assistant_message // .lastAssistantMessage // empty' 2>/dev/null)"
DEVKIT_HOOK_TRANSCRIPT="$(printf '%s' "$DEVKIT_HOOK_PAYLOAD" | jq -r '.transcript_path // .transcriptPath // empty' 2>/dev/null)"
if [ -z "$DEVKIT_HOOK_TEXT" ] && [ -r "$DEVKIT_HOOK_TRANSCRIPT" ]; then
  DEVKIT_HOOK_TEXT="$(tail -n 20 "$DEVKIT_HOOK_TRANSCRIPT" 2>/dev/null | tail -c 8000)"
fi
[ -n "$DEVKIT_HOOK_TEXT" ] || DEVKIT_HOOK_TEXT='child turn ended without ask or done'

devkit_dispatch_message_append "$DEVKIT_HOOK_DISPATCH" child stalled "$DEVKIT_HOOK_TEXT" "$DEVKIT_SESSION_ID" >/dev/null 2>&1 || devkit_hook_finish
devkit_dispatch_meta_update_state "$DEVKIT_HOOK_DISPATCH" stalled >/dev/null 2>&1 || true
devkit_parent_notify_dispatch "$DEVKIT_HOOK_META" >/dev/null 2>&1 || true
devkit_hook_finish
