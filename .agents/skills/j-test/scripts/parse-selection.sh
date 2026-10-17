#!/usr/bin/env bash
################################################################################
# parse-selection.sh — parse and validate the answer typed at the j.test prompt
# (E72_S02_T03)
#
#   Enter selection (comma-separated, or 'all' for all, or blank for 1 through N):
#
# Per CLAUDE.md's "Scripts Over Inline Logic" principle the model never parses
# or validates that answer itself: SKILL.md calls this script and relays the
# result. The script takes only N and the raw string, so it needs no catalog and
# no repository root and is testable in isolation.
#
# Usage:
#   parse-selection.sh <N> [<input>]
#   parse-selection.sh --help
#
#   <N>      number of runnable suites in the catalog (the N in "1 through N");
#            a positive integer of at most 9 digits
#   <input>  the raw string the user typed; a missing argument is the same as
#            an empty string
#
# Exit codes
#   0  valid selection (or --help): the selected suite numbers are on stdout,
#      one per line, in the order the user gave them
#   1  invalid selection: NOTHING on stdout, one message per problem on stderr
#   2  usage error (missing or non-positive <N>, more than two arguments):
#      a usage line on stderr
#
# Grammar (normative)
#   1. Leading/trailing whitespace on the whole input is ignored. An empty or
#      whitespace-only input means ALL: 1 through N.
#   2. The word `all`, case-insensitive, means ALL. It is only valid alone:
#      `all,2` and `2,all` are invalid.
#   3. Otherwise the input is a comma-separated list of positive integers.
#      Whitespace around each token is ignored (`1, 3` is valid). A token must
#      match ^[1-9][0-9]*$ once trimmed: `0`, `-1`, `01`, `1.5`, `abc` and an
#      empty token (`1,,3`, a leading or trailing comma) are invalid.
#   4. Every number must be in 1..N.
#   5. A number may appear only once. `1,3,1` is invalid; it is never silently
#      deduplicated, since a repeated entry usually means a typo. The message is
#      printed once per repeated number, however many times it repeats.
#   6. Ranges (`1-3`) are NOT supported; the message says so and suggests `all`
#      or an explicit list.
#   7. Order is preserved exactly as given: `3,1` prints 3 then 1.
#
# Every problem is reported, not just the first, each on its own line, each
# naming the offending token and the valid range, in the order the tokens were
# given. A repeated number that is also out of range gets the out-of-range
# message for its first occurrence and the duplicate message for the rest.
#
# Constraints: macOS bash 3.2 compatible (no associative arrays, no mapfile, no
# ${var,,}; lower-casing is done with tr), no dependency beyond coreutils,
# writes nothing to disk, executes nothing from the input (it is only ever
# compared and printed, never evaluated). Output is byte-identical for
# identical arguments.
################################################################################

set -euo pipefail
export LC_ALL=C

usage() {
  printf 'usage: parse-selection.sh <N> [<input>]\n'
}

if [ "${1:-}" = "--help" ]; then
  usage
  printf '\n'
  printf 'Parses the j.test selection prompt answer for a catalog of N suites.\n'
  printf 'Prints the chosen suite numbers one per line, in the order given.\n'
  printf 'Exit 0 valid, 1 invalid selection (problems on stderr), 2 usage error.\n'
  exit 0
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage >&2
  exit 2
fi

N="$1"
case "$N" in
  '' | *[!0-9]* | 0*)
    printf 'parse-selection.sh: <N> must be a positive integer, got '"'%s'"'\n' "$N" >&2
    usage >&2
    exit 2
    ;;
esac
if [ "${#N}" -gt 9 ]; then
  printf 'parse-selection.sh: <N> must be at most 9 digits, got '"'%s'"'\n' "$N" >&2
  usage >&2
  exit 2
fi

RAW="${2:-}"

# trim <string>: strip leading and trailing whitespace (bash 3.2 safe).
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# all_numbers: print 1 through N, one per line.
all_numbers() {
  local i=1
  while [ "$i" -le "$N" ]; do
    printf '%s\n' "$i"
    i=$((i + 1))
  done
}

INPUT="$(trim "$RAW")"

if [ -z "$INPUT" ]; then
  all_numbers
  exit 0
fi

if [ "$(printf '%s' "$INPUT" | tr '[:upper:]' '[:lower:]')" = "all" ]; then
  all_numbers
  exit 0
fi

RANGE_TEXT="choose 1 through $N"
SELECTED=""   # newline-terminated accepted numbers, in the order given
SEEN=" "      # space-delimited numbers already listed
DUP_REPORTED=" "
PROBLEMS=""   # newline-terminated messages

add_problem() {
  PROBLEMS="${PROBLEMS}invalid selection '$1': $2, $RANGE_TEXT
"
}

# Walk the comma-separated tokens, keeping empty ones (a trailing comma must
# yield an empty token, which `read -a` would drop).
REST="${INPUT},"
while [ -n "$REST" ]; do
  RAW_TOKEN="${REST%%,*}"
  REST="${REST#*,}"
  TOKEN="$(trim "$RAW_TOKEN")"

  case "$TOKEN" in
    '')
      add_problem "$TOKEN" "empty entry (stray comma)"
      continue
      ;;
  esac

  if [ "$(printf '%s' "$TOKEN" | tr '[:upper:]' '[:lower:]')" = "all" ]; then
    add_problem "$TOKEN" "'all' cannot be combined with other entries"
    continue
  fi

  case "$TOKEN" in
    [0-9]*-[0-9]*)
      # digits-dash-digits only; anything else falls through to the generic case
      case "$TOKEN" in
        *[!0-9-]* | *-*-*) ;;
        *)
          add_problem "$TOKEN" "ranges are not supported, use 'all' or list the numbers (for example 1,2,3)"
          continue
          ;;
      esac
      ;;
  esac

  case "$TOKEN" in
    [1-9] | [1-9][0-9]*)
      case "$TOKEN" in
        *[!0-9]*)
          add_problem "$TOKEN" "not a positive whole number"
          continue
          ;;
      esac
      ;;
    *)
      add_problem "$TOKEN" "not a positive whole number"
      continue
      ;;
  esac

  # TOKEN is now ^[1-9][0-9]*$.
  case "$SEEN" in
    *" $TOKEN "*)
      case "$DUP_REPORTED" in
        *" $TOKEN "*) ;;
        *)
          add_problem "$TOKEN" "listed more than once"
          DUP_REPORTED="${DUP_REPORTED}${TOKEN} "
          ;;
      esac
      continue
      ;;
  esac
  SEEN="${SEEN}${TOKEN} "

  if [ "${#TOKEN}" -gt 9 ] || [ "$TOKEN" -gt "$N" ]; then
    add_problem "$TOKEN" "out of range"
    continue
  fi

  SELECTED="${SELECTED}${TOKEN}
"
done

if [ -n "$PROBLEMS" ]; then
  printf '%s' "$PROBLEMS" >&2
  exit 1
fi

printf '%s' "$SELECTED"
exit 0
