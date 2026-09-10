#!/usr/bin/env bats
#
# Fixture-based coverage for run-playbook-step.sh's composed/nested-step handling (E53_S05_T04):
# the optional 5th <json-origins> `init` argument, and the explicit AC requirement that a failure
# on an origin-tagged (composed) step halts the entire chain exactly like a top-level step's
# failure -- no special-casing, same completed/failed_step/never_run reporting shape.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RPS="$REPO_ROOT/skills/jenga/scripts/run-playbook-step.sh"

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-root"
  mkdir -p "$FIXTURE_ROOT"
  export JENGA_PLAYBOOK_RUNS_TEST_ROOT="$FIXTURE_ROOT"
}

init_run() {
  local playbook_id="$1" name="$2" steps="$3" conditionals="${4:-}" origins="${5:-}"
  local stderr_file="$BATS_TEST_TMPDIR/init_stderr_$$_$RANDOM"
  if [ -n "$origins" ]; then
    bash "$RPS" init "$playbook_id" "$name" "$steps" "$conditionals" "$origins" >/dev/null 2>"$stderr_file"
  elif [ -n "$conditionals" ]; then
    bash "$RPS" init "$playbook_id" "$name" "$steps" "$conditionals" >/dev/null 2>"$stderr_file"
  else
    bash "$RPS" init "$playbook_id" "$name" "$steps" >/dev/null 2>"$stderr_file"
  fi
  STATE_FILE="$(grep 'STATE_FILE:' "$stderr_file" | sed 's/STATE_FILE: //')"
}

# -----------------------------------------------------------------------------
# Backward compatibility + basic origins storage
# -----------------------------------------------------------------------------

@test "init without <json-origins> still works exactly as before" {
  run bash "$RPS" init "pb" "PB" "stepA,stepB"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "step_ready"'
}

@test "init with <json-origins> stores it verbatim in the state file's origins map" {
  init_run "pb-origins" "PB Origins" "stepA,stepB,stepC" '{}' \
    '{"stepB": {"playbook_id": "nested", "depth": 2}, "stepC": {"playbook_id": "nested", "depth": 2}}'

  run python3 -c "import json; print(json.load(open('$STATE_FILE'))['origins'])"
  [ "$status" -eq 0 ]
  assert_output_contains "'stepB'"
  assert_output_contains "'playbook_id': 'nested'"
  assert_output_contains "'depth': 2"
}

# -----------------------------------------------------------------------------
# The story's explicit AC: a failure on a composed (origin-tagged) step halts the WHOLE chain
# -----------------------------------------------------------------------------

@test "a failure on a composed/origin-tagged step halts the entire chain, same as a top-level step" {
  init_run "pb-composed-halt" "PB Composed Halt" "outer1,src,sink" '{}' \
    '{"src": {"playbook_id": "nested", "depth": 2}, "sink": {"playbook_id": "nested", "depth": 2}}'

  bash "$RPS" advance "$STATE_FILE" passed >/dev/null 2>&1  # outer1 completes normally

  run bash "$RPS" advance "$STATE_FILE" failed "composed step exploded"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "halted"'
  assert_output_contains '"completed": ["outer1"]'
  assert_output_contains '"failed_step": "src"'
  assert_output_contains '"failed_note": "composed step exploded"'
  assert_output_contains '"never_run": ["sink"]'
}

@test "a halted composed-chain run rejects a further advance call (no silent resumption)" {
  init_run "pb-composed-halt2" "PB Composed Halt2" "outer1,src" '{}' \
    '{"src": {"playbook_id": "nested", "depth": 2}}'

  bash "$RPS" advance "$STATE_FILE" failed "boom" >/dev/null 2>&1

  run bash "$RPS" advance "$STATE_FILE" passed
  [ "$status" -eq 3 ]
  assert_output_contains "already halted"
}

@test "a successful composed chain reports the same 'complete' shape as a non-composed chain" {
  init_run "pb-composed-complete" "PB Composed Complete" "outer1,src" '{}' \
    '{"src": {"playbook_id": "nested", "depth": 2}}'

  bash "$RPS" advance "$STATE_FILE" passed >/dev/null 2>&1

  run bash "$RPS" advance "$STATE_FILE" passed
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "complete"'
  assert_output_contains '"completed": ["outer1", "src"]'
  assert_output_contains '"skipped": []'
}

# -----------------------------------------------------------------------------
# should-skip / get-output stay origin-agnostic (address purely by step name)
# -----------------------------------------------------------------------------

@test "should-skip and get-output are unaffected by a step's origins entry" {
  init_run "pb-origin-agnostic" "PB Origin Agnostic" "outer1,src" \
    '{"src": {"depends_on": "outer1", "predicate": "non_empty"}}' \
    '{"src": {"playbook_id": "nested", "depth": 2}}'

  bash "$RPS" advance "$STATE_FILE" passed "some-value" >/dev/null 2>&1

  run bash "$RPS" should-skip "$STATE_FILE"
  [ "$status" -eq 0 ]
  assert_output_contains '"skip": false'
  assert_output_contains '"step": "src"'

  run bash "$RPS" get-output "$STATE_FILE" outer1
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "found"'
  assert_output_contains '"value": "some-value"'
}

@test "init rejects origins metadata for a step not in the step list" {
  run bash "$RPS" init "pb-bad-origin" "PB Bad Origin" "stepA,stepB" '{}' \
    '{"nonexistent": {"playbook_id": "x", "depth": 2}}'
  [ "$status" -eq 2 ]
  assert_output_contains "which is not in the step list"
}
