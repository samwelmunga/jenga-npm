#!/usr/bin/env bash
#
# Throwaway scrum-board fixture for the progress-visualisation suites (epic E92, task E92_S01_T02).
#
# Other E92 tasks `load helpers/progress-fixture` READ-ONLY; only E92_S01 tasks may edit this file. It is a .bash file,
# not a .bats file, so test discovery never runs it. Sourcing it only defines functions and a few PF_* variables.
# Compatible with bash 3.2 (no mapfile, no associative arrays) and uses no bare `[[ ... ]]` statement.
#
# Use:
#     load helpers/assertions
#     load helpers/progress-fixture
#     setup() { pf_setup; }
#     @test "..." { pf_run --story E01_S01 --items; [ "$PF_RC" -eq 0 ]; pf_py 'd["scope"]["type"]'; ... }
#
# pf_setup builds the board under $BATS_TEST_TMPDIR/fixture (never the real project/board/) and every pf_run passes
# --root $PF_ROOT, so the script reads only the fixture. The fixture's registry is the minimal `{}`: the conventional
# project/board/{epics,stories,tasks} layout then resolves by default.
#
# What the board holds (statuses in table order: the 14 of templates/SCRUM_BOARD_SCHEMA.md "Status Values", then an
# unknown one, "Not Started"):
#   E01    story S01: 15 tasks T01..T15, one per status above (T15 is the unknown one); S02 (Passed Passed Passed
#          Rejected Pending, the Rejected rule); S03 has no tasks
#   E02    no children (empty epic)
#   E03    task E03_S01_T01 whose story file does not exist (orphan task)
#   (E04)  no epic file: story E04_S01 and its task E04_S01_T01 (orphan task through a missing epic)
#   E05    story S01 with quirky files: a quoted status, a CRLF file, a status: line in the body, a file with no id
#   E06    stories S01..S15, each with ONE task; story and task carry the same status (the S<nn> story holds the nn-th
#          status of the list above), so a story-scoped run isolates one status
#   E99    stories S2, S10, S100, each with tasks T2, T10, T100 (unpadded numbers)
#   E100   the same shape as E99
# E99 and E100 are written in a non-numeric order on purpose, so the file system never hands back numeric order.
#
# The backlog scope reads a todo file, never the live project/todo.md: pf_setup points PF_TODO at a path under the test's
# own tmpdir (no file yet, so a bare --backlog is the missing-file case) and pf_run exports it as JENGA_TODO_FILE for every
# run. pf_todo "<line>" ... writes that file, one argument per line (an empty argument is a blank line).

PF_STATUSES="Pending|In Progress|Passed|Passed with remarks|Failed|Rejected|Blocked|Backlog|Done|Merged|Publicized|Privatized|Deployed to Stage|Deployed to Prod|Not Started"
PF_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/board-progress.sh"

# pf_status_at <n>: the n-th (1-based) status of PF_STATUSES.
pf_status_at() {
  printf '%s\n' "$PF_STATUSES" | awk -F'|' -v n="$1" '{ print $n }'
}

# pf_item <id> <status> [raw-extra-frontmatter-line ...]: writes one item file under $PF_ROOT. The level comes from
# the id; story_id and epic_id are derived from it. Prints nothing.
pf_item() {
  local id="$1" status="$2" dir f epic story extra
  shift 2
  epic="${id%%_*}"
  story=""
  case "$id" in
    *_S*_T*) dir="$PF_ROOT/project/board/tasks"; story="${id%_T*}" ;;
    *_S*)    dir="$PF_ROOT/project/board/stories" ;;
    *)       dir="$PF_ROOT/project/board/epics" ;;
  esac
  mkdir -p "$dir"
  f="$dir/${id}_fixture-item.md"
  {
    printf -- '---\nid: %s\n' "$id"
    if [ -n "$story" ]; then printf 'story_id: %s\n' "$story"; fi
    if [ "$epic" != "$id" ]; then printf 'epic_id: %s\n' "$epic"; fi
    printf 'title: "Fixture %s"\nstatus: %s\n' "$id" "$status"
    for extra in "$@"; do printf '%s\n' "$extra"; done
    printf -- '---\n\n# Fixture %s\n' "$id"
  } > "$f"
}

# pf_build <root>: builds the whole fixture board under <root>.
pf_build() {
  local n pad s e st
  PF_ROOT="$1"
  mkdir -p "$PF_ROOT/project/configs" "$PF_ROOT/project/board/epics" "$PF_ROOT/project/board/stories" "$PF_ROOT/project/board/tasks"
  printf '{}\n' > "$PF_ROOT/project/configs/workflow.json"

  # E01: statuses at task level, the Rejected rule, an empty story
  pf_item E01 Pending
  pf_item E01_S01 Passed
  pf_item E01_S02 "In Progress"
  pf_item E01_S03 Pending
  n=1
  while [ "$n" -le 15 ]; do
    pad="$(printf '%02d' "$n")"
    pf_item "E01_S01_T$pad" "$(pf_status_at "$n")"
    n=$((n + 1))
  done
  pf_item E01_S02_T01 Passed
  pf_item E01_S02_T02 Passed
  pf_item E01_S02_T03 Passed
  pf_item E01_S02_T04 Rejected
  pf_item E01_S02_T05 Pending

  # E02: an epic with no children. E03: a task whose story file is missing. E04: no epic file at all.
  pf_item E02 Pending
  pf_item E03 Pending
  pf_item E03_S01_T01 Pending
  pf_item E04_S01 Pending
  pf_item E04_S01_T01 Pending

  # E05: quirky but valid files
  pf_item E05 Pending
  pf_item E05_S01 Pending
  pf_item E05_S01_T01 '"Passed"'
  printf -- '---\r\nid: E05_S01_T02\r\nstory_id: E05_S01\r\nepic_id: E05\r\nstatus: Pending\r\n---\r\n\r\nbody\r\n' \
    > "$PF_ROOT/project/board/tasks/E05_S01_T02_crlf.md"
  pf_item E05_S01_T03 Passed
  printf 'status: Failed\n' >> "$PF_ROOT/project/board/tasks/E05_S01_T03_fixture-item.md"
  printf -- '---\nstory_id: E05_S01\nepic_id: E05\nstatus: Merged\n---\n\nno id in the frontmatter; the file name carries it\n' \
    > "$PF_ROOT/project/board/tasks/E05_S01_T04_name-only.md"

  # E06: one story and one task per status
  pf_item E06 Pending
  n=1
  while [ "$n" -le 15 ]; do
    pad="$(printf '%02d' "$n")"
    st="$(pf_status_at "$n")"
    pf_item "E06_S$pad" "$st"
    pf_item "E06_S${pad}_T01" "$st"
    n=$((n + 1))
  done

  # E99 and E100: numbers past one digit, created in a non-numeric order
  for e in 100 99; do
    pf_item "E$e" Pending
    for s in 100 2 10; do
      pf_item "E${e}_S$s" "In Progress"
      for t in 10 100 2; do
        pf_item "E${e}_S${s}_T$t" Passed
      done
    done
  done
}

pf_setup() {
  PF_TODO="$BATS_TEST_TMPDIR/todo.md"
  PF_OUT="$BATS_TEST_TMPDIR/pf.out"
  PF_ERR="$BATS_TEST_TMPDIR/pf.err"
  pf_build "$BATS_TEST_TMPDIR/fixture"
}

# pf_run <script args...>: runs the script against the fixture; sets PF_RC and the files $PF_OUT / $PF_ERR.
pf_run() {
  PF_RC=0
  JENGA_TODO_FILE="$PF_TODO" bash "$PF_SCRIPT" --root "$PF_ROOT" "$@" > "$PF_OUT" 2> "$PF_ERR" || PF_RC=$?
}

# pf_todo <line> ...: writes the fixture todo file ($PF_TODO), one argument per line.
pf_todo() {
  local l
  : > "$PF_TODO"
  for l in "$@"; do printf '%s\n' "$l" >> "$PF_TODO"; done
}

# pf_py '<python expression over d>': prints the expression evaluated on the JSON in $PF_OUT (compact for containers).
pf_py() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = eval(sys.argv[2])
print(v if isinstance(v, str) else json.dumps(v, separators=(",", ":")))
' "$PF_OUT" "$1"
}

# pf_tree_sum <dir>: one checksum for the file names, sizes-by-content and modes of the whole tree.
pf_tree_sum() {
  (cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r p; do
    if [ -f "$p" ]; then printf '%s %s\n' "$(cksum < "$p")" "$p"; else printf 'd %s\n' "$p"; fi
  done) | cksum
}
