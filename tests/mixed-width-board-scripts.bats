#!/usr/bin/env bats
#
# E86_S06_T02: the board scripts run against the mixed-width synthetic board (tests/helpers/mixed-width-board.sh, E86_S06_T01).
#
# Subject: validate-board.sh, board-scan.sh, cascade-resolve.sh, resolve-id.sh, next-board-id.sh and
# render-ranked-list.sh, each pointed at the generated fixture (E01, E10, E11, E99, E100, E101, E1001; S10, S100; T99, T100) and
# asserted on their real output: numeric ordering E01 < E10 < E11 < E99 < E100 < E101 < E1001 (S10 before S100, T99 before T100),
# the resolve-id grammar (old shorthand and the wide grammar), the allocator, and the prefix-collision invariant (E10, E10_S1 and
# E1001 never return E100-, E10_S10- or E100-family items).
#
# Isolation: the fixture is generated once in setup_file under $BATS_FILE_TMPDIR with its own TMPDIR and HOME, JENGA_PROJECT_DIR and
# CLAUDE_PROJECT_DIR point at it (JENGA_PROJECT_DIR wins in lib/resolve-project-dir.sh, so it must be set), and the test
# aborts if either points anywhere else. Nothing here touches this repository's own board, and nothing needs the network.
# Nothing is renamed and there is no migration step.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GEN="$REPO_ROOT/tests/helpers/mixed-width-board.sh"
VALIDATE="$REPO_ROOT/scripts/validate-board.sh"
SCAN="$REPO_ROOT/skills/jenga/scripts/board-scan.sh"
CASCADE="$REPO_ROOT/skills/jenga/scripts/cascade-resolve.sh"
RESOLVE="$REPO_ROOT/skills/jenga/scripts/resolve-id.sh"
NEXT_ID="$REPO_ROOT/scripts/next-board-id.sh"
RANKED="$REPO_ROOT/scripts/render-ranked-list.sh"

setup_file() {
  export TMPDIR="$BATS_FILE_TMPDIR/tmp" HOME="$BATS_FILE_TMPDIR/home"
  mkdir -p "$TMPDIR" "$HOME"
  bash "$GEN" "$BATS_FILE_TMPDIR/wide" > "$BATS_FILE_TMPDIR/gen.out" 2>&1
  # A copy of the board with the E01_S03 story that the old shorthand "0103" names (the generated board stops at E01_S01).
  mkdir -p "$BATS_FILE_TMPDIR/aug"
  cp -R "$BATS_FILE_TMPDIR/wide/project" "$BATS_FILE_TMPDIR/aug/project"
  sed 's/^id: E01_S01$/id: E01_S03/' "$BATS_FILE_TMPDIR/wide/project/board/stories/E01_S01_fixture-story.md" \
    > "$BATS_FILE_TMPDIR/aug/project/board/stories/E01_S03_fixture-story.md"
}

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  export TMPDIR="$BATS_FILE_TMPDIR/tmp" HOME="$BATS_FILE_TMPDIR/home"
  WIDE="$BATS_FILE_TMPDIR/wide"
  B="$WIDE/project/board"
  export JENGA_PROJECT_DIR="$WIDE" CLAUDE_PROJECT_DIR="$WIDE"
  unset COPILOT_WORKSPACE_FOLDER
  [ -f "$B/epics/E1001_fixture-epic.md" ]
}

ids_of() { jq -r '[.[] | .id] | join(" ")'; }                     # board-scan array -> ids
scan_type() { bash "$SCAN" | jq -r --arg t "$1" '[.[] | select(.type == $t) | .id] | join(" ")'; }
all_match() { # <regex> <ids...>  - every id matches the regex
  local re="$1" id; shift
  for id in "$@"; do [[ $id =~ $re ]] || { echo "id outside the family: $id" >&2; return 1; }; done
}
position() { local i=0 x; for x in $2; do [ "$x" = "$1" ] && { echo $i; return; }; i=$((i + 1)); done; echo -1; }
resolved() { bash "$RESOLVE" "$1" | jq -r '.[0] | "\(.status) \(.resolved_id // "-")"'; }

@test "the fixture was generated in the temp tree and the scripts are pointed at it" {
  [ "$(cat "$BATS_FILE_TMPDIR/gen.out")" != "" ]
  case "$BATS_FILE_TMPDIR" in "$REPO_ROOT"/*) false ;; esac
  [ "$JENGA_PROJECT_DIR" = "$BATS_FILE_TMPDIR/wide" ]
  [ "$(bash "$SCAN" | jq 'length')" -eq 31 ]
}

@test "validate-board.sh: every fixture file is valid" {
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$B" -type f -name '*.md' | sort)
  [ "${#files[@]}" -eq 31 ]
  run bash "$VALIDATE" "${files[@]}"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'board frontmatter valid')" -eq 31 ]
}

@test "validate-board.sh: a malformed ID inserted into a copy of the fixture is still rejected" {
  for bad in E1001x E100_S1x E100_S100_T100_ E_100 E100_T100; do
    f="$BATS_TEST_TMPDIR/bad-$bad.md"
    sed "s/^id: E100_S100_T100\$/id: $bad/" "$B/tasks/E100_S100_T100_fixture-task.md" > "$f"
    run bash "$VALIDATE" "$f"
    [ "$status" -ne 0 ]
  done
  run bash "$VALIDATE" "$B/tasks/E100_S100_T100_fixture-task.md"
  [ "$status" -eq 0 ]
}

@test "board-scan.sh: every type is listed in numeric order, E99 before E100, S10 before S100, T99 before T100" {
  [ "$(scan_type epic)" = "E01 E10 E11 E99 E100 E101 E1001" ]
  stories="$(scan_type story)"
  [ "$(printf '%s\n' $stories | grep -vx 'E10_S1')" = "$(printf '%s\n' E01_S01 E10_S01 E10_S10 E11_S01 E99_S99 E100_S10 E100_S100 E101_S01 E1001_S01 E1001_S100)" ]
  [ "$(position E10_S1 "$stories")" -lt "$(position E10_S10 "$stories")" ]
  [ "$(position E100_S10 "$stories")" -lt "$(position E100_S100 "$stories")" ]
  tasks="$(scan_type task)"
  [ "$(printf '%s\n' $tasks | grep -vx 'E10_S1_T1')" = "$(printf '%s\n' E01_S01_T01 E01_S01_T02 E10_S01_T01 E10_S10_T10 E11_S01_T01 E99_S99_T99 E100_S10_T10 E100_S100_T99 E100_S100_T100 E101_S01_T01 E1001_S01_T01 E1001_S100_T100)" ]
  [ "$(position E100_S100_T99 "$tasks")" -lt "$(position E100_S100_T100 "$tasks")" ]
  [ "$(position E10_S1_T1 "$tasks")" -lt "$(position E10_S10_T10 "$tasks")" ]
}

@test "board-scan.sh: each item's file and parents match its own ID, never a longer ID it prefixes" {
  run bash "$SCAN"
  [ "$status" -eq 0 ]
  bad="$(jq -r '.[] | select((.file | split("/") | last) as $n | (.id + "_") as $p | ($n | startswith($p)) | not) | .id' <<<"$output")"
  [ -z "$bad" ]
  [ -z "$(jq -r '.[] | select(.type == "task") | select((.id | sub("_T[0-9]+$"; "")) != .story_id) | .id' <<<"$output")" ]
  [ -z "$(jq -r '.[] | select(.type != "epic") | select((.id | sub("_.*$"; "")) != .epic_id) | .id' <<<"$output")" ]
  [ "$(jq -r '[.[] | select(.epic_id == "E10") | .id] | join(" ")' <<<"$output" | tr ' ' '\n' | sort | tr '\n' ' ')" = "E10 E10_S01 E10_S01_T01 E10_S1 E10_S10 E10_S10_T10 E10_S1_T1 " ]
}

@test "cascade-resolve.sh: E10, E10_S1 and E1001 stay inside their own family" {
  run bash "$CASCADE" E10
  [ "$status" -eq 0 ]
  ids="$(jq -r '.resolved_ids[]' <<<"$output")"
  [ "$(printf '%s\n' $ids | tr '\n' ' ')" = "E10 E10_S10 E10_S10_T10 " ]
  all_match '^E10(_|$)' $ids

  run bash "$CASCADE" E10_S1
  [ "$status" -eq 0 ]
  ids="$(jq -r '.resolved_ids[]' <<<"$output")"
  [ "$ids" = "E10_S1" ]
  all_match '^E10_S1(_|$)' $ids

  run bash "$CASCADE" E1001
  [ "$status" -eq 0 ]
  ids="$(jq -r '.resolved_ids[]' <<<"$output")"
  [ "$(printf '%s\n' $ids | tr '\n' ' ')" = "E1001 E1001_S01 E1001_S01_T01 " ]
  all_match '^E1001(_|$)' $ids
}

@test "cascade-resolve.sh: several epics resolve in numeric order with consistent counts" {
  run bash "$CASCADE" "E1001,E101,E100,E99,E11,E10,E01"
  [ "$status" -eq 0 ]
  # the selection order is kept (this resolver reports what was asked for); the per-epic children are numerically ordered
  [ "$(jq -r '[.resolved_ids[] | select(test("^E[0-9]+$"))] | join(" ")' <<<"$output")" = "E1001 E101 E100 E99 E11 E10 E01" ]
  [ "$(jq -c .counts <<<"$output")" = '{"epics":7,"stories":5,"tasks":5}' ]
  [ "$(jq '.warnings | length' <<<"$output")" -eq 0 ]
  run bash "$CASCADE" "E01,E10,E11,E99,E100,E101,E1001"
  [ "$(jq -r '[.resolved_ids[] | select(test("^E[0-9]+$"))] | join(" ")' <<<"$output")" = "E01 E10 E11 E99 E100 E101 E1001" ]
  [ "$(jq -r '[.resolved_ids[] | select(test("^E100(_|$)"))] | join(" ")' <<<"$output")" = "E100 E100_S10 E100_S10_T10" ]
}

@test "resolve-id.sh: the old shorthand still resolves on the wide board" {
  [ "$(resolved e10)" = "resolved E10" ]
  [ "$(resolved e100)" = "resolved E100" ]
  [ "$(resolved e101)" = "resolved E101" ]
  [ "$(resolved e10s10)" = "resolved E10_S10" ]
  [ "$(resolved 0101)" = "resolved E01_S01" ]
  [ "$(resolved 'e01 S01 t02')" = "resolved E01_S01_T02" ]
  # "0103" names E01_S03, which the generated board does not have; on the copy that has it, it resolves
  [ "$(resolved 0103)" = "rejected -" ]
  JENGA_PROJECT_DIR="$BATS_FILE_TMPDIR/aug" CLAUDE_PROJECT_DIR="$BATS_FILE_TMPDIR/aug" run bash "$RESOLVE" 0103
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].resolved_id' <<<"$output")" = "E01_S03" ]
}

@test "resolve-id.sh: the wide grammar resolves e100s10, e1001 s100 t100 and tagged numbers of any width" {
  [ "$(resolved e100s10)" = "resolved E100_S10" ]
  [ "$(resolved 'e1001 s100 t100')" = "resolved E1001_S100_T100" ]
  [ "$(resolved e1001s100)" = "resolved E1001_S100" ]
  [ "$(resolved e100s100t99)" = "resolved E100_S100_T99" ]
  [ "$(resolved e100s100t100)" = "resolved E100_S100_T100" ]
  run bash "$RESOLVE" "e100s10, e1001 s100 t100, 0101"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].resolved_id] | join(",")' <<<"$output")" = "E100_S10,E1001_S100_T100,E01_S01" ]
}

@test "resolve-id.sh: 10002 is rejected and the message names the letters-or-separators fix" {
  run bash "$RESOLVE" 10002
  [ "$status" -eq 1 ]
  [ "$(jq -r '.[0].status' <<<"$output")" = "rejected" ]
  reason="$(jq -r '.[0].reason' <<<"$output")"
  [[ $reason == *"cannot be read unambiguously"* ]]
  [[ $reason == *"use letters or separators"* ]]
}

@test "resolve-id.sh: lookups never cross into a longer ID's family" {
  # E10_S01 and E10_S1 are the same story number written two ways on this board, so a bare number is ambiguous, never guessed
  run bash "$RESOLVE" e10s1
  [ "$(jq -r '.[0].status' <<<"$output")" = "rejected" ]
  [[ "$(jq -r '.[0].reason' <<<"$output")" == *"disambiguation required"* ]]
  [[ "$(jq -r '.[0].reason' <<<"$output")" != *"E10_S10"* ]]
  # "e1001" reads as epic E1001 and as E10 plus an untagged 01 (E10_S01 or E10_S1): rejected as ambiguous, never E100 or E101
  run bash "$RESOLVE" e1001
  [ "$status" -eq 1 ]
  [[ "$(jq -r '.[0].reason' <<<"$output")" == *"ambiguous"* ]]
  [ "$(jq -r '.[0].resolved_id' <<<"$output")" = "null" ]
  [ "$(resolved e10s10)" = "resolved E10_S10" ]
  [ "$(resolved e101)" = "resolved E101" ]
}

@test "next-board-id.sh: the allocator is the numeric maximum plus one" {
  next() { bash "$NEXT_ID" --epics-dir "$B/epics" --stories-dir "$B/stories" --tasks-dir "$B/tasks" "$@"; }
  [ "$(next epic)" = "E1002" ]
  [ "$(next story E1001)" = "E1001_S101" ]
  [ "$(next story E100)" = "E100_S101" ]
  [ "$(next story E99)" = "E99_S100" ]
  [ "$(next story E10)" = "E10_S11" ]
  [ "$(next story E101)" = "E101_S02" ]
  [ "$(next task E100_S100)" = "E100_S100_T101" ]
  [ "$(next task E1001_S100)" = "E1001_S100_T101" ]
  [ "$(next task E10_S10)" = "E10_S10_T11" ]
  [ "$(next task E10_S1)" = "E10_S1_T02" ]
  [ "$(next task E01_S01)" = "E01_S01_T03" ]
  [ -z "$(git -C "$WIDE" status --porcelain)" ]
}

@test "render-ranked-list.sh: eligible stories and tasks come out in numeric board order" {
  export JENGA_TODO_FILE="$WIDE/project/todo.md" JENGA_BOARD_EPICS_DIR="$B/epics" JENGA_BOARD_STORIES_DIR="$B/stories" JENGA_BOARD_TASKS_DIR="$B/tasks"
  run bash "$RANKED"
  [ "$status" -eq 0 ]
  # the generated todo lists E10_S10_T10 and E101_S01_T01: text order would put E101 first
  [ "$(printf '%s\n' "$output" | sed 's/^[0-9]*\. \([A-Z0-9_]*\) .*/\1/' | tr '\n' ' ')" = "E10_S10_T10 E101_S01_T01 " ]
  # a todo copy that lists every pending story and task gives the full numeric order
  { cat "$JENGA_TODO_FILE"; for id in E1001_S01 E101_S01 E11_S01 E100_S10; do echo "Mission $id: $id"; done; } > "$BATS_TEST_TMPDIR/todo.md"
  JENGA_TODO_FILE="$BATS_TEST_TMPDIR/todo.md" run bash "$RANKED"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed 's/^[0-9]*\. \([A-Z0-9_]*\) .*/\1/' | tr '\n' ' ')" = "E11_S01 E101_S01 E1001_S01 E10_S10_T10 E11_S01_T01 E100_S10_T10 E101_S01_T01 E1001_S01_T01 " ]
}

@test "the scripts leave the fixture unchanged and the repository's own board untouched" {
  before="$(git -C "$WIDE" log --format=%H | wc -l | tr -d ' ')"
  bash "$SCAN" > /dev/null
  bash "$CASCADE" E100 > /dev/null
  [ -z "$(git -C "$WIDE" status --porcelain)" ]
  [ "$(git -C "$WIDE" log --format=%H | wc -l | tr -d ' ')" = "$before" ]
  [ -z "$(find "$B" -type f ! -perm 644)" ]
}
