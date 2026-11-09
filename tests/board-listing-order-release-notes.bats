#!/usr/bin/env bats
#
# E86_S02_T06: skills/j-publish/scripts/generate_release_notes.sh lists the "Completed tasks" bullets in NUMERIC task-ID
# order.
#
# The bullets ("- <id> — <title>") came from a listing of project/board/tasks and were sorted with `LC_ALL=C sort -u`,
# which is text order: E100 and E1001 landed before E11 and a story's T10 before T2. They are now sorted with
# board_id_sort from scripts/lib/board-ids.sh. The script reads the tasks of the git repository the script itself lives
# in, so each case builds a throwaway repo holding a COPY of the script plus the board.
#
# Fixture rule (board-ids.md, Decisions item 7): the script resolves scripts/lib from its own location with no fallback
# ordering, so the repo copies scripts/lib next to the script (except in the case that proves the missing-library error).

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS_SRC="$REPO_ROOT/skills/j-publish/scripts"

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  TMP_REPO="$(cd "$BATS_TEST_TMPDIR/repo" && pwd -P)"
  mkdir -p "$TMP_REPO/skills/j-publish/scripts" "$TMP_REPO/project/board/tasks"
  cp "$SCRIPTS_SRC/publish_common.sh" "$SCRIPTS_SRC/generate_release_notes.sh" "$TMP_REPO/skills/j-publish/scripts/"
  GEN="$TMP_REPO/skills/j-publish/scripts/generate_release_notes.sh"
  OUT="$BATS_TEST_TMPDIR/notes.md"
}

with_lib() {
  mkdir -p "$TMP_REPO/scripts"
  cp -R "$REPO_ROOT/scripts/lib" "$TMP_REPO/scripts/lib"
}

# done_task <id>: a Passed task completed after any cutoff
done_task() {
  printf -- '---\nid: %s\ntitle: title %s\nstatus: Passed\ndate_completed: 2026-11-01\n---\n' "$1" "$1" > "$TMP_REPO/project/board/tasks/$1_x.md"
}

seed_repo() {
  git -C "$TMP_REPO" init -q
  git -C "$TMP_REPO" config user.email test@example.com
  git -C "$TMP_REPO" config user.name "Test"
  git -C "$TMP_REPO" add -A
  git -C "$TMP_REPO" commit -q -m "chore: seed fixture repo"
}

# bullets: the "Completed tasks" bullet lines of the notes, in order
bullets() {
  sed -n '/^### Completed tasks$/,$p' "$OUT" | grep '^- '
}

@test "completed tasks at E2, E10, E100 and E1001 list in numeric order" {
  with_lib
  local id
  for id in E1001_S01_T01 E100_S01_T01 E10_S01_T10 E10_S01_T2 E2_S01_T01; do done_task "$id"; done
  seed_repo
  run --separate-stderr bash -c 'cd "$1" && bash "$2" --output "$3"' _ "$TMP_REPO" "$GEN" "$OUT"
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' \
    '- E2_S01_T01 — title E2_S01_T01' \
    '- E10_S01_T2 — title E10_S01_T2' \
    '- E10_S01_T10 — title E10_S01_T10' \
    '- E100_S01_T01 — title E100_S01_T01' \
    '- E1001_S01_T01 — title E1001_S01_T01')"
  [ "$(bullets)" = "$expected" ]
}

@test "an all-two-digit board lists in the same order plain text sorting gave" {
  with_lib
  local id
  for id in E10_S02_T01 E02_S01_T03 E02_S01_T01 E99_S10_T01 E10_S01_T09; do done_task "$id"; done
  seed_repo
  run --separate-stderr bash -c 'cd "$1" && bash "$2" --output "$3"' _ "$TMP_REPO" "$GEN" "$OUT"
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' \
    '- E02_S01_T01 — title E02_S01_T01' \
    '- E02_S01_T03 — title E02_S01_T03' \
    '- E10_S01_T09 — title E10_S01_T09' \
    '- E10_S02_T01 — title E10_S02_T01' \
    '- E99_S10_T01 — title E99_S10_T01')"
  [ "$(bullets)" = "$expected" ]
}

@test "a copy of the script without scripts/lib beside it fails loudly when there are tasks to list" {
  done_task E10_S01_T01
  seed_repo
  run --separate-stderr bash -c 'cd "$1" && bash "$2" --output "$3"' _ "$TMP_REPO" "$GEN" "$OUT"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"board-ids.sh not found"* ]]
}

@test "a publish with no project/board/tasks needs no shared library" {
  rmdir "$TMP_REPO/project/board/tasks"
  seed_repo
  run --separate-stderr bash -c 'cd "$1" && bash "$2" --output "$3"' _ "$TMP_REPO" "$GEN" "$OUT"
  [ "$status" -eq 0 ]
  ! grep -q '^### Completed tasks$' "$OUT"
}
