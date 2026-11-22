#!/usr/bin/env bats
# bats file_tags=tier:fast
#
# E76_S01_T01: the per-task usage frontmatter fields (usage_*) are allow-listed for tasks in
# scripts/validate-board.sh (the USAGE_KEYS group), and a misspelled usage key is still rejected.
#
# This file tests only the validator, never scripts/task-usage.sh, so it is safe to ship.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATE="$REPO_ROOT/scripts/validate-board.sh"

setup() {
  FIXTURE_DIR="$BATS_TEST_TMPDIR/board"
  mkdir -p "$FIXTURE_DIR"
}

# Writes a minimal valid task fixture with the supplied extra frontmatter lines appended.
write_task() {
  local name="$1" extra="$2"
  cat > "$FIXTURE_DIR/$name" <<EOF2
---
id: E99_S01_T01
story_id: E99_S01
epic_id: E99
title: Usage fixture
status: Passed
date_created: 2026-10-25
assigned_to: developer
execution_scope: task
scope_rationale: "touches 1 file"
jenga_assigned: true
$extra
---

# Task: Usage fixture

## Description

Fixture.
EOF2
}

@test "accepts a task carrying all eight usage fields" {
  write_task "full.md" 'usage_input_tokens: 1043
usage_output_tokens: 6893
usage_cache_write_tokens: 91880
usage_cache_read_tokens: 2312044
usage_total_tokens: 2411860
usage_transcripts: 2
usage_measured_on: 2026-10-25
usage_possibly_incomplete: true'

  run bash "$VALIDATE" "$FIXTURE_DIR/full.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (task)"
}

@test "accepts a task with no usage fields (absence means not measured)" {
  write_task "none.md" ''

  run bash "$VALIDATE" "$FIXTURE_DIR/none.md"
  [ "$status" -eq 0 ]
}

@test "accepts a task carrying only the four token fields and the total" {
  write_task "partial.md" 'usage_input_tokens: 10
usage_output_tokens: 20
usage_cache_write_tokens: 30
usage_cache_read_tokens: 40
usage_total_tokens: 100'

  run bash "$VALIDATE" "$FIXTURE_DIR/partial.md"
  [ "$status" -eq 0 ]
}

@test "rejects a misspelled usage key" {
  write_task "typo.md" 'usage_tokens_in: 1043'

  run bash "$VALIDATE" "$FIXTURE_DIR/typo.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_tokens_in"
}

@test "rejects a usage key that is close to a real one" {
  write_task "typo2.md" 'usage_cache_reads_tokens: 5'

  run bash "$VALIDATE" "$FIXTURE_DIR/typo2.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_cache_reads_tokens"
}

@test "does not allow-list a cost or price usage field" {
  write_task "cost.md" 'usage_cost_usd: 1.25'

  run bash "$VALIDATE" "$FIXTURE_DIR/cost.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_cost_usd"
}

# E90_S01_T05: the cost-equivalent unit field on a task (a derived view, not a currency amount).

@test "accepts a task carrying usage_cost_units" {
  write_task "cu.md" 'usage_cost_units: 12345'

  run bash "$VALIDATE" "$FIXTURE_DIR/cu.md"
  [ "$status" -eq 0 ]
}

@test "accepts an explicit zero usage_cost_units (a measured zero)" {
  write_task "cu0.md" 'usage_cost_units: 0'

  run bash "$VALIDATE" "$FIXTURE_DIR/cu0.md"
  [ "$status" -eq 0 ]
}

@test "rejects a misspelled cost-unit key on a task" {
  write_task "cu-typo.md" 'usage_cost_unit: 5'
  run bash "$VALIDATE" "$FIXTURE_DIR/cu-typo.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_cost_unit"

  write_task "cu-typo2.md" 'usage_costunits: 5'
  run bash "$VALIDATE" "$FIXTURE_DIR/cu-typo2.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_costunits"
}

@test "rejects a negative usage_cost_units" {
  write_task "cu-neg.md" 'usage_cost_units: -3'

  run bash "$VALIDATE" "$FIXTURE_DIR/cu-neg.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_cost_units"
}

@test "rejects a non-numeric or decimal usage_cost_units" {
  write_task "cu-str.md" 'usage_cost_units: lots'
  run bash "$VALIDATE" "$FIXTURE_DIR/cu-str.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_cost_units"

  write_task "cu-dec.md" 'usage_cost_units: 12.5'
  run bash "$VALIDATE" "$FIXTURE_DIR/cu-dec.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_cost_units"
}

@test "rejects a story-only cost-unit key on a task" {
  write_task "cu-story.md" 'usage_tasks_cost_units: 5'

  run bash "$VALIDATE" "$FIXTURE_DIR/cu-story.md"
  [ "$status" -ne 0 ]
  assert_output_contains "usage_tasks_cost_units"
}
