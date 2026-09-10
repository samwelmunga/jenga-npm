#!/usr/bin/env bats
#
# Fixture-based coverage for render-playbook-confirmation.sh's nested/depth-label grouping
# display (E53_S05_T03) -- the optional 5th <json-origins> start-mode argument, its indentation +
# "(from playbook: <id>, depth N)" annotation, backward compatibility, and coexistence with the
# existing conditional marker (E53_S04_T04).

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RPC="$REPO_ROOT/skills/jenga/scripts/render-playbook-confirmation.sh"

# Captures the STATE_FILE path from stderr into $STATE_FILE, stdout into $START_OUTPUT.
start_run() {
  local playbook_id="$1" name="$2" steps="$3" conditionals="${4:-}" origins="${5:-}"
  local stdout_file="$BATS_TEST_TMPDIR/start_stdout_$$_$RANDOM"
  local stderr_file="$BATS_TEST_TMPDIR/start_stderr_$$_$RANDOM"
  if [ -n "$origins" ]; then
    bash "$RPC" "$playbook_id" "$name" "$steps" "$conditionals" "$origins" >"$stdout_file" 2>"$stderr_file"
  elif [ -n "$conditionals" ]; then
    bash "$RPC" "$playbook_id" "$name" "$steps" "$conditionals" >"$stdout_file" 2>"$stderr_file"
  else
    bash "$RPC" "$playbook_id" "$name" "$steps" >"$stdout_file" 2>"$stderr_file"
  fi
  STATE_FILE="$(grep 'STATE_FILE:' "$stderr_file" | sed 's/STATE_FILE: //')"
  START_OUTPUT="$(cat "$stdout_file")"
}

# -----------------------------------------------------------------------------
# Backward compatibility: no <json-origins> argument renders no indentation/annotation
# -----------------------------------------------------------------------------

@test "omitting <json-origins> renders identically to before this task" {
  start_run "pb" "PB" "stepA,stepB,stepC"
  assert_not_contains "$START_OUTPUT" "from playbook:"
  assert_contains "$START_OUTPUT" "  [x] 1. stepA"
  assert_contains "$START_OUTPUT" "  [x] 2. stepB"
}

@test "an empty origins object ({}) also renders with no indentation/annotation" {
  start_run "pb-empty" "PB Empty" "stepA,stepB" '{}' '{}'
  assert_not_contains "$START_OUTPUT" "from playbook:"
}

# -----------------------------------------------------------------------------
# Case: a depth>1 step is visibly indented and labeled
# -----------------------------------------------------------------------------

@test "a depth>1 step is indented and labeled with its originating playbook and depth" {
  start_run "outerchain" "Outer" "outer1,src,sink,outer2" '{}' \
    '{"src": {"playbook_id": "nested", "depth": 2}, "sink": {"playbook_id": "nested", "depth": 2}}'
  assert_contains "$START_OUTPUT" "    [x] 2. src (from playbook: nested, depth 2)"
  assert_contains "$START_OUTPUT" "    [x] 3. sink (from playbook: nested, depth 2)"
  # depth-1 steps (outer1, outer2) are untouched -- no extra indentation, no annotation.
  assert_contains "$START_OUTPUT" "  [x] 1. outer1"
  assert_contains "$START_OUTPUT" "  [x] 4. outer2"
  assert_not_contains "$START_OUTPUT" "1. outer1 (from playbook"
  assert_not_contains "$START_OUTPUT" "4. outer2 (from playbook"
}

@test "numbering stays flat 1..N across nesting -- no renumbering, still one list" {
  start_run "outerchain2" "Outer2" "outer1,src,sink,outer2" '{}' \
    '{"src": {"playbook_id": "nested", "depth": 2}, "sink": {"playbook_id": "nested", "depth": 2}}'
  assert_contains "$START_OUTPUT" "1. outer1"
  assert_contains "$START_OUTPUT" "2. src"
  assert_contains "$START_OUTPUT" "3. sink"
  assert_contains "$START_OUTPUT" "4. outer2"
  assert_contains "$START_OUTPUT" "Currently checked: 4 of 4 step(s)."
}

# -----------------------------------------------------------------------------
# Case: origin annotation coexists with the existing conditional marker on the same line
# -----------------------------------------------------------------------------

@test "origin annotation and the conditional marker coexist on the same line" {
  start_run "combo" "Combo" "stepA,stepB" '{"stepB": "stepA"}' \
    '{"stepB": {"playbook_id": "nested", "depth": 2}}'
  assert_contains "$START_OUTPUT" \
    "2. stepB (from playbook: nested, depth 2) (may be skipped depending on step 1's result)"
}

# -----------------------------------------------------------------------------
# Case: origin metadata persists across a continue-mode toggle re-render
# -----------------------------------------------------------------------------

@test "origin annotation persists across a continue-mode toggle re-render" {
  start_run "persist" "Persist" "stepA,stepB" '{}' \
    '{"stepB": {"playbook_id": "nested", "depth": 2}}'

  run bash "$RPC" "$STATE_FILE" "check 1"
  [ "$status" -eq 0 ]
  assert_output_contains "2. stepB (from playbook: nested, depth 2)"
}

# -----------------------------------------------------------------------------
# Validation: malformed origins metadata is rejected at start
# -----------------------------------------------------------------------------

@test "start mode rejects an origins entry with depth <= 1" {
  run bash "$RPC" "bad" "Bad" "stepA,stepB" '{}' '{"stepB": {"playbook_id": "x", "depth": 1}}'
  [ "$status" -eq 2 ]
  assert_output_contains "must be an object with a non-empty string 'playbook_id'"
}

@test "start mode rejects origins metadata for a step not in the step list" {
  run bash "$RPC" "bad2" "Bad2" "stepA,stepB" '{}' '{"nonexistent": {"playbook_id": "x", "depth": 2}}'
  [ "$status" -eq 2 ]
  assert_output_contains "which is not in the step list"
}
