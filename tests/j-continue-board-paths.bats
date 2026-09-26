#!/usr/bin/env bats
#
# Regression coverage for E42_S09_T01: skills/j-continue/SKILL.md's stale
# project/epics//project/stories/ path references.
#
# Why this file exists
# ---------------------
# templates/SCRUM_BOARD_SCHEMA.md documents project/epics/ and project/stories/
# as deprecated legacy paths -- the current locations are project/board/epics/
# and project/board/stories/. skills/j-status/SKILL.md was already migrated to
# the correct paths; skills/j-continue/SKILL.md was not, so /continue silently
# checked empty legacy directories instead of live board state.
#
# This is a pure prose/documentation fix -- SKILL.md is instructions consumed
# by an LLM at conversation time, never executed, so there is no executable
# code path to unit-test. Instead this pins the two literal facts the story's
# Acceptance Criteria describe: the stale bare paths are gone, and the
# corrected project/board/... paths are present. Same spirit as other
# doc-correctness assertions in this suite (e.g. check-public-playbook-steps.bats
# grepping SKILL.md content directly).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL_FILE="$REPO_ROOT/skills/j-continue/SKILL.md"

@test "j-continue SKILL.md no longer references the stale bare project/epics/ path" {
  run grep -n "project/epics/" "$SKILL_FILE"
  [ "$status" -ne 0 ]
}

@test "j-continue SKILL.md no longer references the stale bare project/stories/ path" {
  run grep -n "project/stories/" "$SKILL_FILE"
  [ "$status" -ne 0 ]
}

@test "j-continue SKILL.md checks the current project/board/epics/ path" {
  run grep -c "project/board/epics/" "$SKILL_FILE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "j-continue SKILL.md checks the current project/board/stories/ path" {
  run grep -c "project/board/stories/" "$SKILL_FILE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
