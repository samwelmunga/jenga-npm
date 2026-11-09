#!/usr/bin/env bats
#
# E86_S01_T03: cascade-resolve.sh takes its ID shapes from scripts/lib/board_ids.py, so wide IDs
# (E100, E100_S100_T100) cascade correctly, a shorter epic never pulls in a longer one's children,
# and malformed IDs are still rejected.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO/skills/jenga/scripts/cascade-resolve.sh"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/board/epics" "$PROJ/project/board/stories" "$PROJ/project/board/tasks"
  mk_epic E10; mk_epic E100; mk_epic E1001
  mk_story E10_S01 E10; mk_task E10_S01_T01 E10_S01 E10
  mk_story E100_S100 E100; mk_task E100_S100_T100 E100_S100 E100
  mk_story E1001_S01 E1001; mk_task E1001_S01_T01 E1001_S01 E1001
  export CLAUDE_PROJECT_DIR="$PROJ"
}

mk_epic() { # <id>
  printf -- '---\nid: %s\ntitle: "Epic %s"\nstatus: Pending\n---\n\n## Purpose\n\nx\n' "$1" "$1" \
    > "$PROJ/project/board/epics/$1_x.md"
}
mk_story() { # <id> <epic>
  printf -- '---\nid: %s\nepic_id: %s\ntitle: "Story %s"\nstatus: Pending\n---\n\n# Story: S\n\nx\n' "$1" "$2" "$1" \
    > "$PROJ/project/board/stories/$1_x.md"
}
mk_task() { # <id> <story> <epic>
  printf -- '---\nid: %s\nstory_id: %s\nepic_id: %s\ntitle: "Task %s"\nstatus: Pending\n---\n\n## Description\n\nx\n' \
    "$1" "$2" "$3" "$1" > "$PROJ/project/board/tasks/$1_x.md"
}
ids() { jq -r '.resolved_ids | join(",")'; }

@test "cascading E100 returns E100 and only its own stories and tasks" {
  run bash "$SCRIPT" "E100"
  [ "$status" -eq 0 ]
  [ "$(ids <<<"$output")" = "E100,E100_S100,E100_S100_T100" ]
  [ "$(jq -c .counts <<<"$output")" = '{"epics":1,"stories":1,"tasks":1}' ]
}

@test "cascading E10 returns none of E100's or E1001's items" {
  run bash "$SCRIPT" "E10"
  [ "$status" -eq 0 ]
  [ "$(ids <<<"$output")" = "E10,E10_S01,E10_S01_T01" ]
}

@test "cascading E1001 returns only its own items" {
  run bash "$SCRIPT" "E1001"
  [ "$status" -eq 0 ]
  [ "$(ids <<<"$output")" = "E1001,E1001_S01,E1001_S01_T01" ]
}

@test "a wide story and a wide task ID resolve directly" {
  run bash "$SCRIPT" "E100_S100,E100_S100_T100"
  [ "$status" -eq 0 ]
  [ "$(ids <<<"$output")" = "E100_S100,E100_S100_T100" ]
  [ "$(jq '.warnings | length' <<<"$output")" -eq 0 ]
}

@test "malformed IDs are rejected as malformed, exactly as before" {
  for bad in "E1_" "e100" "E" "E01_T01" "E100x" "E10_S1_"; do
    run bash "$SCRIPT" "$bad"
    [ "$status" -eq 0 ]
    [ "$(jq '.resolved_ids | length' <<<"$output")" -eq 0 ]
    [ "$(jq -r '.warnings[0].reason' <<<"$output")" = "malformed ID (does not match E##, E##_S##, or E##_S##_T## shape)" ]
  done
}

@test "a well-formed ID absent from the board is not found, not malformed" {
  run bash "$SCRIPT" "E999"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.warnings[0].reason' <<<"$output")" = "not found on board" ]
}

@test "the script has no digit-width ID regex of its own" {
  run grep -E '\\d\{2\}' "$SCRIPT"
  [ "$status" -ne 0 ]
}
