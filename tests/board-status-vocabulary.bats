#!/usr/bin/env bats
#
# E42_S01 regression coverage: the status vocabulary a skill instructs agents to write
# to a board file must be one scripts/validate-board.sh accepts.
#
# Background: /jenga Phase 4 and /j-dooo step 1 used to say "mark the story/task as Running",
# a value absent from STATUS_VALUES, so a board snapshot taken mid-dispatch failed validation.
# These tests (1) pin the skill wording to the valid `In Progress` status, (2) simulate the
# status-marking step each skill prescribes against a throwaway copy of a real board file and
# run the validator on the result, and (3) compare the schema doc and validator vocabularies.
# Nothing here mutates real board files; all writes land in $BATS_TEST_TMPDIR.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATE="$REPO_ROOT/scripts/validate-board.sh"
JENGA_SKILL="$REPO_ROOT/skills/jenga/SKILL.md"
DOOO_SKILL="$REPO_ROOT/skills/j-dooo/SKILL.md"
SCHEMA="$REPO_ROOT/templates/SCRUM_BOARD_SCHEMA.md"

setup() {
  FIXTURE_DIR="$BATS_TEST_TMPDIR/board"
  mkdir -p "$FIXTURE_DIR"
  cat > "$FIXTURE_DIR/E98_S01_T01_fixture-task.md" <<'EOF'
---
id: E98_S01_T01
story_id: E98_S01
epic_id: E98
title: Fixture task
status: Pending
date_created: 2026-01-01
---

## Description

Fixture.
EOF
  cat > "$FIXTURE_DIR/E98_S01_fixture-story.md" <<'EOF'
---
id: E98_S01
epic_id: E98
title: Fixture story
status: Pending
date_created: 2026-01-01
tasks:
  - E98_S01_T01
---

## Description

Fixture.
EOF
}

# Mirrors the step both skills prescribe: update the `status:` field in the YAML front-matter.
mark_status() {
  local file="$1" value="$2"
  sed -i.bak "s/^status:.*/status: ${value}/" "$file"
  rm -f "$file.bak"
}

# Extracts the value the skill's marking instruction tells the agent to write.
jenga_marked_status() {
  grep -E '^4\. \*\*Mark ' "$JENGA_SKILL" | grep -o 'status: [A-Za-z ]*[A-Za-z]' | head -1 | sed 's/^status: //'
}
dooo_marked_status() {
  grep -E 'mark the story/task that was just started as' "$DOOO_SKILL" | grep -o '\*\*[A-Za-z ]*\*\*' | head -1 | tr -d '*'
}

@test "no skill, agent, or script instructs writing status: Running" {
  run grep -rnE 'status:[[:space:]]*[`"'"'"']?Running' "$REPO_ROOT/skills" "$REPO_ROOT/agents" "$REPO_ROOT/scripts"
  # Only the defensive comment in render-ranked-list.sh may match.
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  assert_output_contains "scripts/render-ranked-list.sh"
}

@test "jenga Phase 4 and j-dooo both prescribe the valid In Progress status" {
  [ "$(jenga_marked_status)" = "In Progress" ]
  [ "$(dooo_marked_status)" = "In Progress" ]
}

@test "simulated /jenga dispatch: marking a task and story In Progress passes validate-board.sh" {
  value="$(jenga_marked_status)"
  mark_status "$FIXTURE_DIR/E98_S01_T01_fixture-task.md" "$value"
  mark_status "$FIXTURE_DIR/E98_S01_fixture-story.md" "$value"
  run bash "$VALIDATE" "$FIXTURE_DIR"/*.md
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (task)"
  assert_output_contains "board frontmatter valid (story)"
}

@test "simulated /j-dooo dispatch: marking a task and story In Progress passes validate-board.sh" {
  value="$(dooo_marked_status)"
  mark_status "$FIXTURE_DIR/E98_S01_T01_fixture-task.md" "$value"
  mark_status "$FIXTURE_DIR/E98_S01_fixture-story.md" "$value"
  run bash "$VALIDATE" "$FIXTURE_DIR"/*.md
  [ "$status" -eq 0 ]
}

@test "validate-board.sh rejects the legacy Running status" {
  mark_status "$FIXTURE_DIR/E98_S01_T01_fixture-task.md" "Running"
  run bash "$VALIDATE" "$FIXTURE_DIR/E98_S01_T01_fixture-task.md"
  [ "$status" -ne 0 ]
  assert_output_contains "invalid status 'Running'"
}

@test "schema doc Status Values table and validate-board.sh STATUS_VALUES agree exactly" {
  doc="$(awk '/^## Status Values/{f=1;next} /^## /{f=0} f' "$SCHEMA" \
    | grep -E '^\| `' | sed -E 's/^\| `([^`]+)`.*/\1/' | sort)"
  script="$(awk '/^STATUS_VALUES = \{/{f=1;next} f&&/^\}/{f=0} f' "$VALIDATE" \
    | sed -E 's/^[[:space:]]*"([^"]+)",?[[:space:]]*$/\1/' | sort)"
  [ -n "$doc" ]
  [ -n "$script" ]
  [ "$(printf '%s\n' "$doc" | wc -l | tr -d ' ')" -eq 14 ]
  [ "$doc" = "$script" ]
}
