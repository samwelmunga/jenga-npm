#!/usr/bin/env bats
#
# Fixture-based coverage for run-playbook-step.sh's conditional predicate evaluation, the
# `skipped` status, the `get-output` forward_from lookup, and the artifact-persistence/redaction
# policy (E53_S04_T01 through E53_S04_T05).
#
# This script needs no skills/ or playbooks/ fixture tree the way load-playbooks.sh does -- it
# operates purely on its own ephemeral temp state file, so each test drives it directly via `run`
# against real (throwaway) state files. Artifact-persistence cases redirect the persisted-artifact
# location via JENGA_PLAYBOOK_RUNS_TEST_ROOT so this suite never writes into this repository's own
# project/logs/ (mirrors load-playbooks.sh's own JENGA_PLAYBOOKS_TEST_ROOT fixture-tree
# convention).

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RPS="$REPO_ROOT/skills/jenga/scripts/run-playbook-step.sh"

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-root"
  mkdir -p "$FIXTURE_ROOT"
  # Every `advance ... passed <value>` call in this suite -- not just the ones explicitly testing
  # persistence -- resolves a project root and may attempt to persist an artifact (E53_S04_T05).
  # Exporting this for the WHOLE test file, not just the persistence-specific tests, is what keeps
  # every test in this suite from ever writing into this repository's own real project/logs/.
  export JENGA_PLAYBOOK_RUNS_TEST_ROOT="$FIXTURE_ROOT"
}

# Runs `init` once (outside bats' `run`, since these tests don't need init's own $output/$status)
# and captures the STATE_FILE path from stderr into $STATE_FILE.
init_run() {
  local playbook_id="$1" name="$2" steps="$3" conditionals="${4:-}"
  local stderr_file="$BATS_TEST_TMPDIR/init_stderr_$$_$RANDOM"
  if [ -n "$conditionals" ]; then
    bash "$RPS" init "$playbook_id" "$name" "$steps" "$conditionals" >/dev/null 2>"$stderr_file"
  else
    bash "$RPS" init "$playbook_id" "$name" "$steps" >/dev/null 2>"$stderr_file"
  fi
  STATE_FILE="$(grep 'STATE_FILE:' "$stderr_file" | sed 's/STATE_FILE: //')"
}

# -----------------------------------------------------------------------------
# Backward compatibility: 3-arg init (no conditionals) still works
# -----------------------------------------------------------------------------

@test "3-arg init (no conditionals) still works exactly as before" {
  run bash "$RPS" init "pb" "PB" "stepA,stepB"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "step_ready"'
  assert_output_contains '"step": "stepA"'
}

# -----------------------------------------------------------------------------
# Case 1: a true-conditional step runs normally
# -----------------------------------------------------------------------------

@test "a true-conditional step is not skipped (should-skip reports skip: false)" {
  init_run "pb-true" "PB True" "stepA,stepB" '{"stepB": {"depends_on": "stepA", "predicate": "non_empty"}}'

  run bash "$RPS" should-skip "$STATE_FILE"
  [ "$status" -eq 0 ]
  assert_output_contains '"skip": false'

  bash "$RPS" advance "$STATE_FILE" passed "some-real-value" >/dev/null 2>&1

  run bash "$RPS" should-skip "$STATE_FILE"
  [ "$status" -eq 0 ]
  assert_output_contains '"skip": false'
  assert_output_contains '"step": "stepB"'
}

# -----------------------------------------------------------------------------
# Case 2: a false-conditional step is skipped, chain continues, never halts
# -----------------------------------------------------------------------------

@test "a false-conditional step is skipped and the chain continues without halting" {
  init_run "pb-false" "PB False" "stepA,stepB,stepC" '{"stepB": {"depends_on": "stepA", "predicate": "non_empty"}}'

  # stepA passes with NO value -> captured output is empty -> stepB's non_empty predicate is false
  bash "$RPS" advance "$STATE_FILE" passed >/dev/null 2>&1

  run bash "$RPS" should-skip "$STATE_FILE"
  [ "$status" -eq 0 ]
  assert_output_contains '"skip": true'

  run bash "$RPS" advance "$STATE_FILE" skipped
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "step_ready"'
  assert_output_contains '"step": "stepC"'

  run bash "$RPS" advance "$STATE_FILE" passed
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "complete"'
  assert_output_contains '"completed": ["stepA", "stepC"]'
  assert_output_contains '"skipped": ["stepB"]'
}

@test "advance skipped rejects a 3rd argument (a skipped step has nothing to report)" {
  init_run "pb-reject" "PB Reject" "x,y"

  run bash "$RPS" advance "$STATE_FILE" skipped "should-not-be-allowed"
  [ "$status" -eq 2 ]
  assert_output_contains "does not accept a 3rd argument"
}

# -----------------------------------------------------------------------------
# Case 3: a skipped step followed by a forward_from attempt -- the documented failure mode
# -----------------------------------------------------------------------------

@test "get-output on a skipped step returns the defined step_skipped failure mode" {
  init_run "pb-skip-forward" "PB Skip Forward" "stepA,stepB,stepC" '{"stepB": {"depends_on": "stepA", "predicate": "non_empty"}}'

  bash "$RPS" advance "$STATE_FILE" passed >/dev/null 2>&1   # stepA, no value -> empty
  bash "$RPS" advance "$STATE_FILE" skipped >/dev/null 2>&1  # stepB is skipped (non_empty is false)

  # stepC "attempts to forward_from stepB" -- the calling agent would call get-output here.
  run bash "$RPS" get-output "$STATE_FILE" stepB
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "unavailable"'
  assert_output_contains '"reason": "step_skipped"'
}

@test "get-output on a never-captured (but not skipped) step returns not_captured" {
  init_run "pb-never-captured" "PB Never Captured" "stepA,stepB"

  run bash "$RPS" get-output "$STATE_FILE" stepA
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "unavailable"'
  assert_output_contains '"reason": "not_captured"'
}

@test "get-output on a step with a captured value returns it" {
  init_run "pb-found" "PB Found" "stepA,stepB"
  bash "$RPS" advance "$STATE_FILE" passed "captured-value-here" >/dev/null 2>&1

  run bash "$RPS" get-output "$STATE_FILE" stepA
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "found"'
  assert_output_contains '"value": "captured-value-here"'
}

# -----------------------------------------------------------------------------
# Predicate variety
# -----------------------------------------------------------------------------

@test "predicate 'empty' skips when the depended-on step produced no value" {
  init_run "pb-empty" "PB Empty" "stepA,stepB" '{"stepB": {"depends_on": "stepA", "predicate": "empty"}}'
  bash "$RPS" advance "$STATE_FILE" passed >/dev/null 2>&1

  run bash "$RPS" should-skip "$STATE_FILE"
  [ "$status" -eq 0 ]
  assert_output_contains '"skip": false'
}

@test "predicate 'equals:<value>' matches exactly and only exactly" {
  init_run "pb-equals" "PB Equals" "stepA,stepB" '{"stepB": {"depends_on": "stepA", "predicate": "equals:yes"}}'
  bash "$RPS" advance "$STATE_FILE" passed "yes" >/dev/null 2>&1

  run bash "$RPS" should-skip "$STATE_FILE"
  [ "$status" -eq 0 ]
  assert_output_contains '"skip": false'
}

@test "predicate 'not_equals:<value>' skips only on an exact match" {
  init_run "pb-not-equals" "PB Not Equals" "stepA,stepB" '{"stepB": {"depends_on": "stepA", "predicate": "not_equals:yes"}}'
  bash "$RPS" advance "$STATE_FILE" passed "yes" >/dev/null 2>&1

  run bash "$RPS" should-skip "$STATE_FILE"
  [ "$status" -eq 0 ]
  assert_output_contains '"skip": true'
}

# -----------------------------------------------------------------------------
# init-time conditional validation
# -----------------------------------------------------------------------------

@test "init rejects a conditional depends_on that is not an earlier step" {
  run bash "$RPS" init "pb-bad" "PB Bad" "stepA,stepB" '{"stepA": {"depends_on": "stepB", "predicate": "non_empty"}}'
  [ "$status" -eq 2 ]
  assert_output_contains "not an earlier step"
}

@test "init rejects an unrecognized predicate" {
  run bash "$RPS" init "pb-bad-pred" "PB Bad Pred" "stepA,stepB" '{"stepB": {"depends_on": "stepA", "predicate": "bogus"}}'
  [ "$status" -eq 2 ]
  assert_output_contains "unrecognized predicate"
}

# -----------------------------------------------------------------------------
# Artifact persistence + redaction (E53_S04_T05)
# -----------------------------------------------------------------------------

@test "a captured value is persisted (redacted) under JENGA_PLAYBOOK_RUNS_TEST_ROOT" {
  init_run "pb-persist" "PB Persist" "stepA,stepB"
  RUN_ID="$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['run_id'])")"

  JENGA_PLAYBOOK_RUNS_TEST_ROOT="$FIXTURE_ROOT" bash "$RPS" advance "$STATE_FILE" passed "email me at test@example.com" >/dev/null 2>&1

  ARTIFACT_FILE="$FIXTURE_ROOT/project/logs/playbook-runs/$RUN_ID/artifacts.jsonl"
  [ -f "$ARTIFACT_FILE" ]

  run cat "$ARTIFACT_FILE"
  [ "$status" -eq 0 ]
  assert_output_contains '"step": "stepA"'
  assert_output_contains '[REDACTED_EMAIL]'
  assert_output_not_contains 'test@example.com'
}

@test "the live captured_outputs value is never redacted, even when persistence redacts it" {
  init_run "pb-live-unredacted" "PB Live Unredacted" "stepA,stepB"

  JENGA_PLAYBOOK_RUNS_TEST_ROOT="$FIXTURE_ROOT" bash "$RPS" advance "$STATE_FILE" passed "email me at test@example.com" >/dev/null 2>&1

  run python3 -c "import json; print(json.load(open('$STATE_FILE'))['captured_outputs']['stepA'])"
  [ "$status" -eq 0 ]
  assert_output_contains 'test@example.com'
}
