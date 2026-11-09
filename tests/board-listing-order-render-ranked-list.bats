#!/usr/bin/env bats
#
# E86_S02_T06: scripts/render-ranked-list.sh lists board files in NUMERIC board-ID order, not filename text order.
#
# The script finds eligible stories and tasks by listing the board directories. It used `find ... | sort`, which is text
# order, so on a board holding E10, E100 and E1001 the ranked list came out E100, E1001, E10 (text order puts "E100_"
# before "E10_" and "E1001_" before "E2_"). It now sorts the bare file names with board_id_sort from
# scripts/lib/board-ids.sh. Every case builds its own board in BATS_TEST_TMPDIR through the script's documented
# JENGA_* path overrides; the real board is never read.
#
# Fixture rule (board-ids.md, Decisions item 7): the script resolves scripts/lib from its own location with no fallback
# ordering, so the one case that runs a COPY of the script copies scripts/lib next to it.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/render-ranked-list.sh"

setup() {
  BOARD="$BATS_TEST_TMPDIR/board"
  mkdir -p "$BOARD/epics" "$BOARD/stories" "$BOARD/tasks"
  export JENGA_BOARD_EPICS_DIR="$BOARD/epics"
  export JENGA_BOARD_STORIES_DIR="$BOARD/stories"
  export JENGA_BOARD_TASKS_DIR="$BOARD/tasks"
  export JENGA_TODO_FILE="$BATS_TEST_TMPDIR/todo.md"
  : > "$JENGA_TODO_FILE"
}

# story <id> <title>: a Pending story file named <id>_x.md, listed in todo.md
story() {
  printf -- '---\nid: %s\ntitle: %s\nstatus: Pending\n---\n' "$1" "$2" > "$BOARD/stories/$1_x.md"
  printf -- '- %s\n' "$1" >> "$JENGA_TODO_FILE"
}

# task <id> <story id> <title>: a Pending task file named <id>_x.md, listed in todo.md
task() {
  printf -- '---\nid: %s\nstory_id: %s\ntitle: %s\nstatus: Pending\n---\n' "$1" "$2" "$3" > "$BOARD/tasks/$1_x.md"
  printf -- '- %s\n' "$1" >> "$JENGA_TODO_FILE"
}

@test "stories at E10, E100 and E1001 list in numeric order" {
  story E1001_S01 "story d"
  story E100_S01 "story c"
  story E10_S01 "story a"
  story E2_S01 "story z"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1. E2_S01 — story z" ]
  [ "${lines[1]}" = "2. E10_S01 — story a" ]
  [ "${lines[2]}" = "3. E100_S01 — story c" ]
  [ "${lines[3]}" = "4. E1001_S01 — story d" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "tasks at E10, E100 and E1001 list in numeric order, after the stories" {
  story E10_S01 "story a"
  task E1001_S01_T01 E1001_S01 "task d"
  task E100_S01_T01 E100_S01 "task c"
  task E10_S01_T01 E10_S01 "task a"
  task E10_S01_T10 E10_S01 "task a10"
  task E10_S01_T2 E10_S01 "task a2"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1. E10_S01 — story a" ]
  [ "${lines[1]}" = "2. E10_S01_T01 — task a" ]
  [ "${lines[2]}" = "3. E10_S01_T2 — task a2" ]
  [ "${lines[3]}" = "4. E10_S01_T10 — task a10" ]
  [ "${lines[4]}" = "5. E100_S01_T01 — task c" ]
  [ "${lines[5]}" = "6. E1001_S01_T01 — task d" ]
  [ "${#lines[@]}" -eq 6 ]
}

@test "story and task numbers within one epic compare numerically (S2 before S10 before S100)" {
  story E10_S100 "s100"
  story E10_S10 "s10"
  story E10_S2 "s2"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1. E10_S2 — s2" ]
  [ "${lines[1]}" = "2. E10_S10 — s10" ]
  [ "${lines[2]}" = "3. E10_S100 — s100" ]
}

@test "an all-two-digit board lists exactly as plain text order would" {
  story E01_S02 "b"
  story E01_S01 "a"
  story E09_S01 "c"
  story E10_S03 "d"
  story E99_S01 "e"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' 'E01_S01 — a' 'E01_S02 — b' 'E09_S01 — c' 'E10_S03 — d' 'E99_S01 — e' | awk '{ print NR ". " $0 }')"
  [ "$output" = "$expected" ]
}

@test "a missing board directory still renders an empty list, status 0" {
  rm -rf "$BOARD/tasks"
  story E10_S01 "story a"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "1. E10_S01 — story a" ]
}

@test "a copy of the script without scripts/lib beside it fails loudly instead of falling back to text order" {
  mkdir -p "$BATS_TEST_TMPDIR/copy/scripts"
  cp "$SCRIPT" "$BATS_TEST_TMPDIR/copy/scripts/render-ranked-list.sh"
  story E10_S01 "story a"
  run --separate-stderr bash "$BATS_TEST_TMPDIR/copy/scripts/render-ranked-list.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"board-ids.sh not found"* ]]
}

@test "a copy of the script with scripts/lib copied beside it works (the fixture rule)" {
  mkdir -p "$BATS_TEST_TMPDIR/copy/scripts"
  cp "$SCRIPT" "$BATS_TEST_TMPDIR/copy/scripts/render-ranked-list.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$BATS_TEST_TMPDIR/copy/scripts/lib"
  story E100_S01 "story c"
  story E10_S01 "story a"
  run --separate-stderr bash "$BATS_TEST_TMPDIR/copy/scripts/render-ranked-list.sh"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1. E10_S01 — story a" ]
  [ "${lines[1]}" = "2. E100_S01 — story c" ]
}
