#!/usr/bin/env bats
#
# E92_S06_T02: task states (ready, locked, ...), blocked_by, unlocked_by, ready, ready_count, external and --within of the
# --graph mode of scripts/board-progress.sh. Fixture only, built under $BATS_TEST_TMPDIR; the live board is never read.

bats_require_minimum_version 1.5.0

load helpers/assertions

SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/board-progress.sh"

item() {
  local id="$1" status="$2" dir f l
  shift 2
  case "$id" in
    *_T*) dir=tasks ;;
    *_S*) dir=stories ;;
    *)    dir=epics ;;
  esac
  f="$ROOT/project/board/$dir/${id}_x.md"
  { printf -- '---\nid: %s\ntitle: "Title of %s"\nstatus: %s\n' "$id" "$id" "$status"
    case "$id" in
      *_T*) printf 'story_id: %s\nepic_id: %s\n' "${id%_T*}" "${id%%_*}" ;;
      *_S*) printf 'epic_id: %s\n' "${id%%_*}" ;;
    esac
    for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n\n# body\n'
  } > "$f"
}

mkroot() {
  ROOT="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$ROOT/project/configs" "$ROOT/project/board/epics" "$ROOT/project/board/stories" "$ROOT/project/board/tasks"
  printf '{}\n' > "$ROOT/project/configs/workflow.json"
}

# E01: S01 (done work) and S02 (in progress, depends on S01); E02 depends on E01 and holds S01 with an outside edge.
states() {
  mkroot states
  item E01 "In Progress"
  item E02 Pending "depends_on: E01"
  item E01_S01 Passed
  item E01_S02 "In Progress" "depends_on: E01_S01"
  item E01_S03 Pending "depends_on: E01_S02"
  item E02_S01 Pending
  item E01_S01_T01 Passed "date_completed: 2026-11-01"
  item E01_S01_T02 "Passed with remarks" "date_completed: 2026-11-05"
  item E01_S01_T03 Rejected
  item E01_S02_T01 "In Progress" "depends_on: [E01_S01_T01, E01_S01_T02]"
  item E01_S02_T02 Pending "depends_on: E01_S01_T01"
  item E01_S02_T03 Pending "depends_on: E01_S02_T01"
  item E01_S02_T04 Failed
  item E01_S02_T05 Pending "depends_on: E01_S02_T04"
  item E01_S02_T06 Pending "depends_on: E01_S01_T03"
  item E01_S03_T01 Pending
  item E01_S03_T02 Pending "depends_on: E01_S01_T01"
  item E02_S01_T01 Pending "depends_on: E01_S02_T01, E01_S01_T01"
}

run_graph() {
  RC=0
  bash "$SCRIPT" --root "$ROOT" "$@" > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err" || RC=$?
}

py() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = eval(sys.argv[2])
print(v if isinstance(v, str) else json.dumps(v, separators=(",", ":")))
' "${2:-$BATS_TEST_TMPDIR/out}" "$1"
}

task() { py '[t for t in d["tasks"] if t["id"]=="'"$1"'"][0]["'"$2"'"]'; }

@test "every state is produced: done, in_progress, failed, rejected, ready, locked" {
  states
  run_graph --graph
  [ "$RC" -eq 0 ]
  [ "$(task E01_S01_T01 state)" = "done" ]
  [ "$(task E01_S01_T02 state)" = "done" ]
  [ "$(task E01_S02_T01 state)" = "in_progress" ]
  [ "$(task E01_S02_T04 state)" = "failed" ]
  [ "$(task E01_S01_T03 state)" = "rejected" ]
  [ "$(task E01_S02_T02 state)" = "ready" ]
  [ "$(task E01_S02_T03 state)" = "locked" ]
}

@test "a dependency on a failed item keeps the task locked, a rejected dependency is satisfied" {
  states
  run_graph --graph
  [ "$(task E01_S02_T05 state)" = "locked" ]
  [ "$(task E01_S02_T05 blocked_by)" = '["E01_S02_T04"]' ]
  [ "$(task E01_S02_T06 state)" = "ready" ]
}

@test "a story-level dependency locks a pending task whose own dependencies are satisfied" {
  states
  run_graph --graph
  # E01_S03 depends on E01_S02, which is In Progress (its own status): the tasks are locked although T01 has no dependency
  [ "$(task E01_S03_T01 state)" = "locked" ]
  [ "$(task E01_S03_T01 blocked_by)" = '["E01_S02"]' ]
  [ "$(task E01_S03_T02 state)" = "locked" ]
  [ "$(task E01_S03_T02 blocked_by)" = '["E01_S02"]' ]
}

@test "a story counts as done through its own status, not through its tasks" {
  states
  # make the story done by its own status while one task is still pending
  item E01_S02 Passed "depends_on: E01_S01"
  run_graph --graph
  [ "$(task E01_S03_T01 state)" = "ready" ]
  # and a story whose tasks are all done but whose own status is Pending does not unlock
  item E01_S02 Pending "depends_on: E01_S01"
  run_graph --graph
  [ "$(task E01_S03_T01 state)" = "locked" ]
}

@test "blocked_by is exactly the unsatisfied ids for a locked task and empty otherwise" {
  states
  run_graph --graph
  [ "$(task E01_S02_T03 blocked_by)" = '["E01_S02_T01"]' ]
  [ "$(task E02_S01_T01 blocked_by)" = '["E01_S02_T01"]' ]
  [ "$(py 'all(t["blocked_by"] == [] for t in d["tasks"] if t["state"] != "locked")')" = "true" ]
  [ "$(py 'all(t["blocked_by"] != [] for t in d["tasks"] if t["state"] == "locked")')" = "true" ]
}

@test "unlocked_by picks the latest date_completed dependency" {
  states
  run_graph --graph
  # T01 finished 2026-11-01, T02 2026-11-05
  [ "$(task E01_S02_T01 unlocked_by)" = "E01_S01_T02" ]
  # in a locked task unlocked_by is null; a task with no dependency has none either
  [ "$(task E01_S02_T03 unlocked_by)" = "null" ]
  [ "$(task E01_S01_T02 unlocked_by)" = "null" ]
  [ "$(task E01_S02_T02 unlocked_by)" = "E01_S01_T01" ]
}

@test "unlocked_by falls back to the larger numeric id on a tie and on missing dates" {
  states
  item E01_S01_T01 Passed "date_completed: 2026-11-05"
  run_graph --graph
  [ "$(task E01_S02_T01 unlocked_by)" = "E01_S01_T02" ]
  item E01_S01_T01 Passed
  item E01_S01_T02 Passed
  run_graph --graph
  [ "$(task E01_S02_T01 unlocked_by)" = "E01_S01_T02" ]
  # numeric, not lexical: T10 is after T9
  item E01_S01_T09 Passed
  item E01_S01_T10 Passed
  item E01_S02_T01 "In Progress" "depends_on: [E01_S01_T10, E01_S01_T09]"
  run_graph --graph
  [ "$(task E01_S02_T01 unlocked_by)" = "E01_S01_T10" ]
}

@test "ready and ready_count agree with the per-task states" {
  states
  run_graph --graph
  [ "$(py 'd["ready"]')" = '["E01_S02_T02","E01_S02_T06"]' ]
  [ "$(py '[t["id"] for t in d["tasks"] if t["state"]=="ready"]')" = "$(py 'd["ready"]')" ]
  [ "$(py '[[s["id"], s["ready_count"]] for s in d["stories"]]')" = '[["E01_S01",0],["E01_S02",2],["E01_S03",0],["E02_S01",0]]' ]
  [ "$(py '[[e["id"], e["ready_count"]] for e in d["epics"]]')" = '[["E01",2],["E02",0]]' ]
  [ "$(py 'sum(e["ready_count"] for e in d["epics"]) == len(d["ready"])')" = "true" ]
}

@test "ready is in numeric id order" {
  mkroot order
  item E01 Pending
  item E01_S01 Pending
  item E01_S01_T10 Pending
  item E01_S01_T02 Pending
  item E01_S01_T09 Pending
  run_graph --graph
  [ "$(py 'd["ready"]')" = '["E01_S01_T02","E01_S01_T09","E01_S01_T10"]' ]
}

@test "an unknown dependency id does not lock and gives an unknown_dependency warning" {
  mkroot unknown
  item E01 Pending
  item E01_S01 Pending
  item E01_S01_T01 Pending "depends_on: E01_S01_T77"
  run_graph --graph
  [ "$RC" -eq 0 ]
  [ "$(task E01_S01_T01 state)" = "ready" ]
  [ "$(task E01_S01_T01 blocked_by)" = "[]" ]
  [ "$(task E01_S01_T01 unlocked_by)" = "null" ]
  [ "$(py '[[w["kind"], w["id"]] for w in d["warnings"]]')" = '[["unknown_dependency","E01_S01_T01"]]' ]
  [ "$(py 'list(d["warnings"][0].keys())')" = '["kind","id","detail"]' ]
}

@test "a cycle terminates, both tasks are locked, dependency_cycle warnings" {
  mkroot cycle
  item E01 Pending
  item E01_S01 Pending
  item E01_S01_T01 Pending "depends_on: E01_S01_T02"
  item E01_S01_T02 Pending "depends_on: E01_S01_T01"
  run timeout 20 bash "$SCRIPT" --root "$ROOT" --graph
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/out"
  [ "$(task E01_S01_T01 state)" = "locked" ]
  [ "$(task E01_S01_T02 state)" = "locked" ]
  [ "$(task E01_S01_T01 blocked_by)" = '["E01_S01_T02"]' ]
  [ "$(py '[w["id"] for w in d["warnings"] if w["kind"]=="dependency_cycle"]')" = '["E01_S01_T01","E01_S01_T02"]' ]
  [ "$(py 'd["ready"]')" = "[]" ]
}

@test "a task depending on its own story stays locked until the story is done by its own status" {
  mkroot ownstory
  item E01 Pending
  item E01_S01 "In Progress"
  item E01_S01_T01 Pending "depends_on: E01_S01"
  run_graph --graph
  [ "$RC" -eq 0 ]
  [ "$(task E01_S01_T01 state)" = "locked" ]
  [ "$(task E01_S01_T01 blocked_by)" = '["E01_S01"]' ]
  item E01_S01 Passed
  run_graph --graph
  [ "$(task E01_S01_T01 state)" = "ready" ]
}

@test "a dependency on an epic is satisfied through the epic's own status" {
  mkroot epicdep
  item E01 "In Progress"
  item E02 Pending
  item E02_S01 Pending
  item E02_S01_T01 Pending "depends_on: E01"
  run_graph --graph
  [ "$(task E02_S01_T01 state)" = "locked" ]
  [ "$(task E02_S01_T01 blocked_by)" = '["E01"]' ]
  item E01 Passed
  run_graph --graph
  [ "$(task E02_S01_T01 state)" = "ready" ]
}

@test "--within an epic restricts the output and lists outside referenced items under external" {
  states
  run_graph --graph --within E02
  [ "$RC" -eq 0 ]
  [ "$(py 'd["scope"]')" = '{"type":"graph","within":"E02"}' ]
  [ "$(py '[e["id"] for e in d["epics"]]')" = '["E02"]' ]
  [ "$(py '[s["id"] for s in d["stories"]]')" = '["E02_S01"]' ]
  [ "$(py '[t["id"] for t in d["tasks"]]')" = '["E02_S01_T01"]' ]
  # edges to outside items stay in depends_on; each outside item referenced is listed once
  [ "$(task E02_S01_T01 depends_on)" = '["E01_S02_T01","E01_S01_T01"]' ]
  [ "$(py 'd["external"]')" = '[{"id":"E01","status":"In Progress","bucket":"in_progress"},{"id":"E01_S01_T01","status":"Passed","bucket":"done"},{"id":"E01_S02_T01","status":"In Progress","bucket":"in_progress"}]' ]
  # the state is computed over the whole board
  [ "$(task E02_S01_T01 state)" = "locked" ]
}

@test "--within a story restricts to the story, width-agnostic, with no epic listed" {
  states
  run_graph --graph --within E1_S2
  [ "$RC" -eq 0 ]
  [ "$(py 'd["scope"]["within"]')" = "E01_S02" ]
  [ "$(py '[e["id"] for e in d["epics"]]')" = "[]" ]
  [ "$(py '[s["id"] for s in d["stories"]]')" = '["E01_S02"]' ]
  [ "$(py '[t["id"] for t in d["tasks"]]')" = '["E01_S02_T01","E01_S02_T02","E01_S02_T03","E01_S02_T04","E01_S02_T05","E01_S02_T06"]' ]
  [ "$(py '[x["id"] for x in d["external"]]')" = '["E01_S01","E01_S01_T01","E01_S01_T02","E01_S01_T03"]' ]
  [ "$(py 'd["ready"]')" = '["E01_S02_T02","E01_S02_T06"]' ]
  run_graph --graph --within=E01_S02
  [ "$RC" -eq 0 ]
}

@test "--within with --counts-only still has ready and external, and no tasks" {
  states
  run_graph --graph --counts-only --within E01
  [ "$RC" -eq 0 ]
  [ "$(py '"tasks" in d')" = "false" ]
  [ "$(py 'd["ready"]')" = '["E01_S02_T02","E01_S02_T06"]' ]
  [ "$(py '"external" in d')" = "true" ]
}

@test "without --within there is no external key" {
  states
  run_graph --graph
  [ "$(py '"external" in d')" = "false" ]
}

@test "--within without --graph, with a task id, with an unknown or malformed id exits 2" {
  states
  run_graph --all --within E01;                      [ "$RC" -eq 2 ]; [ ! -s "$BATS_TEST_TMPDIR/out" ]
  run_graph --graph --within E01_S02_T01;            [ "$RC" -eq 2 ]; [ ! -s "$BATS_TEST_TMPDIR/out" ]
  run_graph --graph --within E99;                    [ "$RC" -eq 2 ]; [ ! -s "$BATS_TEST_TMPDIR/out" ]
  run_graph --graph --within E01_S99;                [ "$RC" -eq 2 ]
  run_graph --graph --within nonsense;               [ "$RC" -eq 2 ]
  run_graph --graph --within "";                     [ "$RC" -eq 2 ]
  run_graph --graph --within;                        [ "$RC" -eq 2 ]
}

@test "output is byte-identical across runs and writes nothing" {
  states
  before="$(find "$ROOT" -type f | sort | xargs cksum)"
  run_graph --graph --within E01
  cp "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/a.json"
  run_graph --graph --within E01
  cmp "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/out"
  [ "$(find "$ROOT" -type f | sort | xargs cksum)" = "$before" ]
}
