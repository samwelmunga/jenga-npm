#!/usr/bin/env bats
#
# Coverage for scripts/slowness-probe.sh and for its preflight call in skills/j-test/scripts/run-suites.sh.
#
# The probe runs one reference bats file and compares its wall time with its CPU time. These cases never run the real
# reference file: a stub `bats` placed first on PATH stands in for it, and the "reference file" is an empty file under
# BATS_TEST_TMPDIR. A stub that sleeps has wall time and almost no CPU time (slow); a stub that exits at once is judged
# with a very large --threshold, so no case depends on how busy the machine happens to be. SHELL is pinned to /bin/sh so
# the terminal-start measurement costs milliseconds instead of a login shell's startup.
#
#   1. contract    exists, executable, shellcheck clean, --help, argument validation
#   2. skip        no reference file or no bats: exit 3, nothing measured, nothing logged
#   3. verdicts    exit 0 healthy, 10 slow (with diagnostics), 1 when the reference file fails
#   4. log         one valid JSON line per run, appended; --no-log writes nothing
#   5. preflight   run-suites.sh runs the probe first on a full-catalog selection only, and never changes what runs
#
# Everything scratch lives under BATS_TEST_TMPDIR; the repository is only read.

# shellcheck disable=SC2030,SC2031
# SC2030/SC2031: bats runs every @test in its own subshell, so reading $status after `run` is correct.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PROBE="$REPO_ROOT/scripts/slowness-probe.sh"
RUN="$REPO_ROOT/skills/j-test/scripts/run-suites.sh"
BASH_BIN="$(command -v bash)"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$PROJ/tests" "$STUBS"
  : > "$PROJ/tests/ref.bats"
  : > "$PROJ/tests/workflow-outputs.bats"
  LOG="$PROJ/project/logs/slowness-probe.jsonl"
  RUN_MARK="$BATS_TEST_TMPDIR/mark"
  export RUN_MARK
}

# stub_bats <exit code> <seconds to sleep>: a `bats` that sleeps (wall time, no CPU) and exits with the code.
stub_bats() {
  printf '#!/bin/sh\n[ "%s" = 0 ] || sleep %s\nexit %s\n' "$2" "$2" "$1" > "$STUBS/bats"
  chmod +x "$STUBS/bats"
}

# probe <args...>: run the probe against the scratch project with the stub bats first on PATH.
probe() {
  run --separate-stderr env PATH="$STUBS:$PATH" SHELL=/bin/sh "$BASH_BIN" "$PROBE" --root "$PROJ" --probe-file tests/ref.bats --exec-files 3 "$@"
}

# --- 1. contract ---------------------------------------------------------------------------------------------------

@test "the script exists, is executable, is mode 100755 in git, and is shellcheck clean" {
  [ -f "$PROBE" ]
  [ -x "$PROBE" ]
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local mode
    mode="$(git -C "$REPO_ROOT" ls-files -s -- scripts/slowness-probe.sh | cut -d' ' -f1)"
    [ -z "$mode" ] || [ "$mode" = "100755" ]
  fi
  if command -v shellcheck >/dev/null 2>&1; then
    run shellcheck -S warning "$PROBE"
    [ "$status" -eq 0 ]
  fi
}

@test "--help prints the contract and exits 0" {
  run "$BASH_BIN" "$PROBE" --help
  [ "$status" -eq 0 ]
  assert_output_contains "EXIT CODES"
  assert_output_contains "--threshold"
}

@test "an unknown option, a bad threshold and a bad file count are usage errors (exit 2)" {
  run --separate-stderr "$BASH_BIN" "$PROBE" --bogus
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "unknown option"
  run --separate-stderr "$BASH_BIN" "$PROBE" --root "$PROJ" --threshold abc
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--threshold"
  run --separate-stderr "$BASH_BIN" "$PROBE" --root "$PROJ" --exec-files 0
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--exec-files"
  run --separate-stderr "$BASH_BIN" "$PROBE" --root "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "not a directory"
}

# --- 2. skip -------------------------------------------------------------------------------------------------------

@test "a missing reference file is a skip (exit 3): nothing measured, nothing logged" {
  stub_bats 0 0
  probe --probe-file tests/absent.bats
  [ "$status" -eq 3 ]
  assert_output_contains "skipped"
  [ ! -e "$LOG" ]
}

@test "bats absent from PATH is a skip (exit 3)" {
  local dir filtered=""
  # jq may live in the same directory as bats (Homebrew), so link it into a directory that stays on PATH.
  ln -s "$(command -v jq)" "$STUBS/jq"
  filtered="$STUBS"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -x "$dir/bats" ] && continue
    filtered="$filtered:$dir"
  done < <(printf '%s\n' "$PATH" | tr ':' '\n')
  run env PATH="$filtered" SHELL=/bin/sh "$BASH_BIN" "$PROBE" --root "$PROJ" --probe-file tests/ref.bats
  [ "$status" -eq 3 ]
  assert_output_contains "bats is not on PATH"
  [ ! -e "$LOG" ]
}

# --- 3. verdicts ---------------------------------------------------------------------------------------------------

@test "wall within the threshold of CPU is healthy (exit 0), with no diagnostics" {
  stub_bats 0 0
  probe --threshold 1000
  [ "$status" -eq 0 ]
  assert_output_contains "machine is not slow"
  assert_output_not_contains "MACHINE IS SLOW"
  [ "$(jq -r '.slow' "$LOG")" = "false" ]
  [ "$(jq -r '.first_exec_ms' "$LOG")" = "0" ]
}

@test "wall above the threshold times CPU is slow (exit 10) and the diagnostics run" {
  stub_bats 0 1
  probe
  [ "$status" -eq 10 ]
  assert_output_contains "MACHINE IS SLOW"
  assert_output_contains "first exec"
  assert_output_contains "busiest processes"
  [ "$(jq -r '.slow' "$LOG")" = "true" ]
  [ "$(jq -r '.ratio > 2.5' "$LOG")" = "true" ]
  [ "$(jq -r '.first_exec_ms > 0' "$LOG")" = "true" ]
  [ "$(jq -r '.top_processes | length > 0' "$LOG")" = "true" ]
}

@test "the threshold decides: the same slow stub is healthy under a very large threshold, given by option or environment" {
  stub_bats 0 1
  probe --threshold 100000
  [ "$status" -eq 0 ]
  [ "$(jq -r '.slow' "$LOG")" = "false" ]
  run --separate-stderr env PATH="$STUBS:$PATH" SHELL=/bin/sh JENGA_SLOWNESS_THRESHOLD=100000 "$BASH_BIN" "$PROBE" --root "$PROJ" --probe-file tests/ref.bats
  [ "$status" -eq 0 ]
}

@test "a failing reference file is exit 1, and the failure is logged" {
  stub_bats 1 0
  probe --threshold 1000
  [ "$status" -eq 1 ]
  assert_output_contains "FAILED"
  [ "$(jq -r '.bats_exit' "$LOG")" = "1" ]
}

# --- 4. log ----------------------------------------------------------------------------------------------------------

@test "each run appends one valid JSON line carrying the machine context" {
  stub_bats 0 0
  probe --threshold 1000
  probe --threshold 1000
  [ "$(wc -l < "$LOG" | tr -d ' ')" = "2" ]
  run jq -e -s 'all(.[]; has("ts") and has("wall_s") and has("cpu_s") and has("ratio") and has("uptime")
    and has("load1") and has("terminal_start_s") and has("idle_spawn_ms") and has("loaded_spawn_ms")
    and has("security_agent_cpu_max") and has("fsmonitor_daemons") and (.indicators | type == "array"))' "$LOG"
  [ "$status" -eq 0 ]
}

@test "--no-log writes no log" {
  stub_bats 0 0
  probe --threshold 1000 --no-log
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
}

# --- 5. the preflight in run-suites.sh ----------------------------------------------------------------------------

# one.json / two.json: a catalog of one, or two, trivial suites that record that they ran.
write_catalogs() {
  printf '{"runnable":[{"n":1,"name":"one","type":"unit","command":"echo one >> \\"$RUN_MARK\\""}]}\n' > "$BATS_TEST_TMPDIR/one.json"
  printf '{"runnable":[{"n":1,"name":"one","type":"unit","command":"echo one >> \\"$RUN_MARK\\""},{"n":2,"name":"two","type":"unit","command":"echo two >> \\"$RUN_MARK\\""}]}\n' > "$BATS_TEST_TMPDIR/two.json"
}

@test "a full-catalog run starts with the probe, still runs every suite, and flags a slow machine without changing the exit code" {
  write_catalogs
  stub_bats 0 1
  run --separate-stderr env PATH="$STUBS:$PATH" SHELL=/bin/sh "$BASH_BIN" "$RUN" --root "$PROJ" --catalog "$BATS_TEST_TMPDIR/one.json" 1
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "slowness probe: measuring baselines"
  assert_output_contains "MACHINE IS SLOW"
  assert_output_contains "✓ one (unit)"
  assert_output_contains "Note: the slowness probe found this machine slow"
  [ "$(cat "$RUN_MARK")" = "one" ]
  [ "$(jq -r '.slow' "$LOG")" = "true" ]
}

@test "a healthy machine adds the probe lines but no note" {
  write_catalogs
  stub_bats 0 0
  run --separate-stderr env PATH="$STUBS:$PATH" SHELL=/bin/sh JENGA_SLOWNESS_THRESHOLD=100000 "$BASH_BIN" "$RUN" --root "$PROJ" --catalog "$BATS_TEST_TMPDIR/one.json" 1
  [ "$status" -eq 0 ]
  assert_output_contains "machine is not slow"
  assert_output_not_contains "Note: the slowness probe"
}

@test "a partial selection does not run the probe" {
  write_catalogs
  stub_bats 0 1
  run --separate-stderr env PATH="$STUBS:$PATH" SHELL=/bin/sh "$BASH_BIN" "$RUN" --root "$PROJ" --catalog "$BATS_TEST_TMPDIR/two.json" 1
  [ "$status" -eq 0 ]
  assert_output_not_contains "slowness probe"
  [ ! -e "$LOG" ]
}

@test "JENGA_SLOWNESS_PROBE=0 and a nested suite run both skip the probe" {
  write_catalogs
  stub_bats 0 1
  run --separate-stderr env PATH="$STUBS:$PATH" SHELL=/bin/sh JENGA_SLOWNESS_PROBE=0 "$BASH_BIN" "$RUN" --root "$PROJ" --catalog "$BATS_TEST_TMPDIR/one.json" 1
  [ "$status" -eq 0 ]
  assert_output_not_contains "slowness probe"
  run --separate-stderr env PATH="$STUBS:$PATH" SHELL=/bin/sh JENGA_NESTED_SUITE_RUN=1 "$BASH_BIN" "$RUN" --root "$PROJ" --catalog "$BATS_TEST_TMPDIR/one.json" 1
  [ "$status" -eq 0 ]
  assert_output_not_contains "slowness probe"
  [ ! -e "$LOG" ]
}

@test "a root without the reference file skips the probe silently" {
  write_catalogs
  stub_bats 0 1
  rm "$PROJ/tests/workflow-outputs.bats"
  run --separate-stderr env PATH="$STUBS:$PATH" SHELL=/bin/sh "$BASH_BIN" "$RUN" --root "$PROJ" --catalog "$BATS_TEST_TMPDIR/one.json" 1
  [ "$status" -eq 0 ]
  assert_output_not_contains "slowness probe"
  assert_output_contains "✓ one (unit)"
  [ ! -e "$LOG" ]
}
