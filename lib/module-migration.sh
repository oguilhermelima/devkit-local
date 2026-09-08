#!/usr/bin/env bash

devkit_state_migration_source() {
  if [ "${DEVKIT_STATE_DIR_EXPLICIT:-false}" = true ] && [ "${MEGABRAIN_STATE_DIR_EXPLICIT:-false}" != true ]; then
    printf '%s\n' "$DEVKIT_STATE_DIR_LEGACY"
  else
    printf '%s/.devkit\n' "$HOME"
  fi
}

devkit_state_migration_entries() {
  local source="$1"
  find "$source" -mindepth 1 -print 2>/dev/null | sort | sed "s#^${source%/}/##"
}

devkit_state_migration_verify() {
  local source="$1" target="$2"
  diff -qr "$source" "$target" >/dev/null 2>&1
}

devkit_state_migrate() {
  local source target staging entries count
  source="$(devkit_state_migration_source)"
  if [ "${DEVKIT_STATE_DIR_EXPLICIT:-false}" = true ] && [ "${MEGABRAIN_STATE_DIR_EXPLICIT:-false}" != true ]; then
    target="$HOME/.megabrain"
  else
    target="$DEVKIT_STATE_DIR"
  fi
  [ "$source" != "$target" ] || {
    devkit_error "migration source and target are the same directory: $source"
    return 1
  }
  if [ ! -e "$source" ]; then
    printf 'No migration needed: %s does not exist; %s is active.\n' "$source" "$target"
    return 0
  fi
  [ -d "$source" ] || {
    devkit_error "migration source is not a directory: $source"
    return 1
  }
  [ "$source" != / ] && [ "$source" != "$HOME" ] || {
    devkit_error "refusing to migrate a broad directory: $source"
    return 1
  }
  if [ -e "$target" ]; then
    [ -d "$target" ] || {
      devkit_error "migration target is not a directory: $target"
      return 1
    }
    devkit_state_migration_verify "$source" "$target" || {
      devkit_error "migration target is not identical to the source; nothing was removed: $target"
      return 1
    }
    entries="$(devkit_state_migration_entries "$source")"
    rm -rf "$source" || {
      devkit_error "could not remove the verified old state directory: $source"
      return 1
    }
    count="$(printf '%s\n' "$entries" | awk 'NF { count += 1 } END { print count + 0 }')"
    printf 'Moved %s paths from %s to %s after verifying the existing target.\n' "$count" "$source" "$target"
    [ -z "$entries" ] || printf '  %s\n' "$entries"
    return 0
  fi
  mkdir -p "$(dirname "$target")" || return 1
  staging="${target}.migration.$$"
  [ ! -e "$staging" ] || {
    devkit_error "migration staging path already exists: $staging"
    return 1
  }
  mkdir "$staging" || return 1
  if ! cp -Rp "$source/." "$staging/"; then
    rm -rf "$staging"
    devkit_error "could not copy state to the migration staging path"
    return 1
  fi
  if ! devkit_state_migration_verify "$source" "$staging"; then
    rm -rf "$staging"
    devkit_error "copied state did not verify; the old state was left untouched"
    return 1
  fi
  if ! mv "$staging" "$target"; then
    rm -rf "$staging"
    devkit_error "could not activate the verified migrated state; the old state was left untouched"
    return 1
  fi
  if ! devkit_state_migration_verify "$source" "$target"; then
    devkit_error "activated state did not verify; the old state was left untouched"
    return 1
  fi
  entries="$(devkit_state_migration_entries "$source")"
  rm -rf "$source" || {
    devkit_error "could not remove the verified old state directory: $source"
    return 1
  }
  count="$(printf '%s\n' "$entries" | awk 'NF { count += 1 } END { print count + 0 }')"
  printf 'Moved %s paths from %s to %s:\n' "$count" "$source" "$target"
  [ -z "$entries" ] || printf '  %s\n' "$entries"
}

command_migrate() {
  local arg="${1:-}"
  case "$arg" in
    ''|--json)
      [ -z "$arg" ] || {
        devkit_error 'JSON migration output is not supported yet'
        return "$DEVKIT_USAGE_ERROR"
      }
      devkit_state_migrate
      ;;
    -h|--help)
      printf 'Usage: megabrain migrate\n'
      ;;
    *)
      devkit_error "unknown migrate option: $arg"
      return "$DEVKIT_USAGE_ERROR"
      ;;
  esac
}
