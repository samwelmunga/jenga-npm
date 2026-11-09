#!/usr/bin/env bats
#
# Coverage for skills/j-test/scripts/slowness-check.sh: the seam the j.test skill uses to run the slowness probe, read and
# save this machine's "slow" threshold, and re-judge the last probe against a new threshold without measuring again.
#
# The probe itself is stubbed (a `bats` that sleeps), so nothing here runs a real suite. Everything scratch lives under
# BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECK="$REPO_ROOT/skills/j-test/scripts/slowness-check.sh"
BASH_BIN="$(command -v bash)"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$PROJ/tests" "$STUBS"
  : > "$PROJ/tests/workflow-outputs.bats"
  LOG="$PROJ/project/logs/slowness-probe.jsonl"
  SAVED="$PROJ/project/logs/slowness-threshold"
}

# stub_bats <exit code> <seconds to sleep>
stub_bats() {
  printf '#!/bin/sh\n[ "%s" = 0 ] || sleep %s\nexit %s\n' "$2" "$2" "$1" > "$STUBS/bats"
  chmod +x "$STUBS/bats"
}

# check <args...>: run the script against the scratch project, stub bats first on PATH, no inherited threshold.
check() {
  run --separate-stderr env -u JENGA_SLOWNESS_THRESHOLD PATH="$STUBS:$PATH" SHELL=/bin/sh "$BASH_BIN" "$CHECK" --root "$PROJ" "$@"
}

@test "the script exists, takes --help, and is shellcheck clean" {
  [ -f "$CHECK" ]
  run "$BASH_BIN" "$CHECK" --help
  [ "$status" -eq 0 ]
  assert_output_contains "set-threshold"
  if command -v shellcheck >/dev/null 2>&1; then
    run shellcheck -S warning "$CHECK"
    [ "$status" -eq 0 ]
  fi
}

@test "no subcommand, an unknown one and stray arguments are usage errors (exit 2)" {
  check
  [ "$status" -eq 2 ]
  check frobnicate
  [ "$status" -eq 2 ]
  check probe extra
  [ "$status" -eq 2 ]
  check threshold extra
  [ "$status" -eq 2 ]
}

@test "threshold prints the default, then the saved value after set-threshold" {
  check threshold
  [ "$status" -eq 0 ]
  [ "$output" = "2.5 default" ]
  check set-threshold 4
  [ "$status" -eq 0 ]
  assert_output_contains "wall above 4 times CPU"
  [ "$(cat "$SAVED")" = "4" ]
  check threshold
  [ "$output" = "4 saved" ]
}

@test "set-threshold refuses zero, a negative, a non-number and a missing value, and leaves the saved value alone" {
  check set-threshold 4
  [ "$status" -eq 0 ]
  local bad
  for bad in 0 0.0 -1 abc 1.2.3 ""; do
    check set-threshold "$bad"
    [ "$status" -eq 2 ]
    [ "$(cat "$SAVED")" = "4" ]
  done
  check set-threshold
  [ "$status" -eq 2 ]
}

@test "set-threshold default removes the saved value" {
  check set-threshold 4
  [ -f "$SAVED" ]
  check set-threshold default
  [ "$status" -eq 0 ]
  assert_output_contains "2.5"
  [ ! -e "$SAVED" ]
  check threshold
  [ "$output" = "2.5 default" ]
}

@test "set-threshold says when the environment overrides the saved value" {
  run --separate-stderr env JENGA_SLOWNESS_THRESHOLD=7 "$BASH_BIN" "$CHECK" --root "$PROJ" set-threshold 5
  [ "$status" -eq 0 ]
  assert_output_contains "JENGA_SLOWNESS_THRESHOLD=7"
  assert_output_contains "overrides"
}

@test "probe passes the probe's exit code through: 10 slow, 0 healthy under a saved threshold, 3 when skipped" {
  stub_bats 0 1
  check probe
  [ "$status" -eq 10 ]
  assert_output_contains "MACHINE IS SLOW"
  check set-threshold 100000
  check probe
  [ "$status" -eq 0 ]
  assert_output_contains "machine is not slow"
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr env PATH="$STUBS:$PATH" SHELL=/bin/sh "$BASH_BIN" "$CHECK" --root "$BATS_TEST_TMPDIR/empty" probe
  [ "$status" -eq 3 ]
}

@test "reclassify with no logged probe is exit 3 and says so" {
  check reclassify
  [ "$status" -eq 3 ]
  assert_output_contains "no logged probe"
}

@test "reclassify judges the last logged ratio against the threshold that applies now, without measuring" {
  mkdir -p "$PROJ/project/logs"
  printf '{"ratio":9.9}\n{"ratio":3.1}\n' > "$LOG"
  check reclassify
  [ "$status" -eq 10 ]
  assert_output_contains "still slow"
  check set-threshold 4
  check reclassify
  [ "$status" -eq 0 ]
  assert_output_contains "not slow"
  assert_output_contains "(saved)"
  [ "$(wc -l < "$LOG" | tr -d ' ')" = "2" ]
}

@test "reclassify with a log line that has no ratio is exit 3" {
  mkdir -p "$PROJ/project/logs"
  printf '{"wall_s":1}\n' > "$LOG"
  check reclassify
  [ "$status" -eq 3 ]
}
