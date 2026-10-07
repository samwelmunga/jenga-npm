#!/usr/bin/env bash
# Shared working-file root resolver (E34_S01).
#
# Locates the anchor directory that holds the Jenga working-file tree (normally the repo
# root) so scripts never hardcode `project/...`. The full contract is documented in
# templates/SCRUM_BOARD_SCHEMA.md, section "Working-File Path Resolution".
#
# Resolution order, highest priority first:
#   1. JENGA_PROJECT_ROOT  - names the anchor directly; a registry must exist under it,
#                            otherwise exit 3 (never falls through to a lower layer)
#   2. upward search       - from $PWD (and up to 25 ancestors) for
#                            project/configs/workflow.json, then .project/configs/workflow.json
#   3. default             - anchor = $PWD, tree = ./project/ (exit 3 under --strict)
#
# Usage (executed):
#   resolve-root.sh [--strict] root      print the anchor directory
#   resolve-root.sh [--strict] source    print env | search | default
#   resolve-root.sh [--strict] tree      print project | .project
#   resolve-root.sh [--strict] [--relative] get <key>   resolved path of one `paths` key
#   resolve-root.sh [--strict] [--relative] list        key=path for all 18 keys
#
# Usage (sourced): `. resolve-root.sh` defines jenga_resolve_root, jenga_resolve_source,
# jenga_resolve_tree, jenga_resolve_path <key> and jenga_resolve_list. Sourcing prints nothing,
# exits nothing and creates nothing.
#
# Exit codes: 0 ok, 1 malformed registry JSON, 2 unknown key or usage error, 3 unresolvable
# (strict mode, or JENGA_PROJECT_ROOT names a root without a registry).
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions)
# and safe under `set -u`. Creates no file or directory.

_JENGA_SEARCH_DEPTH=25

_jenga_err() {
  printf '%s\n' "$*" >&2
}

# Prints the tree name ("project" or ".project") whose registry exists under directory $1.
_jenga_find_tree() {
  local d="${1%/}" t
  for t in project .project; do
    if [ -f "$d/$t/configs/workflow.json" ]; then
      printf '%s' "$t"
      return 0
    fi
  done
  return 1
}

# Locates the anchor. Sets JENGA_ROOT, JENGA_ROOT_SOURCE, JENGA_ROOT_TREE and
# JENGA_ROOT_REGISTRY (absolute registry path, empty for the default layer) in the calling
# shell. $1 = 1 for strict mode.
_jenga_locate() {
  local strict="${1:-0}" d tree depth envroot="${JENGA_PROJECT_ROOT:-}"
  JENGA_ROOT=""
  JENGA_ROOT_SOURCE=""
  JENGA_ROOT_TREE=""
  JENGA_ROOT_REGISTRY=""

  if [ -n "$envroot" ]; then
    d=""
    if [ -d "$envroot" ]; then
      d=$(cd "$envroot" && pwd)
    fi
    if [ -n "$d" ] && tree=$(_jenga_find_tree "$d"); then
      JENGA_ROOT="$d"
      JENGA_ROOT_SOURCE="env"
      JENGA_ROOT_TREE="$tree"
      JENGA_ROOT_REGISTRY="${d%/}/$tree/configs/workflow.json"
      return 0
    fi
    _jenga_err "Error: JENGA_PROJECT_ROOT=$envroot has no registry; checked ${envroot%/}/project/configs/workflow.json and ${envroot%/}/.project/configs/workflow.json"
    return 3
  fi

  d="$PWD"
  depth=0
  while :; do
    if tree=$(_jenga_find_tree "$d"); then
      JENGA_ROOT="$d"
      JENGA_ROOT_SOURCE="search"
      JENGA_ROOT_TREE="$tree"
      JENGA_ROOT_REGISTRY="${d%/}/$tree/configs/workflow.json"
      return 0
    fi
    if [ "$d" = "/" ] || [ "$depth" -ge "$_JENGA_SEARCH_DEPTH" ]; then
      break
    fi
    d="${d%/*}"
    [ -z "$d" ] && d="/"
    depth=$((depth + 1))
  done

  if [ "$strict" = "1" ]; then
    _jenga_err "Error: no workflow.json registry found searching upward from $PWD (checked project/configs/ and .project/configs/, ${_JENGA_SEARCH_DEPTH} levels); set JENGA_PROJECT_ROOT or run from inside the project"
    return 3
  fi
  JENGA_ROOT="$PWD"
  JENGA_ROOT_SOURCE="default"
  JENGA_ROOT_TREE="project"
  return 0
}

# Parses a lone optional --strict argument shared by the three root-level functions.
_jenga_strict_arg() {
  local a strict="${JENGA_RESOLVE_STRICT:-0}"
  for a in "$@"; do
    case "$a" in
      --strict) strict=1 ;;
      *) _jenga_err "Error: unexpected argument '$a'"; return 2 ;;
    esac
  done
  printf '%s' "$strict"
}

jenga_resolve_root() {
  local strict
  strict=$(_jenga_strict_arg "$@") || return $?
  _jenga_locate "$strict" || return $?
  printf '%s\n' "$JENGA_ROOT"
}

jenga_resolve_source() {
  local strict
  strict=$(_jenga_strict_arg "$@") || return $?
  _jenga_locate "$strict" || return $?
  printf '%s\n' "$JENGA_ROOT_SOURCE"
}

jenga_resolve_tree() {
  local strict
  strict=$(_jenga_strict_arg "$@") || return $?
  _jenga_locate "$strict" || return $?
  printf '%s\n' "$JENGA_ROOT_TREE"
}

# --- per-key resolution (E34_S01_T03) -------------------------------------------------------

# The 18 keys of workflow.json's `paths` map, in the order the schema doc's key table lists them.
_JENGA_KEYS="board epics stories tasks rapports_problems rapports_analysis queue scrum_triggers developer_triggers tester_triggers session_handoff logs data configs documentation documentation_plans documentation_summaries strategy"

# Prints the conventional default for key $1 (relative to the anchor); returns 1 for an unknown key.
# A case statement, not an associative array, for bash 3.2.
_jenga_default_path() {
  case "${1:-}" in
    board) printf '%s' "project/board" ;;
    epics) printf '%s' "project/board/epics" ;;
    stories) printf '%s' "project/board/stories" ;;
    tasks) printf '%s' "project/board/tasks" ;;
    rapports_problems) printf '%s' "project/rapports/problems" ;;
    rapports_analysis) printf '%s' "project/rapports/analysis" ;;
    queue) printf '%s' "project/queue" ;;
    scrum_triggers) printf '%s' "project/queue/scrum_triggers.jsonl" ;;
    developer_triggers) printf '%s' "project/queue/developer_triggers.jsonl" ;;
    tester_triggers) printf '%s' "project/queue/tester_triggers.jsonl" ;;
    session_handoff) printf '%s' "project/queue/handoffs" ;;
    logs) printf '%s' "project/logs" ;;
    data) printf '%s' "project/data" ;;
    configs) printf '%s' "project/configs" ;;
    documentation) printf '%s' "project/documentation" ;;
    documentation_plans) printf '%s' "project/documentation/plans" ;;
    documentation_summaries) printf '%s' "project/documentation/summaries" ;;
    strategy) printf '%s' "project/documentation/STRATEGY.md" ;;
    *) return 1 ;;
  esac
}

# Fails with the contract's malformed-JSON message when the located registry is not valid JSON.
# A default-layer resolution has no registry and always passes.
_jenga_validate_registry() {
  local f="$JENGA_ROOT_REGISTRY" first
  [ -n "$f" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    if ! jq empty "$f" >/dev/null 2>&1; then
      _jenga_err "Error: ${f#"${JENGA_ROOT%/}"/} contains malformed JSON"
      return 1
    fi
  else
    # Portable check: the file must start with '{' or '[' after whitespace.
    first=$(sed 's/^[[:space:]]*//' "$f" | head -c1)
    if [ "$first" != "{" ] && [ "$first" != "["  ]; then
      _jenga_err "Error: ${f#"${JENGA_ROOT%/}"/} contains malformed JSON"
      return 1
    fi
  fi
  return 0
}

# Prints paths.<key> from the located registry, or nothing when the key (or registry) is absent.
_jenga_read_key() {
  local key="$1" f="$JENGA_ROOT_REGISTRY"
  [ -n "$f" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '(.paths // {}) | if type == "object" then .[$k] else empty end | if type == "string" then . else empty end' "$f" 2>/dev/null
  else
    # grep/sed fallback, restricted to the `paths` object so a same-named key elsewhere in the
    # file cannot be picked up.
    tr '\n' ' ' < "$f" \
      | sed -n 's/.*"paths"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' \
      | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | sed "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/" \
      | head -1
  fi
}

# Resolves key $1 against the already-located anchor. $2 = 1 for a path relative to the anchor.
# Prints the path with no trailing slash.
_jenga_path_for_key() {
  local key="$1" rel="$2" v
  v=$(_jenga_read_key "$key")
  if [ -z "$v" ]; then
    v=$(_jenga_default_path "$key") || return 2
    # A partial registry in a relocated tree must not point back at ./project/.
    if [ "$JENGA_ROOT_TREE" = ".project" ]; then
      case "$v" in project/*) v=".project/${v#project/}" ;; esac
    fi
  fi
  while [ "$v" != "/" ] && [ "${v%/}" != "$v" ]; do
    v="${v%/}"
  done
  case "$v" in
    /*) printf '%s\n' "$v" ;;
    *)
      if [ "$rel" = "1" ]; then
        printf '%s\n' "$v"
      else
        printf '%s\n' "${JENGA_ROOT%/}/$v"
      fi
      ;;
  esac
}

_jenga_valid_keys_msg() {
  _jenga_err "Valid keys: $_JENGA_KEYS"
}

# jenga_resolve_path <key> [--relative] [--strict]
jenga_resolve_path() {
  local key="" rel=0 strict="${JENGA_RESOLVE_STRICT:-0}" a
  for a in "$@"; do
    case "$a" in
      --relative) rel=1 ;;
      --strict) strict=1 ;;
      -*) _jenga_err "Error: unknown option '$a'"; return 2 ;;
      *)
        if [ -n "$key" ]; then
          _jenga_err "Error: unexpected argument '$a'"
          return 2
        fi
        key="$a"
        ;;
    esac
  done
  if [ -z "$key" ]; then
    _jenga_err "Usage: resolve-root.sh [--strict] [--relative] get <key>"
    _jenga_valid_keys_msg
    return 2
  fi
  if ! _jenga_default_path "$key" >/dev/null; then
    _jenga_err "Error: unknown key '$key'"
    _jenga_valid_keys_msg
    return 2
  fi
  _jenga_locate "$strict" || return $?
  _jenga_validate_registry || return 1
  _jenga_path_for_key "$key" "$rel"
}

# jenga_resolve_list [--relative] [--strict]: prints key=path for every key.
jenga_resolve_list() {
  local rel=0 strict="${JENGA_RESOLVE_STRICT:-0}" a k line
  for a in "$@"; do
    case "$a" in
      --relative) rel=1 ;;
      --strict) strict=1 ;;
      *) _jenga_err "Error: unexpected argument '$a'"; return 2 ;;
    esac
  done
  _jenga_locate "$strict" || return $?
  _jenga_validate_registry || return 1
  for k in $_JENGA_KEYS; do
    line=$(_jenga_path_for_key "$k" "$rel") || return $?
    printf '%s=%s\n' "$k" "$line"
  done
}

_jenga_usage() {
  _jenga_err "Usage: resolve-root.sh [--strict] [--relative] {root|source|tree|get <key>|list}"
}

_jenga_main() {
  local cmd="" strict=0 rel=0 key="" a
  for a in "$@"; do
    case "$a" in
      --strict) strict=1 ;;
      --relative) rel=1 ;;
      -h|--help) _jenga_usage; return 0 ;;
      -*) _jenga_err "Error: unknown option '$a'"; _jenga_usage; return 2 ;;
      *)
        if [ -z "$cmd" ]; then
          cmd="$a"
        elif [ "$cmd" = "get" ] && [ -z "$key" ]; then
          key="$a"
        else
          _jenga_err "Error: unexpected argument '$a'"
          _jenga_usage
          return 2
        fi
        ;;
    esac
  done
  JENGA_RESOLVE_STRICT="$strict"
  case "$cmd" in
    root)   jenga_resolve_root ;;
    source) jenga_resolve_source ;;
    tree)   jenga_resolve_tree ;;
    get)
      if [ "$rel" = "1" ]; then jenga_resolve_path "$key" --relative; else jenga_resolve_path "$key"; fi
      ;;
    list)
      if [ "$rel" = "1" ]; then jenga_resolve_list --relative; else jenga_resolve_list; fi
      ;;
    *) _jenga_usage; return 2 ;;
  esac
}

# Dispatch only when executed, never when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  _jenga_main "$@"
  exit $?
fi
