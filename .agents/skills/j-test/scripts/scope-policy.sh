#!/usr/bin/env bash
################################################################################
# scope-policy.sh — the effective test-run mode of a board scope (E72_S06_T02)
#
# The deterministic resolver the scope test gate (scope-test-gate.sh, E72_S06_T03)
# and any other caller use to learn which test-run mode applies before a task, a
# story or an epic is closed. No agent parses test-config.json itself. The script
# only reads: it writes nothing to the repository or to disk, runs no suite and no
# project code, and never touches board status.
#
# Usage:
#   scope-policy.sh get <task|story|epic> [--root <dir>] [--config <file>]
#   scope-policy.sh --help
#
#   get <scope>       resolve the mode for one scope: task, story or epic.
#   --root <dir>      project root the configs directory is resolved against
#                     (JENGA_PROJECT_ROOT semantics of scripts/resolve-root.sh,
#                     with the resolver's relative `configs` path joined onto the
#                     root as the fallback). Default: the configs directory the
#                     resolver finds from $PWD (or JENGA_PROJECT_ROOT). Must be an
#                     existing directory.
#   --config <file>   read this file instead of <configs dir>/test-config.json.
#                     Wins over --root for locating the file.
#
# CONFIGURATION. The mode of a scope is the value of one flat top-level string key
# of test-config.json (the same flat shape as commit_prompt_default, because the
# config descriptor can express an editable key only as a scalar):
#
#   scope   key              default   allowed values
#   task    test_run_task    none      none | scoped | full
#   story   test_run_story   scoped    none | scoped | full
#   epic    test_run_epic    full      none | scoped | full
#
# STDOUT. Exactly one line in every non-usage case: the mode token (`none`,
# `scoped` or `full`) and nothing else. Warnings and usage go to stderr only.
#
# ABSENT versus INVALID (neither is ever a failure, and neither ever skips
# testing: the fallback is always the scope's default from the table above):
#   - Absent. No configs directory, no test-config.json, a path that is not a
#     regular file, an empty or whitespace-only file, or a JSON object without the
#     key: the default is printed, silently (nothing on stderr), exit 0. Older
#     configs lack the keys; that is not an error.
#   - Invalid. The key is present but holds anything other than "none", "scoped"
#     or "full" (another string, the empty string, a number, a boolean, null, an
#     object, an array): the default is printed, exit 0, and ONE warning line goes
#     to stderr naming the key, the offending value (as JSON) and the default used:
#       scope-policy.sh: test_run_story is "banana", expected "none", "scoped" or "full"; using the default "scoped"
#   - Unreadable. The file cannot be read, is malformed JSON, is not a JSON object,
#     or jq is not installed: treated like an invalid value (the default, exit 0,
#     one warning line naming the key and saying the value could not be read):
#       scope-policy.sh: test_run_story: value unavailable (<why>); using the default "scoped"
#
# EXIT CODES
#   0    resolved: one mode token on stdout (including every fallback above)
#   2    usage error (stdout empty, message plus usage on stderr): no or unknown
#        subcommand, missing or unknown scope, extra argument, unknown option, an
#        option without its argument, or a --root that is not a directory
#
# Exit 1 is deliberately unused: a resolver that could fail would let a scope be
# closed without the gate it asks for. Requires jq for reading the config (see
# "Unreadable"). macOS bash 3.2 compatible.
################################################################################

set -euo pipefail

SCRIPT_NAME="scope-policy.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-test/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

usage() {
  cat <<'EOF'
Usage: scope-policy.sh get <task|story|epic> [--root <dir>] [--config <file>]
       scope-policy.sh --help

Print the effective test-run mode of a board scope: none, scoped or full.

  get <scope>       task (default none), story (default scoped), epic (default full)
  --root <dir>      project root to resolve the configs directory against
  --config <file>   read this file instead of <configs dir>/test-config.json
  --help            show this help and exit 0

The mode is read from the key test_run_<scope> of test-config.json. An absent
key, file or empty file prints the default silently; an invalid value or an
unreadable file prints the default plus one warning on stderr.

Exit: 0 resolved (a single token on stdout), 2 usage error
EOF
}

die_usage() {
  err "$1"
  usage >&2
  exit 2
}

# A checkout first, then the installed-package location (the sibling pattern).
find_resolver() {
  local candidate
  for candidate in "$REPO_ROOT/scripts/resolve-root.sh" \
                   "$REPO_ROOT/node_modules/@jenga-ai/agent/scripts/resolve-root.sh"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Prints the configs directory, or nothing when it cannot be resolved. $1 is the
# (already validated and absolute) --root, or empty.
config_dir() {
  local root="$1" resolver dir="" rel=""
  if resolver="$(find_resolver)"; then
    if [ -n "$root" ]; then
      dir="$(JENGA_PROJECT_ROOT="$root" bash "$resolver" get configs 2>/dev/null)" || dir=""
      if [ -z "$dir" ]; then
        rel="$(cd -- "$root" && JENGA_PROJECT_ROOT="" bash "$resolver" --relative get configs 2>/dev/null)" || rel=""
        [ -z "$rel" ] || dir="$root/$rel"
      fi
    else
      dir="$(bash "$resolver" get configs 2>/dev/null)" || dir=""
    fi
  elif [ -n "$root" ]; then
    # No resolver installed: the consuming-project default layout.
    dir="$root/project/configs"
  fi
  printf '%s' "$dir"
}

# ---- arguments ----------------------------------------------------------------
SUBCOMMAND=""
SCOPE=""
ROOT_ARG=""
CONFIG_ARG=""
CONFIG_GIVEN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --root)
      [ "$#" -ge 2 ] || die_usage "--root needs a directory argument"
      ROOT_ARG="$2"
      shift 2
      ;;
    --config)
      [ "$#" -ge 2 ] || die_usage "--config needs a file argument"
      CONFIG_ARG="$2"
      CONFIG_GIVEN=1
      shift 2
      ;;
    -*)
      die_usage "unknown option: $1"
      ;;
    *)
      if [ -z "$SUBCOMMAND" ]; then
        SUBCOMMAND="$1"
      elif [ -z "$SCOPE" ]; then
        SCOPE="$1"
      else
        die_usage "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[ -n "$SUBCOMMAND" ] || die_usage "missing subcommand (expected: get)"
[ "$SUBCOMMAND" = "get" ] || die_usage "unknown subcommand: $SUBCOMMAND (expected: get)"
[ -n "$SCOPE" ] || die_usage "missing scope (expected: task, story or epic)"

case "$SCOPE" in
  task)  DEFAULT="none" ;;
  story) DEFAULT="scoped" ;;
  epic)  DEFAULT="full" ;;
  *) die_usage "unknown scope: $SCOPE (expected: task, story or epic)" ;;
esac
KEY="test_run_${SCOPE}"

ROOT=""
if [ -n "$ROOT_ARG" ]; then
  [ -d "$ROOT_ARG" ] || die_usage "--root is not a directory: $ROOT_ARG"
  ROOT="$(cd -- "$ROOT_ARG" && pwd)"
fi

# ---- locate the file ------------------------------------------------------------
if [ "$CONFIG_GIVEN" -eq 1 ]; then
  CFG="$CONFIG_ARG"
else
  CFG_DIR="$(config_dir "$ROOT")"
  CFG=""
  [ -z "$CFG_DIR" ] || CFG="$CFG_DIR/test-config.json"
fi

# ---- resolve --------------------------------------------------------------------
emit_default() { printf '%s\n' "$DEFAULT"; }

unreadable() {
  err "$KEY: value unavailable ($1); using the default \"$DEFAULT\""
  emit_default
  exit 0
}

# No path, or nothing at that path: absent, silently.
if [ -z "$CFG" ] || { [ ! -e "$CFG" ] && [ ! -L "$CFG" ]; }; then
  emit_default
  exit 0
fi

# Something exists but is not a regular, readable file.
if [ ! -f "$CFG" ]; then
  unreadable "$CFG is not a regular file"
fi
if [ ! -r "$CFG" ]; then
  unreadable "$CFG is not readable"
fi

# An empty or whitespace-only file: absent, silently.
if ! grep -q '[^[:space:]]' "$CFG" 2>/dev/null; then
  emit_default
  exit 0
fi

command -v jq >/dev/null 2>&1 || unreadable "jq is not installed"

# One jq pass. A = key absent, V<mode> = valid, I<json> = present but invalid.
if ! val="$(jq -r --arg k "$KEY" '
      if type == "object"
      then (if has($k) | not then "A"
            else (.[$k]
                  | if type == "string" and (. == "none" or . == "scoped" or . == "full")
                    then "V" + .
                    else "I" + tojson end)
            end)
      else error("not an object") end' "$CFG" 2>/dev/null)"; then
  unreadable "$(basename -- "$CFG") is not valid JSON or not a JSON object"
fi

case "$val" in
  A)
    emit_default
    ;;
  V*)
    printf '%s\n' "${val#V}"
    ;;
  I*)
    err "$KEY is ${val#I}, expected \"none\", \"scoped\" or \"full\"; using the default \"$DEFAULT\""
    emit_default
    ;;
  *)
    unreadable "unexpected result reading $(basename -- "$CFG")"
    ;;
esac
exit 0
