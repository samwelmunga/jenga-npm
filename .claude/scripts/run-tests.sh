#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/run-tests.sh - run the bats suite: a bounded fast set by default, the full suite only deliberately
# (E43_S02_T01 parallel runner; E95_S01_T02 fast set, timeout, --all gate, --list)
#
# `npm test` delegates here with no arguments; `npm run test:ci` delegates here with `--all`. Every consumer of
# either (/publish's `test` gate, the public staging gate's `npm run test:ci`) gets whatever this script does, so
# its EXIT STATUS is the contract: non-zero if ANY bats invocation it ran failed or was timed out, zero only when
# every one of them passed.
#
# USAGE
#   scripts/run-tests.sh                     the fast set (tests/fast-set.txt) under a hard timeout  (= npm test)
#   scripts/run-tests.sh --all               every top-level tests/*.bats; refused unless CI=true or --confirm-full
#   scripts/run-tests.sh --all --confirm-full    the full suite, deliberately, outside CI
#   scripts/run-tests.sh [--all] --list      print the files that mode would run, one per line; run nothing
#   scripts/run-tests.sh --help
#   npm run test:ci                          = scripts/run-tests.sh --all (CI sets CI=true, so it is accepted there)
#
# EXIT STATUS
#   0 every bats invocation passed   1.. the first failing bats status   2 usage error, `--all` refused, or an
#   empty fast set   124 the fast run hit its timeout (never a pass)   127 bats not on PATH
#
# ENVIRONMENT
#   RUN_TESTS_JOBS     positive integer; use this many parallel jobs instead of detecting the core count.
#                      A value below 2 means "do not parallelize". An invalid value is ignored with a warning.
#   RUN_TESTS_TIMEOUT  positive integer seconds; the fast run's hard timeout (default 180). An invalid value is
#                      ignored with a warning. `--all` has no timeout of its own (CI jobs carry theirs).
#   CI                 `true` (set by GitHub Actions and most CI services) lets `--all` run without --confirm-full.
#
# FAST SET (no arguments)
#   The files listed in tests/fast-set.txt, chosen from project/logs/test-timings.jsonl so their summed recorded
#   duration is at most about 90 s (the rule and the sum are in that file's header). An entry that is absent, not a
#   top-level tests/*.bats, or in SERIAL_FILES is skipped with a note on stderr. When no runnable entry remains the
#   script exits 2: a run of nothing is never a pass. The fast run uses the same parallel detection as `--all`
#   (one `bats --jobs N` pass, or plain `bats` when that is not available) and runs under a WATCHDOG: bats runs in
#   the background in its own process group with stdin from /dev/null and its output streaming as usual; on
#   timeout the group and every descendant (pgrep -P, collected before signalling) get TERM, then KILL after 2 s,
#   the script prints `run-tests: timed out after <n> s` and exits 124. No GNU `timeout` is needed (macOS has none).
#   INT/TERM sent to this script are forwarded to the bats process group.
#
# --all BEHAVIOUR (unchanged from E43_S02_T01)
#   No parallel binary (neither GNU `parallel` nor `rush` on PATH), fewer than 2 jobs, or a bats without `--jobs`:
#       bats tests/*.bats                          exactly what `npm test` ran before this script existed
#   Otherwise two passes:
#       1. bats --jobs N [--parallel-binary-name rush] <every tests/*.bats except SERIAL_FILES>
#       2. bats <SERIAL_FILES that exist>          plain serial, no --jobs
#   Pass 2 always runs, even when pass 1 failed, so one run reports every failure. The exit status is the first
#   non-zero status (pass 1, then pass 2).
#
# WHY TWO PASSES
#   `bats --jobs` has no per-file exclusion: --no-parallelize-across-files and --no-parallelize-within-files are
#   global switches (checked against `bats --help`, bats 1.14.0). The files in SERIAL_FILES mutate real, shared
#   repository state (.claude/settings.json, .agents/settings.json, .jenga-permission-level.json, the shared
#   .mirror-worktrees/public clone) instead of an isolated fixture tree, and concurrent runs of them are what
#   corrupted this repo's .git/config `origin` on 2026-09-26
#   (project/rapports/problems/E46_S02_T01-mirror-test-corrupted-shared-repo-state.md). Add a file to SERIAL_FILES
#   when another test is found to share state; remove entries once the isolation defect is fixed. The fast set never
#   contains a SERIAL_FILES entry, so the fast run is a single pass.
#
# DEPENDENCY DETECTION
#   bats picks its parallel backend through --parallel-binary-name (default `parallel`) and does not fall back to
#   `rush` by itself, so when only `rush` is installed this script passes `--parallel-binary-name rush`.
#   Rather than hardcode the bats release that introduced --jobs, the script probes `bats --help` for it.
#   This repo ships as an npm package: a consumer may have neither binary, and that path stays a plain serial run.
#
# NOTES FOR EDITORS
#   - Do not add `set -e` and do not pipe a bats invocation: the status of each pass is captured explicitly with
#     `|| status=$?` (or `wait`), because a pipeline or errexit would let pass 1's failure be lost or skip pass 2.
#   - Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
# ---------------------------------------------------------------------------

set -u

# Files that must never run concurrently with anything else (repo-relative, one per array element).
SERIAL_FILES=(
  "tests/mirror-permission-level-invariant.bats"
  "tests/mirror-test-subject-invariant.bats"
)

# The fast set `npm test` runs (repo-relative). See FAST SET above and the file's own header.
FAST_SET_FILE="tests/fast-set.txt"
DEFAULT_TIMEOUT=180

usage() {
  cat <<'USAGE'
Usage: scripts/run-tests.sh [--all [--confirm-full]] [--list] [--help]

  (no arguments)   run the fast set (tests/fast-set.txt) under a hard timeout     = npm test
  --all            run every top-level tests/*.bats; refused unless CI=true or --confirm-full is given
                                                                                  = npm run test:ci
  --confirm-full   with --all: confirm a deliberate full run outside CI
  --list           print the files the selected mode would run, one per line, and run nothing
  --help           show this help

Environment: RUN_TESTS_TIMEOUT (fast run, seconds, default 180), RUN_TESTS_JOBS, CI.
USAGE
}

# --- Arguments -------------------------------------------------------------------------------------------------------
MODE="fast"
CONFIRM_FULL=0
LIST_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --all) MODE="all" ;;
    --confirm-full) CONFIRM_FULL=1 ;;
    --list) LIST_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "run-tests: unknown argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
done
if [ "$CONFIRM_FULL" -eq 1 ] && [ "$MODE" != "all" ]; then
  echo "run-tests: --confirm-full only applies to --all" >&2
  usage >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || { echo "run-tests: cannot cd to $REPO_ROOT" >&2; exit 2; }

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

# --- Fast-run timeout: RUN_TESTS_TIMEOUT when it is a positive integer, else the default -------------------------
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
  [ -n "$t" ] || t="$DEFAULT_TIMEOUT"
  printf '%s\n' "$t"
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

# --- File lists ----------------------------------------------------------------------------------------------------
is_serial_file() {
  local f="$1" s
  for s in "${SERIAL_FILES[@]}"; do
    [ "$f" = "$s" ] && return 0
  done
  return 1
}

# Top-level tests/*.bats only (tests/fixtures/ holds inputs, some deliberately failing). `nullglob` so an empty
# tests/ yields an empty list instead of the literal pattern.
shopt -s nullglob
ALL_FILES=(tests/*.bats)
shopt -u nullglob

BULK_FILES=()
for f in "${ALL_FILES[@]+"${ALL_FILES[@]}"}"; do
  is_serial_file "$f" || BULK_FILES+=("$f")
done

SERIAL_PRESENT=()
for f in "${SERIAL_FILES[@]}"; do
  [ -f "$f" ] && SERIAL_PRESENT+=("$f")
done

# The fast set: the runnable entries of FAST_SET_FILE, in file order. Notes about skipped entries go to stderr.
load_fast_set() {
  local line entry
  FAST_FILES=()
  if [ ! -f "$FAST_SET_FILE" ]; then
    echo "run-tests: fast-set list $FAST_SET_FILE not found" >&2
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    # Trim surrounding whitespace; skip blanks and comments.
    entry="${line#"${line%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    case "$entry" in ""|"#"*) continue ;; esac
    case "$entry" in
      tests/*/*) echo "run-tests: fast-set entry is not a top-level tests/*.bats, skipped: $entry" >&2; continue ;;
      tests/*.bats) ;;
      *) echo "run-tests: fast-set entry is not a top-level tests/*.bats, skipped: $entry" >&2; continue ;;
    esac
    if is_serial_file "$entry"; then
      echo "run-tests: fast-set entry is a shared-state (SERIAL_FILES) file, skipped: $entry" >&2
      continue
    fi
    if [ ! -f "$entry" ]; then
      echo "run-tests: fast-set entry not present, skipped: $entry" >&2
      continue
    fi
    FAST_FILES+=("$entry")
  done < "$FAST_SET_FILE"
}

# --- --list: print the selection, run nothing (needs no bats and no confirmation) --------------------------------
if [ "$LIST_ONLY" -eq 1 ]; then
  if [ "$MODE" = "all" ]; then
    for f in "${ALL_FILES[@]+"${ALL_FILES[@]}"}"; do printf '%s\n' "$f"; done
  else
    load_fast_set
    for f in "${FAST_FILES[@]+"${FAST_FILES[@]}"}"; do printf '%s\n' "$f"; done
  fi
  exit 0
fi

# --- --all is deliberate only --------------------------------------------------------------------------------------
if [ "$MODE" = "all" ] && [ "${CI:-}" != "true" ] && [ "$CONFIRM_FULL" -ne 1 ]; then
  echo "run-tests: refusing --all: it runs every top-level tests/*.bats (${#ALL_FILES[@]} files), which takes hours locally." >&2
  echo "run-tests: run the full suite deliberately with 'scripts/run-tests.sh --all --confirm-full'," >&2
  echo "run-tests: or in CI with 'npm run test:ci' (accepted when CI=true). 'npm test' runs the bounded fast set." >&2
  exit 2
fi

if ! command -v bats >/dev/null 2>&1; then
  echo "run-tests: bats not found on PATH (npm install, or brew install bats-core)" >&2
  exit 127
fi

PARALLEL_BIN="$(detect_parallel_binary)"
JOBS="$(detect_cores)"

# Why the parallel path is unavailable, or empty when it is available. Printed by each mode in its own words.
SERIAL_REASON=""
if [ -z "$PARALLEL_BIN" ]; then
  SERIAL_REASON="no parallel binary (GNU parallel / rush) on PATH"
elif [ "$JOBS" -lt 2 ]; then
  SERIAL_REASON="only $JOBS job available"
elif ! bats_supports_jobs; then
  SERIAL_REASON="this bats has no --jobs support"
fi

PARALLEL_FLAGS=()
if [ -z "$SERIAL_REASON" ]; then
  PARALLEL_FLAGS=(--jobs "$JOBS")
  [ "$PARALLEL_BIN" = "parallel" ] || PARALLEL_FLAGS+=(--parallel-binary-name "$PARALLEL_BIN")
fi

# ====================================================================================================================
# Fast set (default): one bats invocation under a watchdog
# ====================================================================================================================

# descendants <pid>: every descendant pid of <pid>, one per line (none when pgrep is not installed).
descendants() {
  local kids k
  command -v pgrep >/dev/null 2>&1 || return 0
  kids="$(pgrep -P "$1" 2>/dev/null || true)"
  for k in $kids; do
    printf '%s\n' "$k"
    descendants "$k"
  done
}

# signal_tree <signal> <pid>: the process group led by <pid> (it was started with job control on) and every
# descendant found by pgrep, in case a child (GNU parallel, for one) moved its own jobs to another group.
signal_tree() {
  local sig="$1" pid="$2" p
  for p in $(descendants "$pid"); do
    kill "-$sig" "$p" 2>/dev/null || true
  done
  kill "-$sig" -- "-$pid" 2>/dev/null || true
  kill "-$sig" "$pid" 2>/dev/null || true
}

if [ "$MODE" = "fast" ]; then
  load_fast_set
  if [ "${#FAST_FILES[@]}" -eq 0 ]; then
    echo "run-tests: the fast set is empty, nothing to run - this is not a pass" >&2
    exit 2
  fi
  TIMEOUT="$(detect_timeout)"
  if [ -n "$SERIAL_REASON" ]; then
    echo "run-tests: fast set - ${#FAST_FILES[@]} file(s), serially ($SERIAL_REASON), timeout ${TIMEOUT} s" >&2
  else
    echo "run-tests: fast set - ${#FAST_FILES[@]} file(s) with --jobs $JOBS ($PARALLEL_BIN), timeout ${TIMEOUT} s" >&2
  fi
  echo "run-tests: the full suite is 'npm run test:ci' (CI) or 'scripts/run-tests.sh --all --confirm-full'" >&2

  # Job control on just for the launch, so bats leads its own process group and the whole tree can be signalled.
  set -m
  bats ${PARALLEL_FLAGS[@]+"${PARALLEL_FLAGS[@]}"} "${FAST_FILES[@]}" < /dev/null &
  BATS_PID=$!
  set +m
  trap 'signal_tree TERM "$BATS_PID"; exit 130' INT
  trap 'signal_tree TERM "$BATS_PID"; exit 143' TERM

  START=$SECONDS
  TIMED_OUT=0
  while kill -0 "$BATS_PID" 2>/dev/null; do
    if [ $((SECONDS - START)) -ge "$TIMEOUT" ]; then
      TIMED_OUT=1
      break
    fi
    sleep 0.2
  done

  if [ "$TIMED_OUT" -eq 1 ]; then
    signal_tree TERM "$BATS_PID"
    GRACE_END=$((SECONDS + 2))
    while kill -0 "$BATS_PID" 2>/dev/null && [ "$SECONDS" -lt "$GRACE_END" ]; do sleep 0.2; done
    signal_tree KILL "$BATS_PID"
    wait "$BATS_PID" 2>/dev/null
    trap - INT TERM
    echo "run-tests: timed out after ${TIMEOUT} s" >&2
    exit 124
  fi

  fast_status=0
  wait "$BATS_PID" || fast_status=$?
  trap - INT TERM
  exit "$fast_status"
fi

# ====================================================================================================================
# --all: the full suite, exactly as before E95_S01_T02
# ====================================================================================================================

# --- Fallback: exactly today's behaviour ---------------------------------------------------------------------------
run_serial_fallback() {
  # Unquoted glob on purpose: it is the literal command `npm test` used to run, so the behaviour (including
  # bats' own "no tests" handling) stays identical. Bash expands it here, as the shell did for the old script.
  bats tests/*.bats
}

if [ -n "$SERIAL_REASON" ]; then
  echo "run-tests: $SERIAL_REASON - running the suite serially" >&2
  run_serial_fallback
  exit $?
fi

# --- Two passes ----------------------------------------------------------------------------------------------------
echo "run-tests: $PARALLEL_BIN found - ${#BULK_FILES[@]} file(s) with --jobs $JOBS, then ${#SERIAL_PRESENT[@]} shared-state file(s) serially" >&2

pass1=0
pass2=0

if [ "${#BULK_FILES[@]}" -gt 0 ]; then
  bats "${PARALLEL_FLAGS[@]}" "${BULK_FILES[@]}" || pass1=$?
fi

if [ "${#SERIAL_PRESENT[@]}" -gt 0 ]; then
  bats "${SERIAL_PRESENT[@]}" || pass2=$?
fi

if [ "$pass1" -ne 0 ]; then exit "$pass1"; fi
exit "$pass2"
