#!/usr/bin/env bash
################################################################################
# test-estimate.sh — up-front duration estimate for a selection of test files
# (E95_S02_T02)
#
# Reads the test timing log (project/logs/test-timings.jsonl, written only by
# skills/j-test/scripts/record-timing.sh) and estimates how long running the given
# test files would take. Shared by the runner and by agents deciding whether to ask
# the user before a run (threshold: `test-thresholds.sh get ask-before-run`).
# Read-only: it writes nothing and runs no test.
#
# Usage:
#   test-estimate.sh [--timings <path>] [--json] <file>...
#   test-estimate.sh [--timings <path>] [--json] --files-from <file|->
#   test-estimate.sh --help
#
#   <file>               a root-relative test path as recorded in the log's `suite`
#                        field (e.g. tests/example.bats); a leading ./ is dropped.
#   --files-from <f|->   read paths one per line from a file or stdin (blank lines
#                        ignored); may be combined with positional paths.
#   --timings <path>     the timing log to read. Default: <logs dir>/test-timings.jsonl,
#                        where the logs dir comes from scripts/resolve-root.sh, else
#                        <repo root>/project/logs.
#   --json               print one JSON object instead of the text lines.
#
# HOW A FILE IS ESTIMATED. Only `scope: "file"` records count (a file run alone). For
# each path, the newest such record by `date` wins. The key is the PATH (`suite`),
# never the `blob`: tagging a file changes its blob without changing its cost, and
# a blob match would turn every retagged file untimed. A `timeout` record carries
# the cap as its duration, so it counts as that many milliseconds (a lower bound).
#
# SERIAL SUM ONLY. The estimate is the plain sum of the per-file durations. There is
# no model of parallel execution, machine load or cache warmth; treat it as an order
# of magnitude.
#
# UNTIMED FILES. A path with no file record is counted and named, never priced at
# zero silently: the summary says the estimate excludes it. A missing timing log
# (the public mirror ships no project/logs/) makes every file untimed; that is exit 0.
#
# OUTPUT (text):
#   estimate: <seconds> s for <n> file(s) (<k> timed, <u> untimed)[; excludes <u> untimed file(s)]
#   untimed: <path>                      (one line per untimed file, input order)
# OUTPUT (--json):
#   {"files":n,"timed":k,"untimed":[...],"estimated_seconds":s}
# <seconds> is the summed duration_ms / 1000, rounded up to a whole second.
# A path given twice is counted once.
#
# EXIT CODES
#   0  estimate printed (including all-untimed and a missing log)
#   2  usage error, no paths given, unreadable --files-from, or jq not installed
#   6  the timing log exists but cannot be read or holds a line that is not JSON
#
# Requires jq. macOS bash 3.2 compatible.
################################################################################

set -u

SCRIPT_NAME="test-estimate.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

usage() {
  cat <<'EOF'
Usage: test-estimate.sh [--timings <path>] [--json] <file>...
       test-estimate.sh [--timings <path>] [--json] --files-from <file|->
       test-estimate.sh --help

Estimate the serial run time of the given test files from the newest
`scope: file` record per path in the test timing log. Untimed files are
counted and named; the estimate excludes them.

  --files-from <f|->  read paths one per line from a file or stdin
  --timings <path>    timing log (default: <logs dir>/test-timings.jsonl)
  --json              print {"files","timed","untimed","estimated_seconds"}
  --help              show this help and exit 0

Exit: 0 estimate printed, 2 usage error or jq missing, 6 timing log unreadable
EOF
}

die_usage() {
  err "$1"
  usage >&2
  exit 2
}

default_timings() {
  local dir="" top=""
  if [ -f "$SCRIPT_DIR/resolve-root.sh" ]; then
    dir="$(bash "$SCRIPT_DIR/resolve-root.sh" get logs 2>/dev/null)" || dir=""
  fi
  if [ -z "$dir" ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
    [ -n "$top" ] || top="$PWD"
    dir="$top/project/logs"
  fi
  printf '%s/test-timings.jsonl' "$dir"
}

PATHS_FILE=""
TIMINGS=""
JSON=0
FILES_FROM=""
PATH_LIST=""

add_path() {
  local p="$1"
  p="${p#./}"
  [ -n "$p" ] || return 0
  PATH_LIST="${PATH_LIST}${p}
"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --json) JSON=1; shift ;;
    --timings)
      [ "$#" -ge 2 ] || die_usage "--timings needs a path argument"
      TIMINGS="$2"; shift 2 ;;
    --files-from)
      [ "$#" -ge 2 ] || die_usage "--files-from needs a file argument (or - for stdin)"
      FILES_FROM="$2"; shift 2 ;;
    --) shift; while [ "$#" -gt 0 ]; do add_path "$1"; shift; done ;;
    -?*) die_usage "unknown option: $1" ;;
    *) add_path "$1"; shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || { err "jq is required but not installed (install jq, e.g. brew install jq)"; exit 2; }

if [ -n "$FILES_FROM" ]; then
  if [ "$FILES_FROM" = "-" ]; then
    PATHS_FILE="$(cat)"
  else
    [ -f "$FILES_FROM" ] && [ -r "$FILES_FROM" ] || die_usage "--files-from is not a readable file: $FILES_FROM"
    PATHS_FILE="$(cat -- "$FILES_FROM")"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    # trim surrounding whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    add_path "$line"
  done <<EOF
$PATHS_FILE
EOF
fi

[ -n "$PATH_LIST" ] || die_usage "no test files given"

[ -n "$TIMINGS" ] || TIMINGS="$(default_timings)"

# The selection as a JSON array, duplicates removed, input order kept.
SELECTION="$(printf '%s' "$PATH_LIST" | jq -R -s -c 'split("\n") | map(select(length > 0)) | reduce .[] as $p ([]; if index([$p]) then . else . + [$p] end)')" \
  || { err "could not read the path list"; exit 2; }

# Latest scope:file duration per path, as {"<path>": ms}. Empty object when no log.
LATEST='{}'
if [ -e "$TIMINGS" ]; then
  [ -f "$TIMINGS" ] && [ -r "$TIMINGS" ] || { err "cannot read the timing log: $TIMINGS"; exit 6; }
  LATEST="$(jq -c -n --argjson sel "$SELECTION" '
      [inputs
       | select(type == "object" and .scope == "file" and (.suite | type) == "string"
                and (.duration_ms | type) == "number")
       | select(.suite as $s | $sel | index([$s]))]
      | group_by(.suite)
      | map(max_by(.date // "") | {key: .suite, value: .duration_ms})
      | from_entries' "$TIMINGS" 2>/dev/null)" \
    || { err "the timing log holds a line that is not JSON: $TIMINGS"; exit 6; }
fi

RESULT="$(jq -c -n --argjson sel "$SELECTION" --argjson lat "$LATEST" '
    ($sel | map(select($lat[.] != null))) as $timed
    | ($sel | map(select($lat[.] == null))) as $untimed
    | ([$timed[] | $lat[.]] | add // 0) as $ms
    | {files: ($sel | length), timed: ($timed | length), untimed: $untimed,
       estimated_seconds: (($ms / 1000) | ceil)}')" \
  || { err "could not compute the estimate"; exit 6; }

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$RESULT"
  exit 0
fi

printf '%s\n' "$RESULT" | jq -r '
  (.untimed | length) as $u
  | "estimate: \(.estimated_seconds) s for \(.files) file(s) (\(.timed) timed, \($u) untimed)"
    + (if $u > 0 then "; excludes \($u) untimed file(s)" else "" end),
    (.untimed[] | "untimed: \(.)")'
exit 0
