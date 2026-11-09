#!/usr/bin/env bats
#
# Coverage for skills/j-reconcile/scripts/resolve-reconcile-scope.sh with the revised fuzzy-ID grammar
# (E86_S03_T04): story ranges on a board whose epics and stories have three or more digits, plus the
# unchanged two-digit range behaviour. The script builds range members such as E100_S03 (zero-padded to the
# wider of the two input widths, minimum 2) and sends them to resolve-id.sh in one batch.
#
# Fixture, not the live repo: board-scan.sh reads project/board/ under JENGA_PROJECT_DIR / CLAUDE_PROJECT_DIR,
# both pointed at a temporary board under BATS_TEST_TMPDIR. The scripts under test are run in place.
#
# Fixture board:
#   epics   E01, E100
#   stories E01_S03..E01_S05, E100_S03..E100_S05, E100_S99..E100_S101
#   tasks   E100_S04_T01

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-reconcile/scripts/resolve-reconcile-scope.sh"

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

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/project-root"
  BOARD="$FIXTURE/project/board"
  mkdir -p "$BOARD/epics" "$BOARD/stories" "$BOARD/tasks"

  mk_item epics E01
  mk_item epics E100
  local n
  for n in 03 04 05; do mk_item stories "E01_S$n" E01; done
  for n in 03 04 05 99 100 101; do mk_item stories "E100_S$n" E100; done
  mk_item tasks E100_S04_T01 E100 E100_S04

  export JENGA_PROJECT_DIR="$FIXTURE"
  export CLAUDE_PROJECT_DIR="$FIXTURE"
}

teardown() {
  unset JENGA_PROJECT_DIR CLAUDE_PROJECT_DIR
}

# field <python-expr-on-d> -- evaluates an expression against the JSON object in $output.
field() {
  JSON_OUT="$output" python3 -c 'import json,os,sys; d=json.loads(os.environ["JSON_OUT"]); print(eval(sys.argv[1]))' "$1"
}

@test "e100s3-5 resolves to the three E100 story ids" {
  run "$SCRIPT" "e100s3-5"
  [ "$status" -eq 0 ]
  [ "$(field 'd["scope_type"]')" = "range" ]
  [ "$(field '",".join(d["story_ids"])')" = "E100_S03,E100_S04,E100_S05" ]
  [ "$(field '",".join(d["epic_ids"])')" = "E100" ]
  [ "$(field '",".join(d["task_ids"])')" = "E100_S04_T01" ]
}

@test "E100_S03-05 resolves to the three E100 story ids" {
  run "$SCRIPT" "E100_S03-05"
  [ "$status" -eq 0 ]
  [ "$(field '",".join(d["story_ids"])')" = "E100_S03,E100_S04,E100_S05" ]
}

@test "E100_S99-101 spans two to three digit story numbers" {
  run "$SCRIPT" "E100_S99-101"
  [ "$status" -eq 0 ]
  [ "$(field '",".join(d["story_ids"])')" = "E100_S100,E100_S101,E100_S99" ]
  [ "$(field '",".join(d["epic_ids"])')" = "E100" ]
}

@test "bare S99-101 is ambiguity-free when only one epic has those stories" {
  run "$SCRIPT" "S99-101"
  [ "$status" -eq 0 ]
  [ "$(field '",".join(d["story_ids"])')" = "E100_S100,E100_S101,E100_S99" ]
}

@test "existing two-digit range E01_S03-05 is unchanged" {
  run "$SCRIPT" "E01_S03-05"
  [ "$status" -eq 0 ]
  [ "$(field 'd["scope_type"]')" = "range" ]
  [ "$(field '",".join(d["story_ids"])')" = "E01_S03,E01_S04,E01_S05" ]
  [ "$(field '",".join(d["epic_ids"])')" = "E01" ]
}

@test "existing short range e01s3-5 is unchanged" {
  run "$SCRIPT" "e01s3-5"
  [ "$status" -eq 0 ]
  [ "$(field '",".join(d["story_ids"])')" = "E01_S03,E01_S04,E01_S05" ]
}

@test "a range with a missing member on a wide epic fails whole" {
  run "$SCRIPT" "e100s5-7"
  [ "$status" -eq 1 ]
  [ "$(field 'd["status"]')" = "error" ]
}
