#!/usr/bin/env bats
#
# E86_S02_T06: skills/j-check-in/scripts/collect-liveness.sh lists the In Progress board items, and so builds its F5/F6
# findings, in NUMERIC board-ID order.
#
# The collector shortlists the declared In Progress items with `grep -l ... project/board/<kind>/*.md`, so it saw them in
# the shell's glob order, which is filename text: E100 and E1001 before E11, and a story's T10 before T2. The shortlist
# is now re-sorted with board_id_sort from scripts/lib/board-ids.sh before the items are parsed. Every case builds its
# own fixture tree in BATS_TEST_TMPDIR and points JENGA_PROJECT_ROOT at it; the real project/ tree is never read.
#
# Fixture rule (board-ids.md, Decisions item 7): the script resolves scripts/lib from its own location with no fallback
# ordering, so the one case that runs a COPY of the script leaves scripts/lib out to prove the error.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
COLLECT_LIVENESS="$REPO_ROOT/skills/j-check-in/scripts/collect-liveness.sh"

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE_ROOT/project/queue" "$FIXTURE_ROOT/project/logs" "$FIXTURE_ROOT/project/board/tasks" \
    "$FIXTURE_ROOT/project/rapports/problems" "$FIXTURE_ROOT/.claude/worktrees"
  printf '{"event": "session_start", "agent": "developer", "session_id": "dev-session-123", "date": "2026-10-07T10:00:00Z"}\n' \
    > "$FIXTURE_ROOT/project/logs/events.json"
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"
}

# board_item <id>: a task declared In Progress at task scope (no worktree, so it yields an F6 finding)
board_item() {
  printf -- '---\nid: %s\nstatus: In Progress\nexecution_scope: task\n---\n' "$1" > "$FIXTURE_ROOT/project/board/tasks/$1_fixture.md"
}

f6_ids() {
  printf '%s' "$output" | jq -r '.findings[] | select(.code == "F6") | .subject.task_id'
}

@test "In Progress tasks at E2, E10, E100 and E1001 yield findings in numeric order" {
  local id
  for id in E1001_S01_T01 E100_S01_T01 E10_S01_T10 E10_S01_T2 E2_S01_T01 E10_S01_T01; do board_item "$id"; done
  run --separate-stderr bash "$COLLECT_LIVENESS" --no-agents
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' E2_S01_T01 E10_S01_T01 E10_S01_T2 E10_S01_T10 E100_S01_T01 E1001_S01_T01)"
  [ "$(f6_ids)" = "$expected" ]
}

@test "an all-two-digit board yields findings in the same order plain text sorting gave" {
  local id
  for id in E99_S01_T01 E10_S02_T01 E02_S01_T03 E02_S01_T01 E10_S01_T09; do board_item "$id"; done
  run --separate-stderr bash "$COLLECT_LIVENESS" --no-agents
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' E02_S01_T01 E02_S01_T03 E10_S01_T09 E10_S02_T01 E99_S01_T01)"
  [ "$(f6_ids)" = "$expected" ]
}

@test "a copy of the script without scripts/lib beside it fails loudly when a board exists" {
  local copy="$BATS_TEST_TMPDIR/copy"
  mkdir -p "$copy/skills/j-check-in/scripts"
  cp "$COLLECT_LIVENESS" "$copy/skills/j-check-in/scripts/collect-liveness.sh"
  board_item E10_S01_T01
  run --separate-stderr bash "$copy/skills/j-check-in/scripts/collect-liveness.sh" --no-agents
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"board-ids.sh not found"* ]]
}
