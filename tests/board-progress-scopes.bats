#!/usr/bin/env bats
#
# E92_S01_T03: the --ids and --all scopes of scripts/board-progress.sh (contract: project/documentation/
# progress-visualisation.md sections 2, 3 and 8). Every test runs against the throwaway fixture board built by
# tests/helpers/progress-fixture.bash and never reads the live project/board/.
#
# Fixture facts used below: epics E01, E02, E03, E05, E06, E99, E100 (all Pending; E04 has stories and tasks but no epic
# file); 26 stories and 59 tasks in all; E01_S01 is Passed, E01_S02 is In Progress, E01_S01_T01 is Pending.

bats_require_minimum_version 1.5.0

load helpers/assertions
load helpers/progress-fixture

setup() { pf_setup; }

# assert_error <code> <stderr-fragment>: the last pf_run failed with <code>, said <fragment> on stderr, printed
# nothing on stdout.
assert_error() {
  [ "$PF_RC" -eq "$1" ]
  [ ! -s "$PF_OUT" ]
  grep -qF -- "$2" "$PF_ERR"
}

@test "--ids with a task, a story and an epic: one item in each block, each counted at its own level" {
  pf_run --ids E01_S01_T01,E01_S01,E01 --items
  [ "$PF_RC" -eq 0 ]
  [ ! -s "$PF_ERR" ]
  [ "$(pf_py "d['scope']")" = '{"type":"ids","ids":["E01_S01_T01","E01_S01","E01"]}' ]
  [ "$(pf_py "list(d['levels'])")" = '["tasks","stories","epics"]' ]
  [ "$(pf_py "d['levels']['tasks']['items']")" = '[{"id":"E01_S01_T01","status":"Pending"}]' ]
  [ "$(pf_py "d['levels']['stories']['items']")" = '[{"id":"E01_S01","status":"Passed"}]' ]
  [ "$(pf_py "d['levels']['epics']['items']")" = '[{"id":"E01","status":"Pending"}]' ]
  [ "$(pf_py "d['levels']['stories']['totals']")" = '{"done":1,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":1}' ]
  [ "$(pf_py "d['levels']['epics']['totals']")" = '{"done":0,"in_progress":0,"failed":0,"pending":1,"rejected":0,"unknown":0,"denominator":1}' ]
}

@test "--ids with one epic id: only the epics block, the epic is one item and its children are not counted" {
  pf_run --ids E06 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "list(d['levels'])")" = '["epics"]' ]
  [ "$(pf_py "d['levels']['epics']['items']")" = '[{"id":"E06","status":"Pending"}]' ]
  [ "$(pf_py "d['levels']['epics']['totals']['denominator']")" = "1" ]
}

@test "--ids with one story id: only the stories block, the story is one item and its tasks are not counted" {
  pf_run --ids E01_S02 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "list(d['levels'])")" = '["stories"]' ]
  [ "$(pf_py "d['levels']['stories']['items']")" = '[{"id":"E01_S02","status":"In Progress"}]' ]
  [ "$(pf_py "d['levels']['stories']['counts']")" = '{"In Progress":1}' ]
  [ "$(pf_py "d['levels']['stories']['totals']['in_progress']")" = "1" ]
}

@test "--ids with one task id: only the tasks block" {
  pf_run --ids E01_S02_T04
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "list(d['levels'])")" = '["tasks"]' ]
  [ "$(pf_py "d['levels']['tasks']['totals']")" = '{"done":0,"in_progress":0,"failed":0,"pending":0,"rejected":1,"unknown":0,"denominator":0}' ]
}

@test "--ids E1,E01 names epic 1 twice and counts it once" {
  pf_run --ids E1,E01 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "len(d['levels']['epics']['items'])")" = "1" ]
  [ "$(pf_py "d['levels']['epics']['items'][0]['id']")" = "E01" ]
  [ "$(pf_py "d['levels']['epics']['totals']['denominator']")" = "1" ]
  [ "$(pf_py "d['scope']['ids']")" = '["E1","E01"]' ]
}

@test "--ids is width-agnostic at every level and duplicates count once" {
  pf_run --ids E001_S001_T001,E1_S1_T1,E01_S01_T01 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "d['levels']['tasks']['items']")" = '[{"id":"E01_S01_T01","status":"Pending"}]' ]
  pf_run --ids E01_S01,E01_S01,E1_S1 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "len(d['levels']['stories']['items'])")" = "1" ]
}

@test "--ids tolerates a space after a comma, accepts --ids=<list> and may be repeated" {
  pf_run --ids "E01_S01, E01_S02 ,E06" --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "[i['id'] for i in d['levels']['stories']['items']]")" = '["E01_S01","E01_S02"]' ]
  [ "$(pf_py "[i['id'] for i in d['levels']['epics']['items']]")" = '["E06"]' ]
  pf_run --ids=E01_S01 --ids E01_S02 --ids "E06" --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "[i['id'] for i in d['levels']['stories']['items']]")" = '["E01_S01","E01_S02"]' ]
  [ "$(pf_py "[i['id'] for i in d['levels']['epics']['items']]")" = '["E06"]' ]
}

@test "--ids reports an orphan task it was asked for, exit code unchanged" {
  pf_run --ids E03_S01_T01
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "d['warnings']")" = '[{"kind":"orphan_task","id":"E03_S01_T01","detail":"story E03_S01 has no board file"}]' ]
}

@test "--ids --items lists every level in numeric id order, whatever order the ids were given in" {
  pf_run --ids E100_S2,E99_S100,E99_S2,E100_S100,E99_S10,E100_S10 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "[i['id'] for i in d['levels']['stories']['items']]")" = '["E99_S2","E99_S10","E99_S100","E100_S2","E100_S10","E100_S100"]' ]
  pf_run --ids E99_S10_T100,E99_S10_T2,E99_S10_T10 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "[i['id'] for i in d['levels']['tasks']['items']]")" = '["E99_S10_T2","E99_S10_T10","E99_S10_T100"]' ]
}

@test "E99 sorts before E100 at the epics level, for --ids and for --all" {
  pf_run --ids E100,E99,E01 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "[i['id'] for i in d['levels']['epics']['items']]")" = '["E01","E99","E100"]' ]
  pf_run --all --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "[i['id'] for i in d['levels']['epics']['items']]")" = '["E01","E02","E03","E05","E06","E99","E100"]' ]
}

@test "an unknown id exits 2, names the id on stderr and prints nothing on stdout" {
  pf_run --ids E07
  assert_error 2 "board-progress.sh: unknown id: E07"
  pf_run --ids E01,E01_S01,E07_S01
  assert_error 2 "unknown id: E07_S01"
  pf_run --ids E01_S09
  assert_error 2 "unknown id: E01_S09"
  pf_run --ids E01_S01_T99
  assert_error 2 "unknown id: E01_S01_T99"
  pf_run --ids E03_S01
  assert_error 2 "unknown id: E03_S01"
  pf_run --ids E04
  assert_error 2 "unknown id: E04"
}

@test "a malformed id exits 2, names the value on stderr and prints nothing on stdout" {
  local bad
  for bad in X12 E1_T3 e1 E1_S T3 E01_S01_T01_X "E1 E2" E1__S2; do
    pf_run --ids "$bad"
    assert_error 2 "malformed id '$bad'"
  done
  pf_run --ids E01,X12
  assert_error 2 "malformed id 'X12'"
}

@test "an empty element inside the list is malformed, not skipped" {
  pf_run --ids "E01,,E06"
  assert_error 2 "malformed id ''"
  pf_run --ids "E01,"
  assert_error 2 "malformed id ''"
  pf_run --ids ","
  assert_error 2 "malformed id ''"
}

@test "an empty --ids list exits 2" {
  pf_run --ids ""
  assert_error 2 "empty --ids list"
  pf_run --ids "   "
  assert_error 2 "empty --ids list"
  pf_run --ids "" --ids ""
  assert_error 2 "empty --ids list"
  pf_run --ids
  assert_error 2 "--ids needs"
}

@test "an empty value among non-empty --ids flags is ignored" {
  pf_run --ids "" --ids E06 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "[i['id'] for i in d['levels']['epics']['items']]")" = '["E06"]' ]
}

@test "--all returns the three levels, tasks then stories then epics, with every item of the board" {
  pf_run --all --items
  [ "$PF_RC" -eq 0 ]
  [ ! -s "$PF_ERR" ]
  [ "$(pf_py "d['scope']")" = '{"type":"all","ids":[]}' ]
  [ "$(pf_py "list(d['levels'])")" = '["tasks","stories","epics"]' ]
  [ "$(pf_py "len(d['levels']['tasks']['items'])")" = "59" ]
  [ "$(pf_py "len(d['levels']['stories']['items'])")" = "26" ]
  [ "$(pf_py "len(d['levels']['epics']['items'])")" = "7" ]
  [ "$(pf_py "d['levels']['epics']['totals']")" = '{"done":0,"in_progress":0,"failed":0,"pending":7,"rejected":0,"unknown":0,"denominator":7}' ]
}

@test "--all without --items has counts and totals but no items list" {
  pf_run --all
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "sorted(d['levels']['tasks'])")" = '["counts","totals"]' ]
  [ "$(pf_py "sum(d['levels']['tasks']['counts'].values())")" = "59" ]
}

@test "--all task items are in numeric id order across epics of different digit counts" {
  pf_run --all --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py '(lambda ids: str(ids == sorted(ids, key=lambda s: tuple(int(x[1:]) for x in s.split("_")))))([i["id"] for i in d["levels"]["tasks"]["items"]])')" = "True" ]
  [ "$(pf_py "d['levels']['tasks']['items'][-1]['id']")" = "E100_S100_T100" ]
}

@test "--all per-level totals equal the sum of the per-epic --epic results over the same board" {
  # E04 has stories and tasks but no epic file, so no --epic run can reach it: take it off this test's own copy.
  rm -f "$PF_ROOT"/project/board/stories/E04_* "$PF_ROOT"/project/board/tasks/E04_*
  pf_run --all
  [ "$PF_RC" -eq 0 ]
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/all.json"
  local e n=0
  for e in E01 E03 E05 E06 E99 E100; do
    pf_run --epic "$e"
    [ "$PF_RC" -eq 0 ]
    cp "$PF_OUT" "$BATS_TEST_TMPDIR/epic-$e.json"
    n=$((n + 1))
  done
  [ "$n" -eq 6 ]
  # E02 is an empty epic: exit 3, contributes nothing to stories or tasks
  pf_run --epic E02
  [ "$PF_RC" -eq 3 ]
  python3 -I - "$BATS_TEST_TMPDIR" <<'PY'
import json, sys, glob
d = sys.argv[1]
allj = json.load(open(d + "/all.json"))
for level in ("tasks", "stories"):
    sums = {"counts": {}, "totals": {}}
    for f in sorted(glob.glob(d + "/epic-*.json")):
        blk = json.load(open(f))["levels"][level]
        for part in ("counts", "totals"):
            for k, v in blk[part].items():
                sums[part][k] = sums[part].get(k, 0) + v
    want = allj["levels"][level]
    assert sums["totals"] == want["totals"], (level, sums["totals"], want["totals"])
    assert sums["counts"] == want["counts"], (level, sums["counts"], want["counts"])
    assert want["totals"]["denominator"] > 0
PY
}

@test "--all on a board with no items exits 3 with a stderr message and nothing on stdout" {
  PF_ROOT="$BATS_TEST_TMPDIR/empty-board"
  mkdir -p "$PF_ROOT/project/configs" "$PF_ROOT/project/board/epics" "$PF_ROOT/project/board/stories" "$PF_ROOT/project/board/tasks"
  printf '{}\n' > "$PF_ROOT/project/configs/workflow.json"
  pf_run --all
  assert_error 3 "empty scope"
}

@test "--ids and --all are deterministic: byte-identical output on repeated runs" {
  pf_run --ids E01_S01_T01,E01_S01,E01,E99_S10 --items
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/ids-1.json"
  pf_run --ids E01_S01_T01,E01_S01,E01,E99_S10 --items
  cmp "$BATS_TEST_TMPDIR/ids-1.json" "$PF_OUT"
  pf_run --all --items
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/all-1.json"
  pf_run --all --items
  cmp "$BATS_TEST_TMPDIR/all-1.json" "$PF_OUT"
}

@test "the output is valid JSON for --ids and --all" {
  pf_run --ids E01_S01_T01,E01_S01,E01 --items
  python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$PF_OUT"
  pf_run --all --items
  python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$PF_OUT"
}

@test "exactly one scope flag: --ids with --all, --epic or --story, and a stray argument to --all, exit 2" {
  pf_run --ids E01 --all
  assert_error 2 "exactly one scope flag"
  pf_run --all --ids E01
  assert_error 2 "exactly one scope flag"
  pf_run --epic E01 --ids E01
  assert_error 2 "exactly one scope flag"
  pf_run --ids E01 --story E01_S01
  assert_error 2 "exactly one scope flag"
  pf_run --all E01
  assert_error 2 "unknown argument: E01"
}

@test "--ids and --all write nothing: the fixture tree is unchanged" {
  local before after
  before="$(pf_tree_sum "$PF_ROOT")"
  pf_run --ids E01,E01_S01,E01_S01_T01 --items
  pf_run --all --items
  after="$(pf_tree_sum "$PF_ROOT")"
  [ "$before" = "$after" ]
}
