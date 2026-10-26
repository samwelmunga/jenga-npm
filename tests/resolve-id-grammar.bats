#!/usr/bin/env bats
#
# Characterization coverage for skills/jenga/scripts/resolve-id.sh (E86_S03_T01): the fuzzy-ID grammar
# parser and board-backed resolver behind `/jenga <ids>`.
#
# These tests PIN WHAT THE SCRIPT DOES TODAY, on a board whose item numbers are all two digits, so the
# grammar revision for three-plus-digit values (E86_S03_T02) can change the script with evidence that
# every two-digit behaviour below stayed byte-identical. They assert the real outputs, rejection
# wording included; when a later task changes the grammar on purpose, it updates the affected
# expectation here deliberately rather than loosening it.
#
# Fixture, not the live repo: resolve-id.sh invokes board-scan.sh, which reads project/board/ under the
# project root chosen by lib/resolve-project-dir.sh (JENGA_PROJECT_DIR, then CLAUDE_PROJECT_DIR, ...).
# Every test points both at a temporary board under BATS_TEST_TMPDIR, so the repository's own board is
# never read and nothing touches the network.
#
# Fixture board:
#   epics   E01, E02
#   stories E01_S02, E01_S03, E01_S04, E02_S02      (S02 exists under both epics: the ambiguity case)
#   tasks   E01_S04_T02

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
    echo
    echo "# Fixture $id"
  } > "$BOARD/$dir/${id}_fixture.md"
}

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/project-root"
  BOARD="$FIXTURE/project/board"
  mkdir -p "$BOARD/epics" "$BOARD/stories" "$BOARD/tasks"

  mk_item epics E01
  mk_item epics E02
  mk_item stories E01_S02 E01
  mk_item stories E01_S03 E01
  mk_item stories E01_S04 E01
  mk_item stories E02_S02 E02
  mk_item tasks E01_S04_T02 E01 E01_S04

  export JENGA_PROJECT_DIR="$FIXTURE"
  export CLAUDE_PROJECT_DIR="$FIXTURE"
}

teardown() {
  unset JENGA_PROJECT_DIR CLAUDE_PROJECT_DIR
}

# json_field <index> <key> -- prints that field of the index-th element of $output ("null" for JSON null).
json_field() {
  JSON_OUT="$output" python3 - "$1" "$2" <<'PY'
import json, os, sys
v = json.loads(os.environ["JSON_OUT"])[int(sys.argv[1])][sys.argv[2]]
print("null" if v is None else v)
PY
}

# json_len -- prints the number of elements in the top-level array of $output.
json_len() {
  JSON_OUT="$output" python3 -c 'import json,os; print(len(json.loads(os.environ["JSON_OUT"])))'
}

# --- resolved IDs -------------------------------------------------------------------------------

@test "E01s02 resolves to the story E01_S02" {
  run "$SCRIPT" "E01s02"
  [ "$status" -eq 0 ]
  [ "$(json_len)" = "1" ]
  [ "$(json_field 0 input)" = "E01s02" ]
  [ "$(json_field 0 status)" = "resolved" ]
  [ "$(json_field 0 resolved_id)" = "E01_S02" ]
  [ "$(json_field 0 reason)" = "null" ]
}

@test "'e01 S04 t02' resolves to the task E01_S04_T02 (case and spaces are insignificant)" {
  run "$SCRIPT" "e01 S04 t02"
  [ "$status" -eq 0 ]
  [ "$(json_field 0 input)" = "e01 S04 t02" ]
  [ "$(json_field 0 status)" = "resolved" ]
  [ "$(json_field 0 resolved_id)" = "E01_S04_T02" ]
  [ "$(json_field 0 reason)" = "null" ]
}

@test "0103 resolves to E01_S03 (two untagged chunks fill epic then story)" {
  run "$SCRIPT" "0103"
  [ "$status" -eq 0 ]
  [ "$(json_field 0 status)" = "resolved" ]
  [ "$(json_field 0 resolved_id)" = "E01_S03" ]
  [ "$(json_field 0 reason)" = "null" ]
}

@test "E01 resolves to the epic E01" {
  run "$SCRIPT" "E01"
  [ "$status" -eq 0 ]
  [ "$(json_field 0 status)" = "resolved" ]
  [ "$(json_field 0 resolved_id)" = "E01" ]
  [ "$(json_field 0 reason)" = "null" ]
}

# --- rejections ---------------------------------------------------------------------------------

@test "an odd-length digit run is rejected with the malformed digit run reason" {
  run "$SCRIPT" "010"
  [ "$status" -eq 1 ]
  [ "$(json_field 0 status)" = "rejected" ]
  [ "$(json_field 0 resolved_id)" = "null" ]
  [ "$(json_field 0 reason)" = "malformed digit run: '010' has odd length 3 (not a multiple of 2)" ]
}

@test "more untagged chunks than open levels is rejected as too many untagged chunks" {
  run "$SCRIPT" "0102030405"
  [ "$status" -eq 1 ]
  [ "$(json_field 0 status)" = "rejected" ]
  [ "$(json_field 0 resolved_id)" = "null" ]
  [ "$(json_field 0 reason)" = "too many untagged chunks: 5 chunks but only 3 open level(s)" ]
}

@test "input with no digits is rejected with no ID chunks found" {
  run "$SCRIPT" "abc"
  [ "$status" -eq 1 ]
  [ "$(json_field 0 status)" = "rejected" ]
  [ "$(json_field 0 resolved_id)" = "null" ]
  [ "$(json_field 0 reason)" = "no ID chunks found in input" ]
}

@test "a bare story number that exists under two epics is rejected as ambiguous" {
  run "$SCRIPT" "s02"
  [ "$status" -eq 1 ]
  [ "$(json_field 0 status)" = "rejected" ]
  [ "$(json_field 0 resolved_id)" = "null" ]
  [ "$(json_field 0 reason)" = "ambiguous partial ID 'story=S02': matches 2 candidates (E01_S02, E02_S02) - disambiguation required" ]
}

@test "an ID that parses but is not on the board is rejected as not found" {
  run "$SCRIPT" "E09"
  [ "$status" -eq 1 ]
  [ "$(json_field 0 status)" = "rejected" ]
  [ "$(json_field 0 resolved_id)" = "null" ]
  [ "$(json_field 0 reason)" = "not found on board: epic=E09" ]
}

@test "a full epic/story/task triple with no such task is rejected as not found" {
  run "$SCRIPT" "010203"
  [ "$status" -eq 1 ]
  [ "$(json_field 0 status)" = "rejected" ]
  [ "$(json_field 0 reason)" = "not found on board: epic=E01, story=S02, task=T03" ]
}

# --- multiple segments and exit codes ------------------------------------------------------------

@test "comma-separated segments are reported in input order; mixed outcomes exit 1" {
  run "$SCRIPT" "E01s02,E09,0103"
  [ "$status" -eq 1 ]
  [ "$(json_len)" = "3" ]

  [ "$(json_field 0 input)" = "E01s02" ]
  [ "$(json_field 0 status)" = "resolved" ]
  [ "$(json_field 0 resolved_id)" = "E01_S02" ]
  [ "$(json_field 0 reason)" = "null" ]

  [ "$(json_field 1 input)" = "E09" ]
  [ "$(json_field 1 status)" = "rejected" ]
  [ "$(json_field 1 resolved_id)" = "null" ]
  [ "$(json_field 1 reason)" = "not found on board: epic=E09" ]

  [ "$(json_field 2 input)" = "0103" ]
  [ "$(json_field 2 status)" = "resolved" ]
  [ "$(json_field 2 resolved_id)" = "E01_S03" ]
  [ "$(json_field 2 reason)" = "null" ]
}

@test "every segment resolving exits 0 and each input is echoed exactly as given, whitespace included" {
  run "$SCRIPT" "E01s02, e01 S04 t02, 0103"
  [ "$status" -eq 0 ]
  [ "$(json_len)" = "3" ]
  [ "$(json_field 0 input)" = "E01s02" ]
  [ "$(json_field 1 input)" = " e01 S04 t02" ]
  [ "$(json_field 2 input)" = " 0103" ]
  [ "$(json_field 0 resolved_id)" = "E01_S02" ]
  [ "$(json_field 1 resolved_id)" = "E01_S04_T02" ]
  [ "$(json_field 2 resolved_id)" = "E01_S03" ]
}

@test "every segment rejected exits 1" {
  run "$SCRIPT" "E09,abc"
  [ "$status" -eq 1 ]
  [ "$(json_len)" = "2" ]
  [ "$(json_field 0 status)" = "rejected" ]
  [ "$(json_field 1 status)" = "rejected" ]
}

# --- JSON shape ----------------------------------------------------------------------------------

@test "output is a JSON array whose objects have exactly input, status, resolved_id, reason" {
  run "$SCRIPT" "E01s02,E09"
  JSON_OUT="$output" run python3 - <<'PY'
import json, os
data = json.loads(os.environ["JSON_OUT"])
assert isinstance(data, list), "top level is not an array"
assert len(data) == 2, len(data)
for obj in data:
    assert isinstance(obj, dict), obj
    assert sorted(obj.keys()) == ["input", "reason", "resolved_id", "status"], sorted(obj.keys())
    assert obj["status"] in ("resolved", "rejected"), obj["status"]
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "a resolved element has a null reason and a rejected element has a null resolved_id" {
  run "$SCRIPT" "E01s02,E09"
  [ "$(json_field 0 reason)" = "null" ]
  [ "$(json_field 0 resolved_id)" != "null" ]
  [ "$(json_field 1 resolved_id)" = "null" ]
  [ "$(json_field 1 reason)" != "null" ]
}
