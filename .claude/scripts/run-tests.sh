#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/run-tests.sh - run the bats suite by tier: tier:fast by default, large runs only deliberately
# (E43_S02_T01 parallel runner; E95_S01_T02 timeout, --list; E95_S02_T03 tiers, --confirm-full above N files,
# nesting refusal, a timeout in every mode, up-front estimate, per-file progress; E95_S02_T08 several files at once,
# --jobs, relative tier:fast timeout)
#
# `npm test` delegates here with no arguments; `npm run test:ci` delegates here with `--all`. Every consumer of
# either (/publish's `test` gate, the public staging gate's `npm run test:ci`) gets whatever this script does, so
# its EXIT STATUS is the contract: non-zero if ANY bats invocation it ran failed or was timed out, zero only when
# every one of them passed.
#
# USAGE
#   scripts/run-tests.sh                        tier:fast under a max(180, 2 x estimate) s timeout      (= npm test)
#   scripts/run-tests.sh --tier <a>[,<b>...]    the files tagged with those tiers (fast unit integration slow manual)
#   scripts/run-tests.sh --all                  every tier except tier:manual                      (= npm run test:ci)
#   ... --confirm-full                          accept a selection of more than N files (see LARGE RUNS)
#   ... --jobs <n>                              run up to <n> files at once; 1 = one at a time (see PARALLEL FILES)
#   ... --list                                  print the selection (stdout) and its estimate (stderr); run nothing
#   scripts/run-tests.sh --help
#
# EXIT STATUS
#   0 every bats invocation passed   1.. the first failing bats status (first in completion order)   2 usage error
#   (unknown argument or tier, --tier with --all, a bad --jobs), an empty selection, a refused large run, or a
#   missing helper script   3 refused: started
#   from inside a bats run (NESTING)   124 the run hit its timeout (never a pass)   127 bats not on PATH
#
# ENVIRONMENT
#   RUN_TESTS_JOBS          positive integer; files run at once when --jobs is not given (wins over the config key),
#                           and the in-file `bats --jobs` count when files run one at a time. 1 means "do not
#                           parallelize". An invalid value is ignored with a warning.
#   RUN_TESTS_TIMEOUT       positive integer seconds; overrides the TIMEOUT RULE. Invalid: ignored with a warning.
#   CI                      `true` (GitHub Actions and most CI services) accepts a large run without --confirm-full.
#   RUN_TESTS_ALLOW_NESTED  TEST-ONLY. `1` disables the NESTING refusal. Set only by tests/run-tests.bats, whose
#                           stub-based cases call this script from inside bats with a stub `bats` on PATH and never
#                           start a real suite. No other caller may set it.
#
# SELECTION
#   Every top-level tests/*.bats carries one `# bats file_tags=tier:<name>` line (E95_S02_T01). The selection is
#   `scripts/test-tiers.sh list` (a pre-selection by the written tag; bats' --filter-tags is not needed):
#   `--tier <list>` takes exactly those tiers, `--all` takes every file not tagged tier:manual (an untagged file is
#   included, so a missing tag never drops a file from the broad run). tier:manual runs only when named in --tier.
#   Order: test-tiers.sh's byte order is the START order, except that SERIAL_FILES run last. An empty selection
#   exits 2: a run of nothing is never a pass.
#
# LARGE RUNS
#   A selection of more than N files, N = `full_run_confirm_file_count` read through
#   skills/j-test/scripts/test-thresholds.sh (`get confirm-file-count`, default 60), is refused with exit 2 unless
#   --confirm-full is given or CI=true. The refusal names the selection's file count and estimate, and the cheapest
#   tier that covers the request (the lowest of fast < unit < integration < slow among the requested tiers that
#   selects anything; for --all every one of the four is requested), with that tier's count and estimate.
#
# NESTING
#   A run started from inside a bats run is refused (exit 3): either E77_S01's flag JENGA_NESTED_SUITE_RUN=1, read
#   through tests/helpers/nested-suite.bash (`nested_suite_run_active`; the same flag read inline when the helper is
#   absent), or a surrounding bats process (BATS_TEST_FILENAME or BATS_RUN_TMPDIR in the environment).
#   --list runs nothing and is never refused. The only override is RUN_TESTS_ALLOW_NESTED (test-only, above).
#
# PARALLEL FILES (E95_S02_T08)
#   Up to J files run at once, each as its own bats invocation in its own process group, through the shared
#   scheduler scripts/parallel-files.sh (also used by the private mirror tool's pre-push gate). J, first match:
#   --jobs <n>; RUN_TESTS_JOBS; the key `test_parallel_jobs` of project/configs/test-config.json; else the CPU count
#   capped at 8. The non-serial files run as one batch of up to J at a time; SERIAL_FILES then run alone, one after
#   the other. With J > 1 each file runs as plain `bats <file>` and its output goes to its own file, printed only
#   when that file fails. With J = 1 (--jobs 1) the run is the E95_S02_T03 loop: one file at a time, bats' output
#   streamed unfiltered, and `bats --jobs N` inside each non-serial file when the parallel path is available (see
#   DEPENDENCY DETECTION). Parallelism is across files or within one file, never both, so J files never start
#   J x N processes.
#
# ESTIMATE AND PROGRESS
#   Before running, the output of scripts/test-estimate.sh for the selection is printed on stderr (untimed files
#   counted and named). When each file finishes (completion order) a progress line goes to stderr:
#       run-tests: [i/N] <file> ok|FAILED (exit s) <d> s (elapsed <e> s)
#   <d> is that file's own wall time. on_file_done() is called once per file with the same status and <d>: the
#   hook point for per-file records (E95_S07).
#
# TIMEOUT RULE (every mode)
#   RUN_TESTS_TIMEOUT when set; else, when the request is exactly `--tier fast` (the default, npm test),
#       timeout = max(180, 2 x estimate_seconds)                                  (E95_S02_T08, untimed files add 0)
#   and otherwise
#       timeout = max(600, 2 x estimate_seconds + 120 x untimed_files)
#   (an unavailable estimate counts every file as untimed). The whole run, SERIAL_FILES included, is under one
#   deadline. On timeout every running file's process group and every descendant get TERM, then KILL after 2 s; the
#   script prints `run-tests: timed out after <n> s`, the files that finished (with their result) and the files that
#   did not (each one stopped and the ones never started), and exits 124. No GNU `timeout` is needed (macOS has
#   none). INT/TERM sent to this script are forwarded to every running file's process group.
#
# SERIAL_FILES
#   PF_SERIAL_FILES of scripts/parallel-files.sh (one list for both runners): files that mutate real, shared
#   repository state instead of an isolated fixture tree. They run last, alone, plain (no --jobs). Add or remove
#   entries there, with the reason, not here.
#
# DEPENDENCY DETECTION (in-file parallelism, J = 1 only)
#   The in-file parallel path needs GNU `parallel` or `rush` on PATH, at least 2 jobs, and a bats whose --help mentions
#   --jobs. bats does not fall back to `rush` by itself, so `--parallel-binary-name rush` is passed when only rush is
#   installed. Without it every file runs plain. File-level parallelism (PARALLEL FILES) needs none of this. This
#   repo ships as an npm package: a consumer may
#   have neither binary.
#
# NOTES FOR EDITORS
#   - Do not add `set -e` and do not pipe a bats invocation: each file's status is captured explicitly (in
#     parallel-files.sh, `wait ... || st=$?`), because a pipeline or errexit would lose a failure or stop the run.
#   - Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
# ---------------------------------------------------------------------------

set -u

FAST_TIMEOUT_FLOOR=180
TIMEOUT_FLOOR=600
TIMEOUT_PER_UNTIMED=120
DEFAULT_CONFIRM_FILE_COUNT=60
KNOWN_TIERS="fast unit integration slow manual"
# Cheapest first; tier:manual is never suggested.
TIER_ORDER="fast unit integration slow"

usage() {
  cat <<'USAGE'
Usage: scripts/run-tests.sh [--tier <a>[,<b>...] | --all] [--confirm-full] [--jobs <n>] [--list] [--help]

  (no arguments)      tier:fast under a max(180, 2 x estimate) s timeout               = npm test
  --tier <list>       the files tagged with these tiers: fast unit integration slow manual
  --all               every tier except tier:manual                                    = npm run test:ci
  --confirm-full      accept a selection of more than full_run_confirm_file_count files (default 60);
                      not needed when CI=true
  --jobs <n>          run up to <n> files at once (default: RUN_TESTS_JOBS, else test_parallel_jobs
                      in test-config.json, else the CPU count capped at 8); 1 = one at a time
  --list              print the selection (stdout) and its estimate (stderr); run nothing
  --help              show this help

Every run has a hard timeout (RUN_TESTS_TIMEOUT overrides it) and prints an estimate first.
Environment: RUN_TESTS_TIMEOUT, RUN_TESTS_JOBS, CI.
USAGE
}

is_known_tier() {
  case " $KNOWN_TIERS " in *" $1 "*) return 0 ;; esac
  return 1
}

# --- Arguments -------------------------------------------------------------------------------------------------------
ORIG_ARGS="$*"
MODE=""
TIER_LIST=""
CONFIRM_FULL=0
LIST_ONLY=0
JOBS_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) [ "$MODE" != "tier" ] || { echo "run-tests: give --tier or --all, not both" >&2; usage >&2; exit 2; }
           MODE="all"; shift ;;
    --tier|--tier=*)
      [ "$MODE" != "all" ] || { echo "run-tests: give --tier or --all, not both" >&2; usage >&2; exit 2; }
      if [ "$1" = "--tier" ]; then
        [ "$#" -ge 2 ] || { echo "run-tests: --tier needs a tier list" >&2; usage >&2; exit 2; }
        _t="$2"; shift 2
      else
        _t="${1#--tier=}"; shift
      fi
      [ -n "$_t" ] || { echo "run-tests: --tier needs a tier list" >&2; usage >&2; exit 2; }
      MODE="tier"
      TIER_LIST="${TIER_LIST:+$TIER_LIST,}$_t" ;;
    --confirm-full) CONFIRM_FULL=1; shift ;;
    --jobs|--jobs=*)
      if [ "$1" = "--jobs" ]; then
        [ "$#" -ge 2 ] || { echo "run-tests: --jobs needs a number" >&2; usage >&2; exit 2; }
        JOBS_ARG="$2"; shift 2
      else
        JOBS_ARG="${1#--jobs=}"; shift
      fi
      case "$JOBS_ARG" in
        ""|*[!0-9]*) echo "run-tests: --jobs wants a positive whole number, got '$JOBS_ARG'" >&2; usage >&2; exit 2 ;;
      esac ;;
    --list) LIST_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "run-tests: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done
if [ -z "$MODE" ]; then
  MODE="tier"
  TIER_LIST="fast"
fi
if [ "$MODE" = "tier" ]; then
  _old_ifs="$IFS"; IFS=','
  for _t in $TIER_LIST; do
    if [ -z "$_t" ] || ! is_known_tier "$_t"; then
      IFS="$_old_ifs"
      echo "run-tests: unknown tier '$_t' (tiers: $KNOWN_TIERS)" >&2
      usage >&2
      exit 2
    fi
  done
  IFS="$_old_ifs"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || { echo "run-tests: cannot cd to $REPO_ROOT" >&2; exit 2; }

TIERS_SCRIPT="$REPO_ROOT/scripts/test-tiers.sh"
ESTIMATE_SCRIPT="$REPO_ROOT/scripts/test-estimate.sh"
THRESHOLDS_SCRIPT="$REPO_ROOT/skills/j-test/scripts/test-thresholds.sh"
NESTED_HELPER="$REPO_ROOT/tests/helpers/nested-suite.bash"
PARALLEL_HELPER="$REPO_ROOT/scripts/parallel-files.sh"
TEST_CONFIG="$REPO_ROOT/project/configs/test-config.json"

# --- Nesting refusal (never for --list, which runs nothing) --------------------------------------------------------
if [ "$LIST_ONLY" -ne 1 ] && [ "${RUN_TESTS_ALLOW_NESTED:-}" != "1" ]; then
  NESTED_REASON=""
  if [ -f "$NESTED_HELPER" ]; then
    # shellcheck source=/dev/null
    . "$NESTED_HELPER"
    if nested_suite_run_active; then NESTED_REASON="JENGA_NESTED_SUITE_RUN=1 (a nested suite run)"; fi
  elif [ "${JENGA_NESTED_SUITE_RUN:-0}" = "1" ]; then
    NESTED_REASON="JENGA_NESTED_SUITE_RUN=1 (a nested suite run)"
  fi
  if [ -z "$NESTED_REASON" ]; then
    if [ -n "${BATS_TEST_FILENAME:-}" ]; then
      NESTED_REASON="started from inside a bats run (BATS_TEST_FILENAME=$BATS_TEST_FILENAME)"
    elif [ -n "${BATS_RUN_TMPDIR:-}" ]; then
      NESTED_REASON="started from inside a bats run (BATS_RUN_TMPDIR is set)"
    fi
  fi
  if [ -n "$NESTED_REASON" ]; then
    echo "run-tests: refusing to start a test run from inside another one: $NESTED_REASON." >&2
    echo "run-tests: a test must never start a real suite run; use --list, or a stub bats in a fixture tree." >&2
    exit 3
  fi
fi

[ -f "$TIERS_SCRIPT" ] || { echo "run-tests: missing $TIERS_SCRIPT (it selects files by tier)" >&2; exit 2; }
[ -f "$PARALLEL_HELPER" ] || { echo "run-tests: missing $PARALLEL_HELPER (it runs the files)" >&2; exit 2; }
# shellcheck source=scripts/parallel-files.sh
. "$PARALLEL_HELPER"
if [ -n "$JOBS_ARG" ]; then
  JOBS_ARG="$(_pf_pos_int "$JOBS_ARG")" || { echo "run-tests: --jobs wants a positive whole number" >&2; usage >&2; exit 2; }
fi

# Files that must never run concurrently with anything else (SERIAL_FILES): one list, PF_SERIAL_FILES in
# scripts/parallel-files.sh.
is_serial_file() {
  pf_is_serial_file "$1"
}

# select_files <test-tiers.sh list arguments...>: the selection in run order (SERIAL_FILES last), one per line.
select_files() {
  local out f serial=""
  out="$(bash "$TIERS_SCRIPT" list "$@" --root "$REPO_ROOT")" || return 2
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_serial_file "$f"; then serial="$serial$f
"; else printf '%s\n' "$f"; fi
  done <<EOF
$out
EOF
  printf '%s' "$serial"
}

# estimate_numbers <files...>: sets EST_SECONDS and EST_UNTIMED from test-estimate.sh --json; EST_OK=0 when the
# estimate is unavailable (then every file counts as untimed).
estimate_numbers() {
  local json s u
  EST_OK=0; EST_SECONDS=0; EST_UNTIMED=$#
  [ "$#" -gt 0 ] || return 0
  json="$(printf '%s\n' "$@" | bash "$ESTIMATE_SCRIPT" --json --files-from - 2>/dev/null)" || return 0
  s="$(printf '%s\n' "$json" | jq -r '.estimated_seconds' 2>/dev/null)" || return 0
  u="$(printf '%s\n' "$json" | jq -r '.untimed | length' 2>/dev/null)" || return 0
  case "$s$u" in *[!0-9]*|"") return 0 ;; esac
  EST_OK=1; EST_SECONDS="$s"; EST_UNTIMED="$u"
}

# estimate_label: "<s> s (<u> untimed)" from the last estimate_numbers call.
estimate_label() {
  if [ "$EST_OK" -eq 1 ]; then
    printf '%s s (%s untimed)' "$EST_SECONDS" "$EST_UNTIMED"
  else
    printf 'unknown (%s untimed)' "$EST_UNTIMED"
  fi
}

# print_estimate <files...>: test-estimate.sh's own text on stderr, or a note when it is unavailable.
print_estimate() {
  local st=0
  printf '%s\n' "$@" | bash "$ESTIMATE_SCRIPT" --files-from - >&2 || st=$?
  if [ "$st" -ne 0 ]; then
    echo "run-tests: no estimate available (scripts/test-estimate.sh exit $st); all $# file(s) counted as untimed" >&2
  fi
}

# --- Selection -----------------------------------------------------------------------------------------------------
if [ "$MODE" = "all" ]; then
  REQUEST_LABEL="--all (every tier except tier:manual)"
  SELECTION="$(select_files --exclude-tier manual)" || { echo "run-tests: scripts/test-tiers.sh list failed" >&2; exit 2; }
else
  REQUEST_LABEL="--tier $TIER_LIST"
  SELECTION="$(select_files --tier "$TIER_LIST")" || { echo "run-tests: scripts/test-tiers.sh list failed" >&2; exit 2; }
fi

SELECTED=()
while IFS= read -r f; do
  [ -n "$f" ] && SELECTED+=("$f")
done <<EOF
$SELECTION
EOF

if [ "${#SELECTED[@]}" -eq 0 ]; then
  echo "run-tests: $REQUEST_LABEL selects no file, nothing to run - this is not a pass" >&2
  exit 2
fi

# --- --list: the selection on stdout, the estimate on stderr; no bats, no confirmation -----------------------------
if [ "$LIST_ONLY" -eq 1 ]; then
  for f in "${SELECTED[@]}"; do printf '%s\n' "$f"; done
  print_estimate "${SELECTED[@]}"
  exit 0
fi

estimate_numbers "${SELECTED[@]}"
SEL_EST_SECONDS="$EST_SECONDS"; SEL_EST_UNTIMED="$EST_UNTIMED"
SEL_EST_LABEL="$(estimate_label)"

# --- Large runs are deliberate only --------------------------------------------------------------------------------
CONFIRM_N=""
if [ -f "$THRESHOLDS_SCRIPT" ]; then
  CONFIRM_N="$(bash "$THRESHOLDS_SCRIPT" get confirm-file-count --root "$REPO_ROOT")" || CONFIRM_N=""
fi
case "$CONFIRM_N" in
  ""|*[!0-9]*)
    echo "run-tests: could not read full_run_confirm_file_count; using $DEFAULT_CONFIRM_FILE_COUNT" >&2
    CONFIRM_N="$DEFAULT_CONFIRM_FILE_COUNT" ;;
esac

if [ "${#SELECTED[@]}" -gt "$CONFIRM_N" ] && [ "${CI:-}" != "true" ] && [ "$CONFIRM_FULL" -ne 1 ]; then
  echo "run-tests: refusing $REQUEST_LABEL: it selects ${#SELECTED[@]} files, more than full_run_confirm_file_count ($CONFIRM_N); estimate $SEL_EST_LABEL." >&2
  if [ "$MODE" = "all" ]; then REQUESTED="$TIER_ORDER"; else REQUESTED="$(printf '%s' "$TIER_LIST" | tr ',' ' ')"; fi
  SUGGESTED=""
  for t in $TIER_ORDER; do
    case " $REQUESTED " in *" $t "*) ;; *) continue ;; esac
    tier_sel="$(select_files --tier "$t")" || continue
    [ -n "$tier_sel" ] || continue
    tier_files=()
    while IFS= read -r f; do [ -n "$f" ] && tier_files+=("$f"); done <<EOF
$tier_sel
EOF
    estimate_numbers "${tier_files[@]}"
    SUGGESTED="$t"
    extra=""
    [ "${#tier_files[@]}" -le "$CONFIRM_N" ] || extra=" --confirm-full"
    echo "run-tests: the cheapest tier that covers the request is tier:$t: ${#tier_files[@]} file(s), estimate $(estimate_label)." >&2
    echo "run-tests: next step: 'scripts/run-tests.sh --tier $t$extra'." >&2
    break
  done
  [ -n "$SUGGESTED" ] || echo "run-tests: no cheaper tier selects anything for this request." >&2
  echo "run-tests: to run this selection deliberately: 'scripts/run-tests.sh ${ORIG_ARGS:+$ORIG_ARGS }--confirm-full'; in CI (CI=true) no confirmation is needed." >&2
  exit 2
fi

if ! command -v bats >/dev/null 2>&1; then
  echo "run-tests: bats not found on PATH (npm install, or brew install bats-core)" >&2
  exit 127
fi

# --- Core count (portable: getconf on Linux and macOS, then nproc, then sysctl) ----------------------------------
detect_cores() {
  local n=""
  if [ -n "${RUN_TESTS_JOBS:-}" ]; then
    case "$RUN_TESTS_JOBS" in
      *[!0-9]*|"") echo "run-tests: ignoring invalid RUN_TESTS_JOBS='$RUN_TESTS_JOBS' (want a positive integer)" >&2 ;;
      *) n="$RUN_TESTS_JOBS" ;;
    esac
  fi
  [ -n "$n" ] || n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  [ -n "$n" ] || n="$(nproc 2>/dev/null || true)"
  [ -n "$n" ] || n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  case "$n" in *[!0-9]*|"") n=1 ;; esac
  [ "$n" -ge 1 ] || n=1
  printf '%s\n' "$n"
}

# --- Timeout: RUN_TESTS_TIMEOUT when valid, else the TIMEOUT RULE --------------------------------------------------
TIMEOUT_RULE=""
detect_timeout() {
  local t="${RUN_TESTS_TIMEOUT:-}"
  case "$t" in
    "") ;;
    *[!0-9]*) echo "run-tests: ignoring invalid RUN_TESTS_TIMEOUT='$t' (want a positive integer of seconds)" >&2; t="" ;;
    *) if [ "$t" -lt 1 ]; then
         echo "run-tests: ignoring invalid RUN_TESTS_TIMEOUT='$t' (want a positive integer of seconds)" >&2
         t=""
       fi ;;
  esac
  if [ -n "$t" ]; then
    TIMEOUT_RULE="RUN_TESTS_TIMEOUT"
  elif [ "$MODE" = "tier" ] && [ "$TIER_LIST" = "fast" ]; then
    t=$((2 * SEL_EST_SECONDS))
    [ "$t" -ge "$FAST_TIMEOUT_FLOOR" ] || t="$FAST_TIMEOUT_FLOOR"
    TIMEOUT_RULE="tier:fast: max($FAST_TIMEOUT_FLOOR, 2 x ${SEL_EST_SECONDS} s)"
  else
    t=$((2 * SEL_EST_SECONDS + TIMEOUT_PER_UNTIMED * SEL_EST_UNTIMED))
    [ "$t" -ge "$TIMEOUT_FLOOR" ] || t="$TIMEOUT_FLOOR"
    TIMEOUT_RULE="max($TIMEOUT_FLOOR, 2 x ${SEL_EST_SECONDS} s + $TIMEOUT_PER_UNTIMED s x $SEL_EST_UNTIMED untimed)"
  fi
  TIMEOUT="$t"
}

# --- Parallel backend: GNU parallel first, then rush; empty when neither is installed ----------------------------
detect_parallel_binary() {
  if command -v parallel >/dev/null 2>&1; then
    printf 'parallel\n'
  elif command -v rush >/dev/null 2>&1; then
    printf 'rush\n'
  fi
}

bats_supports_jobs() {
  bats --help 2>&1 | grep -q -- '--jobs'
}

PARALLEL_BIN="$(detect_parallel_binary)"
JOBS="$(detect_cores)"

# Files at once (PARALLEL FILES): --jobs, RUN_TESTS_JOBS, test_parallel_jobs, else the CPU count capped at 8.
pf_resolve_jobs "$JOBS_ARG" "$TEST_CONFIG" "run-tests"
FILE_JOBS="$PF_JOBS"

# Why the in-file parallel path is unavailable, or empty when it is available (it is used only when FILE_JOBS = 1).
SERIAL_REASON=""
if [ -z "$PARALLEL_BIN" ]; then
  SERIAL_REASON="no parallel binary (GNU parallel / rush) on PATH"
elif [ "$JOBS" -lt 2 ]; then
  SERIAL_REASON="only $JOBS job available"
elif ! bats_supports_jobs; then
  SERIAL_REASON="this bats has no --jobs support"
fi

PARALLEL_FLAGS=()
if [ "$FILE_JOBS" -eq 1 ] && [ -z "$SERIAL_REASON" ]; then
  PARALLEL_FLAGS=(--jobs "$JOBS")
  [ "$PARALLEL_BIN" = "parallel" ] || PARALLEL_FLAGS+=(--parallel-binary-name "$PARALLEL_BIN")
fi

detect_timeout

# ====================================================================================================================
# The run: up to FILE_JOBS files at once (scripts/parallel-files.sh), SERIAL_FILES alone afterwards, one deadline
# ====================================================================================================================

# on_file_done <file> <status> <seconds>: called once per finished file, with that file's own duration. A no-op hook
# point for per-file records (E95_S07 writes timing records here). It must not print to stdout and must not change
# the run's status.
on_file_done() {
  :  # E95_S07 hook point
}

# CAPTURE=1 (FILE_JOBS > 1): each file's output goes to its own file and is printed only when that file fails.
# CAPTURE=0 (FILE_JOBS = 1): the E95_S02_T03 loop, output streamed unfiltered.
CAPTURE=0
[ "$FILE_JOBS" -eq 1 ] || CAPTURE=1

# pf_launch <file> <outfile>: one bats invocation (scripts/parallel-files.sh runs it in its own process group).
pf_launch() {
  if [ "$CAPTURE" -eq 1 ]; then
    exec bats "$1" > "$2" 2>&1
  elif is_serial_file "$1"; then
    exec bats "$1"
  else
    exec bats ${PARALLEL_FLAGS[@]+"${PARALLEL_FLAGS[@]}"} "$1"
  fi
}

FINISHED=()      # "<result> <file> (<d> s)" per finished file, in completion order
FAILED_FILES=()
RUN_STATUS=0
DONE_COUNT=0

# pf_on_done <file> <status> <seconds> <outfile>: the progress line, the failing file's own output, the hook.
pf_on_done() {
  local f="$1" st="$2" dur="$3" out="$4" result
  DONE_COUNT=$((DONE_COUNT + 1))
  if [ "$st" -eq 0 ]; then
    result="ok"
  else
    result="FAILED (exit $st)"
    FAILED_FILES+=("$f")
    [ "$RUN_STATUS" -ne 0 ] || RUN_STATUS="$st"
  fi
  FINISHED+=("$result $f ($dur s)")
  echo "run-tests: [$DONE_COUNT/$TOTAL] $f $result $dur s (elapsed $((SECONDS - START)) s)" >&2
  if [ "$st" -ne 0 ] && [ "$CAPTURE" -eq 1 ] && [ -f "$out" ]; then
    echo "run-tests: --- output of $f ---" >&2
    cat "$out"
    echo "run-tests: --- end of output of $f ---" >&2
  fi
  on_file_done "$f" "$st" "$dur"
  return 0
}

print_estimate "${SELECTED[@]}"
TOTAL="${#SELECTED[@]}"
BATCH=()
SERIAL_SELECTED=()
for f in "${SELECTED[@]}"; do
  if is_serial_file "$f"; then SERIAL_SELECTED+=("$f"); else BATCH+=("$f"); fi
done
if [ "$FILE_JOBS" -gt 1 ]; then
  RUN_HOW="up to $FILE_JOBS files at once ($PF_JOBS_SOURCE), plain bats per file, shared-state files alone afterwards"
elif [ -n "$SERIAL_REASON" ]; then
  RUN_HOW="one file at a time ($PF_JOBS_SOURCE), plain bats ($SERIAL_REASON)"
else
  RUN_HOW="one file at a time ($PF_JOBS_SOURCE), bats --jobs $JOBS ($PARALLEL_BIN) within each file"
fi
echo "run-tests: $REQUEST_LABEL - $TOTAL file(s), one bats invocation per file, $RUN_HOW; timeout $TIMEOUT s ($TIMEOUT_RULE)" >&2
if [ "$MODE" = "tier" ] && [ "$TIER_LIST" = "fast" ]; then
  echo "run-tests: larger runs: 'scripts/run-tests.sh --tier <name>', 'npm run test:ci' (CI) or 'scripts/run-tests.sh --all --confirm-full'" >&2
fi

OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run-tests.XXXXXX")" || { echo "run-tests: cannot create a temp directory" >&2; exit 2; }
trap 'rm -rf "$OUT_DIR"' EXIT
trap 'pf_stop_all; exit 130' INT
trap 'pf_stop_all; exit 143' TERM

START=$SECONDS
DEADLINE=$((START + TIMEOUT))

# report_timeout <never-started files...>: the timeout report; the caller exits 124.
report_timeout() {
  local j=0 not_finished
  trap - INT TERM
  not_finished=$((TOTAL - ${#FINISHED[@]}))
  echo "run-tests: timed out after $TIMEOUT s ($TIMEOUT_RULE) - this is not a pass" >&2
  echo "run-tests: finished (${#FINISHED[@]} of $TOTAL):" >&2
  while [ "$j" -lt "${#FINISHED[@]}" ]; do
    echo "run-tests:   ${FINISHED[$j]}" >&2
    j=$((j + 1))
  done
  echo "run-tests: not finished ($not_finished of $TOTAL):" >&2
  j=0
  while [ "$j" -lt "${#PF_STOPPED[@]}" ]; do
    echo "run-tests:   stopped     ${PF_STOPPED[$j]}" >&2
    j=$((j + 1))
  done
  for f in "$@"; do
    echo "run-tests:   not started $f" >&2
  done
}

PF_ST=0
if [ "${#BATCH[@]}" -gt 0 ]; then
  pf_run_files "$FILE_JOBS" "$DEADLINE" "$OUT_DIR" "${BATCH[@]}" || PF_ST=$?
  if [ "$PF_ST" -eq 124 ]; then
    report_timeout ${PF_NOT_STARTED[@]+"${PF_NOT_STARTED[@]}"} ${SERIAL_SELECTED[@]+"${SERIAL_SELECTED[@]}"}
    exit 124
  fi
fi
if [ "${#SERIAL_SELECTED[@]}" -gt 0 ]; then
  pf_run_files 1 "$DEADLINE" "$OUT_DIR" "${SERIAL_SELECTED[@]}" || PF_ST=$?
  if [ "$PF_ST" -eq 124 ]; then
    report_timeout ${PF_NOT_STARTED[@]+"${PF_NOT_STARTED[@]}"}
    exit 124
  fi
fi
trap - INT TERM

if [ "${#FAILED_FILES[@]}" -eq 0 ]; then
  echo "run-tests: $TOTAL file(s) passed in $((SECONDS - START)) s" >&2
else
  echo "run-tests: ${#FAILED_FILES[@]} of $TOTAL file(s) failed in $((SECONDS - START)) s:" >&2
  for f in "${FAILED_FILES[@]}"; do echo "run-tests:   $f" >&2; done
fi
exit "$RUN_STATUS"
