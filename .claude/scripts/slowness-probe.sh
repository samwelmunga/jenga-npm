#!/usr/bin/env bash
################################################################################
# slowness-probe.sh — is this machine slow right now? (wall time versus CPU time)
#
# Runs one reference bats file and compares the wall-clock time it took with the CPU time
# (user + sys) it used. On a healthy machine the two are close (about 1.7 on the maintainer
# machine after a reboot); when something outside the tests makes every process start wait
# (a security agent authorising each exec, for instance) the same file keeps its CPU time and
# its wall time grows 10 times (see project/rapports/problems/
# E77_S06_T11-wall-clock-timings-inflated-by-first-exec-latency.md). Wall above THRESHOLD
# times CPU classifies the machine as slow, and the probe then collects diagnostics.
#
# Usage:
#   slowness-probe.sh [--root <dir>] [--probe-file <rel>] [--threshold <n>] [--log <file>]
#                     [--no-log] [--exec-files <n>] [--quiet-skip]
#   slowness-probe.sh --print-threshold [--root <dir>] [--threshold <n>]
#   slowness-probe.sh --help
#
#   --root <dir>        project root; the reference file is resolved under it and the log is
#                       written under it. Default: the root scripts/resolve-root.sh resolves.
#   --probe-file <rel>  reference bats file relative to the root. Default
#                       tests/workflow-outputs.bats (about 60 s on a healthy machine).
#   --threshold <n>     slow when wall > n * CPU. Resolved in this order: this option, then
#                       $JENGA_SLOWNESS_THRESHOLD, then the machine-local file
#                       <root>/project/logs/slowness-threshold (one number on its first line,
#                       git-ignored, written by skills/j-test/scripts/slowness-check.sh
#                       set-threshold), then 2.5. An unreadable or non-positive value in the file
#                       is reported on stderr and ignored.
#   --log <file>        JSON-lines log. Default <root>/project/logs/slowness-probe.jsonl.
#   --no-log            do not write the log.
#   --exec-files <n>    number of fresh scripts the first-exec benchmark runs when the machine
#                       is slow. Default 100.
#   --quiet-skip        print nothing when the run is skipped (exit 3 still reported).
#   --print-threshold   measure nothing: print "<n> <source>" for the threshold that applies,
#                       source being option, environment, saved or default, and exit 0.
#
# WHAT IT MEASURES (all of it recorded in one JSON line per run)
#   - uptime, load average, the CPU of security-agent processes (wdav*, epsext, mdatp) at the
#     busiest sample, the number of `git fsmonitor--daemon` processes
#   - terminal start: time of `$SHELL -i -l -c exit`, median of 3
#   - process start cost: `bash -c :` per call, idle, and sampled while the reference file runs
#     (the ratio is spawn_inflation)
#   - wall and CPU of the reference file, and their ratio
#   When the ratio crosses the threshold it also runs the diagnostics: the first-exec versus
#   re-exec benchmark of N fresh scripts, the five busiest processes, and a list of the
#   indicators that crossed their own threshold.
#
# EXIT CODES
#   0   healthy: wall <= threshold * CPU and the reference file passed
#   1   the reference file failed (the ratio is still logged and, when slow, diagnosed)
#   2   usage error
#   3   skipped: bats or the reference file is absent (nothing measured, nothing logged)
#   10  slow: wall > threshold * CPU
#   130 interrupted
#
# Read-only apart from the log line and a scratch directory under ${TMPDIR:-/tmp}, removed on
# every exit path. Never changes any machine setting. Requires jq. bash 3.2 compatible.
################################################################################

set -uo pipefail
# bash's `time` honours the numeric locale; a comma decimal would break the arithmetic below.
export LC_NUMERIC=C

SCRIPT_NAME="slowness-probe.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
die_usage() { err "$1"; exit 2; }

usage() {
  sed -n '2,/^####/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

ROOT=""
PROBE_FILE="tests/workflow-outputs.bats"
THRESHOLD="${JENGA_SLOWNESS_THRESHOLD:-}"
THRESHOLD_GIVEN=0
[ -z "$THRESHOLD" ] || THRESHOLD_GIVEN=1
LOG=""
WRITE_LOG=1
EXEC_FILES=100
QUIET_SKIP=0
PRINT_THRESHOLD=0
THRESHOLD_SOURCE="default"
[ "$THRESHOLD_GIVEN" -eq 0 ] || THRESHOLD_SOURCE="environment"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --root)       [ "$#" -ge 2 ] || die_usage "--root needs an argument"; ROOT="$2"; shift 2 ;;
    --probe-file) [ "$#" -ge 2 ] || die_usage "--probe-file needs an argument"; PROBE_FILE="$2"; shift 2 ;;
    --threshold)  [ "$#" -ge 2 ] || die_usage "--threshold needs an argument"; THRESHOLD="$2"; THRESHOLD_GIVEN=1; THRESHOLD_SOURCE="option"; shift 2 ;;
    --log)        [ "$#" -ge 2 ] || die_usage "--log needs an argument"; LOG="$2"; shift 2 ;;
    --no-log)     WRITE_LOG=0; shift ;;
    --quiet-skip) QUIET_SKIP=1; shift ;;
    --print-threshold) PRINT_THRESHOLD=1; shift ;;
    --exec-files) [ "$#" -ge 2 ] || die_usage "--exec-files needs an argument"; EXEC_FILES="$2"; shift 2 ;;
    *) die_usage "unknown option: $1 (see --help)" ;;
  esac
done

if [ "$THRESHOLD_GIVEN" -eq 1 ]; then
  case "$THRESHOLD" in
    ''|*[!0-9.]*|.|*.*.*) die_usage "--threshold must be a positive number, got '$THRESHOLD'" ;;
  esac
fi
case "$EXEC_FILES" in
  ''|*[!0-9]*|0*) die_usage "--exec-files must be a positive integer, got '$EXEC_FILES'" ;;
esac
command -v jq >/dev/null 2>&1 || die_usage "jq is required but was not found on PATH"

if [ -z "$ROOT" ]; then
  ROOT="$(bash "$SCRIPT_DIR/resolve-root.sh" root 2>/dev/null)" || die_usage "could not resolve the project root"
fi
[ -d "$ROOT" ] || die_usage "root is not a directory: $ROOT"
ROOT="$(cd -- "$ROOT" && pwd)"
[ -n "$LOG" ] || LOG="$ROOT/project/logs/slowness-probe.jsonl"

if [ -z "$THRESHOLD" ]; then
  THRESHOLD="2.5"
  THRESHOLD_FILE="$ROOT/project/logs/slowness-threshold"
  if [ -f "$THRESHOLD_FILE" ]; then
    saved="$(head -n 1 "$THRESHOLD_FILE" 2>/dev/null | tr -d '[:space:]')"
    case "$saved" in
      ''|*[!0-9.]*|.|*.*.*) err "ignoring $THRESHOLD_FILE: '$saved' is not a positive number" ;;
      *) if awk -v t="$saved" 'BEGIN { exit !(t > 0) }'; then THRESHOLD="$saved"; THRESHOLD_SOURCE="saved"; else err "ignoring $THRESHOLD_FILE: '$saved' is not a positive number"; fi ;;
    esac
  fi
fi

if [ "$PRINT_THRESHOLD" -eq 1 ]; then
  printf '%s %s\n' "$THRESHOLD" "$THRESHOLD_SOURCE"
  exit 0
fi

if ! command -v bats >/dev/null 2>&1; then
  [ "$QUIET_SKIP" -eq 1 ] || printf 'slowness probe skipped: bats is not on PATH\n'
  exit 3
fi
if [ ! -f "$ROOT/$PROBE_FILE" ]; then
  [ "$QUIET_SKIP" -eq 1 ] || printf 'slowness probe skipped: %s is not present under %s\n' "$PROBE_FILE" "$ROOT"
  exit 3
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/slowness-probe.XXXXXX")" || die_usage "could not create a scratch directory"
BATS_PID=""
SAMPLER_PID=""

cleanup() {
  [ -z "$SAMPLER_PID" ] || kill -TERM "$SAMPLER_PID" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
on_signal() {
  [ -z "$BATS_PID" ] || kill -TERM -- "-$BATS_PID" 2>/dev/null || kill -TERM "$BATS_PID" 2>/dev/null || true
  cleanup
  exit 130
}
trap cleanup EXIT
trap on_signal INT TERM

# ---- helpers ----------------------------------------------------------------------------

# time_block <outfile> <command...>: runs the command, writes "real user sys" (seconds) to outfile.
time_block() {
  local out="$1"
  shift
  local TIMEFORMAT='%R %U %S'
  { time "$@" >/dev/null 2>&1; } 2> "$out"
}

# spawn_batch_ms <n>: milliseconds per `bash -c :`, measured over a batch of n.
spawn_batch_ms() {
  local n="$1" f="$SCRATCH/spawn.$$.$RANDOM"
  time_block "$f" bash -c "i=0; while [ \$i -lt $n ]; do /bin/bash -c :; i=\$((i+1)); done"
  awk -v n="$n" '{ printf "%.1f", $1 * 1000 / n }' "$f"
  rm -f "$f"
}

median() {
  sort -n | awk '{ a[NR] = $1 } END { if (NR == 0) print 0; else print a[int((NR + 1) / 2)] }'
}

security_agent_cpu() {
  ps -Ao pcpu,comm 2>/dev/null | awk '/wdav|epsext|mdatp|MsMpEng/ { s += $1 } END { printf "%.1f", s + 0 }'
}

fsmonitor_count() {
  ps -Ao command 2>/dev/null | grep -c '[f]smonitor--daemon'
}

# ---- context and baselines (machine idle) -------------------------------------------------
UPTIME_RAW="$(uptime 2>/dev/null | sed 's/^ *//')"
LOAD1="$(printf '%s' "$UPTIME_RAW" | sed -n 's/.*load averages\{0,1\}: *\([0-9.]*\).*/\1/p')"
LOAD1="$(printf '%s' "${LOAD1:-0}" | tr , .)"
UPTIME_DAYS="$(printf '%s' "$UPTIME_RAW" | sed -n 's/.* up \([0-9]*\) days\{0,1\}.*/\1/p')"
UPTIME_DAYS="${UPTIME_DAYS:-0}"

printf 'slowness probe: measuring baselines (terminal start, process start)\n'

TERM_SHELL="${SHELL:-/bin/zsh}"
[ -x "$TERM_SHELL" ] || TERM_SHELL="$(command -v bash)"
TERM_FILE="$SCRATCH/term"
: > "$TERM_FILE"
for _ in 1 2 3; do
  time_block "$SCRATCH/t1" "$TERM_SHELL" -i -l -c exit < /dev/null
  awk '{ print $1 }' "$SCRATCH/t1" >> "$TERM_FILE"
done
TERMINAL_START_S="$(median < "$TERM_FILE")"

IDLE_SPAWN_MS="$(spawn_batch_ms 50)"

# ---- the reference file, sampled while it runs ---------------------------------------------
printf 'slowness probe: running %s (about 1 minute on a healthy machine)\n' "$PROBE_FILE"

set -m
SAMPLES="$SCRATCH/samples"
: > "$SAMPLES"
(
  while :; do
    ms="$(spawn_batch_ms 20)"
    printf '%s %s\n' "$ms" "$(security_agent_cpu)" >> "$SAMPLES"
    sleep 1
  done
) &
SAMPLER_PID=$!

(
  cd -- "$ROOT" || exit 126
  export JENGA_NESTED_SUITE_RUN=1
  TIMEFORMAT='%R %U %S'
  { time bats "$PROBE_FILE" > "$SCRATCH/bats.out" 2>&1; } 2> "$SCRATCH/bats.time"
  exit "$?"
) &
BATS_PID=$!
BATS_RC=0
wait "$BATS_PID" || BATS_RC=$?
BATS_PID=""
kill -TERM "$SAMPLER_PID" 2>/dev/null || true
wait "$SAMPLER_PID" 2>/dev/null || true
SAMPLER_PID=""
set +m

read -r WALL USER_T SYS_T < "$SCRATCH/bats.time" || true
WALL="${WALL:-0}"; USER_T="${USER_T:-0}"; SYS_T="${SYS_T:-0}"
CPU="$(awk -v u="$USER_T" -v s="$SYS_T" 'BEGIN { printf "%.3f", u + s }')"
RATIO="$(awk -v w="$WALL" -v c="$CPU" 'BEGIN { if (c < 0.01) c = 0.01; printf "%.2f", w / c }')"
SLOW="$(awk -v r="$RATIO" -v t="$THRESHOLD" 'BEGIN { print (r > t) ? "true" : "false" }')"

LOADED_SPAWN_MS="$(awk '{ print $1 }' "$SAMPLES" | median)"
AGENT_CPU_MAX="$(awk '{ if ($2 > m) m = $2 } END { printf "%.1f", m + 0 }' "$SAMPLES")"
SPAWN_INFLATION="$(awk -v l="$LOADED_SPAWN_MS" -v i="$IDLE_SPAWN_MS" 'BEGIN { if (i < 0.1) i = 0.1; printf "%.1f", l / i }')"
FSMONITOR="$(fsmonitor_count)"
FSMONITOR="${FSMONITOR:-0}"

# ---- diagnostics (slow only) -----------------------------------------------------------
FIRST_EXEC_MS=0
REEXEC_MS=0
INDICATORS=""
TOP_PROCS="[]"

if [ "$SLOW" = "true" ]; then
  printf 'slowness probe: slow machine, collecting diagnostics (first-exec benchmark of %s scripts)\n' "$EXEC_FILES"
  DD="$SCRATCH/exec"
  mkdir -p "$DD"
  k=1
  while [ "$k" -le "$EXEC_FILES" ]; do
    printf '#!/bin/bash\n:\n' > "$DD/s$k"
    chmod +x "$DD/s$k"
    k=$((k + 1))
  done
  time_block "$SCRATCH/first" bash -c "k=1; while [ \$k -le $EXEC_FILES ]; do '$DD'/s\$k; k=\$((k+1)); done"
  time_block "$SCRATCH/again" bash -c "k=1; while [ \$k -le $EXEC_FILES ]; do '$DD'/s\$k; k=\$((k+1)); done"
  FIRST_EXEC_MS="$(awk -v n="$EXEC_FILES" '{ printf "%.1f", $1 * 1000 / n }' "$SCRATCH/first")"
  REEXEC_MS="$(awk -v n="$EXEC_FILES" '{ printf "%.1f", $1 * 1000 / n }' "$SCRATCH/again")"
  TOP_PROCS="$(ps -Ao pcpu,comm 2>/dev/null | sort -rn | head -5 \
    | awk '{ p = $1; $1 = ""; sub(/^ /, ""); n = split($0, a, "/"); printf "%s\t%s\n", p, a[n] }' \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {cpu_pct: (.[0] | tonumber), process: .[1]})')"

  flag() { INDICATORS="${INDICATORS}${INDICATORS:+
}$1"; }
  awk -v f="$FIRST_EXEC_MS" -v r="$REEXEC_MS" 'BEGIN { exit !(f >= 50 && f >= 10 * (r < 0.5 ? 0.5 : r)) }' \
    && flag "first execution of a new file is slow (${FIRST_EXEC_MS} ms against ${REEXEC_MS} ms for a re-run): something authorises every exec"
  awk -v a="$AGENT_CPU_MAX" 'BEGIN { exit !(a >= 50) }' \
    && flag "security-agent processes (wdav*, epsext, mdatp) reached ${AGENT_CPU_MAX}% CPU while the file ran"
  awk -v s="$SPAWN_INFLATION" 'BEGIN { exit !(s >= 3) }' \
    && flag "starting a process cost ${SPAWN_INFLATION} times more while the file ran than when idle"
  [ "$FSMONITOR" -ge 5 ] \
    && flag "${FSMONITOR} git fsmonitor--daemon processes are running"
  awk -v t="$TERMINAL_START_S" 'BEGIN { exit !(t >= 5) }' \
    && flag "starting a terminal shell takes ${TERMINAL_START_S} s"
  awk -v l="$LOAD1" 'BEGIN { exit !(l >= 8) }' \
    && flag "the load average is ${LOAD1}"
  : # the flag lines above end in `&&`, and a false test must not decide the exit status
fi

# ---- the log line --------------------------------------------------------------------
if [ "$WRITE_LOG" -eq 1 ]; then
  mkdir -p "$(dirname -- "$LOG")" 2>/dev/null || true
  jq -n -c \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg probe "$PROBE_FILE" \
    --arg uptime "$UPTIME_RAW" \
    --arg indicators "$INDICATORS" \
    --argjson wall "$WALL" --argjson cpu "$CPU" --argjson ratio "$RATIO" \
    --argjson threshold "$THRESHOLD" --argjson slow "$SLOW" --argjson bats_rc "$BATS_RC" \
    --argjson load1 "$LOAD1" --argjson uptime_days "$UPTIME_DAYS" \
    --argjson terminal_start_s "$TERMINAL_START_S" \
    --argjson idle_spawn_ms "$IDLE_SPAWN_MS" --argjson loaded_spawn_ms "$LOADED_SPAWN_MS" \
    --argjson spawn_inflation "$SPAWN_INFLATION" \
    --argjson security_agent_cpu_max "$AGENT_CPU_MAX" --argjson fsmonitor_daemons "$FSMONITOR" \
    --argjson first_exec_ms "$FIRST_EXEC_MS" --argjson reexec_ms "$REEXEC_MS" \
    --argjson top_processes "$TOP_PROCS" \
    '{ts:$ts, probe:$probe, wall_s:$wall, cpu_s:$cpu, ratio:$ratio, threshold:$threshold, slow:$slow,
      bats_exit:$bats_rc, uptime:$uptime, uptime_days:$uptime_days, load1:$load1,
      terminal_start_s:$terminal_start_s, idle_spawn_ms:$idle_spawn_ms, loaded_spawn_ms:$loaded_spawn_ms,
      spawn_inflation:$spawn_inflation, security_agent_cpu_max:$security_agent_cpu_max,
      fsmonitor_daemons:$fsmonitor_daemons, first_exec_ms:$first_exec_ms, reexec_ms:$reexec_ms,
      top_processes:$top_processes, indicators:($indicators | split("\n") | map(select(length > 0)))}' \
    >> "$LOG" 2>/dev/null || err "could not write the log: $LOG"
fi

# ---- report ------------------------------------------------------------------------------
printf 'slowness probe: %s  wall %ss, CPU %ss, ratio %s (slow above %s)\n' \
  "$PROBE_FILE" "$WALL" "$CPU" "$RATIO" "$THRESHOLD"
printf '  terminal start %ss | bash -c : %s ms idle, %s ms under load (x%s) | security agents up to %s%% CPU | %s fsmonitor daemons | %s\n' \
  "$TERMINAL_START_S" "$IDLE_SPAWN_MS" "$LOADED_SPAWN_MS" "$SPAWN_INFLATION" "$AGENT_CPU_MAX" "$FSMONITOR" "$UPTIME_RAW"
if [ "$BATS_RC" -ne 0 ]; then
  printf '  the reference file FAILED (bats exit %s); output kept below\n' "$BATS_RC"
  tail -n 15 "$SCRATCH/bats.out" | sed 's/^/    /'
fi
if [ "$SLOW" = "true" ]; then
  printf 'MACHINE IS SLOW: wall time is %sx CPU time. Wall-clock timings from this run are not trustworthy; use CPU time.\n' "$RATIO"
  printf '  first exec %s ms, re-exec %s ms\n' "$FIRST_EXEC_MS" "$REEXEC_MS"
  if [ -n "$INDICATORS" ]; then
    printf '  indicators:\n'
    printf '%s\n' "$INDICATORS" | sed 's/^/    - /'
  else
    printf '  no single indicator crossed its threshold; the cause is not identified by this probe\n'
  fi
  printf '  busiest processes: %s\n' "$(printf '%s' "$TOP_PROCS" | jq -r 'map("\(.process) \(.cpu_pct)%") | join(", ")')"
  [ "$WRITE_LOG" -eq 0 ] || printf '  logged to %s\n' "$LOG"
  exit 10
fi
printf 'machine is not slow\n'
[ "$WRITE_LOG" -eq 0 ] || printf '  logged to %s\n' "$LOG"
[ "$BATS_RC" -eq 0 ] || exit 1
exit 0
