#!/usr/bin/env bash
################################################################################
# run-suites.sh — run the selected j.test suites in order and summarise (E72_S02_T04)
#
# Consumes the catalog JSON that build-catalog.sh prints (its header holds the
# normative contract) and never calls build-catalog.sh or discover-tests.sh.
# Reads only `runnable[]` entries `{n,name,type,command,...}`; every other field,
# and `not_runnable`, is ignored. Never runs a command that is not in the catalog.
#
# Usage:
#   run-suites.sh --catalog <catalog.json> [--root <dir>] <n> [<n> ...]
#   run-suites.sh --help
#
#   --catalog <file>  catalog JSON (required)
#   --root <dir>      directory the commands run in (discovery's commands are
#                     relative to the scanned root). Defaults to the root
#                     scripts/resolve-root.sh resolves.
#   <n> ...           suite numbers, in the order to run (parse-selection.sh's
#                     output). At least one; each a plain positive integer.
#
# VALIDATION happens first, before anything runs. An unreadable or invalid
# catalog, a number that is malformed, repeated or not a runnable suite, no
# numbers, or an unknown flag print the cause to stderr and exit 2: a half-run
# on a bad selection is worse than none.
#
# EXECUTION. Suites run one at a time, in argument order, each exactly once.
# Header line `==> [i/total] <name> (<type>)`, then `bash -c "<command>"` from the
# root (the command is one shell string, never word-split here, so globs and
# pipes work). stdin is /dev/null so a prompting suite cannot hang the run;
# stdout and stderr pass straight through, so a long suite shows progress.
# A failing suite (non-zero, including 127) does not stop the run.
#
# INTERRUPT. SIGINT/SIGTERM stops the running suite (its whole process group:
# TERM, then KILL after a short grace), starts no further suite, prints the
# summary and exits 130. The suite that was running is listed `(interrupted)`,
# the ones never started `(not run)`. Note: a shell started with `&` from a
# non-interactive parent ignores SIGINT and cannot trap it; send SIGTERM (or
# start the script under `set -m`) in that situation.
#
# SUMMARY (stdout, after the last suite; exact layout):
#   Test Results
#   ============
#   ✓ npm test (unit)
#   ✗ shellcheck (sast)
#
#   1 passed, 1 failed. Exit code: 1
# One line per selected suite in run order, labelled `name (type)` (` (type)` is
# not appended when the name already ends in it, the same rule as the numbered
# list in build-catalog.sh). After an interrupt, unfinished suites are listed as
# `- name (type) (not run)` / `- name (type) (interrupted)` and the last line
# reads `<P> passed, <F> failed, <U> not finished. Exit code: 130`.
#
# EXIT CODES
#   0    every selected suite passed
#   1    at least one failed
#   2    validation or usage error (nothing ran); also jq missing or the root
#        unresolvable, since exit 1 must only ever mean "a suite failed"
#   130  interrupted
#
# The locale is forced to C for this script's own bookkeeping only; the suites
# get the caller's original locale back. Writes nothing to disk. macOS bash 3.2
# compatible. Requires jq plus coreutils.
################################################################################

set -euo pipefail

SCRIPT_NAME="run-suites.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-test/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

# Remember the caller's locale so suites see it, then pin ours.
ORIG_LC_ALL_SET=0
ORIG_LC_ALL=""
if [ "${LC_ALL+set}" = "set" ]; then
  ORIG_LC_ALL_SET=1
  ORIG_LC_ALL="$LC_ALL"
fi
export LC_ALL=C

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

die_usage() {
  err "$1"
  exit 2
}

usage() {
  cat <<'EOF'
Usage: run-suites.sh --catalog <catalog.json> [--root <dir>] <n> [<n> ...]
       run-suites.sh --help

Run the selected suites from a build-catalog.sh catalog, in the order given,
then print the result summary.

  --catalog <file>  catalog JSON printed by build-catalog.sh (required)
  --root <dir>      directory the commands run in (default: the resolved root)
  <n> ...           suite numbers to run, in order; at least one, no repeats
  --help            show this help and exit 0

Exit: 0 all passed, 1 a suite failed, 2 usage/validation error (nothing ran),
      130 interrupted
EOF
}

# Mirrors the resolve_helper pattern of discover-tests.sh: a checkout first,
# then the installed-package location.
resolve_helper() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# ---- arguments ----------------------------------------------------------------
CATALOG=""
ROOT=""
ROOT_GIVEN=0
NUMS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --catalog)
      [ "$#" -ge 2 ] || die_usage "--catalog needs a file argument"
      CATALOG="$2"
      shift 2
      ;;
    --root)
      [ "$#" -ge 2 ] || die_usage "--root needs a directory argument"
      ROOT="$2"
      ROOT_GIVEN=1
      shift 2
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        NUMS+=("$1")
        shift
      done
      ;;
    -*)
      die_usage "unknown option: $1 (see --help)"
      ;;
    *)
      NUMS+=("$1")
      shift
      ;;
  esac
done

[ -n "$CATALOG" ] || die_usage "--catalog <catalog.json> is required (see --help)"
[ "${#NUMS[@]}" -gt 0 ] || die_usage "no suite numbers given; at least one is required (see --help)"

command -v jq >/dev/null 2>&1 || die_usage "jq is required but was not found on PATH"

# ---- catalog ------------------------------------------------------------------
[ -f "$CATALOG" ] && [ -r "$CATALOG" ] || die_usage "catalog is not a readable file: $CATALOG"

CATALOG_JSON="$(jq -c -s 'if length == 1 then .[0] else error("expected exactly one JSON value") end' \
  "$CATALOG" 2>/dev/null)" || die_usage "catalog is not valid JSON: $CATALOG"

printf '%s' "$CATALOG_JSON" | jq -e 'type == "object" and (.runnable | type == "array")' >/dev/null 2>&1 \
  || die_usage "catalog is not a catalog object with a runnable array: $CATALOG"

# Counts entries of runnable[] numbered $1 that carry a non-empty string command.
count_runnable() {
  printf '%s' "$CATALOG_JSON" | jq -r --argjson n "$1" \
    '[.runnable[] | select(type == "object" and .n == $n and ((.command // "") | type == "string" and length > 0))] | length'
}

# Prints one field of the runnable entry numbered $1; $2 is a jq expression over it.
entry_field() {
  printf '%s' "$CATALOG_JSON" | jq -r --argjson n "$1" \
    "[.runnable[] | select(type == \"object\" and .n == \$n)] | first | $2"
}

RUNNABLE_COUNT="$(printf '%s' "$CATALOG_JSON" | jq -r '.runnable | length')"

# ---- selection ----------------------------------------------------------------
# Everything is checked before the first suite runs.
SEEN=" "
for num in "${NUMS[@]}"; do
  case "$num" in
    ''|*[!0-9]*|0*)
      die_usage "not a suite number: '$num' (expected a positive integer without leading zeros)"
      ;;
  esac
  case "$SEEN" in
    *" $num "*) die_usage "suite $num was given more than once" ;;
  esac
  SEEN="$SEEN$num "

  found="$(count_runnable "$num")"
  if [ "$found" -eq 0 ]; then
    if [ "$RUNNABLE_COUNT" -eq 0 ]; then
      die_usage "suite $num is not runnable: the catalog has no runnable suites"
    fi
    die_usage "suite $num is not a runnable suite in the catalog (valid: 1 through $RUNNABLE_COUNT)"
  elif [ "$found" -gt 1 ]; then
    die_usage "suite $num appears more than once in the catalog"
  fi
done

# ---- root ---------------------------------------------------------------------
if [ "$ROOT_GIVEN" -eq 0 ]; then
  RESOLVER="$(resolve_helper scripts/resolve-root.sh)" || die_usage "could not locate scripts/resolve-root.sh"
  ROOT="$(bash "$RESOLVER" root)" || die_usage "could not resolve the working root"
fi
[ -d "$ROOT" ] || die_usage "root is not a directory: $ROOT"
ROOT="$(cd -- "$ROOT" && pwd)"

# ---- gather the selected entries ------------------------------------------------
NAMES=()
TYPES=()
LABELS=()
CMDS=()
for num in "${NUMS[@]}"; do
  # shellcheck disable=SC2016  # $n is a jq variable (--argjson n), not a shell expansion
  name="$(entry_field "$num" '(.name // .id // "suite \($n)") | tostring')"
  type="$(entry_field "$num" '(.type // "unknown") | tostring')"
  NAMES+=("$name")
  TYPES+=("$type")
  case "$name" in
    *" ($type)") LABELS+=("$name") ;;
    *) LABELS+=("$name ($type)") ;;
  esac
  # command substitution drops only trailing newlines, which bash -c does not need
  CMDS+=("$(entry_field "$num" '.command')")
done

TOTAL="${#NUMS[@]}"
# STATUS per suite: pending | pass | fail | interrupted
STATUS=()
for ((k = 0; k < TOTAL; k++)); do
  STATUS+=("pending")
done

# ---- interrupt handling -----------------------------------------------------------
INTERRUPTED=0
CHILD=""

# Stop the running suite's process group: TERM, a bounded grace, then KILL.
stop_child() {
  local pid="$CHILD" waited=0
  [ -n "$pid" ] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  while [ "$waited" -lt 20 ] && kill -0 -- "-$pid" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 -- "-$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
}

# shellcheck disable=SC2329  # invoked indirectly, through the INT/TERM trap below
on_signal() {
  INTERRUPTED=1
  stop_child
}

trap on_signal INT TERM
# Job control gives each suite its own process group, so stop_child reaches its
# descendants (a `bash -c "a; b"` suite, a pipeline), not just the shell.
set -m

# ---- run ----------------------------------------------------------------------
i=0
while [ "$i" -lt "$TOTAL" ]; do
  [ "$INTERRUPTED" -eq 0 ] || break

  printf '==> [%d/%d] %s\n' "$((i + 1))" "$TOTAL" "${LABELS[$i]}"

  (
    cd -- "$ROOT" || exit 126
    # Hand the suite the caller's locale back. `env -u` rather than `unset`:
    # `unset LC_ALL` in a subshell segfaults bash 5.3.20 on macOS.
    if [ "$ORIG_LC_ALL_SET" -eq 1 ]; then
      exec env LC_ALL="$ORIG_LC_ALL" bash -c "${CMDS[$i]}"
    fi
    exec env -u LC_ALL bash -c "${CMDS[$i]}"
  ) </dev/null &
  CHILD=$!
  # A signal that landed between the check above and the launch.
  if [ "$INTERRUPTED" -eq 1 ]; then
    stop_child
  fi

  rc=0
  { wait "$CHILD" || rc=$?; } 2>/dev/null
  # `wait` returns early (128+n) when a trapped signal arrives; the handler has
  # already stopped the child, so reap its real status before moving on.
  if [ "$INTERRUPTED" -eq 1 ]; then
    { wait "$CHILD" || true; } 2>/dev/null
    STATUS[i]="interrupted"
    CHILD=""
    break
  fi
  CHILD=""

  if [ "$rc" -eq 0 ]; then
    STATUS[i]="pass"
  else
    STATUS[i]="fail"
  fi
  i=$((i + 1))
done

# A signal during the summary must not cut it short.
trap '' INT TERM
set +m

# ---- summary ------------------------------------------------------------------
PASSED=0
FAILED=0
UNFINISHED=0
for ((k = 0; k < TOTAL; k++)); do
  case "${STATUS[$k]}" in
    pass) PASSED=$((PASSED + 1)) ;;
    fail) FAILED=$((FAILED + 1)) ;;
    *) UNFINISHED=$((UNFINISHED + 1)) ;;
  esac
done

if [ "$INTERRUPTED" -eq 1 ]; then
  CODE=130
elif [ "$FAILED" -gt 0 ]; then
  CODE=1
else
  CODE=0
fi

{
  printf 'Test Results\n============\n'
  for ((k = 0; k < TOTAL; k++)); do
    case "${STATUS[$k]}" in
      pass) printf '✓ %s\n' "${LABELS[$k]}" ;;
      fail) printf '✗ %s\n' "${LABELS[$k]}" ;;
      interrupted) printf -- '- %s (interrupted)\n' "${LABELS[$k]}" ;;
      *) printf -- '- %s (not run)\n' "${LABELS[$k]}" ;;
    esac
  done
  printf '\n'
  if [ "$INTERRUPTED" -eq 1 ]; then
    printf '%d passed, %d failed, %d not finished. Exit code: %d\n' "$PASSED" "$FAILED" "$UNFINISHED" "$CODE"
  else
    printf '%d passed, %d failed. Exit code: %d\n' "$PASSED" "$FAILED" "$CODE"
  fi
}

exit "$CODE"
