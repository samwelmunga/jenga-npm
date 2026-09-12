#!/usr/bin/env bats
#
# Test coverage for scripts/populate-knowledge-graph.js (E20_S09_T03), the mechanical
# board-to-graph populator built in E20_S09_T02 (merged to main at c11c187, plus a
# node-pruning fix at d8b7d82).
#
# Why this file exists
# ---------------------
# E20_S09's Definition of Done requires test coverage for the populator; this closes that gap.
# The populator reads `project/board/epics/*.md` and `project/board/stories/*.md` frontmatter
# (read-only) and writes/merges `board`-sourced nodes and edges into
# `project/knowledge-graph/graph.json`, per STUB_SCHEMA.md. It is invoked here exactly as its own
# CLI documents: `node scripts/populate-knowledge-graph.js --project-root <path> [--dry-run]` —
# the `--project-root` flag exists specifically so callers (including this suite) can point it at
# a throwaway fixture tree instead of this repository's real board/graph.
#
# Fixture-tree convention (following tests/load-playbooks-resolve-lookup.bats and
# tests/generate-j-alias.bats precedent): every case builds its OWN synthetic
# `$FIXTURE_ROOT/board/{epics,stories}` tree under $BATS_TEST_TMPDIR and drives the populator at
# it via `--project-root` — never against this repository's own project/board/ or
# project/knowledge-graph/graph.json.
#
# What is pinned here (mapped to the task's Acceptance Criteria)
# ----------------------------------------------------------------
#   1. Node generation for a fixture set of epics/stories, plus the guard that a Task board file is
#      never turned into a node (the story's AC: "Individual Tasks are never auto-populated as
#      nodes by this populator" — added by the tester at verification time to close a gap the
#      original suite left implicit rather than asserted).
#   2. Epic -> Story containment edges (derived from a story's own epic_id — and the documented
#      guard that a story whose epic_id does not resolve to a known epic produces no edge).
#   3. Cross-story/epic dependency edge detection via a story's depends_on frontmatter field,
#      including the documented guard that a depends_on target which isn't a known Epic/Story id
#      (e.g. a Task id) is skipped rather than fabricated.
#   4. Idempotency: running twice produces byte-identical graph.json output.
#   5. Empty/missing board directory handling: no crash, an empty/unchanged graph is written.
#   6. No file under project/board/ is ever touched by a populator run.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
POPULATOR="$REPO_ROOT/scripts/populate-knowledge-graph.js"

# Writes a minimal fixture Epic board file at $FIXTURE_ROOT/board/epics/<id>.md.
write_epic() {
  local id="$1" title="$2" purpose="$3"
  mkdir -p "$FIXTURE_ROOT/board/epics"
  cat > "$FIXTURE_ROOT/board/epics/${id}.md" <<EOF
---
id: $id
title: $title
status: Pending
date_created: 2026-01-01
date_started:
date_completed:
---

# Epic: $title

## Purpose
$purpose
EOF
}

# Writes a minimal fixture Task board file at $FIXTURE_ROOT/board/tasks/<id>.md — used only to
# assert the populator never turns Tasks into nodes (it doesn't even glob this directory), per the
# story's AC: "Individual Tasks are never auto-populated as nodes by this populator."
write_task() {
  local id="$1" story_id="$2" title="$3"
  mkdir -p "$FIXTURE_ROOT/board/tasks"
  cat > "$FIXTURE_ROOT/board/tasks/${id}.md" <<EOF
---
id: $id
story_id: $story_id
title: $title
status: Pending
date_created: 2026-01-01
---

# Task: $title

Fixture task body.
EOF
}

# Writes a minimal fixture Story board file at $FIXTURE_ROOT/board/stories/<id>.md.
# depends_on is written as a scalar frontmatter value (matching this repo's real board
# convention, e.g. the E20_S09_T03 task file's own `depends_on: E20_S09_T02`), defaulting to the
# literal "None" the populator's own parseDependsOn() treats as no dependency.
write_story() {
  local id="$1" epic_id="$2" title="$3" desc="$4" depends_on="${5:-None}"
  mkdir -p "$FIXTURE_ROOT/board/stories"
  cat > "$FIXTURE_ROOT/board/stories/${id}.md" <<EOF
---
id: $id
epic_id: $epic_id
title: $title
status: Pending
date_created: 2026-01-01
depends_on: $depends_on
---

# Story: $title

$desc
EOF
}

run_populator() {
  run node "$POPULATOR" --project-root "$FIXTURE_ROOT"
}

graph_json() {
  cat "$FIXTURE_ROOT/knowledge-graph/graph.json"
}

# node_field <id> <field> — extracts a field from the node with the given id, or "" if absent.
node_field() {
  local id="$1" field="$2"
  graph_json | python3 -c "
import json, sys
g = json.load(sys.stdin)
for n in g['nodes']:
    if n['id'] == '$id':
        print(n.get('$field', ''))
        break
"
}

# has_edge <id> — prints 'yes'/'no' for whether an edge with this id exists.
has_edge() {
  local id="$1"
  graph_json | python3 -c "
import json, sys
g = json.load(sys.stdin)
print('yes' if any(e['id'] == '$id' for e in g['edges']) else 'no')
"
}

# checksum_board_files <dir> — stable per-file checksum listing for drift detection.
checksum_board_files() {
  find "$FIXTURE_ROOT/board" -type f -exec cksum {} \; | sort
}

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE_ROOT/board/epics" "$FIXTURE_ROOT/board/stories"
}

# -----------------------------------------------------------------------------
# 1. Node generation
# -----------------------------------------------------------------------------

@test "generates board-sourced nodes for a fixture epic and story" {
  write_epic "E90" "Test Epic Alpha" "This epic exists purely to validate node generation."
  write_story "E90_S01" "E90" "Test Story One" "This story exists purely to validate node generation."

  run_populator
  [ "$status" -eq 0 ]

  [ "$(node_field E90 type)" = "epic" ]
  [ "$(node_field E90 label)" = "Test Epic Alpha" ]
  [ "$(node_field E90 source)" = "board" ]
  assert_contains "$(node_field E90 description)" "validate node generation"

  [ "$(node_field E90_S01 type)" = "story" ]
  [ "$(node_field E90_S01 label)" = "Test Story One" ]
  [ "$(node_field E90_S01 source)" = "board" ]
  assert_contains "$(node_field E90_S01 description)" "validate node generation"
}

@test "node generation covers a full multi-epic, multi-story fixture set" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
  write_epic "E91" "Test Epic Beta" "Beta purpose."
  write_story "E90_S01" "E90" "Alpha Story One" "Alpha story one body."
  write_story "E90_S02" "E90" "Alpha Story Two" "Alpha story two body."
  write_story "E91_S01" "E91" "Beta Story One" "Beta story one body."

  run_populator
  [ "$status" -eq 0 ]

  local count
  count="$(graph_json | python3 -c "import json,sys; print(len(json.load(sys.stdin)['nodes']))")"
  [ "$count" = "5" ]
}

@test "a Task board file is never turned into a node, even when present alongside epics/stories" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
  write_story "E90_S01" "E90" "Test Story One" "Story body."
  write_task "E90_S01_T01" "E90_S01" "Test Task One"

  run_populator
  [ "$status" -eq 0 ]

  [ "$(node_field E90_S01_T01 type)" = "" ]
  local count
  count="$(graph_json | python3 -c "import json,sys; print(len(json.load(sys.stdin)['nodes']))")"
  [ "$count" = "2" ]
}

# -----------------------------------------------------------------------------
# 2. Epic -> Story containment edges
# -----------------------------------------------------------------------------

@test "containment edge is written from a story's own epic_id" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
  write_story "E90_S01" "E90" "Test Story One" "Story body."

  run_populator
  [ "$status" -eq 0 ]

  [ "$(has_edge 'board:contains:E90:E90_S01')" = "yes" ]

  local from to type
  from="$(graph_json | python3 -c "import json,sys; g=json.load(sys.stdin); print(next(e['from'] for e in g['edges'] if e['id']=='board:contains:E90:E90_S01'))")"
  to="$(graph_json | python3 -c "import json,sys; g=json.load(sys.stdin); print(next(e['to'] for e in g['edges'] if e['id']=='board:contains:E90:E90_S01'))")"
  type="$(graph_json | python3 -c "import json,sys; g=json.load(sys.stdin); print(next(e['type'] for e in g['edges'] if e['id']=='board:contains:E90:E90_S01'))")"
  [ "$from" = "E90" ]
  [ "$to" = "E90_S01" ]
  [ "$type" = "contains" ]
}

@test "a story whose epic_id does not resolve to a known epic produces no containment edge" {
  # No E99 epic fixture is written — E90_S01's epic_id references a nonexistent epic.
  write_story "E90_S01" "E99" "Orphan Story" "Story body."

  run_populator
  [ "$status" -eq 0 ]

  [ "$(has_edge 'board:contains:E99:E90_S01')" = "no" ]
}

# -----------------------------------------------------------------------------
# 3. Cross-story/epic dependency edge detection
# -----------------------------------------------------------------------------

@test "dependency edge is written for a story depending on another known story" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
  write_story "E90_S01" "E90" "Story One" "Story one body."
  write_story "E90_S02" "E90" "Story Two" "Story two body." "E90_S01"

  run_populator
  [ "$status" -eq 0 ]

  [ "$(has_edge 'board:depends-on:E90_S02:E90_S01')" = "yes" ]
  local type
  type="$(graph_json | python3 -c "import json,sys; g=json.load(sys.stdin); print(next(e['type'] for e in g['edges'] if e['id']=='board:depends-on:E90_S02:E90_S01'))")"
  [ "$type" = "depends-on" ]
}

@test "dependency edge is written for a story depending on a known epic" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
  write_epic "E91" "Test Epic Beta" "Beta purpose."
  write_story "E91_S01" "E91" "Beta Story" "Beta story body." "E90"

  run_populator
  [ "$status" -eq 0 ]

  [ "$(has_edge 'board:depends-on:E91_S01:E90')" = "yes" ]
}

@test "a depends_on target that is not a known Epic or Story id is skipped, not fabricated" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
  # Depends on a Task id, which is never a graph node per this populator's own scope.
  write_story "E90_S01" "E90" "Story One" "Story body." "E90_S01_T01"

  run_populator
  [ "$status" -eq 0 ]

  local edge_count
  edge_count="$(graph_json | python3 -c "
import json, sys
g = json.load(sys.stdin)
print(sum(1 for e in g['edges'] if e['type'] == 'depends-on'))
")"
  [ "$edge_count" = "0" ]
}

# -----------------------------------------------------------------------------
# 4. Idempotency
# -----------------------------------------------------------------------------

@test "running the populator twice produces byte-identical graph.json" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
  write_story "E90_S01" "E90" "Story One" "Story body." "None"

  run_populator
  [ "$status" -eq 0 ]
  local first_run
  first_run="$(graph_json)"

  run_populator
  [ "$status" -eq 0 ]
  local second_run
  second_run="$(graph_json)"

  [ "$first_run" = "$second_run" ]
  assert_output_contains "already up to date"
}

@test "idempotency holds with no node/edge duplication across repeated runs" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
  write_epic "E91" "Test Epic Beta" "Beta purpose."
  write_story "E90_S01" "E90" "Story One" "Story body." "E91"

  run_populator
  [ "$status" -eq 0 ]
  run_populator
  [ "$status" -eq 0 ]
  run_populator
  [ "$status" -eq 0 ]

  local node_count edge_count
  node_count="$(graph_json | python3 -c "import json,sys; print(len(json.load(sys.stdin)['nodes']))")"
  edge_count="$(graph_json | python3 -c "import json,sys; print(len(json.load(sys.stdin)['edges']))")"
  [ "$node_count" = "3" ]
  [ "$edge_count" = "2" ]
}

# -----------------------------------------------------------------------------
# 5. Empty/missing board directory handling
# -----------------------------------------------------------------------------

@test "a project root with no board directory at all does not crash and writes an empty graph" {
  local empty_root="$BATS_TEST_TMPDIR/empty-root"
  mkdir -p "$empty_root"

  run node "$POPULATOR" --project-root "$empty_root"
  [ "$status" -eq 0 ]

  [ -f "$empty_root/knowledge-graph/graph.json" ]
  local node_count edge_count
  node_count="$(python3 -c "import json; print(len(json.load(open('$empty_root/knowledge-graph/graph.json'))['nodes']))")"
  edge_count="$(python3 -c "import json; print(len(json.load(open('$empty_root/knowledge-graph/graph.json'))['edges']))")"
  [ "$node_count" = "0" ]
  [ "$edge_count" = "0" ]
}

@test "a board directory with empty epics/stories subdirectories does not crash and writes an empty graph" {
  # setup() already created empty board/epics and board/stories subdirectories; write nothing to them.
  run_populator
  [ "$status" -eq 0 ]

  local node_count
  node_count="$(graph_json | python3 -c "import json,sys; print(len(json.load(sys.stdin)['nodes']))")"
  [ "$node_count" = "0" ]
}

@test "re-running against an empty board leaves a previously-written graph pruned back to empty, without crashing" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
  write_story "E90_S01" "E90" "Story One" "Story body."
  run_populator
  [ "$status" -eq 0 ]

  # Remove the board fixture entirely, then re-run against the now-empty board dir.
  rm -rf "$FIXTURE_ROOT/board/epics" "$FIXTURE_ROOT/board/stories"
  mkdir -p "$FIXTURE_ROOT/board/epics" "$FIXTURE_ROOT/board/stories"

  run_populator
  [ "$status" -eq 0 ]

  local node_count
  node_count="$(graph_json | python3 -c "import json,sys; print(len(json.load(sys.stdin)['nodes']))")"
  [ "$node_count" = "0" ]
}

# -----------------------------------------------------------------------------
# 6. No file under project/board/ is touched by a populator run
# -----------------------------------------------------------------------------

@test "no fixture board file is modified by a populator run" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
  write_epic "E91" "Test Epic Beta" "Beta purpose."
  write_story "E90_S01" "E90" "Story One" "Story body." "E91"
  write_story "E90_S02" "E90" "Story Two" "Story body two."

  local before after
  before="$(checksum_board_files)"

  run_populator
  [ "$status" -eq 0 ]

  after="$(checksum_board_files)"
  [ "$before" = "$after" ]
}

@test "no fixture board file is modified across a second run merging into an existing graph.json" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
  write_story "E90_S01" "E90" "Story One" "Story body."

  run_populator
  [ "$status" -eq 0 ]

  local before after
  before="$(checksum_board_files)"

  # Second run merges against the graph.json the first run already wrote.
  run_populator
  [ "$status" -eq 0 ]

  after="$(checksum_board_files)"
  [ "$before" = "$after" ]
}

@test "board file count and set are unchanged after a populator run (no board file created or deleted)" {
  write_epic "E90" "Test Epic Alpha" "Alpha purpose."
  write_story "E90_S01" "E90" "Story One" "Story body."

  local before_list after_list
  before_list="$(find "$FIXTURE_ROOT/board" -type f | sort)"

  run_populator
  [ "$status" -eq 0 ]

  after_list="$(find "$FIXTURE_ROOT/board" -type f | sort)"
  [ "$before_list" = "$after_list" ]
}
