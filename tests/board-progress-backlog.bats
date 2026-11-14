#!/usr/bin/env bats
#
# E92_S01_T04: the --backlog scope of scripts/board-progress.sh (the board items named by the real entries of the todo
# file) and the orphan reporting (contract: project/documentation/progress-visualisation.md sections 3, 6 and 7). Every
# test runs against the throwaway fixture board built by tests/helpers/progress-fixture.bash and a fixture todo file
# selected with JENGA_TODO_FILE (pf_run exports it); neither the live project/board/ nor the live project/todo.md is read.
#
# Fixture facts used below: E01_S01_T01 is a task, E01_S02 a story with tasks T01..T05, E05 an epic with the single story
# E05_S01 and tasks T01..T04, E03 is an epic whose only task E03_S01_T01 has no story file, E04 has no epic file but the
# story E04_S01 and its task E04_S01_T01, E99 and E100 hold stories S2/S10/S100.

bats_require_minimum_version 1.5.0

load helpers/assertions
load helpers/progress-fixture

setup() { pf_setup; }

# assert_error <code> <stderr-fragment>: the last pf_run failed with <code>, said <fragment> on stderr, printed nothing on
# stdout.
assert_error() {
  [ "$PF_RC" -eq "$1" ]
  [ ! -s "$PF_OUT" ]
  grep -qF -- "$2" "$PF_ERR"
}

# absent <pattern>: fails unless the last output has no match for the pattern (a bare `! grep` would not fail a test).
absent() { ! grep -q -- "$1" "$PF_OUT"; }

# ids_at <level>: the ids listed under that level's items (needs --items), compact JSON.
ids_at() { pf_py "[i['id'] for i in d['levels']['$1']['items']]"; }

# A todo naming one task, one story and one epic, wrapped in blank lines, # lines and comments.
write_mixed_todo() {
  pf_todo "# Todo" "" "<!-- Format: <mission title>: <E##_S##> -->" \
    "Fix one task: E01_S01_T01" "" "A whole story: E01_S02" "   " "<!-- RECONCILED: done long ago: E06_S01_T01 -->" \
    "An epic: E05" "# E06_S02 is only a comment"
}

@test "--backlog counts exactly the named task, the named story with its tasks and the named epic with its stories and tasks" {
  write_mixed_todo
  pf_run --backlog --items
  [ "$PF_RC" -eq 0 ]
  [ ! -s "$PF_ERR" ]
  [ "$(pf_py "d['scope']")" = '{"type":"backlog","ids":[]}' ]
  [ "$(pf_py "list(d['levels'])")" = '["tasks","stories","epics"]' ]
  [ "$(ids_at tasks)" = '["E01_S01_T01","E01_S02_T01","E01_S02_T02","E01_S02_T03","E01_S02_T04","E01_S02_T05","E05_S01_T01","E05_S01_T02","E05_S01_T03","E05_S01_T04"]' ]
  [ "$(ids_at stories)" = '["E01_S02","E05_S01"]' ]
  [ "$(ids_at epics)" = '["E05"]' ]
  [ "$(pf_py "d['warnings']")" = '[]' ]
}

@test "a board item that no entry names is absent: the parent of a named story, its siblings, comment-only ids" {
  write_mixed_todo
  pf_run --backlog --items
  [ "$PF_RC" -eq 0 ]
  absent '"E01_S01"'
  absent '"E01_S03"'
  absent '"E01"'
  absent 'E01_S01_T02'
  absent 'E06'
  absent 'E02'
}

@test "an item named twice, in any case or width, is counted once" {
  pf_todo "One: E01_S01_T01" "Again: e01_s01_t01" "Padded differently: E1_S1_T1" "Story: E01_S02" "Its task too: E01_S02_T01" "Story again: E1_S2"
  pf_run --backlog --items
  [ "$PF_RC" -eq 0 ]
  [ "$(ids_at tasks)" = '["E01_S01_T01","E01_S02_T01","E01_S02_T02","E01_S02_T03","E01_S02_T04","E01_S02_T05"]' ]
  [ "$(pf_py "d['levels']['tasks']['totals']['denominator']")" = "5" ]
  [ "$(ids_at stories)" = '["E01_S02"]' ]
  [ "$(pf_py "d['warnings']")" = '[]' ]
}

@test "a level with no item is absent: a todo naming one task has only the tasks block" {
  pf_todo "Just this: E01_S02_T04"
  pf_run --backlog --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "list(d['levels'])")" = '["tasks"]' ]
  [ "$(ids_at tasks)" = '["E01_S02_T04"]' ]
  [ "$(pf_py "d['levels']['tasks']['totals']")" = '{"done":0,"in_progress":0,"failed":0,"pending":0,"rejected":1,"unknown":0,"denominator":0}' ]
}

@test "a named story is one story item plus its tasks; a named epic expands by the children's own epic_id" {
  pf_todo "Story: E06_S03" "Epic whose child task has no story file: E03"
  pf_run --backlog --items
  [ "$PF_RC" -eq 0 ]
  [ "$(ids_at stories)" = '["E06_S03"]' ]
  [ "$(ids_at epics)" = '["E03"]' ]
  [ "$(ids_at tasks)" = '["E03_S01_T01","E06_S03_T01"]' ]
}

@test "--backlog --items lists items in numeric order, whatever the order of the entries" {
  pf_todo "Later: E100_S10" "Earlier: E99_S2" "Middle: E99_S10_T10" "First: E99_S10_T2"
  pf_run --backlog --items
  [ "$PF_RC" -eq 0 ]
  [ "$(ids_at stories)" = '["E99_S2","E100_S10"]' ]
  [ "$(ids_at tasks)" = '["E99_S2_T2","E99_S2_T10","E99_S2_T100","E99_S10_T2","E99_S10_T10","E100_S10_T2","E100_S10_T10","E100_S10_T100"]' ]
}

@test "a CRLF todo file and indented entries resolve the same way" {
  printf 'Task: E01_S01_T01\r\n  Indented story:   E01_S02  \r\n\r\n' > "$PF_TODO"
  pf_run --backlog --items
  [ "$PF_RC" -eq 0 ]
  [ "$(ids_at stories)" = '["E01_S02"]' ]
  [ "$(pf_py "d['warnings']")" = '[]' ]
}

@test "a status of Backlog on a board epic has no effect on the scope" {
  pf_item E50 Backlog
  pf_item E50_S01 Pending
  pf_item E50_S01_T01 Pending
  pf_todo "Only this: E01_S01_T01"
  pf_run --backlog --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "list(d['levels'])")" = '["tasks"]' ]
  absent 'E50'
  # and an empty todo stays empty even though a Backlog epic exists
  pf_todo "# nothing queued"
  pf_run --backlog
  assert_error 3 "no real entries"
}

@test "a missing todo file is an empty scope: exit 3, a message on stderr, nothing on stdout" {
  rm -f "$PF_TODO"
  pf_run --backlog
  assert_error 3 "does not exist"
  grep -qF -- "$PF_TODO" "$PF_ERR"
}

@test "a todo file with only comments, blank lines and # lines is an empty scope: exit 3" {
  pf_todo "# Todo" "" "<!-- Format: <mission title>: <E##_S##> -->" "   " "<!-- RECONCILED: old: E01_S01 -->"
  pf_run --backlog
  assert_error 3 "no real entries"
}

@test "a todo file whose every entry is unresolved is an empty scope: exit 3, the orphans listed on stderr" {
  pf_todo "# Todo" "Fix the thing" "E01_S02_T03 - Fix the thing" "Gone: E77_S01" "Gone too: E77"
  pf_run --backlog
  assert_error 3 "empty scope"
  grep -qF -- "line 2 'Fix the thing'" "$PF_ERR"
  grep -qF -- "line 3 'E01_S02_T03 - Fix the thing'" "$PF_ERR"
  grep -qF -- "line 4 E77_S01" "$PF_ERR"
  grep -qF -- "line 5 E77" "$PF_ERR"
}

@test "an entry with no trailing id is a todo_unresolved_entry warning with its line number; exit stays 0" {
  pf_todo "# Todo" "Fix the thing" "Real one: E01_S01_T01" "" "E01_S02_T03 - Fix the thing" "Prose with an id in the middle E01_S02 and more"
  pf_run --backlog
  [ "$PF_RC" -eq 0 ]
  [ ! -s "$PF_ERR" ]
  [ "$(pf_py "[(w['kind'], w['id'], w['detail']) for w in d['warnings']]")" = \
    '[["todo_unresolved_entry","","line 2: Fix the thing (no trailing id)"],["todo_unresolved_entry","","line 5: E01_S02_T03 - Fix the thing (no trailing id)"],["todo_unresolved_entry","","line 6: Prose with an id in the middle E01_S02 and more (no trailing id)"]]' ]
  [ "$(pf_py "list(d['levels'])")" = '["tasks"]' ]
  [ "$(pf_py "d['levels']['tasks']['counts']")" = '{"Pending":1}' ]
}

@test "an id with no board file is a todo_unknown_id warning naming the id; exit stays 0, once per id" {
  pf_todo "Real: E01_S01_T01" "Gone task: E77_S01_T01" "Gone story: E01_S09" "Same gone task again: e77_s01_t01" "Wrong level exists elsewhere: E01_S01_T99"
  pf_run --backlog
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "[(w['kind'], w['id']) for w in d['warnings']]")" = '[["todo_unknown_id","E01_S01_T99"],["todo_unknown_id","E01_S09"],["todo_unknown_id","E77_S01_T01"]]' ]
  [ "$(pf_py "d['warnings'][2]['detail']")" = "no task file carries this id (todo line 2)" ]
  [ "$(pf_py "d['levels']['tasks']['totals']['denominator']")" = "1" ]
}

@test "unresolved entries come first, then warnings in numeric id order, an orphan warning with its item" {
  pf_todo "Orphan task: E03_S01_T01" "Nothing here" "Gone: E02_S05" "Orphan story: E04_S01"
  pf_run --backlog
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "[(w['kind'], w['id']) for w in d['warnings']]")" = \
    '[["todo_unresolved_entry",""],["todo_unknown_id","E02_S05"],["orphan_task","E03_S01_T01"],["orphan_story","E04_S01"],["orphan_task","E04_S01_T01"]]' ]
}

@test "a task whose story file is missing is counted in --all and warned as orphan_task with the missing story id" {
  pf_run --all --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "'E03_S01_T01' in [i['id'] for i in d['levels']['tasks']['items']]")" = "true" ]
  [ "$(pf_py "[w['detail'] for w in d['warnings'] if w['kind'] == 'orphan_task' and w['id'] == 'E03_S01_T01']")" = '["story E03_S01 has no board file"]' ]
}

@test "a task whose epic file is missing is warned as orphan_task and a story whose epic file is missing as orphan_story; both are counted in --all" {
  pf_run --all --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "'E04_S01' in [i['id'] for i in d['levels']['stories']['items']]")" = "true" ]
  [ "$(pf_py "'E04_S01_T01' in [i['id'] for i in d['levels']['tasks']['items']]")" = "true" ]
  [ "$(pf_py "[w['detail'] for w in d['warnings'] if w['kind'] == 'orphan_story' and w['id'] == 'E04_S01']")" = '["epic E04 has no board file"]' ]
  [ "$(pf_py "[w['detail'] for w in d['warnings'] if w['kind'] == 'orphan_task' and w['id'] == 'E04_S01_T01']")" = '["epic E04 has no board file"]' ]
  # the epic E04 does not exist, so nothing is counted under it and no scope can name it
  pf_run --epic E04
  assert_error 2 "unknown epic id"
}

@test "an orphan task is counted under the epic it names when that epic exists, and warns there too" {
  pf_run --epic E03 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(ids_at tasks)" = '["E03_S01_T01"]' ]
  [ "$(pf_py "[(w['kind'], w['id']) for w in d['warnings']]")" = '[["orphan_task","E03_S01_T01"]]' ]
}

@test "a warning never changes the exit code, and an orphan whose parents are both missing names both" {
  pf_item E60_S01_T01 Pending
  pf_run --ids E60_S01_T01
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "d['warnings'][0]['detail']")" = "story E60_S01 has no board file; epic E60 has no board file" ]
}

@test "--backlog excludes the other scope flags, and takes no id of its own" {
  write_mixed_todo
  pf_run --backlog --all
  assert_error 2 "exactly one scope flag"
  pf_run --all --backlog
  assert_error 2 "exactly one scope flag"
  pf_run --epic E01 --backlog
  assert_error 2 "exactly one scope flag"
  pf_run --ids E01 --backlog
  assert_error 2 "exactly one scope flag"
  pf_run --backlog E01
  assert_error 2 "unknown argument"
}

@test "--backlog is deterministic and read-only: same JSON twice, board and todo file untouched" {
  write_mixed_todo
  local before_board before_todo
  before_board="$(pf_tree_sum "$PF_ROOT")"
  before_todo="$(cksum < "$PF_TODO")"
  pf_run --backlog --items
  [ "$PF_RC" -eq 0 ]
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/first.json"
  pf_run --backlog --items
  cmp -s "$PF_OUT" "$BATS_TEST_TMPDIR/first.json"
  [ "$(pf_tree_sum "$PF_ROOT")" = "$before_board" ]
  [ "$(cksum < "$PF_TODO")" = "$before_todo" ]
}

@test "without JENGA_TODO_FILE and with --root, the todo file is <root>/project/todo.md" {
  printf 'Fixture queue: E01_S01_T01\n' > "$PF_ROOT/project/todo.md"
  PF_RC=0
  (cd "$BATS_TEST_TMPDIR" && env -u JENGA_TODO_FILE bash "$PF_SCRIPT" --root "$PF_ROOT" --backlog --items) > "$PF_OUT" 2> "$PF_ERR" || PF_RC=$?
  [ "$PF_RC" -eq 0 ]
  [ "$(ids_at tasks)" = '["E01_S01_T01"]' ]
}

@test "JENGA_TODO_FILE wins over <root>/project/todo.md" {
  printf 'Wrong queue: E01_S02\n' > "$PF_ROOT/project/todo.md"
  pf_todo "Right queue: E01_S01_T01"
  pf_run --backlog --items
  [ "$PF_RC" -eq 0 ]
  [ "$(ids_at tasks)" = '["E01_S01_T01"]' ]
  [ "$(pf_py "list(d['levels'])")" = '["tasks"]' ]
}
