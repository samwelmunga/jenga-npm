#!/usr/bin/env bats
#
# E85_S01_T05: agents/tester.md wires scripts/audit-deps.sh in as the opt-in vulnerability executor.
# Reads files relative to the checkout this test runs in; nothing is written.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TESTER="$REPO_ROOT/agents/tester.md"
CONFIG="$REPO_ROOT/project/configs/test-config.json"

@test "tester.md names audit-deps.sh as the vulnerability executor" {
  grep -q 'The `vulnerability` executor for npm projects is `scripts/audit-deps.sh`' "$TESTER"
}

@test "tester.md requires the tool_approval event and audit-record.sh consent before the first run" {
  grep -q 'Before the first run' "$TESTER"
  grep -q 'log the `tool_approval` event' "$TESTER"
  grep -q 'audit-record.sh' "$TESTER"
  grep -Eq 'consent --dir <dir>' "$TESTER"
}

@test "tester.md says the manifest-change trigger only offers the audit" {
  grep -q 'package-lock.json' "$TESTER"
  grep -q 'manifest-change trigger only offers' "$TESTER"
  grep -q 'never starts an audit unprompted' "$TESTER"
}

@test "tester.md says the audit never runs unprompted unless mode: on and every result is recorded" {
  grep -q 'never runs unprompted unless `audit-config.json` has `mode: on`' "$TESTER"
  grep -q "Every run's result is recorded" "$TESTER"
}

@test "tester.md frames a findings result as a recommendation, not an automatic status write" {
  grep -q 'Passed with remarks' "$TESTER"
  grep -q 'not an automatic status write' "$TESTER"
}

@test "test-config.json is valid JSON and has all seven tool types" {
  run jq -e '[.tools[].type] as $t | ["unit","integration","e2e","sast","vulnerability","performance","coverage"] | all(. as $w | $t | index($w) != null)' "$CONFIG"
  [ "$status" -eq 0 ]
}

@test "the existing SAST/performance opt-in wording is unchanged" {
  grep -qF 'These tool types are opt-in. They must not run automatically unless the user has explicitly requested and approved their inclusion in the workflow.' "$TESTER"
}
