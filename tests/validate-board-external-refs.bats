#!/usr/bin/env bats
#
# Coverage for validate-board.sh's external_refs support (E71_S03_T02).
#
# The contract lives in templates/SCRUM_BOARD_SCHEMA.md ("External Refs Fields" and "Declined
# External Refs Fields"). Three things are pinned here:
#   1. a valid block list of mappings is accepted on epics, stories AND tasks, and is not misread
#      as unknown top-level keys by the hand-rolled parse_frontmatter();
#   2. every malformed shape the schema names is rejected with a message naming the file and the
#      problem; absence of the fields is always valid;
#   3. the strict-YAML gate (duplicate keys, invalid YAML) still applies to a file carrying
#      external_refs, so the new parser branch did not open a way around it.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATE="$REPO_ROOT/scripts/validate-board.sh"

setup() {
  FIXTURE_DIR="$BATS_TEST_TMPDIR/board"
  mkdir -p "$FIXTURE_DIR"
}

# write_item <file> <frontmatter body>: the body is written verbatim between the delimiters.
write_item() {
  cat > "$FIXTURE_DIR/$1" <<EOF
---
$2
---

## Description

Fixture.
EOF
}

EPIC_BASE='id: E99
title: Fixture epic
status: Pending
date_created: 2026-01-01'

STORY_BASE='id: E99_S01
epic_id: E99
title: Fixture story
status: Pending
date_created: 2026-01-01'

TASK_BASE='id: E99_S01_T01
story_id: E99_S01
epic_id: E99
title: Fixture task
status: Pending
date_created: 2026-01-01'

JIRA_ENTRY='  - system: jira
    kind: issue
    key: PROJ-123
    linked_on: 2026-10-06'

# --- present: accepted on all three item types ------------------------------------------------

@test "accepts a valid external_refs list on an epic" {
  write_item "E99_epic.md" "$EPIC_BASE
external_refs:
$JIRA_ENTRY"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_epic.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (epic)"
}

@test "accepts a valid external_refs list on a story" {
  write_item "E99_S01_story.md" "$STORY_BASE
external_refs:
$JIRA_ENTRY"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_story.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (story)"
}

@test "accepts a valid external_refs list on a task" {
  write_item "E99_S01_T01_task.md" "$TASK_BASE
external_refs:
$JIRA_ENTRY"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_T01_task.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (task)"
}

@test "accepts multiple entries across all documented systems and kinds" {
  write_item "E99_S01_multi.md" "$STORY_BASE
external_refs:
  - system: jira
    kind: issue
    key: PROJ-123
    linked_on: 2026-10-06
  - system: confluence
    kind: page
    url: https://example.atlassian.net/wiki/spaces/PROJ/pages/123456
    linked_on: 2026-10-06
  - system: bitbucket
    kind: repo
    url: https://bitbucket.org/acme/widgets
    linked_on: 2026-10-07
  - system: bitbucket
    kind: pull-request
    url: https://bitbucket.org/acme/widgets/pull-requests/7
    linked_on: 2026-10-08
tasks:
  - E99_S01_T01"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_multi.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (story)"
}

@test "keys after an external_refs block still parse and are still checked" {
  # The block ends at the next top-level key; that key must neither be swallowed nor skipped.
  write_item "E99_S01_after.md" "$STORY_BASE
external_refs:
$JIRA_ENTRY
bogus_key: nope"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_after.md"
  [ "$status" -ne 0 ]
  assert_output_contains "unknown frontmatter field(s) for story: bogus_key"
}

@test "keeps a URL fragment and an inline comment apart" {
  write_item "E99_S01_frag.md" "$STORY_BASE
external_refs:
  - system: confluence
    kind: page
    url: https://example.atlassian.net/wiki/pages/1#section
    linked_on: 2026-10-06   # recorded by scrum-master"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_frag.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (story)"
}

# --- absent: requires nothing -----------------------------------------------------------------

@test "accepts items that omit every external_refs field" {
  write_item "E99_epic_none.md" "$EPIC_BASE"
  write_item "E99_S01_none.md" "$STORY_BASE"
  write_item "E99_S01_T01_none.md" "$TASK_BASE"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_epic_none.md" "$FIXTURE_DIR/E99_S01_none.md" \
    "$FIXTURE_DIR/E99_S01_T01_none.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (task)"
}

@test "accepts an explicitly empty external_refs list" {
  write_item "E99_S01_empty.md" "$STORY_BASE
external_refs: []"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_empty.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (story)"
}

# --- malformed: rejected with a message naming the file and the problem -----------------------

@test "rejects an entry with no system" {
  write_item "E99_S01_nosys.md" "$STORY_BASE
external_refs:
  - kind: issue
    key: PROJ-123
    linked_on: 2026-10-06"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_nosys.md"
  [ "$status" -ne 0 ]
  assert_output_contains "E99_S01_nosys.md"
  assert_output_contains "external_refs entry 1 is missing required 'system'"
}

@test "rejects an unknown system" {
  write_item "E99_S01_badsys.md" "$STORY_BASE
external_refs:
  - system: github
    kind: issue
    key: PROJ-123
    linked_on: 2026-10-06"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_badsys.md"
  [ "$status" -ne 0 ]
  assert_output_contains "unknown system 'github'"
}

@test "rejects a kind that is not valid for the system" {
  write_item "E99_S01_badkind.md" "$STORY_BASE
external_refs:
  - system: jira
    kind: page
    key: PROJ-123
    linked_on: 2026-10-06"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_badkind.md"
  [ "$status" -ne 0 ]
  assert_output_contains "invalid kind 'page' for system 'jira'"
}

@test "rejects an entry with both key and url" {
  write_item "E99_S01_both.md" "$STORY_BASE
external_refs:
  - system: jira
    kind: issue
    key: PROJ-123
    url: https://example.atlassian.net/browse/PROJ-123
    linked_on: 2026-10-06"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_both.md"
  [ "$status" -ne 0 ]
  assert_output_contains "has both 'key' and 'url'"
}

@test "rejects an entry with neither key nor url" {
  write_item "E99_S01_neither.md" "$STORY_BASE
external_refs:
  - system: jira
    kind: issue
    linked_on: 2026-10-06"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_neither.md"
  [ "$status" -ne 0 ]
  assert_output_contains "has neither 'key' nor 'url'"
}

@test "rejects a linked_on that is not a date" {
  write_item "E99_S01_baddate.md" "$STORY_BASE
external_refs:
  - system: jira
    kind: issue
    key: PROJ-123
    linked_on: yesterday"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_baddate.md"
  [ "$status" -ne 0 ]
  assert_output_contains "linked_on 'yesterday' which is not a real YYYY-MM-DD date"
}

@test "rejects a well-shaped but impossible linked_on date" {
  write_item "E99_S01_feb30.md" "$STORY_BASE
external_refs:
  - system: jira
    kind: issue
    key: PROJ-123
    linked_on: 2026-02-30"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_feb30.md"
  [ "$status" -ne 0 ]
  # Caught by the YAML gate (PyYAML cannot load the date) or by the entry check when PyYAML is
  # absent; either way the failure must name the file and the YYYY-MM-DD requirement.
  assert_output_contains "E99_S01_feb30.md"
  assert_output_contains "YYYY-MM-DD"
}

@test "rejects a missing linked_on" {
  write_item "E99_S01_nodate.md" "$STORY_BASE
external_refs:
  - system: jira
    kind: issue
    key: PROJ-123"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_nodate.md"
  [ "$status" -ne 0 ]
  assert_output_contains "missing required 'linked_on'"
}

@test "names the failing entry by index when a later entry is the bad one" {
  write_item "E99_S01_second.md" "$STORY_BASE
external_refs:
$JIRA_ENTRY
  - system: confluence
    kind: issue
    url: https://example.atlassian.net/wiki/pages/1
    linked_on: 2026-10-06"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_second.md"
  [ "$status" -ne 0 ]
  assert_output_contains "external_refs entry 2 has invalid kind 'issue' for system 'confluence'"
}

@test "rejects an unknown key inside an entry" {
  write_item "E99_S01_extra.md" "$STORY_BASE
external_refs:
  - system: jira
    kind: issue
    key: PROJ-123
    linked_on: 2026-10-06
    priority: high"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_extra.md"
  [ "$status" -ne 0 ]
  assert_output_contains "unknown key(s): priority"
}

@test "rejects a non-mapping list entry" {
  write_item "E99_S01_scalar.md" "$STORY_BASE
external_refs:
  - PROJ-123"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_scalar.md"
  [ "$status" -ne 0 ]
  assert_output_contains "entries must be mappings"
}

@test "rejects external_refs written as a scalar" {
  write_item "E99_S01_scalarval.md" "$STORY_BASE
external_refs: PROJ-123"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_scalarval.md"
  [ "$status" -ne 0 ]
  assert_output_contains "external_refs must be a YAML list of mappings"
}

# --- skip marker ------------------------------------------------------------------------------

@test "accepts the skip marker with a note on an epic, a story and a task" {
  write_item "E99_skip.md" "$EPIC_BASE
external_refs_declined: true
external_refs_declined_note: \"Skipped 2026-10-06: user chose not to link this item.\""
  write_item "E99_S01_skip.md" "$STORY_BASE
external_refs_declined: true
external_refs_declined_note: \"Skipped 2026-10-06: user chose not to link this item.\""
  write_item "E99_S01_T01_skip.md" "$TASK_BASE
external_refs_declined: true
external_refs_declined_note: \"Skipped 2026-10-06: user chose not to link this item.\""

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_skip.md" "$FIXTURE_DIR/E99_S01_skip.md" \
    "$FIXTURE_DIR/E99_S01_T01_skip.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (task)"
}

@test "rejects external_refs_declined with any value other than true" {
  write_item "E99_S01_false.md" "$STORY_BASE
external_refs_declined: false
external_refs_declined_note: \"Skipped 2026-10-06\""

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_false.md"
  [ "$status" -ne 0 ]
  assert_output_contains "external_refs_declined must be 'true' when present"
}

@test "rejects external_refs_declined: true without a note" {
  write_item "E99_S01_nonote.md" "$STORY_BASE
external_refs_declined: true"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_nonote.md"
  [ "$status" -ne 0 ]
  assert_output_contains "requires a non-empty external_refs_declined_note"
}

@test "rejects external_refs_declined: true with a blank note" {
  write_item "E99_S01_blank.md" "$STORY_BASE
external_refs_declined: true
external_refs_declined_note: \"\""

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_blank.md"
  [ "$status" -ne 0 ]
  assert_output_contains "requires a non-empty external_refs_declined_note"
}

@test "allows a recorded skip and later links to coexist" {
  write_item "E99_S01_both_paths.md" "$STORY_BASE
external_refs_declined: true
external_refs_declined_note: \"Skipped 2026-10-06\"
external_refs:
$JIRA_ENTRY"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_both_paths.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (story)"
}

# --- the strict-YAML gate still applies -------------------------------------------------------

@test "still rejects a duplicated key in a file that has external_refs" {
  write_item "E99_S01_dup.md" "$STORY_BASE
external_refs:
$JIRA_ENTRY
title: A second title"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_dup.md"
  [ "$status" -ne 0 ]
  assert_output_contains "duplicated frontmatter key 'title'"
}

@test "still rejects a duplicated external_refs key" {
  write_item "E99_S01_dupref.md" "$STORY_BASE
external_refs:
$JIRA_ENTRY
external_refs: []"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_dupref.md"
  [ "$status" -ne 0 ]
  assert_output_contains "duplicated frontmatter key 'external_refs'"
}

@test "still rejects invalid YAML in a file that has external_refs" {
  write_item "E99_S01_badyaml.md" "$STORY_BASE
external_refs:
$JIRA_ENTRY
reopened_reason: \"Scope expanded\", \"Bug found post-release\""

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_badyaml.md"
  [ "$status" -ne 0 ]
  assert_output_contains "not valid YAML"
}
