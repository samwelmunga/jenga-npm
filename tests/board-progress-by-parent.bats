#!/usr/bin/env bats
#
# E92_S05_T02: the --by-parent mode of scripts/board-progress.sh (contract: project/documentation/progress-visualisation.md).
# Fixture only (tests/helpers/progress-fixture.bash); the live project/board/ is never read.
#
# Fixture facts used below: E02 is an empty epic (no stories); E01_S03 is an empty story (no tasks); E99 and E100 hold the
# stories S2, S10, S100 (written in a non-numeric order); E03 holds an orphan task (its story file is missing).

bats_require_minimum_version 1.5.0

load helpers/assertions
load helpers/progress-fixture

setup() {
  pf_setup
  unset JENGA_PROGRESS_LANG NO_COLOR
}

# by_parent_totals / scoped_totals: the totals of one parent in a by-parent output, and of one level of a scoped run,
# both read by an independent implementation (python).
by_parent_totals() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
e = [x for x in d[sys.argv[2]] if x["id"] == sys.argv[3]]
assert len(e) == 1, "expected exactly one entry"
print(json.dumps(e[0]["totals"], sort_keys=True))
' "$1" "$2" "$3"
}
scoped_totals() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps(d["levels"][sys.argv[2]]["totals"], sort_keys=True))
' "$1" "$2"
}

@test "shape: schema_version, scope type, epics, stories, warnings; each entry carries its child level" {
  pf_run --by-parent
  [ "$PF_RC" -eq 0 ]
  [ ! -s "$PF_ERR" ]
  [ "$(pf_py 'd["schema_version"]')" = "1" ]
  [ "$(pf_py 'd["scope"]')" = '{"type":"by-parent"}' ]
  [ "$(pf_py 'list(d.keys())')" = '["schema_version","scope","epics","stories","warnings"]' ]
  [ "$(pf_py 'sorted(set(e["level"] for e in d["epics"]))')" = '["stories"]' ]
  [ "$(pf_py 'sorted(set(s["level"] for s in d["stories"]))')" = '["tasks"]' ]
  [ "$(pf_py 'list(d["epics"][0]["totals"].keys())')" = '["done","in_progress","failed","pending","rejected","unknown","denominator"]' ]
}

@test "every epic entry equals --epic <id> at the stories level" {
  pf_run --by-parent
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/bp.json"
  # E01, E05, E06, E99, E100 have stories; E02 has none (covered separately); E03 and E04 have only orphan tasks.
  for e in E01 E05 E06 E99 E100; do
    pf_run --epic "$e"
    [ "$PF_RC" -eq 0 ]
    [ "$(by_parent_totals "$BATS_TEST_TMPDIR/bp.json" epics "$e")" = "$(scoped_totals "$PF_OUT" stories)" ]
  done
}

@test "every story entry equals --story <id> at the tasks level" {
  pf_run --by-parent
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/bp.json"
  for s in E01_S01 E01_S02 E05_S01 E06_S01 E06_S06 E06_S15 E99_S2 E99_S10 E100_S100; do
    pf_run --story "$s"
    [ "$PF_RC" -eq 0 ]
    [ "$(by_parent_totals "$BATS_TEST_TMPDIR/bp.json" stories "$s")" = "$(scoped_totals "$PF_OUT" tasks)" ]
  done
}

@test "the Rejected rule and the unknown bucket carry through: E01_S02 is 3 done of 4, E01_S01 has one unknown" {
  pf_run --by-parent
  [ "$(pf_py '[s for s in d["stories"] if s["id"] == "E01_S02"][0]["totals"]')" = '{"done":3,"in_progress":0,"failed":0,"pending":1,"rejected":1,"unknown":0,"denominator":4}' ]
  [ "$(pf_py '[s for s in d["stories"] if s["id"] == "E01_S01"][0]["totals"]["unknown"]')" = "1" ]
  [ "$(pf_py '[w["id"] for w in d["warnings"] if w["kind"] == "unknown_status"]')" = '["E01_S01_T15","E06_S15","E06_S15_T01"]' ]
}

@test "an epic with no stories and a story with no tasks are listed with all-zero totals" {
  pf_run --by-parent
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py '[e for e in d["epics"] if e["id"] == "E02"][0]["totals"]')" = '{"done":0,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":0}' ]
  [ "$(pf_py '[s for s in d["stories"] if s["id"] == "E01_S03"][0]["totals"]')" = '{"done":0,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":0}' ]
}

@test "ordering is numeric: E99 before E100, S2 before S10 before S100" {
  pf_run --by-parent
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py '[e["id"] for e in d["epics"]]')" = '["E01","E02","E03","E05","E06","E99","E100"]' ]
  [ "$(pf_py '[s["id"] for s in d["stories"] if s["id"].startswith("E99_")]')" = '["E99_S2","E99_S10","E99_S100"]' ]
  [ "$(pf_py '[s["id"] for s in d["stories"] if s["id"].startswith("E100_")]')" = '["E100_S2","E100_S10","E100_S100"]' ]
  [ "$(pf_py '[s["id"] for s in d["stories"]][-6:]')" = '["E99_S2","E99_S10","E99_S100","E100_S2","E100_S10","E100_S100"]' ]
}

@test "orphans: an orphan task is warned, never counted under a parent that has no file" {
  pf_run --by-parent
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py '[w["id"] for w in d["warnings"] if w["kind"] == "orphan_task"]')" = '["E03_S01_T01","E04_S01_T01"]' ]
  [ "$(pf_py '[w["id"] for w in d["warnings"] if w["kind"] == "orphan_story"]')" = '["E04_S01"]' ]
  # E04 has no epic file, so it is no epic entry; its story is still a story entry (own task counted under it).
  [ "$(pf_py '[e["id"] for e in d["epics"] if e["id"] == "E04"]')" = '[]' ]
  [ "$(pf_py '[s for s in d["stories"] if s["id"] == "E04_S01"][0]["totals"]["denominator"]')" = "1" ]
}

@test "output is byte-identical across runs" {
  pf_run --by-parent
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/first.json"
  pf_run --by-parent
  cmp -s "$PF_OUT" "$BATS_TEST_TMPDIR/first.json"
  pf_run --by-parent
  cmp -s "$PF_OUT" "$BATS_TEST_TMPDIR/first.json"
}

@test "the fixture tree is not modified by a run" {
  before="$(pf_tree_sum "$PF_ROOT")"
  pf_run --by-parent
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_tree_sum "$PF_ROOT")" = "$before" ]
}

@test "a board with no epic file exits 3 with a message on stderr and nothing on stdout" {
  rm -f "$PF_ROOT"/project/board/epics/*.md
  pf_run --by-parent
  [ "$PF_RC" -eq 3 ]
  [ ! -s "$PF_OUT" ]
  grep -qF "no epic" "$PF_ERR"
}

@test "an epic file alone (no stories, no tasks) still exits 0 with the epic at zero" {
  rm -f "$PF_ROOT"/project/board/stories/*.md "$PF_ROOT"/project/board/tasks/*.md
  pf_run --by-parent
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py 'd["stories"]')" = '[]' ]
  [ "$(pf_py '[e["totals"]["denominator"] for e in d["epics"]]')" = '[0,0,0,0,0,0,0]' ]
}

@test "--by-parent cannot be combined with another scope, --items or --summary (exit 2, stdout empty)" {
  for args in "--all --by-parent" "--by-parent --all" "--epic E01 --by-parent" "--by-parent --items" "--by-parent --summary" "--by-parent --backlog"; do
    # shellcheck disable=SC2086
    pf_run $args
    [ "$PF_RC" -eq 2 ]
    [ ! -s "$PF_OUT" ]
    [ -s "$PF_ERR" ]
  done
}

@test "the other modes are unchanged: --all still prints the levels shape" {
  pf_run --all
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py 'list(d.keys())')" = '["schema_version","scope","levels","warnings"]' ]
  [ "$(pf_py 'list(d["levels"].keys())')" = '["tasks","stories","epics"]' ]
}
