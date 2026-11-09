#!/usr/bin/env bats
#
# E86_S01_T04: the story and task ID guards in j-close-story and j-uncharted read their shapes from the shared
# board-ID source (scripts/lib/board-ids.sh), so three-plus digit IDs pass while malformed ones are still rejected.
#   check-story-closeable.sh      story guard      E1001_S100 gets past the format guard
#   extract-task-diff-stats.sh    task guard       E1001_S100_T100 is accepted
#   validate-proposed-items.sh    story test       a file with id E100_S100 is classified as a story
# Every case runs against a scratch fixture repo, never this repository's own board. The fixture copies scripts/lib
# in the layout the scripts expect (precedent: tests/mirror-nested-suite-flag.bats).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  FX="$BATS_TEST_TMPDIR/fixture-repo"
  mkdir -p "$FX/skills/j-close-story/scripts" "$FX/skills/j-uncharted/scripts" "$FX/scripts" \
    "$FX/project/board/stories" "$FX/project/board/tasks"
  git -C "$FX" init -q
  git -C "$FX" config user.email fixture@example.com
  git -C "$FX" config user.name fixture
  git -C "$FX" config commit.gpgsign false
  cp "$REPO_ROOT/skills/j-close-story/scripts/check-story-closeable.sh" \
    "$REPO_ROOT/skills/j-close-story/scripts/extract-task-diff-stats.sh" "$FX/skills/j-close-story/scripts/"
  cp "$REPO_ROOT/skills/j-uncharted/scripts/validate-proposed-items.sh" "$FX/skills/j-uncharted/scripts/"
  cp "$REPO_ROOT/scripts/validate-board.sh" "$REPO_ROOT/scripts/validate-story-format.sh" \
    "$REPO_ROOT/scripts/commits-for-item.sh" "$FX/scripts/"
  cp -R "$REPO_ROOT/scripts/lib" "$FX/scripts/lib"
  CLOSEABLE="$FX/skills/j-close-story/scripts/check-story-closeable.sh"
  DIFFSTATS="$FX/skills/j-close-story/scripts/extract-task-diff-stats.sh"
  PROPOSED="$FX/skills/j-uncharted/scripts/validate-proposed-items.sh"
}

# write_story <story id> <task id> <task status>: a story and one task in the fixture board.
write_story() {
  printf -- '---\nid: %s\nstatus: In Progress\ntasks:\n  - %s\n---\n\n# Story\n' "$1" "$2" \
    > "$FX/project/board/stories/${1}_wide.md"
  printf -- '---\nid: %s\nstatus: %s\n---\n\n# Task\n' "$2" "$3" > "$FX/project/board/tasks/${2}_wide.md"
}

# ---- check-story-closeable.sh -------------------------------------------------------------------------------

@test "check-story-closeable: E1001_S100 passes the format guard and reports CLOSEABLE for its tasks" {
  write_story E1001_S100 E1001_S100_T100 Passed
  run bash "$CLOSEABLE" E1001_S100
  [ "$status" -eq 0 ]
  assert_output_contains "CLOSEABLE"
}

@test "check-story-closeable: E1001_S100 reports an open task on the wide board" {
  write_story E1001_S100 E1001_S100_T100 "In Progress"
  run bash "$CLOSEABLE" E1001_S100
  [ "$status" -eq 1 ]
  assert_output_contains "OPEN: 'E1001_S100_T100' has status 'In Progress'"
}

@test "check-story-closeable: a well-formed wide ID with no story file reaches the board lookup, not the format guard" {
  run bash "$CLOSEABLE" E1001_S100
  [ "$status" -eq 1 ]
  assert_output_contains "Story file not found for 'E1001_S100'"
}

@test "check-story-closeable: malformed IDs are still rejected with the existing error text" {
  local id
  for id in E1001_S1x e01_s01 E01_S01_T01 E E1_ E01_T01 E01_S01x; do
    run bash "$CLOSEABLE" "$id"
    [ "$status" -eq 1 ]
    assert_output_contains "ERROR: Invalid story ID format '$id'. Expected format: E##_S## (e.g. E17_S06)"
  done
}

# ---- extract-task-diff-stats.sh -----------------------------------------------------------------------------

@test "extract-task-diff-stats: E1001_S100_T100 is accepted and returns stats for its commit" {
  cd "$FX"
  git add -A && git commit -q -m "scaffold"
  printf 'one\ntwo\nthree\n' > "$FX/wide.txt"
  git add wide.txt && git commit -q -m "task(E1001_S100_T100): x"
  run bash "$DIFFSTATS" E1001_S100_T100
  [ "$status" -eq 0 ]
  assert_output_contains "actual_files_changed: 1"
  assert_output_contains "actual_lines_delta: 3"
}

@test "extract-task-diff-stats: a story-shaped ID is rejected with the existing error text" {
  run bash "$DIFFSTATS" E1001_S100
  [ "$status" -eq 1 ]
  assert_output_contains "ERROR: Invalid task ID format 'E1001_S100'. Expected E##_S##_T## (e.g. E32_S06_T01)"
}

@test "extract-task-diff-stats: other malformed IDs are still rejected" {
  local id
  for id in E01_S01_T01x e01_s01_t01 E01_T01 E1_S01_T E; do
    run bash "$DIFFSTATS" "$id"
    [ "$status" -eq 1 ]
    assert_output_contains "ERROR: Invalid task ID format '$id'. Expected E##_S##_T## (e.g. E32_S06_T01)"
  done
}

# ---- validate-proposed-items.sh -----------------------------------------------------------------------------

# A story-id file with no Acceptance Criteria: if the script classifies it as a story the story-format validator
# runs and reports "story format"; if it does not, only the frontmatter validator speaks.
write_item() {
  printf -- '---\nid: %s\ntitle: x\nstatus: Pending\n---\n\n# Item\n' "$1" > "$FX/$2"
}

@test "validate-proposed-items: an E100_S100 file is classified as a story, as E01_S01 is today" {
  write_item E01_S01 narrow.md
  write_item E100_S100 wide.md
  run bash "$PROPOSED" "$FX/narrow.md"
  [ "$status" -eq 1 ]
  assert_output_contains "story format"
  run bash "$PROPOSED" "$FX/wide.md"
  [ "$status" -eq 1 ]
  assert_output_contains "story format"
}

@test "validate-proposed-items: a task-shaped id is not classified as a story" {
  write_item E100_S100_T100 task.md
  run bash "$PROPOSED" "$FX/task.md"
  assert_output_not_contains "story format"
}
