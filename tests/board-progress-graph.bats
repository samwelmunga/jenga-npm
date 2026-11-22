#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E92_S06_T01: the --graph mode of scripts/board-progress.sh (batch call: counts plus depends_on edges per epic, story, task).
# Fixture only, built under $BATS_TEST_TMPDIR; the live project/board/ is never read.

bats_require_minimum_version 1.5.0

load helpers/assertions

SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/board-progress.sh"

# item <id> <status> [raw frontmatter lines...]: writes one board file under $ROOT.
item() {
  local id="$1" status="$2" dir f
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
    local l
    for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n\n# body\n'
  } > "$f"
}

mkroot() {
  ROOT="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$ROOT/project/configs" "$ROOT/project/board/epics" "$ROOT/project/board/stories" "$ROOT/project/board/tasks"
  printf '{}\n' > "$ROOT/project/configs/workflow.json"
}

# Two epics, three stories, seven tasks; every depends_on form once.
basic() {
  mkroot basic
  item E01 Passed "depends_on:"
  item E02 "In Progress" "depends_on: E1"
  item E01_S01 Passed "depends_on: []"
  item E01_S02 "In Progress" "depends_on: E01_S01, E01_S09"
  item E02_S01 Pending "depends_on: [E01_S01, E1_S2]"
  item E01_S01_T01 Passed "depends_on:" "  - E01_S01_T02" "  - E01_S01_T03"
  item E01_S01_T02 "Passed with remarks" "depends_on: none"
  item E01_S01_T03 Merged
  item E01_S02_T01 "In Progress" "depends_on: E01_S01_T01"
  item E01_S02_T02 Pending "depends_on: E01_S02_T01, E01_S01_T02"
  item E02_S01_T01 Pending "depends_on: [E01_S02_T01, E1_S2_T2]"
  item E02_S01_T02 Rejected
}

# One story per stop case, all under E03.
stops() {
  mkroot stops
  item E03 Pending
  item E03_S01 Passed;  item E03_S01_T01 Passed; item E03_S01_T02 "Passed with remarks"
  item E03_S02 Pending; item E03_S02_T01 "In Progress"; item E03_S02_T02 Pending
  item E03_S03 Pending; item E03_S03_T01 Failed; item E03_S03_T02 Passed
  item E03_S04 Pending; item E03_S04_T01 Pending
  item E03_S05 Pending; item E03_S05_T01 Rejected; item E03_S05_T02 Rejected
  item E03_S06 Rejected; item E03_S06_T01 Passed
  item E03_S07 Pending; item E03_S07_T01 Passed; item E03_S07_T02 Pending
}

run_graph() {
  RC=0
  bash "$SCRIPT" --root "$ROOT" "$@" > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err" || RC=$?
}

# py '<expression over d>' [file]: the expression evaluated on the JSON of the last run.
py() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = eval(sys.argv[2])
print(v if isinstance(v, str) else json.dumps(v, separators=(",", ":")))
' "${2:-$BATS_TEST_TMPDIR/out}" "$1"
}

@test "shape: ordered keys, ordered ids, jq accepts it, nothing on stderr" {
  basic
  run_graph --graph
  [ "$RC" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
  python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$BATS_TEST_TMPDIR/out"
  if command -v jq >/dev/null 2>&1; then jq . "$BATS_TEST_TMPDIR/out" >/dev/null; fi
  [ "$(py 'list(d.keys())')" = '["schema_version","scope","epics","stories","tasks","ready","warnings"]' ]
  [ "$(py 'd["schema_version"]')" = "1" ]
  [ "$(py 'd["scope"]')" = '{"type":"graph"}' ]
  [ "$(py '[e["id"] for e in d["epics"]]')" = '["E01","E02"]' ]
  [ "$(py '[s["id"] for s in d["stories"]]')" = '["E01_S01","E01_S02","E02_S01"]' ]
  [ "$(py 'len(d["tasks"])')" = "7" ]
  # E92_S09_T03: every epic entry gains epic_progress (the epic percent that counts undecomposed stories) between tasks and
  # ready_count; an added key, so schema_version stays 1 and stories/tasks keep their keys (asserted on the next lines).
  [ "$(py 'list(d["epics"][0].keys())')" = '["id","title","depends_on","stories","tasks","epic_progress","ready_count"]' ]
  # E92_S10_T02: epic_progress gains failed_stories after goal_reached (an added key).
  [ "$(py 'list(d["epics"][0]["epic_progress"].keys())')" = '["stories","decomposed","tasks_done","tasks_denominator","percent","goal_reached","failed_stories"]' ]
  [ "$(py 'list(d["epics"][0]["stories"].keys())')" = '["totals","complete"]' ]
  [ "$(py 'list(d["epics"][0]["tasks"].keys())')" = '["totals"]' ]
  # E92_S12_T01: stories gain decomposed after complete (an added key; schema_version stays 1, nothing else changes).
  [ "$(py 'list(d["stories"][0].keys())')" = '["id","epic_id","title","depends_on","totals","complete","decomposed","stop","ready_count"]' ]
  # E92_S10_T01: tasks gain waiting_on after blocked_by (an added key; blocked_by keeps its meaning, schema_version stays 1).
  # E92_S11_T02: and unfinished_deps after waiting_on (an added key: the unsatisfied effective ids of a DONE task).
  [ "$(py 'list(d["tasks"][0].keys())')" = '["id","story_id","epic_id","title","status","bucket","state","depends_on","blocked_by","waiting_on","unfinished_deps","unlocked_by"]' ]
  [ "$(py 'd["tasks"][0]["title"]')" = "Title of E01_S01_T01" ]
}

@test "totals equal the --epic and --story totals for the same ids" {
  basic
  run_graph --graph
  cp "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/graph.json"
  for e in E01 E02; do
    run_graph --epic "$e"
    a="$(py 'json.dumps(d["levels"]["stories"]["totals"], sort_keys=True)')"
    b="$(py 'json.dumps([x for x in d["epics"] if x["id"]=="'"$e"'"][0]["stories"]["totals"], sort_keys=True)' "$BATS_TEST_TMPDIR/graph.json")"
    [ "$a" = "$b" ]
    a="$(py 'json.dumps(d["levels"]["tasks"]["totals"], sort_keys=True)')"
    b="$(py 'json.dumps([x for x in d["epics"] if x["id"]=="'"$e"'"][0]["tasks"]["totals"], sort_keys=True)' "$BATS_TEST_TMPDIR/graph.json")"
    [ "$a" = "$b" ]
  done
  for s in E01_S01 E01_S02 E02_S01; do
    run_graph --story "$s"
    a="$(py 'json.dumps(d["levels"]["tasks"]["totals"], sort_keys=True)')"
    b="$(py 'json.dumps([x for x in d["stories"] if x["id"]=="'"$s"'"][0]["totals"], sort_keys=True)' "$BATS_TEST_TMPDIR/graph.json")"
    [ "$a" = "$b" ]
  done
}

@test "complete and stop for every story case" {
  stops
  run_graph --graph
  [ "$RC" -eq 0 ]
  [ "$(py '[[s["id"], s["complete"], s["stop"]] for s in d["stories"]]')" = '[["E03_S01",true,"done"],["E03_S02",false,"in_progress"],["E03_S03",false,"failed"],["E03_S04",false,"pending"],["E03_S05",false,"pending"],["E03_S06",true,"rejected"],["E03_S07",false,"in_progress"]]' ]
  [ "$(py 'd["stories"][4]["totals"]["denominator"]')" = "0" ]
  [ "$(py 'd["epics"][0]["stories"]["complete"]')" = "2" ]
}

@test "depends_on: every form parses, E1 and E01 are one item" {
  basic
  run_graph --graph
  [ "$(py 'd["epics"][0]["depends_on"]')" = '[]' ]
  [ "$(py 'd["epics"][1]["depends_on"]')" = '["E01"]' ]
  [ "$(py 'd["stories"][0]["depends_on"]')" = '[]' ]
  [ "$(py 'd["stories"][1]["depends_on"]')" = '["E01_S01","E01_S09"]' ]
  [ "$(py 'd["stories"][2]["depends_on"]')" = '["E01_S01","E01_S02"]' ]
  [ "$(py 'd["tasks"][0]["depends_on"]')" = '["E01_S01_T02","E01_S01_T03"]' ]
  [ "$(py 'd["tasks"][1]["depends_on"]')" = '[]' ]
  [ "$(py 'd["tasks"][2]["depends_on"]')" = '[]' ]
  [ "$(py 'd["tasks"][3]["depends_on"]')" = '["E01_S01_T01"]' ]
  [ "$(py 'd["tasks"][4]["depends_on"]')" = '["E01_S02_T01","E01_S01_T02"]' ]
  [ "$(py 'd["tasks"][5]["depends_on"]')" = '["E01_S02_T01","E01_S02_T02"]' ]
}

@test "an id that resolves to no board file stays in the array" {
  basic
  run_graph --graph
  [ "$(py '"E01_S09" in d["stories"][1]["depends_on"]')" = "true" ]
}

@test "--counts-only has no tasks key and otherwise equals the full output" {
  basic
  run_graph --graph
  cp "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/full.json"
  run_graph --graph --counts-only
  [ "$RC" -eq 0 ]
  [ "$(py '"tasks" in d')" = "false" ]
  [ "$(py 'json.dumps([d[k] for k in ("epics","stories","warnings")], sort_keys=True)')" = "$(py 'json.dumps([d[k] for k in ("epics","stories","warnings")], sort_keys=True)' "$BATS_TEST_TMPDIR/full.json")" ]
}

@test "usage errors exit 2: another scope flag, --items, --summary, --counts-only without --graph" {
  basic
  run_graph --graph --all;       [ "$RC" -eq 2 ]; [ ! -s "$BATS_TEST_TMPDIR/out" ]
  run_graph --graph --by-parent; [ "$RC" -eq 2 ]
  run_graph --epic E01 --graph;  [ "$RC" -eq 2 ]
  run_graph --graph --items;     [ "$RC" -eq 2 ]
  run_graph --graph --summary;   [ "$RC" -eq 2 ]
  run_graph --all --counts-only; [ "$RC" -eq 2 ]
}

@test "an empty board exits 3 with nothing on stdout" {
  mkroot empty
  run_graph --graph
  [ "$RC" -eq 3 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
}

@test "output is byte-identical across runs" {
  basic
  run_graph --graph
  cp "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/a.json"
  run_graph --graph
  cmp "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/out"
}

@test "no jq, no model call, no file written" {
  basic
  before="$(find "$ROOT" -type f | sort | xargs cksum)"
  run_graph --graph
  [ "$RC" -eq 0 ]
  [ "$(find "$ROOT" -type f | sort | xargs cksum)" = "$before" ]
  ! grep -Eq '(^|[^a-z_])jq |claude ' "$SCRIPT"
}

# ---- E92_S12_T01: stories[].decomposed -----------------------------------------------------------------------------

# One story per decomposed case, all under E04, plus an epic E05 for --within; ids ascend with the case.
decomp() {
  mkroot decomp
  item E04 "In Progress"
  item E04_S01 Pending; item E04_S01_T01 Pending                                  # a counted task: true
  item E04_S02 Pending                                                            # no task files: false
  item E04_S03 Pending; item E04_S03_T01 Rejected; item E04_S03_T02 Rejected      # all tasks rejected: false
  item E04_S04 Pending; item E04_S04_T01 "Weird status"                           # all tasks unknown: false
  item E04_S05 Pending; item E04_S05_T01 Passed; item E04_S05_T02 Rejected        # counted and rejected: true
  item E04_S06 Rejected; item E04_S06_T01 Passed                                  # Rejected story: null
  item E04_S07 "Weird status"; item E04_S07_T01 Passed                            # unknown-status story: null
  item E04_S08 Passed; item E04_S08_T01 Passed                                    # done story: true
  item E05 Pending
  item E05_S01 Pending                                                            # the only story: false
}

@test "decomposed: true with a counted task, false with none, null for a story that is not counted" {
  decomp
  run_graph --graph
  [ "$RC" -eq 0 ]
  [ "$(py '[[s["id"], s["decomposed"]] for s in d["stories"] if s["epic_id"] == "E04"]')" = '[["E04_S01",true],["E04_S02",false],["E04_S03",false],["E04_S04",false],["E04_S05",true],["E04_S06",null],["E04_S07",null],["E04_S08",true]]' ]
  [ "$(py '[s["decomposed"] for s in d["stories"] if s["epic_id"] == "E05"]')" = '[false]' ]
}

@test "decomposed: the printed value is a bare JSON literal, true, false or null" {
  decomp
  run_graph --graph
  grep -c '"decomposed": true,'  "$BATS_TEST_TMPDIR/out" | grep -qx 3
  grep -c '"decomposed": false,' "$BATS_TEST_TMPDIR/out" | grep -qx 4
  grep -c '"decomposed": null,'  "$BATS_TEST_TMPDIR/out" | grep -qx 2
}

@test "decomposed: true count equals epic_progress.decomposed, false count equals stories minus decomposed" {
  decomp
  run_graph --graph
  [ "$(py 'all(sum(1 for s in d["stories"] if s["epic_id"] == e["id"] and s["decomposed"] is True) == e["epic_progress"]["decomposed"] and sum(1 for s in d["stories"] if s["epic_id"] == e["id"] and s["decomposed"] is False) == e["epic_progress"]["stories"] - e["epic_progress"]["decomposed"] for e in d["epics"])')" = "true" ]
  # the mixed epic in numbers: 6 counted stories (S06 and S07 are not counted), 3 decomposed (S01, S05, S08), so 3 ghost bands
  [ "$(py '[[e["epic_progress"]["stories"], e["epic_progress"]["decomposed"]] for e in d["epics"]]')" = '[[6,3],[1,0]]' ]
}

@test "decomposed: the same value for the same story under --within, an epic or a story, and with --counts-only" {
  decomp
  run_graph --graph
  cp "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/full.json"
  all="$(py 'json.dumps({s["id"]: s["decomposed"] for s in d["stories"]}, sort_keys=True)')"
  run_graph --graph --within E04
  [ "$(py 'json.dumps({s["id"]: s["decomposed"] for s in d["stories"]}, sort_keys=True)')" = "$(py 'json.dumps({s["id"]: s["decomposed"] for s in d["stories"] if s["epic_id"] == "E04"}, sort_keys=True)' "$BATS_TEST_TMPDIR/full.json")" ]
  run_graph --graph --within E05
  [ "$(py 'json.dumps({s["id"]: s["decomposed"] for s in d["stories"]}, sort_keys=True)')" = '{"E05_S01": false}' ]
  for sid in E04_S01 E04_S02 E04_S03 E04_S04 E04_S05 E04_S06 E04_S07 E04_S08; do
    run_graph --graph --within "$sid"
    [ "$(py '[s["decomposed"] for s in d["stories"]]')" = "$(py '[[s["decomposed"] for s in d["stories"] if s["id"] == "'"$sid"'"][0]]' "$BATS_TEST_TMPDIR/full.json")" ]
  done
  run_graph --graph --counts-only
  [ "$(py 'json.dumps({s["id"]: s["decomposed"] for s in d["stories"]}, sort_keys=True)')" = "$all" ]
}

@test "decomposed: two runs print identical output, and no other story or epic key moved" {
  decomp
  run_graph --graph
  cp "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/a.json"
  run_graph --graph
  cmp "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/out"
  [ "$(py 'd["schema_version"]')" = "1" ]
  [ "$(py 'list(d.keys())')" = '["schema_version","scope","epics","stories","tasks","ready","warnings"]' ]
  [ "$(py 'list(d["epics"][0].keys())')" = '["id","title","depends_on","stories","tasks","epic_progress","ready_count"]' ]
}
