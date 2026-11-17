#!/usr/bin/env bash
################################################################################
# record-timing.sh — the one writer of the test-timing log (E77_S06_T03)
#
# Appends exactly ONE record, describing the timed run of one test file, to
# project/logs/test-timings.jsonl. That log is the single source of truth for
# test timings (decision D2): whatever times a test file writes through this
# script, and whatever reports on timings reads only the log. There is no second
# result file.
#
# Usage:
#   record-timing.sh --suite <root-relative test path> --tests <n> --passed <n> --failed <n>
#                    --duration-ms <n> --caller <script name> --status passed|failed|timeout
#                    --commit <HEAD sha> --blob <git hash-object of the test file>
#                    [--load-1m <number>] [--cpu-ms <n>] [--log <path>]
#   record-timing.sh --help
#
# ---------------------------------------------------------------------------
# THE RECORD (normative; one JSON object per line, keys in this order)
#
#   {"date":"<ISO 8601 UTC>","suite":"<root-relative test path>","tests":<int>,
#    "passed":<int>,"failed":<int>,"duration_ms":<int>,"scope":"file",
#    "caller":"<script name>","status":"passed|failed|timeout",
#    "commit":"<HEAD sha>","blob":"<blob sha of the test file>","load_1m":<number|null>,
#    "cpu_ms":<int|null>}
#
#   The first eight keys are those asked for by the per-suite timing rapport
#   (test-runner-per-suite-timing-log.md); the last five are additive. `status`
#   separates a slow pass from a timeout; `commit` and `blob` let a later run
#   skip a file whose test and code did not change; `load_1m` lets a report
#   distrust a number taken on a busy machine (null when not supplied); `cpu_ms`
#   is the user plus system CPU time of the run, which unlike `duration_ms` does
#   not grow when the machine makes the run wait (null when not supplied, and
#   for a timeout).
#   `date` is stamped here, in UTC, at the moment of the call. `scope` is always
#   "file" today.
#
# FIELD RULES (a violation exits 2 and writes nothing)
#
#   --suite        non-empty, root-relative (no leading `/`), no control characters
#   --tests, --passed, --failed, --duration-ms
#                  non-negative integers (digits only, at most 15 of them);
#                  --passed plus --failed must not exceed --tests
#   --caller       non-empty, no control characters
#   --status       exactly passed, failed or timeout
#   --commit,
#   --blob         lowercase hex object names of 7 to 64 characters
#   --load-1m      optional; a non-negative decimal such as 3 or 3.42; the word
#                  `null` is the same as leaving it out
#   --cpu-ms       optional; a non-negative integer (digits only, at most 15 of
#                  them); the word `null` is the same as leaving it out
#   --log          optional target; default <logs>/test-timings.jsonl, where
#                  <logs> is what scripts/resolve-root.sh resolves for `logs`
#
# HOW IT WRITES
#
#   The append is delegated to scripts/events-append.sh --file <log>, so this
#   script keeps no second copy of the safe-append logic. That gives: one compact
#   ASCII line written with `>>` under scripts/with-lock.sh (two concurrent calls
#   leave two intact lines), no read-modify-write of the shared file, a missing
#   target created, and an unterminated last line repaired before the new record.
#   A target that is not JSONL is refused and left byte-identical.
#   This script reads and writes nothing outside --log.
#
# EXIT CODES
#   0  appended
#   2  usage error, or a bad field (nothing written)
#   4  the log exists but is not JSONL (from events-append.sh; nothing written)
#   5  neither jq nor python3 is available
#   other  the exit status of events-append.sh / with-lock.sh (2 = lock timeout,
#          nothing written)
################################################################################

set -u

SCRIPT_NAME="record-timing.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-test/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
REPO_ROOT="$(jenga_package_root "$SCRIPT_DIR")" || true
export LC_ALL=C

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

usage() {
  # the header comment is the contract: print all of it
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed -e '/^set -u/d' -e '/^#\{20,\}$/d' -e 's/^# \{0,1\}//'
}

bad() { err "$1"; exit 2; }

# a checkout first, then the installed-package location (same pattern as manual-only.sh)
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

SUITE="" TESTS="" PASSED="" FAILED="" DURATION="" CALLER="" STATUS="" COMMIT="" BLOB="" LOAD="" CPU="" LOG=""
HAVE_CPU=0 HAVE_LOAD=0 HAVE_SUITE=0 HAVE_TESTS=0 HAVE_PASSED=0 HAVE_FAILED=0 HAVE_DURATION=0 HAVE_CALLER=0 HAVE_STATUS=0 HAVE_COMMIT=0 HAVE_BLOB=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    --suite|--tests|--passed|--failed|--duration-ms|--caller|--status|--commit|--blob|--load-1m|--cpu-ms|--log)
      [ "$#" -ge 2 ] || bad "$1 needs a value"
      case "$1" in
        --suite) SUITE="$2"; HAVE_SUITE=1 ;;
        --tests) TESTS="$2"; HAVE_TESTS=1 ;;
        --passed) PASSED="$2"; HAVE_PASSED=1 ;;
        --failed) FAILED="$2"; HAVE_FAILED=1 ;;
        --duration-ms) DURATION="$2"; HAVE_DURATION=1 ;;
        --caller) CALLER="$2"; HAVE_CALLER=1 ;;
        --status) STATUS="$2"; HAVE_STATUS=1 ;;
        --commit) COMMIT="$2"; HAVE_COMMIT=1 ;;
        --blob) BLOB="$2"; HAVE_BLOB=1 ;;
        --load-1m) LOAD="$2"; HAVE_LOAD=1 ;;
        --cpu-ms) CPU="$2"; HAVE_CPU=1 ;;
        --log) LOG="$2" ;;
      esac
      shift 2 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

[ "$HAVE_SUITE" = 1 ] || bad "--suite is required"
[ "$HAVE_TESTS" = 1 ] || bad "--tests is required"
[ "$HAVE_PASSED" = 1 ] || bad "--passed is required"
[ "$HAVE_FAILED" = 1 ] || bad "--failed is required"
[ "$HAVE_DURATION" = 1 ] || bad "--duration-ms is required"
[ "$HAVE_CALLER" = 1 ] || bad "--caller is required"
[ "$HAVE_STATUS" = 1 ] || bad "--status is required"
[ "$HAVE_COMMIT" = 1 ] || bad "--commit is required"
[ "$HAVE_BLOB" = 1 ] || bad "--blob is required"

# a non-empty string with no control character (tab, newline, escape, ...)
check_text() {
  local name="$1" value="$2"
  [ -n "$value" ] || bad "$name must not be empty"
  case "$value" in
    *[[:cntrl:]]*) bad "$name must not contain control characters" ;;
  esac
}

# a non-negative integer, 1 to 15 digits (keeps the value exact in every JSON engine)
check_uint() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*) bad "$name must be a non-negative integer, got: $value" ;;
  esac
  [ "${#value}" -le 15 ] || bad "$name is too large: $value"
}

check_hex() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9a-f]*) bad "$name must be a lowercase hex object name, got: $value" ;;
  esac
  [ "${#value}" -ge 7 ] && [ "${#value}" -le 64 ] || bad "$name must be 7 to 64 hex characters, got: $value"
}

check_text --suite "$SUITE"
case "$SUITE" in
  /*) bad "--suite must be root-relative, got: $SUITE" ;;
esac
check_uint --tests "$TESTS"
check_uint --passed "$PASSED"
check_uint --failed "$FAILED"
check_uint --duration-ms "$DURATION"
# force base 10: a value with a leading zero must not be read as octal
[ $((10#$PASSED + 10#$FAILED)) -le $((10#$TESTS)) ] || bad "--passed plus --failed ($PASSED + $FAILED) exceeds --tests ($TESTS)"
check_text --caller "$CALLER"
case "$STATUS" in
  passed|failed|timeout) ;;
  *) bad "--status must be passed, failed or timeout, got: $STATUS" ;;
esac
check_hex --commit "$COMMIT"
check_hex --blob "$BLOB"

LOAD_JSON="null"
if [ -n "$LOAD" ] && [ "$LOAD" != "null" ]; then
  case "$LOAD" in
    *[!0-9.]*|.*|*.|*.*.*) bad "--load-1m must be a non-negative number or null, got: $LOAD" ;;
  esac
  [ "${#LOAD}" -le 15 ] || bad "--load-1m is too long: $LOAD"
  LOAD_JSON="$LOAD"
elif [ "$HAVE_LOAD" = 1 ] && [ -z "$LOAD" ]; then
  bad "--load-1m must be a non-negative number or null, got an empty value"
fi

CPU_JSON="null"
if [ "$HAVE_CPU" = 1 ] && [ "$CPU" != "null" ]; then
  check_uint --cpu-ms "$CPU"
  CPU_JSON="$CPU"
fi

# integers without leading zeros, so the record is valid JSON
norm_uint() { local v="$1"; v="${v#"${v%%[!0]*}"}"; printf '%s' "${v:-0}"; }
TESTS="$(norm_uint "$TESTS")"
PASSED="$(norm_uint "$PASSED")"
FAILED="$(norm_uint "$FAILED")"
DURATION="$(norm_uint "$DURATION")"
[ "$CPU_JSON" = "null" ] || CPU_JSON="$(norm_uint "$CPU_JSON")"
case "$LOAD_JSON" in
  null) ;;
  *) # 007 or 007.5 -> 7 or 7.5 (JSON forbids a leading zero before a digit)
     lead="${LOAD_JSON%%.*}"
     rest=""
     case "$LOAD_JSON" in *.*) rest=".${LOAD_JSON#*.}" ;; esac
     LOAD_JSON="$(norm_uint "$lead")$rest" ;;
esac

# the log path
if [ -z "$LOG" ]; then
  resolver="$(resolve_helper scripts/resolve-root.sh)" || bad "could not locate scripts/resolve-root.sh; pass --log"
  logs_dir="$(bash "$resolver" get logs 2>/dev/null)" && [ -n "$logs_dir" ] || bad "could not resolve the logs directory; pass --log"
  LOG="$logs_dir/test-timings.jsonl"
fi

appender="$(resolve_helper scripts/events-append.sh)" || bad "could not locate scripts/events-append.sh"

DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# build the record
if command -v jq >/dev/null 2>&1; then
  RECORD="$(jq -n -c -a \
    --arg date "$DATE" --arg suite "$SUITE" --arg caller "$CALLER" --arg status "$STATUS" \
    --arg commit "$COMMIT" --arg blob "$BLOB" \
    --argjson tests "$TESTS" --argjson passed "$PASSED" --argjson failed "$FAILED" \
    --argjson duration "$DURATION" --argjson load "$LOAD_JSON" --argjson cpu "$CPU_JSON" \
    '{date:$date, suite:$suite, tests:$tests, passed:$passed, failed:$failed, duration_ms:$duration,
      scope:"file", caller:$caller, status:$status, commit:$commit, blob:$blob, load_1m:$load, cpu_ms:$cpu}')" \
    || { err "could not build the record"; exit 1; }
elif command -v python3 >/dev/null 2>&1; then
  RECORD="$(python3 -c '
import sys, json
from collections import OrderedDict
a = sys.argv[1:]
load = json.loads(a[10])
cpu = json.loads(a[11])
r = OrderedDict([("date", a[0]), ("suite", a[1]), ("tests", int(a[2])), ("passed", int(a[3])),
                 ("failed", int(a[4])), ("duration_ms", int(a[5])), ("scope", "file"),
                 ("caller", a[6]), ("status", a[7]), ("commit", a[8]), ("blob", a[9]),
                 ("load_1m", load), ("cpu_ms", cpu)])
print(json.dumps(r, separators=(",", ":"), ensure_ascii=True))' \
    "$DATE" "$SUITE" "$TESTS" "$PASSED" "$FAILED" "$DURATION" "$CALLER" "$STATUS" "$COMMIT" "$BLOB" "$LOAD_JSON" "$CPU_JSON")" \
    || { err "could not build the record"; exit 1; }
else
  err "neither jq nor python3 is available"
  exit 5
fi

exec bash "$appender" --file "$LOG" "$RECORD"
