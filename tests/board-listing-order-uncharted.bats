#!/usr/bin/env bats
#
# E86_S02_T06: skills/j-uncharted/scripts/run-engine.sh lists the board items that reference a target, in the
# understanding document's "Board linkage" row, in NUMERIC board-ID order.
#
# The engine walks the board directories, collects the IDs of every file naming the target and printed the first eight
# of `sorted(ids)`, which is text order: with E2..E7, E10, E100 and E1001 on the board the row showed E10, E100, E1001,
# E2, ... and so cut off the wrong IDs behind "(+N more)". It now sorts with board_id_sort_key from
# scripts/lib/board_ids.py. The engine reads the board of the git repository the script lives in, so every case builds
# a throwaway repo holding a COPY of skills/j-uncharted.
#
# Fixture rule (board-ids.md, Decisions item 7): the engine resolves scripts/lib from its own location with no fallback
# ordering, so the repo copies scripts/lib next to skills/ (except in the case that proves the missing-library error).

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  TMP_REPO="$(cd "$BATS_TEST_TMPDIR/repo" && pwd -P)"
  mkdir -p "$TMP_REPO/skills" "$TMP_REPO/project/board/tasks" "$TMP_REPO/src"
  cp -R "$REPO_ROOT/skills/j-uncharted" "$TMP_REPO/skills/j-uncharted"
  printf 'x\n' > "$TMP_REPO/src/a.js"
  ENGINE="$TMP_REPO/skills/j-uncharted/scripts/run-engine.sh"
}

with_lib() {
  mkdir -p "$TMP_REPO/scripts"
  cp -R "$REPO_ROOT/scripts/lib" "$TMP_REPO/scripts/lib"
}

# board_item <id>: a task file whose text names src/a.js
board_item() {
  printf -- '---\nid: %s\n---\nTouches src/a.js\n' "$1" > "$TMP_REPO/project/board/tasks/$1_x.md"
}

seed_repo() {
  git -C "$TMP_REPO" init -q
  git -C "$TMP_REPO" config user.email test@example.com
  git -C "$TMP_REPO" config user.name "Test"
  git -C "$TMP_REPO" add -A
  git -C "$TMP_REPO" commit -q -m "chore: seed fixture repo"
}

# linkage_row: the Board linkage row of the written document
linkage_row() {
  grep '^| Board linkage |' "$1"
}

@test "the board linkage row lists items in numeric order and cuts off the numerically last ones" {
  with_lib
  local id
  for id in E1001_S01_T01 E100_S01_T01 E10_S01_T10 E10_S01_T2 E10_S01_T01 E2_S01_T01 E3_S01_T01 E4_S01_T01 E5_S01_T01 E6_S01_T01 E7_S01_T01; do
    board_item "$id"
  done
  seed_repo
  run --separate-stderr bash -c 'cd "$1" && bash "$2" --out-dir "$1/out" src/a.js' _ "$TMP_REPO" "$ENGINE"
  [ "$status" -eq 0 ]
  row="$(linkage_row "$output")"
  [[ "$row" == "| Board linkage | linked to \`E2_S01_T01\`, \`E3_S01_T01\`, \`E4_S01_T01\`, \`E5_S01_T01\`, \`E6_S01_T01\`, \`E7_S01_T01\`, \`E10_S01_T01\`, \`E10_S01_T2\` (+3 more)"* ]]
}

@test "an all-two-digit board links items in the same order plain text sorting gave" {
  with_lib
  local id
  for id in E10_S01_T01 E02_S01_T03 E02_S01_T01 E99_S01_T01; do board_item "$id"; done
  seed_repo
  run --separate-stderr bash -c 'cd "$1" && bash "$2" --out-dir "$1/out" src/a.js' _ "$TMP_REPO" "$ENGINE"
  [ "$status" -eq 0 ]
  row="$(linkage_row "$output")"
  [[ "$row" == "| Board linkage | linked to \`E02_S01_T01\`, \`E02_S01_T03\`, \`E10_S01_T01\`, \`E99_S01_T01\`"* ]]
  [[ "$row" != *"more)"* ]]
}

@test "a copy of the engine without scripts/lib beside it fails loudly with exit 3 and writes no document" {
  board_item E10_S01_T01
  seed_repo
  run --separate-stderr bash -c 'cd "$1" && bash "$2" --out-dir "$1/out" src/a.js' _ "$TMP_REPO" "$ENGINE"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"board_ids.py not found"* ]]
  [ -z "$(ls "$TMP_REPO/out" 2>/dev/null)" ]
}
