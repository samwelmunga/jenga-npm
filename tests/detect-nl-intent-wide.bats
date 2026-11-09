#!/usr/bin/env bats
#
# Coverage for skills/jenga/scripts/detect-nl-intent.sh under the revised fuzzy-ID grammar
# (E86_S03_T04): a three-digit epic written with letters classifies as all_resolved, a bare ambiguous
# digit run is not resolved, and the two-digit shorthand is unchanged.
#
# Fixture, not the live repo: board-scan.sh reads project/board/ under JENGA_PROJECT_DIR / CLAUDE_PROJECT_DIR,
# both pointed at a temporary board under BATS_TEST_TMPDIR. Fixture board: epics E01, E100; stories E01_S02,
# E100_S02.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/jenga/scripts/detect-nl-intent.sh"

mk_item() {
  local dir="$1" id="$2" epic="${3:-}"
  {
    echo "---"
    echo "id: $id"
    [ -n "$epic" ] && echo "epic_id: $epic"
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
  mk_item stories E01_S02 E01
  mk_item stories E100_S02 E100
  export JENGA_PROJECT_DIR="$FIXTURE"
  export CLAUDE_PROJECT_DIR="$FIXTURE"
}

teardown() {
  unset JENGA_PROJECT_DIR CLAUDE_PROJECT_DIR
}

field() {
  JSON_OUT="$output" python3 -c 'import json,os,sys; d=json.loads(os.environ["JSON_OUT"]); print(eval(sys.argv[1]))' "$1"
}

@test "e100s2 classifies as all_resolved with E100_S02" {
  run "$SCRIPT" "e100s2"
  [ "$status" -eq 0 ]
  [ "$(field 'd["classification"]')" = "all_resolved" ]
  [ "$(field 'd["resolved_ids_csv"]')" = "E100_S02" ]
}

@test "10002 is not resolved" {
  run "$SCRIPT" "10002"
  [ "$(field 'd["classification"]')" != "all_resolved" ]
  [ "$(field 'd["classification"]')" = "nl_intent" ]
}

@test "10002 beside a valid id is a mixed result naming the letters-or-separators fix" {
  run "$SCRIPT" "e100s2,10002"
  [ "$(field 'd["classification"]')" = "mixed" ]
  [ "$(field 'd["rejected"][0]["input"]')" = "10002" ]
  [[ "$(field 'd["rejected"][0]["reason"]')" == *"use letters or separators"* ]]
}

@test "two-digit shorthand 0102 still classifies as all_resolved" {
  run "$SCRIPT" "0102"
  [ "$status" -eq 0 ]
  [ "$(field 'd["classification"]')" = "all_resolved" ]
  [ "$(field 'd["resolved_ids_csv"]')" = "E01_S02" ]
}
