#!/usr/bin/env bats
#
# E76_S03_T04: the per-story usage frontmatter fields (usage_tasks_*, usage_overhead_*, and the
# story-level usage_total_tokens / usage_measured_on / usage_possibly_incomplete) are allow-listed
# for stories in scripts/validate-board.sh (the STORY_USAGE_KEYS group). A misspelled usage key is
# still rejected, and epics do not carry these fields.
#
# This file tests only the validator, never scripts/task-usage.sh, so it is safe to ship.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATE="$REPO_ROOT/scripts/validate-board.sh"

setup() {
  FIXTURE_DIR="$BATS_TEST_TMPDIR/board"
  mkdir -p "$FIXTURE_DIR"
}

# Writes a minimal valid story fixture with the supplied extra frontmatter lines appended.
write_story() {
  local name="$1" extra="$2"
  cat > "$FIXTURE_DIR/$name" <<EOF2
---
id: E99_S01
epic_id: E99
title: Story usage fixture
status: Passed
date_created: 2026-10-25
$extra
---

# Story: Story usage fixture

## Description

Fixture.
EOF2
}

# Writes a minimal valid epic fixture with the supplied extra frontmatter lines appended.
write_epic() {
  local name="$1" extra="$2"
  cat > "$FIXTURE_DIR/$name" <<EOF2
---
id: E99
title: Epic usage fixture
status: Passed
date_created: 2026-10-25
$extra
---

# Epic: Epic usage fixture

## Description

Fixture.
EOF2
}

@test "accepts a story carrying all the story usage fields" {
  write_story "full.md" 'usage_tasks_input_tokens: 1000
usage_tasks_output_tokens: 2000
usage_tasks_cache_write_tokens: 3000
usage_tasks_cache_read_tokens: 4000
usage_tasks_total_tokens: 10000
usage_overhead_input_tokens: 10
usage_overhead_output_tokens: 20
usage_overhead_cache_write_tokens: 30
usage_overhead_cache_read_tokens: 40
usage_overhead_total_tokens: 100
usage_total_tokens: 10100
usage_measured_on: 2026-10-25
usage_possibly_incomplete: true'

  run bash "$VALIDATE" "$FIXTURE_DIR/full.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (story)"
}

@test "accepts a story with no usage fields (absence means not measured)" {
  write_story "none.md" ''

  run bash "$VALIDATE" "$FIXTURE_DIR/none.md"
  [ "$status" -eq 0 ]
}

@test "accepts a story carrying only the task part and the total" {
  write_story "tasks-only.md" 'usage_tasks_total_tokens: 500
usage_total_tokens: 500'

  run bash "$VALIDATE" "$FIXTURE_DIR/tasks-only.md"
  [ "$status" -eq 0 ]
}

@test "rejects a misspelled story usage key" {
  write_story "typo.md" 'usage_task_input_tokens: 1000'

  run bash "$VALIDATE" "$FIXTURE_DIR/typo.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_task_input_tokens"
}

@test "rejects a story usage key that is close to a real one" {
  write_story "typo2.md" 'usage_overhead_cache_reads_tokens: 5'

  run bash "$VALIDATE" "$FIXTURE_DIR/typo2.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_overhead_cache_reads_tokens"
}

@test "rejects a task-only usage key on a story" {
  write_story "task-key.md" 'usage_transcripts: 2'

  run bash "$VALIDATE" "$FIXTURE_DIR/task-key.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_transcripts"
}

@test "does not allow-list a cost or price usage field on a story" {
  write_story "cost.md" 'usage_cost_usd: 1.25'

  run bash "$VALIDATE" "$FIXTURE_DIR/cost.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_cost_usd"
}

@test "rejects an epic carrying a story usage field" {
  write_epic "epic-usage.md" 'usage_tasks_total_tokens: 500'

  run bash "$VALIDATE" "$FIXTURE_DIR/epic-usage.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_tasks_total_tokens"
}

@test "rejects an epic carrying the story-level usage total" {
  write_epic "epic-total.md" 'usage_total_tokens: 500'

  run bash "$VALIDATE" "$FIXTURE_DIR/epic-total.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_total_tokens"
}

@test "accepts an epic with no usage fields" {
  write_epic "epic-none.md" ''

  run bash "$VALIDATE" "$FIXTURE_DIR/epic-none.md"
  [ "$status" -eq 0 ]
}
