#!/usr/bin/env bash

MEGABRAIN_HOOK_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$MEGABRAIN_HOOK_SOURCE" ]; do
  MEGABRAIN_HOOK_SOURCE_DIR="$(cd -P "$(dirname "$MEGABRAIN_HOOK_SOURCE")" >/dev/null 2>&1 && pwd)"
  MEGABRAIN_HOOK_SOURCE="$(readlink "$MEGABRAIN_HOOK_SOURCE")"
  case "$MEGABRAIN_HOOK_SOURCE" in
    /*) ;;
    *) MEGABRAIN_HOOK_SOURCE="$MEGABRAIN_HOOK_SOURCE_DIR/$MEGABRAIN_HOOK_SOURCE" ;;
  esac
done
MEGABRAIN_HOOK_ROOT="$(cd -P "$(dirname "$MEGABRAIN_HOOK_SOURCE")" && pwd)"
exec "$MEGABRAIN_HOOK_ROOT/megabrain-turn-end.sh" "$@"
