#!/usr/bin/env bats
#
# Regression coverage for scripts/todo_manager.sh `remove` and board IDs of mixed width (E86_S05_T01, audit group 1:
# substring and prefix matches).
#
# `remove "<title>"` deletes the first line of project/todo.md that contains <title>. A todo entry is
# `<mission title>: <ref>`, so a title argument can end in a board ID. With fixed two-digit IDs no ID was a string
# prefix of another; with wide IDs `E10` is a prefix of `E100` and `E1001`, `E10_S1` of `E10_S10`, and `E10_S1_T1` of
# `E10_S1_T100`, so an unanchored substring match removed whichever of those entries came first. The fix anchors the end
# of the match at the ID when (and only when) the title ends in a board ID.
#
# Every test runs against a throwaway $BATS_TEST_TMPDIR, never against this repository's own project/todo.md.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
# TODO_MANAGER_UNDER_TEST points the whole file at another copy of the script. It exists so the file can be run against
# the pre-fix script (git show <pre-fix-sha>:scripts/todo_manager.sh > /tmp/todo_manager.unfixed.sh) to show the
# regression tests fail there; unset, it tests the real script.
SCRIPT="${TODO_MANAGER_UNDER_TEST:-$REPO_ROOT/scripts/todo_manager.sh}"

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/project"
  cd "$WORK"
}

# write_todo <line>... : one entry per argument, in order, after the usual header and comment.
write_todo() {
  {
    printf '# Todo\n\n<!-- Format: <mission title>: <E##_S##> (epic/story ref optional) -->\n\n'
    printf '%s\n' "$@"
  } > "$WORK/project/todo.md"
}

# entries : the real (non-header) lines of the todo file, as the manager's own `list` prints them.
entries() { bash "$SCRIPT" list; }

@test "E10 vs E100 and E1001: removing 'Beta: E10' leaves the longer-ID entries alone" {
  write_todo 'Beta: E1001' 'Beta: E100' 'Beta: E10'
  run bash "$SCRIPT" remove 'Beta: E10'
  [ "$status" -eq 0 ]
  run entries
  [ "$output" = "$(printf 'Beta: E1001\nBeta: E100')" ]
}

@test "E10 vs E100 and E1001: the entry is found wherever it sits among the longer IDs" {
  write_todo 'Beta: E100' 'Beta: E10' 'Beta: E1001'
  run bash "$SCRIPT" remove 'Beta: E10'
  [ "$status" -eq 0 ]
  run entries
  [ "$output" = "$(printf 'Beta: E100\nBeta: E1001')" ]
}

@test "S1 vs S10: removing 'Alpha: E10_S1' leaves 'Alpha: E10_S10' alone" {
  write_todo 'Alpha: E10_S10' 'Alpha: E10_S1'
  run bash "$SCRIPT" remove 'Alpha: E10_S1'
  [ "$status" -eq 0 ]
  run entries
  [ "$output" = 'Alpha: E10_S10' ]
}

@test "S1 vs S10 across epics: 'E10_S1' does not match 'E100_S1' or 'E1001_S1'" {
  write_todo 'Alpha: E1001_S1' 'Alpha: E100_S1' 'Alpha: E10_S1'
  run bash "$SCRIPT" remove 'Alpha: E10_S1'
  [ "$status" -eq 0 ]
  run entries
  [ "$output" = "$(printf 'Alpha: E1001_S1\nAlpha: E100_S1')" ]
}

@test "T1 vs T100: removing 'Gamma: E10_S1_T1' leaves 'Gamma: E10_S1_T100' alone" {
  write_todo 'Gamma: E10_S1_T100' 'Gamma: E10_S1_T1'
  run bash "$SCRIPT" remove 'Gamma: E10_S1_T1'
  [ "$status" -eq 0 ]
  run entries
  [ "$output" = 'Gamma: E10_S1_T100' ]
}

@test "a story title does not match the same title's task entry that sorts first" {
  write_todo 'Delta: E10_S01_T01' 'Delta: E10_S01'
  run bash "$SCRIPT" remove 'Delta: E10_S01'
  [ "$status" -eq 0 ]
  run entries
  [ "$output" = 'Delta: E10_S01_T01' ]
}

@test "an ID-ending title that only a longer ID contains is no match: exit 1, same message, file unchanged" {
  write_todo 'Beta: E100' 'Beta: E1001'
  cp "$WORK/project/todo.md" "$BATS_TEST_TMPDIR/before"
  run bash "$SCRIPT" remove 'Beta: E10'
  [ "$status" -eq 1 ]
  [[ "$output" == *'Error: no line matching "Beta: E10" found in project/todo.md'* ]]
  cmp "$WORK/project/todo.md" "$BATS_TEST_TMPDIR/before"
}

@test "an ID-ending title still matches with trailing spaces and with text before it" {
  write_todo 'Zed one two: E10_S02   ' 'Zed other: E10_S020'
  run bash "$SCRIPT" remove 'Zed one two: E10_S02'
  [ "$status" -eq 0 ]
  run entries
  [ "$output" = 'Zed other: E10_S020' ]
}

@test "only the first of two identical matching entries is removed" {
  write_todo 'Eps: E10_S3' 'Eps: E10_S3'
  run bash "$SCRIPT" remove 'Eps: E10_S3'
  [ "$status" -eq 0 ]
  run entries
  [ "$output" = 'Eps: E10_S3' ]
}

@test "existing two-digit board: a plain title (no ID) keeps the first-line-containing meaning" {
  write_todo 'Fix the thing: E01_S02_T03' 'Fix the thing again: E01_S02_T04'
  run bash "$SCRIPT" remove 'Fix the thing'
  [ "$status" -eq 0 ]
  run entries
  [ "$output" = 'Fix the thing again: E01_S02_T04' ]
}

@test "existing two-digit board: a full 'title: ref' argument removes exactly that entry" {
  write_todo 'Fix the thing: E01_S02_T03' 'Other thing: E01_S02_T04' 'Last thing: E02_S01'
  run bash "$SCRIPT" remove 'Other thing: E01_S02_T04'
  [ "$status" -eq 0 ]
  run entries
  [ "$output" = "$(printf 'Fix the thing: E01_S02_T03\nLast thing: E02_S01')" ]
}

@test "a title that matches nothing exits 1 with the unchanged message and leaves the file byte-identical" {
  write_todo 'Fix the thing: E01_S02_T03'
  cp "$WORK/project/todo.md" "$BATS_TEST_TMPDIR/before"
  run bash "$SCRIPT" remove 'No such entry'
  [ "$status" -eq 1 ]
  [[ "$output" == *'Error: no line matching "No such entry" found in project/todo.md'* ]]
  cmp "$WORK/project/todo.md" "$BATS_TEST_TMPDIR/before"
  [ ! -e "$WORK/project/todo.md.tmp" ]
}

@test "a missing todo file is still the unchanged error" {
  run bash "$SCRIPT" remove 'anything: E10_S1'
  [ "$status" -eq 1 ]
  [[ "$output" == *'Error: project/todo.md does not exist'* ]]
}
