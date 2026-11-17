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

# E92_S10_T01: waiting_on states the unsatisfied effective ids (own depends_on, then the story's, each once) for EVERY task
# not in the done bucket, so the padlock gate never re-derives satisfaction.
waiting() {
  mkroot waiting
  item E01 "In Progress"
  item E01_S01 Pending
  item E01_S02 Pending "depends_on: E01_S01"
  item E01_S01_T01 Pending
  item E01_S01_T02 Rejected
  item E01_S01_T03 Passed
  item E01_S01_T04 "In Progress" "depends_on: [E01_S01_T01, E01_S01_T03]"
  item E01_S01_T05 Failed "depends_on: E01_S01_T01"
  item E01_S01_T06 Passed "depends_on: E01_S01_T01"
  item E01_S01_T07 "In Progress" "depends_on: E01_S01_T02, E01_S01_T03"
  item E01_S01_T08 Pending "depends_on: E01_S01_T02"
  item E01_S01_T09 "Some Odd Status" "depends_on: E01_S01_T01"
  item E01_S02_T01 Rejected
  item E01_S02_T02 "In Progress" "depends_on: E01_S01_T01"
  item E01_S02_T03 Passed
  item E01_S02_T04 Pending
}

@test "E92_S10_T01: waiting_on lists the unsatisfied effective ids of every task that is not done, [] for a done task" {
  waiting
  run_graph --graph
  [ "$RC" -eq 0 ]
  [ "$(task E01_S01_T04 waiting_on)" = '["E01_S01_T01"]' ]                # in progress: only the unfinished own id
  [ "$(task E01_S01_T05 waiting_on)" = '["E01_S01_T01"]' ]                # failed
  [ "$(task E01_S01_T06 waiting_on)" = '[]' ]                             # done: never waits
  [ "$(task E01_S01_T07 waiting_on)" = '[]' ]                             # rejected and done dependencies are satisfied
  [ "$(task E01_S01_T08 waiting_on)" = '[]' ]                             # ready
  [ "$(task E01_S01_T09 waiting_on)" = '["E01_S01_T01"]' ]                # unknown status
  [ "$(task E01_S02_T01 waiting_on)" = '["E01_S01"]' ]                    # rejected, its story waits
  [ "$(task E01_S02_T02 waiting_on)" = '["E01_S01_T01","E01_S01"]' ]      # own first, then the story's
  [ "$(task E01_S02_T03 waiting_on)" = '[]' ]                             # done although its story waits
  [ "$(task E01_S02_T04 waiting_on)" = '["E01_S01"]' ]                    # locked only through its story
  # for a pending task waiting_on is blocked_by; blocked_by keeps its meaning ([] unless locked)
  [ "$(py 'all(t["waiting_on"] == t["blocked_by"] for t in d["tasks"] if t["bucket"] == "pending")')" = "true" ]
  [ "$(py 'all(t["blocked_by"] == [] for t in d["tasks"] if t["state"] != "locked")')" = "true" ]
  [ "$(py 'all(t["waiting_on"] == [] for t in d["tasks"] if t["bucket"] == "done")')" = "true" ]
  # the key sits after blocked_by, in --within payloads too (E92_S11_T02: unfinished_deps follows it, see below)
  [ "$(py 'list(d["tasks"][0].keys())')" = '["id","story_id","epic_id","title","status","bucket","state","depends_on","blocked_by","waiting_on","unfinished_deps","unlocked_by"]' ]
  run_graph --graph --within E01_S02
  [ "$(task E01_S02_T02 waiting_on)" = '["E01_S01_T01","E01_S01"]' ]
}

@test "E92_S10_T01: the padlock gate of the shared structure follows waiting_on for every task state" {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  waiting
  run_graph --graph
  [ "$RC" -eq 0 ]
  run node --input-type=module -e '
    import { pathToFileURL } from "url";
    import fs from "fs";
    const { buildDependencyStructure } = await import(pathToFileURL(process.argv[1]).href);
    const g = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const s = buildDependencyStructure(g, "E01", {});
    console.log(s.tasks.map((t) => t.id.slice(4) + ":" + t.gate).join(","));
  ' "$BATS_TEST_DIRNAME/../lib/progress/dependency-structure.js" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "S01_T01:none,S01_T02:none,S01_T03:none,S01_T04:locked,S01_T05:locked,S01_T06:open,S01_T07:open,S01_T08:open,S01_T09:locked,S02_T01:locked,S02_T02:locked,S02_T03:open,S02_T04:locked" ]
}

# E92_S11_T02 (user decision 2026-11-15: a task done before its dependency did not really depend on it, so flag it):
# unfinished_deps states, for a task IN the done bucket, the effective ids it would wait on if it were not done (same rule
# as waiting_on: own depends_on, then the story's, each once; satisfied = done bucket by own status, or rejected).
unfinished() {
  mkroot unfinished
  item E01 "In Progress"
  item E01_S01 "In Progress"
  item E01_S02 Pending "depends_on: E01_S01"
  item E01_S03 Passed
  item E01_S01_T01 Passed
  item E01_S01_T02 Failed "dates_previously_completed: [2026-11-01]"
  item E01_S01_T03 Rejected
  item E01_S01_T04 Passed "depends_on: [E01_S01_T01, E01_S01_T02]"
  item E01_S01_T05 Passed "depends_on: E01_S01_T03"
  item E01_S01_T06 "In Progress" "depends_on: E01_S01_T02"
  item E01_S01_T07 Pending "depends_on: E01_S01_T02"
  item E01_S01_T08 Merged "depends_on: E01_S01_T02"
  item E01_S02_T01 Passed
  item E01_S02_T02 Passed "depends_on: E01_S01_T02"
  item E01_S03_T01 Passed "depends_on: E01_S01_T01"
}

@test "E92_S11_T02: unfinished_deps lists the unsatisfied effective ids of a done task, [] for every other task" {
  unfinished
  run_graph --graph
  [ "$RC" -eq 0 ]
  [ "$(task E01_S01_T04 unfinished_deps)" = '["E01_S01_T02"]' ]            # done, its own dependency was reopened (Failed)
  [ "$(task E01_S02_T01 unfinished_deps)" = '["E01_S01"]' ]                # done, its story's dependency is not done
  [ "$(task E01_S02_T02 unfinished_deps)" = '["E01_S01_T02","E01_S01"]' ]  # own first, then the story's, each once
  [ "$(task E01_S01_T05 unfinished_deps)" = '[]' ]                         # done, its only dependency is rejected
  [ "$(task E01_S03_T01 unfinished_deps)" = '[]' ]                         # done, its dependency is done
  [ "$(task E01_S01_T08 unfinished_deps)" = '["E01_S01_T02"]' ]            # a ladder status (Merged) is in the done bucket
  [ "$(task E01_S01_T06 unfinished_deps)" = '[]' ]                         # in progress: not done, so it waits instead
  [ "$(task E01_S01_T07 unfinished_deps)" = '[]' ]                         # pending (locked)
  [ "$(task E01_S01_T02 unfinished_deps)" = '[]' ]                         # failed, no dependency
  # the flag changes nothing else: the task stays done, in the done bucket, never waits and is never blocked
  [ "$(task E01_S01_T04 state)" = "done" ]
  [ "$(task E01_S01_T04 bucket)" = "done" ]
  [ "$(task E01_S01_T04 waiting_on)" = '[]' ]
  [ "$(task E01_S01_T04 blocked_by)" = '[]' ]
  [ "$(task E01_S01_T06 waiting_on)" = '["E01_S01_T02"]' ]
  # never both: waiting_on and unfinished_deps hold ids for different buckets
  [ "$(py 'all(t["unfinished_deps"] == [] for t in d["tasks"] if t["bucket"] != "done")')" = "true" ]
  [ "$(py 'all(not (t["waiting_on"] and t["unfinished_deps"]) for t in d["tasks"])')" = "true" ]
  # the done counts are unchanged: every flagged task is counted as done in the story and epic totals
  [ "$(py '[s["totals"]["done"] for s in d["stories"]]')" = '[4,2,1]' ]
  [ "$(py 'd["epics"][0]["tasks"]["totals"]["done"]')" = "7" ]
  # --within keeps the key and its value (state is computed over the whole board first)
  run_graph --graph --within E01_S02
  [ "$RC" -eq 0 ]
  [ "$(task E01_S02_T02 unfinished_deps)" = '["E01_S01_T02","E01_S01"]' ]
  # --counts-only has no tasks array, so no key to state
  run_graph --graph --counts-only
  [ "$(py '"tasks" in d')" = "false" ]
}

@test "E92_S11_T02: unfinished_deps leaves the padlock gate of the shared structure unchanged (a done task keeps the open one)" {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  unfinished
  run_graph --graph
  [ "$RC" -eq 0 ]
  run node --input-type=module -e '
    import { pathToFileURL } from "url";
    import fs from "fs";
    const { buildDependencyStructure } = await import(pathToFileURL(process.argv[1]).href);
    const g = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const s = buildDependencyStructure(g, "E01", {});
    console.log(s.tasks.map((t) => t.id.slice(4) + ":" + t.gate + ":" + (t.unfinishedDeps || []).join("+")).join(","));
  ' "$BATS_TEST_DIRNAME/../lib/progress/dependency-structure.js" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "S01_T01:none:,S01_T02:none:,S01_T03:none:,S01_T04:open:E01_S01_T02,S01_T05:open:,S01_T06:locked:,S01_T07:locked:,S01_T08:open:E01_S01_T02,S02_T01:open:E01_S01,S02_T02:open:E01_S01_T02+E01_S01,S03_T01:open:" ]
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
