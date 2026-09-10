#!/usr/bin/env bats
#
# Fixture-based coverage for render-playbook-confirmation.sh's conditional marker display
# (E53_S04_T04) -- "(may be skipped depending on step N's result)".

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RPC="$REPO_ROOT/skills/jenga/scripts/render-playbook-confirmation.sh"

# Captures the STATE_FILE path from stderr into $STATE_FILE, stdout into $START_OUTPUT.
start_run() {
  local playbook_id="$1" name="$2" steps="$3" conditionals="${4:-}"
  local stdout_file="$BATS_TEST_TMPDIR/start_stdout_$$_$RANDOM"
  local stderr_file="$BATS_TEST_TMPDIR/start_stderr_$$_$RANDOM"
  if [ -n "$conditionals" ]; then
    bash "$RPC" "$playbook_id" "$name" "$steps" "$conditionals" >"$stdout_file" 2>"$stderr_file"
  else
    bash "$RPC" "$playbook_id" "$name" "$steps" >"$stdout_file" 2>"$stderr_file"
  fi
  STATE_FILE="$(grep 'STATE_FILE:' "$stderr_file" | sed 's/STATE_FILE: //')"
  START_OUTPUT="$(cat "$stdout_file")"
}

# -----------------------------------------------------------------------------
# Backward compatibility: 3-arg start (no conditionals) renders no marker
# -----------------------------------------------------------------------------

@test "3-arg start mode (no conditionals) renders no marker, unchanged from before" {
  start_run "pb" "PB" "stepA,stepB,stepC"
  assert_not_contains "$START_OUTPUT" "may be skipped"
  assert_contains "$START_OUTPUT" "1. stepA"
  assert_contains "$START_OUTPUT" "2. stepB"
  assert_contains "$START_OUTPUT" "3. stepC"
}

# -----------------------------------------------------------------------------
# Case: a conditional step is visibly marked with the correct step number
# -----------------------------------------------------------------------------

@test "a conditional step is marked with '(may be skipped depending on step N's result)'" {
  start_run "pb-cond" "PB Cond" "stepA,stepB,stepC" '{"stepC": "stepA"}'
  assert_contains "$START_OUTPUT" "3. stepC (may be skipped depending on step 1's result)"
  # stepA and stepB (no conditional) must NOT carry the marker.
  assert_not_contains "$START_OUTPUT" "1. stepA (may be skipped"
  assert_not_contains "$START_OUTPUT" "2. stepB (may be skipped"
}

@test "the marker persists across a continue-mode toggle re-render" {
  start_run "pb-cond2" "PB Cond2" "stepA,stepB,stepC" '{"stepC": "stepA"}'

  run bash "$RPC" "$STATE_FILE" "check 1"
  [ "$status" -eq 0 ]
  assert_output_contains "3. stepC (may be skipped depending on step 1's result)"
}

@test "start mode rejects malformed json-conditionals" {
  run bash "$RPC" "pb-bad" "PB Bad" "stepA,stepB" 'not-json'
  [ "$status" -eq 2 ]
  assert_output_contains "not valid JSON"
}

@test "start mode rejects a conditional depends_on that names a nonexistent step" {
  run bash "$RPC" "pb-bad2" "PB Bad2" "stepA,stepB" '{"stepB": "nonexistent"}'
  [ "$status" -eq 2 ]
  assert_output_contains "not a step in this playbook"
}
