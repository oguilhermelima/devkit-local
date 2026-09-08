#!/usr/bin/env bash

if [ "${MEGABRAIN_FACTS_FILE+x}" = x ]; then
  MEGABRAIN_FACTS_FILE_EXPLICIT=true
else
  MEGABRAIN_FACTS_FILE_EXPLICIT=false
  MEGABRAIN_FACTS_FILE="${MEGABRAIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}/.megabrain/facts.json"
fi
MEGABRAIN_FACT_MAX_INJECTED="${MEGABRAIN_FACT_MAX_INJECTED:-20}"
MEGABRAIN_FACT_MAX_PREAMBLE_BYTES="${MEGABRAIN_FACT_MAX_PREAMBLE_BYTES:-6000}"

devkit_fact_repository_id() {
  local worktree_path="${1:-.}" remote common_dir
  remote="$(git -C "$worktree_path" config --get remote.origin.url 2>/dev/null || true)"
  if [ -n "$remote" ]; then
    printf '%s\n' "$remote"
    return 0
  fi
  common_dir="$(git -C "$worktree_path" rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "$common_dir" ] || return 1
  case "$common_dir" in
    /*) ;;
    *) common_dir="$worktree_path/$common_dir" ;;
  esac
  (cd "$common_dir" >/dev/null 2>&1 && pwd -P)
}

devkit_fact_file_for_worktree() {
  local worktree_path="${1:-.}"
  if [ "$MEGABRAIN_FACTS_FILE_EXPLICIT" = true ] || [ "$worktree_path" = . ]; then
    printf '%s\n' "$MEGABRAIN_FACTS_FILE"
  else
    printf '%s/.megabrain/facts.json\n' "${worktree_path%/}"
  fi
}

devkit_fact_empty_store() {
  printf '{"version":1,"facts":[]}\n'
}

devkit_fact_store_read() {
  local path="${1:-$MEGABRAIN_FACTS_FILE}"
  if [ ! -e "$path" ]; then
    devkit_fact_empty_store
    return 0
  fi
  [ -f "$path" ] || { devkit_error "fact store is not a file: $path"; return 1; }
  cat "$path"
}

devkit_fact_string_valid() {
  case "$1" in
    *$'\n'*|*$'\r'*) return 1 ;;
    *) return 0 ;;
  esac
}

devkit_fact_validate() {
  local store="$1" fact id measurement scope_type repository who when command key previous_ids
  if ! printf '%s' "$store" | jq -e 'type == "object" and .version == 1 and (.facts | type == "array")' >/dev/null 2>&1; then
    devkit_error 'invalid fact store: expected version 1 and a facts array'
    return 1
  fi
  previous_ids=''
  while IFS= read -r fact; do
    id="$(printf '%s' "$fact" | jq -r '.id // empty')"
    measurement="$(printf '%s' "$fact" | jq -r '.measurement // empty')"
    scope_type="$(printf '%s' "$fact" | jq -r '.scope.type // empty')"
    repository="$(printf '%s' "$fact" | jq -r '.scope.repository // empty')"
    who="$(printf '%s' "$fact" | jq -r '.provenance.who // empty')"
    when="$(printf '%s' "$fact" | jq -r '.provenance.when // empty')"
    command="$(printf '%s' "$fact" | jq -r '.provenance.command // empty')"
    case "$id" in
      ""|*[!A-Za-z0-9._-]*) devkit_error 'invalid fact: id must contain only letters, numbers, dot, underscore, and hyphen'; return 1 ;;
    esac
    case "$previous_ids" in
      *"|$id|"*) devkit_error "invalid fact $id: duplicate id"; return 1 ;;
      *) previous_ids="${previous_ids}|${id}|" ;;
    esac
    [ -n "$measurement" ] || { devkit_error "fact $id is missing measurement"; return 1; }
    case "$scope_type" in
      global) [ -z "$repository" ] || { devkit_error "fact $id global scope cannot have a repository"; return 1; } ;;
      repository) [ -n "$repository" ] || { devkit_error "fact $id repository scope is missing repository"; return 1; } ;;
      *) devkit_error "fact $id has invalid scope: expected global or repository"; return 1 ;;
    esac
    # WHY: provenance makes stale measurements distinguishable from verified facts.
    [ -n "$who" ] || { devkit_error "fact $id is missing provenance.who"; return 1; }
    [ -n "$when" ] || { devkit_error "fact $id is missing provenance.when"; return 1; }
    [ -n "$command" ] || { devkit_error "fact $id is missing provenance.command"; return 1; }
    for key in "$id" "$measurement" "$repository" "$who" "$when" "$command"; do
      devkit_fact_string_valid "$key" || { devkit_error "fact $id contains a newline in a field"; return 1; }
    done
    if ! printf '%s' "$fact" | jq -e '(.scope | type == "object" and ((keys | sort) == (["type"]))) or (.scope | type == "object" and ((keys | sort) == (["repository", "type"])))' >/dev/null 2>&1; then
      devkit_error "fact $id has unsupported scope fields"
      return 1
    fi
    if ! printf '%s' "$fact" | jq -e '(.provenance | type == "object" and ((keys | sort) == ["command", "when", "who"]))' >/dev/null 2>&1; then
      devkit_error "fact $id provenance must contain only who, when, and command"
      return 1
    fi
  done < <(printf '%s' "$store" | jq -c '.facts[]' 2>/dev/null) || {
    devkit_error 'invalid fact store: facts must contain valid JSON objects'
    return 1
  }
}

devkit_fact_store_write() {
  local store="$1" path="${2:-$MEGABRAIN_FACTS_FILE}" directory tmp
  devkit_fact_validate "$store" || return 1
  directory="$(dirname "$path")"
  mkdir -p "$directory" || return 1
  tmp="$(mktemp "$directory/.facts.XXXXXX")" || return 1
  if ! printf '%s' "$store" | jq . >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path"
}

devkit_fact_render() {
  printf '%s' "$1" | jq -r '"- " + .id + ": " + .measurement + " (measured by " + .provenance.who + " at " + .provenance.when + "; rerun: " + .provenance.command + ")"'
}

devkit_fact_byte_length() {
  LC_ALL=C printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

devkit_dispatch_command_path() {
  local path root
  path="$(type -P megabrain 2>/dev/null || true)"
  if [ -n "$path" ] && [ "${path#/}" != "$path" ]; then
    printf 'megabrain\n'
    return 0
  fi
  # WHY: Children run in arbitrary repositories, so the preamble cannot depend on the checkout as its working directory.
  root="${MEGABRAIN_ROOT:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
  if [ -n "${MEGABRAIN_EXECUTABLE:-}" ] && [ -x "$MEGABRAIN_EXECUTABLE" ]; then
    printf '%q\n' "$MEGABRAIN_EXECUTABLE"
  elif [ -x "$root/megabrain" ]; then
    printf '%q\n' "$root/megabrain"
  else
    return 1
  fi
}

devkit_fact_in_scope_json() {
  local store="$1" worktree_path="${2:-.}" repository_id
  repository_id="$(devkit_fact_repository_id "$worktree_path" 2>/dev/null || true)"
  printf '%s' "$store" | jq -c --arg repository "$repository_id" '.facts | map(select(.scope.type == "global" or (.scope.type == "repository" and .scope.repository == $repository)))'
}

devkit_dispatch_protocol() {
  local command_path
  command_path="$(devkit_dispatch_command_path 2>/dev/null || true)"
  if [ -n "$command_path" ]; then
    printf 'This is a managed megabrain dispatch. Before starting work, run %s received to confirm that you received this prompt. If you need coordinator input, run %s ask "your question" and stop until the coordinator replies. When the requested work is complete, run %s done "short outcome summary". Do not print protocol markers and do not continue past an unanswered question.\n' "$command_path" "$command_path" "$command_path"
  else
    printf 'This is a managed megabrain dispatch. The megabrain command could not be resolved through PATH or an absolute executable path, so receipt, coordinator questions, and completion cannot be recorded. Do not print protocol markers and do not continue past an unanswered question.\n'
  fi
}

devkit_dispatch_preamble() {
  local worktree_path="${1:-.}" path store scoped count rendered protocol
  path="$(devkit_fact_file_for_worktree "$worktree_path")"
  store="$(devkit_fact_store_read "$path")" || return 1
  devkit_fact_validate "$store" || return 1
  scoped="$(devkit_fact_in_scope_json "$store" "$worktree_path")" || return 1
  count="$(printf '%s' "$scoped" | jq 'length')"
  if [ "$count" -gt "$MEGABRAIN_FACT_MAX_INJECTED" ]; then
    devkit_error "fact preamble exceeds fact count limit: $count facts (limit: $MEGABRAIN_FACT_MAX_INJECTED)"
    return 1
  fi
  protocol="${MEGABRAIN_SUPERSET_PROTOCOL:-$(devkit_dispatch_protocol)}"
  rendered=""
  if [ "$count" -gt 0 ]; then
    rendered="Facts in scope (starting points with provenance, not truth):
Treat each fact as a starting point with provenance, not as truth. If your own measurement disagrees, your measurement wins; report the disagreement.
"
    while IFS= read -r fact; do
      rendered="${rendered}$(devkit_fact_render "$fact")
"
    done < <(printf '%s' "$scoped" | jq -c '.[]')
  fi
  if [ -n "$rendered" ]; then
    if [ "$(devkit_fact_byte_length "$rendered")" -gt "$MEGABRAIN_FACT_MAX_PREAMBLE_BYTES" ]; then
      devkit_error "fact preamble exceeds byte limit: $(devkit_fact_byte_length "$rendered") bytes (limit: $MEGABRAIN_FACT_MAX_PREAMBLE_BYTES)"
      return 1
    fi
    printf '%s\n\n%s' "$protocol" "$rendered"
  else
    printf '%s' "$protocol"
  fi
}

devkit_fact_id_valid() {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

devkit_fact_command_add() {
  local id="${1:-}" measurement="" who="" when="" command="" scope_type=global repository="" json=false arg value store path fact updated
  [ -n "$id" ] || { devkit_error 'Usage: megabrain fact add <id> --measurement <text> --who <name> --when <timestamp> --command <command> [--scope global|repository] [--repository <id>] [--json]'; return "$MEGABRAIN_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --measurement|--measured) value="${2:-}"; [ -n "$value" ] || { devkit_error "$arg requires a value"; return "$MEGABRAIN_USAGE_ERROR"; }; measurement="$value"; shift 2 ;;
      --who|--measured-by) value="${2:-}"; [ -n "$value" ] || { devkit_error "$arg requires a value"; return "$MEGABRAIN_USAGE_ERROR"; }; who="$value"; shift 2 ;;
      --when|--measured-at) value="${2:-}"; [ -n "$value" ] || { devkit_error "$arg requires a value"; return "$MEGABRAIN_USAGE_ERROR"; }; when="$value"; shift 2 ;;
      --command) value="${2:-}"; [ -n "$value" ] || { devkit_error '--command requires a value'; return "$MEGABRAIN_USAGE_ERROR"; }; command="$value"; shift 2 ;;
      --scope) value="${2:-}"; [ -n "$value" ] || { devkit_error '--scope requires a value'; return "$MEGABRAIN_USAGE_ERROR"; }; scope_type="$value"; shift 2 ;;
      --repository|--repo) value="${2:-}"; [ -n "$value" ] || { devkit_error "$arg requires a value"; return "$MEGABRAIN_USAGE_ERROR"; }; repository="$value"; scope_type=repository; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: megabrain fact add <id> --measurement <text> --who <name> --when <timestamp> --command <command> [--scope global|repository] [--repository <id>] [--json]\n'; return 0 ;;
      *) devkit_error "unknown fact add option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  devkit_fact_id_valid "$id" || { devkit_error "invalid fact id: $id"; return 1; }
  case "$scope_type" in
    global) [ -z "$repository" ] || { devkit_error 'global facts cannot specify a repository'; return 1; } ;;
    repository)
      if [ -z "$repository" ]; then
        repository="$(devkit_fact_repository_id . 2>/dev/null || true)"
        [ -n "$repository" ] || { devkit_error 'could not determine repository identity for repository-scoped fact'; return 1; }
      fi
      ;;
    *) devkit_error 'fact scope must be global or repository'; return 1 ;;
  esac
  path="$MEGABRAIN_FACTS_FILE"
  store="$(devkit_fact_store_read "$path")" || return 1
  devkit_fact_validate "$store" || return 1
  if printf '%s' "$store" | jq -e --arg id "$id" '.facts | any(.[]; .id == $id)' >/dev/null 2>&1; then
    devkit_error "fact already exists: $id"
    return 1
  fi
  fact="$(jq -n --arg id "$id" --arg measurement "$measurement" --arg scopeType "$scope_type" --arg repository "$repository" --arg who "$who" --arg when "$when" --arg command "$command" '{id: $id, measurement: $measurement, scope: (if $scopeType == "global" then {type: "global"} else {type: "repository", repository: $repository} end), provenance: {who: $who, when: $when, command: $command}}')" || return 1
  updated="$(printf '%s' "$store" | jq --argjson fact "$fact" '.facts += [$fact]')" || return 1
  devkit_fact_store_write "$updated" "$path" || return 1
  if [ "$json" = true ]; then
    printf '%s\n' "$fact"
  else
    printf 'fact added: %s\n' "$id"
  fi
}

devkit_fact_command_list() {
  local json=false arg store id scope who measurement
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: megabrain fact list [--json]\n'; return 0 ;;
      *) devkit_error "unknown fact list option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  store="$(devkit_fact_store_read)" || return 1
  devkit_fact_validate "$store" || return 1
  if [ "$json" = true ]; then
    printf '%s\n' "$store" | jq -c '.facts'
  else
    printf '%-24s %-12s %-32s %s\n' ID SCOPE MEASURED_BY MEASUREMENT
    printf '%s' "$store" | jq -r '.facts[] | [.id, .scope.type, .provenance.who, .measurement] | @tsv' |
      while IFS=$'\t' read -r id scope who measurement; do
        printf '%-24s %-12s %-32s %s\n' "$id" "$scope" "$who" "$measurement"
      done
  fi
}

devkit_fact_command_edit() {
  local id="${1:-}" json=false arg path store tmp editor edited
  [ -n "$id" ] || { devkit_error 'Usage: megabrain fact edit <id> [--json]'; return "$MEGABRAIN_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: megabrain fact edit <id> [--json]\n'; return 0 ;;
      *) devkit_error "unknown fact edit option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  path="$MEGABRAIN_FACTS_FILE"
  store="$(devkit_fact_store_read "$path")" || return 1
  devkit_fact_validate "$store" || return 1
  if ! printf '%s' "$store" | jq -e --arg id "$id" '.facts | any(.[]; .id == $id)' >/dev/null 2>&1; then
    devkit_error "fact not found: $id"
    return 1
  fi
  tmp="$(mktemp "$(dirname "$path")/.facts-edit.XXXXXX")" || return 1
  printf '%s\n' "$store" | jq . >"$tmp" || { rm -f "$tmp"; return 1; }
  editor="${EDITOR:-vi}"
  if ! "$editor" "$tmp"; then
    rm -f "$tmp"
    devkit_error "editor failed while editing fact $id"
    return 1
  fi
  edited="$(cat "$tmp")"
  rm -f "$tmp"
  devkit_fact_validate "$edited" || return 1
  if ! printf '%s' "$edited" | jq -e --arg id "$id" '.facts | any(.[]; .id == $id)' >/dev/null 2>&1; then
    devkit_error "edited fact not found: $id"
    return 1
  fi
  devkit_fact_store_write "$edited" "$path" || return 1
  if [ "$json" = true ]; then
    printf '%s\n' "$edited" | jq -c --arg id "$id" '.facts[] | select(.id == $id)'
  else
    printf 'fact edited: %s\n' "$id"
  fi
}

devkit_fact_command_remove() {
  local id="${1:-}" json=false arg path store updated
  [ -n "$id" ] || { devkit_error 'Usage: megabrain fact remove <id> [--json]'; return "$MEGABRAIN_USAGE_ERROR"; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      -h|--help) printf 'Usage: megabrain fact remove <id> [--json]\n'; return 0 ;;
      *) devkit_error "unknown fact remove option: $arg"; return "$MEGABRAIN_USAGE_ERROR" ;;
    esac
  done
  path="$MEGABRAIN_FACTS_FILE"
  store="$(devkit_fact_store_read "$path")" || return 1
  devkit_fact_validate "$store" || return 1
  if ! printf '%s' "$store" | jq -e --arg id "$id" '.facts | any(.[]; .id == $id)' >/dev/null 2>&1; then
    devkit_error "fact not found: $id"
    return 1
  fi
  updated="$(printf '%s' "$store" | jq --arg id "$id" '.facts |= map(select(.id != $id))')" || return 1
  devkit_fact_store_write "$updated" "$path" || return 1
  if [ "$json" = true ]; then
    printf '{"removed":true,"id":%s}\n' "$(printf '%s' "$id" | jq -Rsa .)"
  else
    printf 'fact removed: %s\n' "$id"
  fi
}

command_fact() {
  local subcommand="${1:-}"
  shift || true
  case "$subcommand" in
    list) devkit_fact_command_list "$@" ;;
    add) devkit_fact_command_add "$@" ;;
    edit) devkit_fact_command_edit "$@" ;;
    remove|delete) devkit_fact_command_remove "$@" ;;
    -h|--help|"")
      printf 'Usage: megabrain fact list|add|edit|remove ...\n'
      ;;
    *) devkit_error "unknown fact command: $subcommand"; return "$MEGABRAIN_USAGE_ERROR" ;;
  esac
}
