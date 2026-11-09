#!/usr/bin/env bats
#
# E86_S01_T02: scripts/validate-board.sh takes its ID shapes from scripts/lib/board_ids.py, so board IDs of any
# digit width validate, malformed IDs are still rejected, and the lookup works in the consumer layout.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATE="$REPO_ROOT/scripts/validate-board.sh"

setup() {
  FIXTURE_DIR="$BATS_TEST_TMPDIR/board"
  mkdir -p "$FIXTURE_DIR"
}

# write_epic <file> <id>
write_epic() {
  cat > "$FIXTURE_DIR/$1" <<EOF2
---
id: $2
title: Wide id epic
status: Pending
date_created: 2026-10-25
stories: []
docs: []
---

# Epic: Wide id epic
EOF2
}

# write_story <file> <id> <epic_id>
write_story() {
  cat > "$FIXTURE_DIR/$1" <<EOF2
---
id: $2
epic_id: $3
title: Wide id story
status: Pending
date_created: 2026-10-25
tasks: []
docs: []
---

# Story: Wide id story
EOF2
}

# write_task <file> <id> <story_id> <epic_id>
write_task() {
  cat > "$FIXTURE_DIR/$1" <<EOF2
---
id: $2
story_id: $3
epic_id: $4
title: Wide id task
status: Pending
date_created: 2026-10-25
assigned_to: developer
docs: []
execution_scope: task
scope_rationale: "touches 1 file"
jenga_assigned: true
---

# Task: Wide id task
EOF2
}

@test "validate-board.sh has no two-digit board-ID regex" {
  run grep -nE 'E\\d\{2\}|_S\\d\{2\}|_T\\d\{2\}' "$VALIDATE"
  [ "$status" -ne 0 ]
}

@test "accepts epics of three and four digits" {
  write_epic "E100_x.md" "E100"
  write_epic "E1001_x.md" "E1001"
  run "$VALIDATE" "$FIXTURE_DIR/E100_x.md"
  [ "$status" -eq 0 ]
  run "$VALIDATE" "$FIXTURE_DIR/E1001_x.md"
  [ "$status" -eq 0 ]
}

@test "accepts a story with a wide epic and story number" {
  write_story "E1001_S100_x.md" "E1001_S100" "E1001"
  run "$VALIDATE" "$FIXTURE_DIR/E1001_S100_x.md"
  [ "$status" -eq 0 ]
}

@test "accepts a task with wide epic, story and task numbers" {
  write_task "E1001_S100_T100_x.md" "E1001_S100_T100" "E1001_S100" "E1001"
  run "$VALIDATE" "$FIXTURE_DIR/E1001_S100_T100_x.md"
  [ "$status" -eq 0 ]
}

@test "still accepts the existing two-digit shapes" {
  write_epic "E01_x.md" "E01"
  write_story "E01_S01_x.md" "E01_S01" "E01"
  write_task "E01_S01_T01_x.md" "E01_S01_T01" "E01_S01" "E01"
  run "$VALIDATE" "$FIXTURE_DIR/E01_x.md" "$FIXTURE_DIR/E01_S01_x.md" "$FIXTURE_DIR/E01_S01_T01_x.md"
  [ "$status" -eq 0 ]
}

@test "rejects malformed ids with the unrecognised-format message" {
  local bad name
  for bad in 'E' 'E1_' 'E01_T01' 'e01' 'E01_S01_T01_x' 'E01 x'; do
    name="bad.md"
    write_epic "$name" "\"$bad\""
    run "$VALIDATE" "$FIXTURE_DIR/$name"
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    [[ "$output" == *"unrecognised board item id format"* ]] || { echo "wrong message for '$bad': $output"; return 1; }
  done
}

@test "works in the consumer layout (node_modules/@jenga-ai/agent/scripts)" {
  local pkg="$BATS_TEST_TMPDIR/proj/node_modules/@jenga-ai/agent/scripts"
  mkdir -p "$pkg"
  cp "$VALIDATE" "$pkg/validate-board.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$pkg/lib"
  write_task "E1001_S100_T100_x.md" "E1001_S100_T100" "E1001_S100" "E1001"
  run bash "$pkg/validate-board.sh" "$FIXTURE_DIR/E1001_S100_T100_x.md"
  [ "$status" -eq 0 ]
  write_epic "bad.md" '"E1_"'
  run bash "$pkg/validate-board.sh" "$FIXTURE_DIR/bad.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognised board item id format"* ]]
}

@test "fails clearly, not with a traceback, when the lib is missing" {
  local dir="$BATS_TEST_TMPDIR/nolib"
  mkdir -p "$dir"
  cp "$VALIDATE" "$dir/validate-board.sh"
  write_epic "E100_x.md" "E100"
  run bash "$dir/validate-board.sh" "$FIXTURE_DIR/E100_x.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot import board_ids"* ]]
  [[ "$output" != *Traceback* ]]
}
