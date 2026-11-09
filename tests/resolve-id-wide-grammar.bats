#!/usr/bin/env bats
#
# Coverage for the revised fuzzy-ID grammar of skills/jenga/scripts/resolve-id.sh (E86_S03_T03): item
# numbers of three or more digits, run on a MIXED-WIDTH board. tests/resolve-id-grammar.bats (T01) stays
# the two-digit characterization file; this file has one purpose, the E86 revision documented in the
# script header (tagged runs are numbers of any width, separators bound runs, bare runs are chunked only
# when even, <= 6 digits and free of a "00" chunk, and the E0102 overlap rule).
#
# Fixture, not the live repo: resolve-id.sh invokes board-scan.sh, which reads project/board/ under the
# project root chosen by JENGA_PROJECT_DIR / CLAUDE_PROJECT_DIR. Both point at a temporary board under
# BATS_TEST_TMPDIR, so the repository's own board is never read and nothing touches the network.
#
# Fixture board:
#   epics   E01, E10, E11, E100, E101, E1001
#   stories E01_S01..S04, E10_S01, E10_S02, E11_S10, E100_S01, E100_S02, E100_S100, E101_S01,
#           E1001_S02, E1001_S100
#   tasks   E01_S04_T02, E1001_S100_T02, E100_S100_T100

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/jenga/scripts/resolve-id.sh"

# mk_item <dir> <id> [epic_id] [story_id] -- writes a minimal board file board-scan.sh can inventory.
mk_item() {
  local dir="$1" id="$2" epic="${3:-}" story="${4:-}"
  {
    echo "---"
    echo "id: $id"
    [ -n "$epic" ] && echo "epic_id: $epic"
    [ -n "$story" ] && echo "story_id: $story"
    echo "title: \"Fixture $id\""
    echo "status: Pending"
    echo "---"
  } > "$BOARD/$dir/${id}_fixture.md"
}

rm_item() { rm -f "$BOARD/$1/${2}_fixture.md"; }

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/project-root"
  BOARD="$FIXTURE/project/board"
  mkdir -p "$BOARD/epics" "$BOARD/stories" "$BOARD/tasks"

  local e s
  for e in E01 E10 E11 E100 E101 E1001; do mk_item epics "$e"; done
  for s in E01_S01 E01_S02 E01_S03 E01_S04 E10_S01 E10_S02 E11_S10 E100_S01 E100_S02 E100_S100 \
           E101_S01 E1001_S02 E1001_S100; do
    mk_item stories "$s" "${s%%_*}"
  done
  mk_item tasks E01_S04_T02 E01 E01_S04
  mk_item tasks E1001_S100_T02 E1001 E1001_S100
  mk_item tasks E100_S100_T100 E100 E100_S100

  export JENGA_PROJECT_DIR="$FIXTURE"
  export CLAUDE_PROJECT_DIR="$FIXTURE"
}

teardown() {
  unset JENGA_PROJECT_DIR CLAUDE_PROJECT_DIR
}

json_field() {
  JSON_OUT="$output" python3 - "$1" "$2" <<'PY'
import json, os, sys
v = json.loads(os.environ["JSON_OUT"])[int(sys.argv[1])][sys.argv[2]]
print("null" if v is None else v)
PY
}

json_len() {
  JSON_OUT="$output" python3 -c 'import json,os; print(len(json.loads(os.environ["JSON_OUT"])))'
}

# assert_resolved <input> <resolved_id> -- one segment, exit 0, exact id, null reason.
assert_resolved() {
  run "$SCRIPT" "$1"
  [ "$status" -eq 0 ]
  [ "$(json_len)" = "1" ]
  [ "$(json_field 0 status)" = "resolved" ]
  [ "$(json_field 0 resolved_id)" = "$2" ]
  [ "$(json_field 0 reason)" = "null" ]
}

# assert_rejected <input> <reason> -- one segment, exit 1, null id, exact reason.
assert_rejected() {
  run "$SCRIPT" "$1"
  [ "$status" -eq 1 ]
  [ "$(json_len)" = "1" ]
  [ "$(json_field 0 status)" = "rejected" ]
  [ "$(json_field 0 resolved_id)" = "null" ]
  [ "$(json_field 0 reason)" = "$2" ]
}

FIX_TAIL="use letters or separators, e.g. e100s02 or '100 2'"

# --- tagged wide forms -----------------------------------------------------------------------------

@test "e100s2 resolves to E100_S02 (a tagged run is a number of any width)" {
  assert_resolved "e100s2" "E100_S02"
}

@test "E100S02 resolves to E100_S02" {
  assert_resolved "E100S02" "E100_S02"
}

@test "'e1001 s100 t2' resolves to the task E1001_S100_T02" {
  assert_resolved "e1001 s100 t2" "E1001_S100_T02"
}

@test "E100_S100_T100 resolves to the task E100_S100_T100 (underscore form)" {
  assert_resolved "E100_S100_T100" "E100_S100_T100"
}

@test "tagged runs compare numerically: e100s100t100 and E1001S100T02 resolve with their zero padding" {
  assert_resolved "e100s100t100" "E100_S100_T100"
  assert_resolved "E1001S100T02" "E1001_S100_T02"
}

@test "a lone tagged wide epic and a two-digit story under it resolve (e11s10, e100)" {
  assert_resolved "e11s10" "E11_S10"
  assert_resolved "e100" "E100"
}

# --- separator forms -------------------------------------------------------------------------------

@test "'100 2' is epic 100, story 2 (a separator bounds the digit runs)" {
  assert_resolved "100 2" "E100_S02"
}

@test "'100 100 100' resolves to E100_S100_T100 and '10 02' to E10_S02" {
  assert_resolved "100 100 100" "E100_S100_T100"
  assert_resolved "10 02" "E10_S02"
}

@test "'100,2' is two segments, not one: each bare run is rejected on its own" {
  run "$SCRIPT" "100,2"
  [ "$status" -eq 1 ]
  [ "$(json_len)" = "2" ]
  [ "$(json_field 0 input)" = "100" ]
  [ "$(json_field 0 status)" = "rejected" ]
  [ "$(json_field 0 reason)" = "digit run '100' cannot be read unambiguously (odd length 3); $FIX_TAIL" ]
  [ "$(json_field 1 input)" = "2" ]
  [ "$(json_field 1 status)" = "rejected" ]
  [ "$(json_field 1 reason)" = "digit run '2' cannot be read unambiguously (odd length 1); $FIX_TAIL" ]
}

# --- digit-width collisions ------------------------------------------------------------------------

@test "e10s1 resolves to E10_S01 and e100s1 to E100_S01, each to its own epic only" {
  assert_resolved "e10s1" "E10_S01"
  assert_resolved "e100s1" "E100_S01"
}

@test "e10s1 never resolves to E100_S01: with E10_S01 absent it is not found" {
  rm_item stories E10_S01
  assert_rejected "e10s1" "not found on board: epic=E10, story=S01"
  assert_resolved "e100s1" "E100_S01"
}

@test "e100s1 never resolves to E10_S01: with E100_S01 absent it is not found" {
  rm_item stories E100_S01
  assert_rejected "e100s1" "not found on board: epic=E100, story=S01"
  assert_resolved "e10s1" "E10_S01"
}

@test "e1s1 resolves to E01_S01 and never matches E10_S01" {
  assert_resolved "e1s1" "E01_S01"
  rm_item stories E01_S01
  assert_rejected "e1s1" "not found on board: epic=E01, story=S01"
}

# --- legacy shorthand unchanged --------------------------------------------------------------------

@test "legacy shorthand still resolves: 0103, E01s02, 'e01 S04 t02', 1002" {
  assert_resolved "0103" "E01_S03"
  assert_resolved "E01s02" "E01_S02"
  assert_resolved "e01 S04 t02" "E01_S04_T02"
  assert_resolved "1002" "E10_S02"
}

# --- rejections ------------------------------------------------------------------------------------

@test "10002 is rejected: odd untagged run, add letters or separators" {
  assert_rejected "10002" "digit run '10002' cannot be read unambiguously (odd length 5); $FIX_TAIL"
}

@test "1000 is rejected: a 00 chunk is never a board number, add letters or separators" {
  assert_rejected "1000" "digit run '1000' cannot be read unambiguously (contains a 00 chunk and numbering starts at 01); $FIX_TAIL"
}

@test "an untagged run longer than 6 digits is rejected (odd) or reports too many chunks (even)" {
  assert_rejected "0102030" "digit run '0102030' cannot be read unambiguously (odd length 7); $FIX_TAIL"
  assert_rejected "01020304" "too many untagged chunks: 4 chunks but only 3 open level(s)"
}

@test "separator-bounded runs past the three levels are rejected as too many chunks" {
  assert_rejected "1001 100 2" "too many untagged chunks: 4 chunks but only 3 open level(s)"
}

# --- the E0102 overlap rule ------------------------------------------------------------------------

@test "E0102 keeps its legacy reading E01_S02 when the wide reading E102 is not on the board" {
  assert_resolved "E0102" "E01_S02"
  assert_resolved "e0102" "E01_S02"
}

@test "E0102 uses the wide reading E102 when only that one resolves" {
  mk_item epics E102
  rm_item stories E01_S02
  assert_resolved "E0102" "E102"
}

@test "E0102 is rejected as ambiguous when both readings resolve; letters or separators disambiguate" {
  mk_item epics E102
  assert_rejected "E0102" "ambiguous digit run in 'E0102': it reads as E01_S02 and E102 on this board - use letters or separators to say which, e.g. e01s02 or e102"
  assert_resolved "e01s02" "E01_S02"
  assert_resolved "e102" "E102"
}

@test "e1001 is ambiguous between E10_S01 and E1001 on this board" {
  assert_rejected "e1001" "ambiguous digit run in 'e1001': it reads as E10_S01 and E1001 on this board - use letters or separators to say which, e.g. e10s01 or e1001"
  assert_resolved "e10s01" "E10_S01"
}

# --- ambiguity across epics, including E100 --------------------------------------------------------

@test "a bare story number under E100 and E1001 is rejected with disambiguation required" {
  assert_rejected "s100" "ambiguous partial ID 'story=S100': matches 2 candidates (E1001_S100, E100_S100) - disambiguation required"
}

@test "s01 and s02 list every epic that has them, E100 included" {
  assert_rejected "s01" "ambiguous partial ID 'story=S01': matches 4 candidates (E01_S01, E100_S01, E101_S01, E10_S01) - disambiguation required"
  assert_rejected "s02" "ambiguous partial ID 'story=S02': matches 4 candidates (E01_S02, E1001_S02, E100_S02, E10_S02) - disambiguation required"
}

@test "a bare task number that is unique resolves through its story and epic" {
  assert_resolved "t100" "E100_S100_T100"
}

# --- JSON shape and exit codes ---------------------------------------------------------------------

@test "mixed wide and legacy segments keep input order, exact ids and exit 1 when any is rejected" {
  run "$SCRIPT" "e100s2,10002,0103,e1001 s100 t2"
  [ "$status" -eq 1 ]
  [ "$(json_len)" = "4" ]
  [ "$(json_field 0 resolved_id)" = "E100_S02" ]
  [ "$(json_field 1 status)" = "rejected" ]
  [ "$(json_field 2 resolved_id)" = "E01_S03" ]
  [ "$(json_field 3 input)" = "e1001 s100 t2" ]
  [ "$(json_field 3 resolved_id)" = "E1001_S100_T02" ]
}

@test "all wide segments resolving exits 0, and every object has exactly input, status, resolved_id, reason" {
  run "$SCRIPT" "e100s2,100 2,E100_S100_T100"
  [ "$status" -eq 0 ]
  JSON_OUT="$output" run python3 - <<'PY'
import json, os
data = json.loads(os.environ["JSON_OUT"])
assert isinstance(data, list) and len(data) == 3, data
for obj in data:
    assert sorted(obj.keys()) == ["input", "reason", "resolved_id", "status"], sorted(obj.keys())
    assert obj["status"] == "resolved" and obj["reason"] is None, obj
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "no argument is still a usage error with exit 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}
