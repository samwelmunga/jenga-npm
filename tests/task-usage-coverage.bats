#!/usr/bin/env bats
# bats file_tags=tier:unit
#
# E90_S03_T01: scripts/task-usage-coverage.sh. The synthetic board is built per test by
# tests/fixtures/task-usage-coverage/make-fixture.sh into $BATS_TEST_TMPDIR; the real board is never read.
#
# Fixture (8 files): T01 measured with cost units, T02 explicit zero, T03 possibly incomplete, T04 stale measured
# (no usage_cost_units), E99_S01_T05 and E100_S01_T01 unmeasured, T06 unparseable (no frontmatter),
# T07 partial (usage_input_tokens only, no total) which is unreadable rather than guessed.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/task-usage-coverage.sh"
FIXTURE="$BATS_TEST_DIRNAME/fixtures/task-usage-coverage/make-fixture.sh"

setup() {
  BOARD="$BATS_TEST_TMPDIR/tasks"
  bash "$FIXTURE" "$BOARD"
}

@test "script is syntactically valid" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "counts: measured, unmeasured, unreadable, possibly incomplete, without cost units" {
  run --separate-stderr bash "$SCRIPT" --board-tasks-dir "$BOARD"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq .total)" = 8 ]
  [ "$(echo "$output" | jq .measured)" = 4 ]
  [ "$(echo "$output" | jq .unmeasured)" = 2 ]
  [ "$(echo "$output" | jq .unreadable)" = 2 ]
  [ "$(echo "$output" | jq .possibly_incomplete)" = 1 ]
  [ "$(echo "$output" | jq .without_cost_units)" = 1 ]
}

@test "measured + unmeasured + unreadable = total" {
  run --separate-stderr bash "$SCRIPT" --board-tasks-dir "$BOARD"
  [ "$(echo "$output" | jq '.measured + .unmeasured + .unreadable == .total')" = true ]
}

@test "an explicit usage_total_tokens: 0 is measured, a task with no fields is unmeasured" {
  run --separate-stderr bash "$SCRIPT" --list --board-tasks-dir "$BOARD"
  [ "$(echo "$output" | jq '.unmeasured_ids | index("E99_S01_T02")')" = null ]
  [ "$(echo "$output" | jq '.unmeasured_ids | index("E99_S01_T05") != null')" = true ]
}

@test "a usage_total_tokens line in the body is ignored" {
  run --separate-stderr bash "$SCRIPT" --list --board-tasks-dir "$BOARD"
  [ "$(echo "$output" | jq '.unmeasured_ids | index("E100_S01_T01") != null')" = true ]
}

@test "--list sorts the unmeasured ids numerically (E99 before E100)" {
  run --separate-stderr bash "$SCRIPT" --list --board-tasks-dir "$BOARD"
  [ "$(echo "$output" | jq -c .unmeasured_ids)" = '["E99_S01_T05","E100_S01_T01"]' ]
}

@test "without --list there is no id list" {
  run --separate-stderr bash "$SCRIPT" --board-tasks-dir "$BOARD"
  [ "$(echo "$output" | jq 'has("unmeasured_ids")')" = false ]
}

@test "a file with no frontmatter and a partial-field file are unreadable, not guessed" {
  run --separate-stderr bash "$SCRIPT" --list --board-tasks-dir "$BOARD"
  [ "$(echo "$output" | jq '.unmeasured_ids | index("E99_S01_T06") // index("E99_S01_T07")')" = null ]
  [ "$(echo "$output" | jq .unreadable)" = 2 ]
}

@test "--out writes the JSON to the file and the board is not touched" {
  before="$(find "$BOARD" -type f | sort | xargs shasum | shasum)"
  run --separate-stderr bash "$SCRIPT" --list --out "$BATS_TEST_TMPDIR/out/report.json" --board-tasks-dir "$BOARD"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/out/report.json" ]
  [ "$(jq .total "$BATS_TEST_TMPDIR/out/report.json")" = 8 ]
  after="$(find "$BOARD" -type f | sort | xargs shasum | shasum)"
  [ "$before" = "$after" ]
}

@test "stderr carries a short human summary" {
  run --separate-stderr bash "$SCRIPT" --board-tasks-dir "$BOARD"
  [[ "$stderr" == *"8 tasks = 4 measured + 2 unmeasured + 2 unreadable"* ]]
}

@test "resolves the board through resolve-root.sh from a project root" {
  root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root/project/configs" "$root/project/board/tasks"
  cp "$BATS_TEST_DIRNAME/../project/configs/workflow.json" "$root/project/configs/workflow.json"
  cp "$BOARD"/E99_S01_T01_x.md "$root/project/board/tasks/"
  cd "$root"
  run --separate-stderr env JENGA_PROJECT_ROOT="$root" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq .total)" = 1 ]
  [ "$(echo "$output" | jq .measured)" = 1 ]
}

@test "a missing tasks directory exits 3 and an unknown option exits 2" {
  run bash "$SCRIPT" --board-tasks-dir "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}
