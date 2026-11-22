#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/parallel-files.sh - run test files several at a time, one process group per file (E95_S02_T08)
#
# A SOURCED library, not a command. Shared by the two runners that run test files one by one and need a per-file
# report: scripts/run-tests.sh (npm test, npm run test:ci) and the private mirror tool's pre-push test gate. One
# scheduler, one shared-state list and one job-count rule, so the two runners cannot drift apart.
#
# Bash 3.2 compatible (macOS /bin/bash): no `wait -n`, no mapfile, no associative arrays. Needs no GNU parallel or
# rush (CI has neither). Safe under `set -euo pipefail` and under IFS=$'\n\t': every status is captured explicitly,
# every function returns 0 unless its status is the point, and nothing relies on splitting at spaces.
#
# ---------------------------------------------------------------------------
# WHAT IT DEFINES
# ---------------------------------------------------------------------------
#   PF_SERIAL_FILES         repo-relative test files that must never run at the same time as anything else: they
#                           mutate real, shared repository state (.claude/settings.json, .agents/settings.json,
#                           .jenga-permission-level.json, the shared .mirror-worktrees/public clone) instead of an
#                           isolated fixture tree. Concurrent runs of them corrupted this repo's .git/config `origin`
#                           on 2026-09-26 (project/rapports/problems/E46_S02_T01-mirror-test-corrupted-shared-repo-
#                           state.md). Callers run them alone, after the parallel batch (pf_run_files with jobs 1).
#   pf_is_serial_file <f>   0 when <f> is in PF_SERIAL_FILES.
#   pf_detect_cores         the online CPU count (getconf, then nproc, then sysctl), at least 1.
#   pf_resolve_jobs <explicit> <config-file> <message-prefix>
#                           sets PF_JOBS (a positive integer) and PF_JOBS_SOURCE (a human label). First match wins:
#                             1. <explicit>, when it is a positive integer (a runner's --jobs)
#                             2. RUN_TESTS_JOBS, when it is a positive integer
#                             3. the key `test_parallel_jobs` of <config-file> (project/configs/test-config.json),
#                                when it is a positive integer; any other value warns once on stderr and is ignored
#                             4. the CPU count, capped at PF_MAX_DEFAULT_JOBS (8)
#                           An absent file, an absent key or a missing jq is not an error.
#   pf_run_files <jobs> <deadline> <outdir> <file>...
#                           the scheduler, below. Returns 0 when every file ran to completion (whatever its own
#                           status), 124 when the deadline was reached.
#   pf_stop_all             stops every file pf_run_files is running (for a caller's INT/TERM trap).
#   pf_signal_tree <sig> <pid>
#                           signals the process group led by <pid> and every descendant pgrep finds.
#
# ---------------------------------------------------------------------------
# THE SCHEDULER: pf_run_files <jobs> <deadline> <outdir> <file>...
# ---------------------------------------------------------------------------
#   Starts up to <jobs> files at once, in the order given, and starts the next one as soon as a slot frees. The
#   caller defines two functions:
#     pf_launch <file> <outfile>    runs ONE file in the foreground (pf_run_files puts it in the background, in its
#                                   own process group, with stdin from /dev/null). It decides the command and whether
#                                   output goes to <outfile> (<outdir>/<n>.out, n = start order) or streams. Ending
#                                   it with `exec` makes the recorded pid the test process itself.
#     pf_on_done <file> <status> <seconds> <outfile>
#                                   called once per finished file, in COMPLETION order, in the calling shell (so it
#                                   may update the caller's counters and lists). <seconds> is that file's own wall
#                                   time. It must return 0.
#   <deadline> is an absolute value of bash's $SECONDS, or 0 for none. When $SECONDS reaches it, every running file
#   gets TERM on its process group and every descendant, then KILL after 2 s; PF_STOPPED holds the files that were
#   running (slot order) and PF_NOT_STARTED the ones never started (start order), and the return status is 124. A
#   deadline already passed starts nothing. Completion is detected by polling `kill -0` every 0.05 s for the first
#   2 s of a file, then every 0.2 s (bash 3.2 has no `wait -n`).
#
# NOTES FOR EDITORS
#   - Never pipe a launched command: its exit status would be the pipe's last command's.
#   - Under `set -u`, bash 3.2 treats "${a[@]}" of an EMPTY array as unbound: index loops are used throughout, and
#     callers should expand PF_STOPPED / PF_NOT_STARTED as ${PF_STOPPED[@]+"${PF_STOPPED[@]}"}.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # the PF_* globals are read by the sourcing script
PF_SERIAL_FILES=(
  "tests/mirror-permission-level-invariant.bats"
  "tests/mirror-test-subject-invariant.bats"
)
PF_MAX_DEFAULT_JOBS=8
PF_CONFIG_KEY="test_parallel_jobs"

PF_JOBS=1
PF_JOBS_SOURCE=""
PF_STOPPED=()
PF_NOT_STARTED=()
_PF_SLOT_PID=()
_PF_SLOT_FILE=()
_PF_SLOT_OUT=()
_PF_SLOT_START=()

pf_is_serial_file() {
  local f="$1" i=0
  while [ "$i" -lt "${#PF_SERIAL_FILES[@]}" ]; do
    if [ "$f" = "${PF_SERIAL_FILES[$i]}" ]; then return 0; fi
    i=$((i + 1))
  done
  return 1
}

# _pf_pos_int <value>: 0 when <value> is a whole number of at least 1 (leading zeros allowed), and prints it in
# canonical form.
_pf_pos_int() {
  case "$1" in ""|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 9 ] || return 1
  local n=$((10#$1))
  [ "$n" -ge 1 ] || return 1
  printf '%s\n' "$n"
}

pf_detect_cores() {
  local n=""
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  [ -n "$n" ] || n="$(nproc 2>/dev/null || true)"
  [ -n "$n" ] || n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  n="$(_pf_pos_int "$n" || true)"
  [ -n "$n" ] || n=1
  printf '%s\n' "$n"
}

pf_resolve_jobs() {
  local explicit="$1" cfg="$2" prefix="$3" n="" raw="" cores
  n="$(_pf_pos_int "$explicit" || true)"
  if [ -n "$n" ]; then
    PF_JOBS="$n"; PF_JOBS_SOURCE="--jobs"; return 0
  fi
  n="$(_pf_pos_int "${RUN_TESTS_JOBS:-}" || true)"
  if [ -n "$n" ]; then
    PF_JOBS="$n"; PF_JOBS_SOURCE="RUN_TESTS_JOBS"; return 0
  fi
  if [ -n "$cfg" ] && [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    raw="$(jq -r --arg k "$PF_CONFIG_KEY" \
      'if type == "object" and has($k) then (.[$k] | if type == "string" then "\"" + . + "\"" else tostring end) else empty end' \
      "$cfg" 2>/dev/null || true)"
    if [ -n "$raw" ]; then
      n="$(_pf_pos_int "$raw" || true)"
      if [ -n "$n" ]; then
        PF_JOBS="$n"; PF_JOBS_SOURCE="$PF_CONFIG_KEY in $(basename "$cfg")"; return 0
      fi
      printf '%s: ignoring %s = %s in %s (want a positive whole number of jobs)\n' \
        "$prefix" "$PF_CONFIG_KEY" "$raw" "$cfg" >&2
    fi
  fi
  cores="$(pf_detect_cores)"
  if [ "$cores" -gt "$PF_MAX_DEFAULT_JOBS" ]; then
    PF_JOBS="$PF_MAX_DEFAULT_JOBS"
  else
    PF_JOBS="$cores"
  fi
  PF_JOBS_SOURCE="CPU count $cores, capped at $PF_MAX_DEFAULT_JOBS"
  return 0
}

# _pf_descendants <pid>: every descendant pid of <pid>, one per line (none when pgrep is not installed).
_pf_descendants() {
  local kids k
  command -v pgrep >/dev/null 2>&1 || return 0
  kids="$(pgrep -P "$1" 2>/dev/null || true)"
  for k in $kids; do
    printf '%s\n' "$k"
    _pf_descendants "$k"
  done
  return 0
}

pf_signal_tree() {
  local sig="$1" pid="$2" p
  [ -n "$pid" ] || return 0
  for p in $(_pf_descendants "$pid"); do
    kill "-$sig" "$p" 2>/dev/null || true
  done
  kill "-$sig" -- "-$pid" 2>/dev/null || true
  kill "-$sig" "$pid" 2>/dev/null || true
  return 0
}

# _pf_any_alive: 0 when any slot's process is still running.
_pf_any_alive() {
  local i=0
  while [ "$i" -lt "${#_PF_SLOT_PID[@]}" ]; do
    if [ -n "${_PF_SLOT_PID[$i]}" ] && kill -0 "${_PF_SLOT_PID[$i]}" 2>/dev/null; then return 0; fi
    i=$((i + 1))
  done
  return 1
}

pf_stop_all() {
  local i=0 grace_end
  while [ "$i" -lt "${#_PF_SLOT_PID[@]}" ]; do
    [ -z "${_PF_SLOT_PID[$i]}" ] || pf_signal_tree TERM "${_PF_SLOT_PID[$i]}"
    i=$((i + 1))
  done
  grace_end=$((SECONDS + 2))
  while _pf_any_alive && [ "$SECONDS" -lt "$grace_end" ]; do sleep 0.2; done
  i=0
  while [ "$i" -lt "${#_PF_SLOT_PID[@]}" ]; do
    if [ -n "${_PF_SLOT_PID[$i]}" ]; then
      pf_signal_tree KILL "${_PF_SLOT_PID[$i]}"
      wait "${_PF_SLOT_PID[$i]}" 2>/dev/null || true
    fi
    i=$((i + 1))
  done
  return 0
}

pf_run_files() {
  local jobs="$1" deadline="$2" outdir="$3"
  shift 3
  local total=$# next=0 running=0 started=0 i f out pid st dur reaped young
  local queue=()
  [ "$total" -eq 0 ] || queue=("$@")
  PF_STOPPED=()
  PF_NOT_STARTED=()
  _PF_SLOT_PID=(); _PF_SLOT_FILE=(); _PF_SLOT_OUT=(); _PF_SLOT_START=()
  [ "$jobs" -ge 1 ] 2>/dev/null || jobs=1

  while :; do
    if [ "$deadline" -gt 0 ] && [ "$SECONDS" -ge "$deadline" ] && { [ "$running" -gt 0 ] || [ "$next" -lt "$total" ]; }; then
      i=0
      while [ "$i" -lt "${#_PF_SLOT_PID[@]}" ]; do
        [ -z "${_PF_SLOT_PID[$i]}" ] || PF_STOPPED+=("${_PF_SLOT_FILE[$i]}")
        i=$((i + 1))
      done
      pf_stop_all
      while [ "$next" -lt "$total" ]; do
        PF_NOT_STARTED+=("${queue[$next]}")
        next=$((next + 1))
      done
      _PF_SLOT_PID=()
      return 124
    fi

    # Fill free slots.
    while [ "$running" -lt "$jobs" ] && [ "$next" -lt "$total" ]; do
      f="${queue[$next]}"
      next=$((next + 1))
      started=$((started + 1))
      out="$outdir/$started.out"
      # Job control on just for the launch, so the file leads its own process group and its whole tree can be
      # signalled.
      set -m
      pf_launch "$f" "$out" < /dev/null &
      pid=$!
      set +m
      i=0
      while [ "$i" -lt "${#_PF_SLOT_PID[@]}" ] && [ -n "${_PF_SLOT_PID[$i]}" ]; do i=$((i + 1)); done
      _PF_SLOT_PID[i]="$pid"
      _PF_SLOT_FILE[i]="$f"
      _PF_SLOT_OUT[i]="$out"
      _PF_SLOT_START[i]="$SECONDS"
      running=$((running + 1))
    done

    [ "$running" -gt 0 ] || break

    # Reap finished files, in completion order.
    reaped=0
    young=0
    i=0
    while [ "$i" -lt "${#_PF_SLOT_PID[@]}" ]; do
      pid="${_PF_SLOT_PID[$i]}"
      if [ -n "$pid" ]; then
        if kill -0 "$pid" 2>/dev/null; then
          [ $((SECONDS - _PF_SLOT_START[i])) -ge 2 ] || young=1
        else
          st=0
          wait "$pid" || st=$?
          dur=$((SECONDS - _PF_SLOT_START[i]))
          _PF_SLOT_PID[i]=""
          running=$((running - 1))
          reaped=1
          pf_on_done "${_PF_SLOT_FILE[$i]}" "$st" "$dur" "${_PF_SLOT_OUT[$i]}"
        fi
      fi
      i=$((i + 1))
    done
    if [ "$reaped" -eq 0 ]; then
      # Poll briskly while a file is young so a short file costs no idle time, then settle.
      if [ "$young" -eq 1 ]; then sleep 0.05; else sleep 0.2; fi
    fi
  done
  _PF_SLOT_PID=()
  return 0
}
