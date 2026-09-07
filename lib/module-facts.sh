#!/usr/bin/env bash

DEVKIT_FACTS_FILE="${DEVKIT_FACTS_FILE:-${DEVKIT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}/.devkit/facts.json}"
DEVKIT_FACT_MAX_INJECTED="${DEVKIT_FACT_MAX_INJECTED:-20}"
DEVKIT_FACT_MAX_PREAMBLE_BYTES="${DEVKIT_FACT_MAX_PREAMBLE_BYTES:-6000}"

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
  if [ "$worktree_path" = . ]; then
    printf '%s\n' "$DEVKIT_FACTS_FILE"
  else
    printf '%s/.devkit/facts.json\n' "${worktree_path%/}"
  fi
}

devkit_fact_empty_store() {
  printf '{"version":1,"facts":[]}\n'
}

devkit_fact_store_read() {
  local path="${1:-$DEVKIT_FACTS_FILE}"
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
  local store="$1" path="${2:-$DEVKIT_FACTS_FILE}" directory tmp
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

devkit_fact_in_scope_json() {
  local store="$1" worktree_path="${2:-.}" repository_id
  repository_id="$(devkit_fact_repository_id "$worktree_path" 2>/dev/null || true)"
  printf '%s' "$store" | jq -c --arg repository "$repository_id" '.facts | map(select(.scope.type == "global" or (.scope.type == "repository" and .scope.repository == $repository)))'
}

devkit_dispatch_preamble() {
  local worktree_path="${1:-.}" path store scoped count rendered protocol
  path="$(devkit_fact_file_for_worktree "$worktree_path")"
  store="$(devkit_fact_store_read "$path")" || return 1
  devkit_fact_validate "$store" || return 1
  scoped="$(devkit_fact_in_scope_json "$store" "$worktree_path")" || return 1
  count="$(printf '%s' "$scoped" | jq 'length')"
  if [ "$count" -gt "$DEVKIT_FACT_MAX_INJECTED" ]; then
    devkit_error "fact preamble exceeds fact count limit: $count facts (limit: $DEVKIT_FACT_MAX_INJECTED)"
    return 1
  fi
  protocol="${DEVKIT_SUPERSET_PROTOCOL:-${DEVKIT_DISPATCH_PROTOCOL:-}}"
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
    if [ "$(devkit_fact_byte_length "$rendered")" -gt "$DEVKIT_FACT_MAX_PREAMBLE_BYTES" ]; then
      devkit_error "fact preamble exceeds byte limit: $(devkit_fact_byte_length "$rendered") bytes (limit: $DEVKIT_FACT_MAX_PREAMBLE_BYTES)"
      return 1
    fi
    printf '%s\n\n%s' "$protocol" "$rendered"
  else
    printf '%s' "$protocol"
  fi
}
