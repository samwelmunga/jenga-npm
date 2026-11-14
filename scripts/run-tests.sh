#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/run-tests.sh - run the bats suite, in parallel where that is safe (E43_S02_T01)
#
# `npm test` delegates here. Every other consumer of `npm test` (scripts/smoke-harness.sh's tier-2 fallback,
# /publish's `test` gate) therefore gets whatever this script does, so its EXIT STATUS is the contract:
# non-zero if ANY bats invocation it ran failed, zero only when all of them passed.
#
# USAGE
#   scripts/run-tests.sh          (no arguments; runs tests/*.bats, top level only, from the repository root)
#
# ENVIRONMENT
#   RUN_TESTS_JOBS   positive integer; use this many parallel jobs instead of detecting the core count.
#                    A value below 2 means "do not parallelize". An invalid value is ignored with a warning.
#
# BEHAVIOUR
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
#   when another test is found to share state; remove entries once the isolation defect is fixed.
#
# DEPENDENCY DETECTION
#   bats picks its parallel backend through --parallel-binary-name (default `parallel`) and does not fall back to
#   `rush` by itself, so when only `rush` is installed this script passes `--parallel-binary-name rush`.
#   Rather than hardcode the bats release that introduced --jobs, the script probes `bats --help` for it.
#   This repo ships as an npm package: a consumer may have neither binary, and that path stays a plain serial run.
#
# NOTES FOR EDITORS
#   - Do not add `set -e` and do not pipe a bats invocation: the status of each pass is captured explicitly with
#     `|| status=$?`, because a pipeline or errexit would let pass 1's failure be lost or skip pass 2.
#   - Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
# ---------------------------------------------------------------------------

set -u

# Files that must never run concurrently with anything else (repo-relative, one per array element).
SERIAL_FILES=(
  "tests/mirror-permission-level-invariant.bats"
  "tests/mirror-test-subject-invariant.bats"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || { echo "run-tests: cannot cd to $REPO_ROOT" >&2; exit 2; }

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

# --- Fallback: exactly today's behaviour ---------------------------------------------------------------------------
run_serial_fallback() {
  # Unquoted glob on purpose: it is the literal command `npm test` used to run, so the behaviour (including
  # bats' own "no tests" handling) stays identical. Bash expands it here, as the shell did for the old script.
  bats tests/*.bats
}

PARALLEL_BIN="$(detect_parallel_binary)"
JOBS="$(detect_cores)"

if [ -z "$PARALLEL_BIN" ]; then
  echo "run-tests: no parallel binary (GNU parallel / rush) on PATH - running the suite serially" >&2
  run_serial_fallback
  exit $?
fi
if [ "$JOBS" -lt 2 ]; then
  echo "run-tests: only $JOBS job available - running the suite serially" >&2
  run_serial_fallback
  exit $?
fi
if ! bats_supports_jobs; then
  echo "run-tests: this bats has no --jobs support - running the suite serially" >&2
  run_serial_fallback
  exit $?
fi

# --- Two passes ----------------------------------------------------------------------------------------------------
PARALLEL_FLAGS=(--jobs "$JOBS")
[ "$PARALLEL_BIN" = "parallel" ] || PARALLEL_FLAGS+=(--parallel-binary-name "$PARALLEL_BIN")

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
