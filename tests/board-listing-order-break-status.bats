#!/usr/bin/env bats
#
# E86_S02_T06: skills/j-break/scripts/render-execution-status.sh orders the epic, story and task lines of its rapport by
# NUMERIC board ID, not by ID text.
#
# The rapport reads the three board directories and then grouped and printed the items with plain `sorted()`, which is
# text order: on a board holding E2, E10, E100 and E1001 it printed E10, E100, E1001, E2, and inside one story
# `..._T10` and `..._T100` came before `..._T2`. It now sorts with board_id_sort_key from scripts/lib/board_ids.py.
# Each case builds its own board in a temp project root via JENGA_PROJECT_ROOT; the real board is never read.
#
# Fixture rule (board-ids.md, Decisions item 7): the script resolves scripts/lib from its own location with no fallback
# ordering, so the one case that runs a COPY of the script copies scripts/lib next to it.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RENDER="$REPO_ROOT/skills/j-break/scripts/render-execution-status.sh"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs" "$PROJ/project/board/epics" "$PROJ/project/board/stories" "$PROJ/project/board/tasks"
  cat > "$PROJ/project/configs/workflow.json" <<'EOF'
{
  "paths": {
    "board": "project/board",
    "epics": "project/board/epics",
    "stories": "project/board/stories",
    "tasks": "project/board/tasks",
    "queue": "project/queue",
    "configs": "project/configs"
  }
}
EOF
  printf '{"bundle_lock_ttl_minutes": 30}\n' > "$PROJ/project/configs/scope-thresholds.json"
  printf '# Todo\n' > "$PROJ/project/todo.md"
  export JENGA_PROJECT_ROOT="$PROJ"
}

epic()  { printf -- '---\nid: %s\ntitle: epic %s\nstatus: In Progress\n---\n' "$1" "$1" > "$PROJ/project/board/epics/$1_x.md"; }
story() { printf -- '---\nid: %s\nepic_id: %s\ntitle: story %s\nstatus: In Progress\n---\n' "$1" "$2" "$1" > "$PROJ/project/board/stories/$1_x.md"; }
task()  { printf -- '---\nid: %s\nstory_id: %s\nepic_id: %s\ntitle: task %s\nstatus: In Progress\n---\n' "$1" "$2" "$3" "$1" > "$PROJ/project/board/tasks/$1_x.md"; }

# ids_in_output: the board ID that follows each icon on an epic, story or task line, in printed order
ids_in_output() {
  printf '%s\n' "$output" | grep -E '^ *(📦|📖|🔄|⏳|✅)' | sed -E 's/^ *[^ ]+ +//' | awk '{ print $1 }'
}

@test "epics, stories and tasks print in numeric order across widths" {
  local e s t
  for e in E1001 E100 E10 E2; do
    epic "$e"
    for s in S10 S2; do
      story "${e}_$s" "$e"
      for t in T100 T10 T2; do task "${e}_${s}_$t" "${e}_$s" "$e"; done
    done
  done
  run --separate-stderr bash "$RENDER"
  [ "$status" -eq 0 ]
  expected=""
  for e in E2 E10 E100 E1001; do
    expected="$expected$e"$'\n'
    for s in S2 S10; do
      expected="$expected${e}_$s"$'\n'
      for t in T2 T10 T100; do expected="$expected${e}_${s}_$t"$'\n'; done
    done
  done
  [ "$(ids_in_output)" = "${expected%$'\n'}" ]
}

@test "an all-two-digit board prints in the same order plain text sorting gave" {
  local e
  for e in E99 E10 E02 E11; do
    epic "$e"
    story "${e}_S01" "$e"
    task "${e}_S01_T02" "${e}_S01" "$e"
    task "${e}_S01_T01" "${e}_S01" "$e"
  done
  run --separate-stderr bash "$RENDER"
  [ "$status" -eq 0 ]
  expected=""
  for e in E02 E10 E11 E99; do
    expected="$expected$e"$'\n'"${e}_S01"$'\n'"${e}_S01_T01"$'\n'"${e}_S01_T02"$'\n'
  done
  [ "$(ids_in_output)" = "${expected%$'\n'}" ]
}

@test "a copy of the script without scripts/lib beside it fails loudly instead of falling back to text order" {
  local copy="$BATS_TEST_TMPDIR/copy"
  mkdir -p "$copy/skills/j-break/scripts" "$copy/scripts"
  cp "$RENDER" "$copy/skills/j-break/scripts/render-execution-status.sh"
  cp "$REPO_ROOT/scripts/resolve-root.sh" "$copy/scripts/resolve-root.sh"
  epic E10
  task E10_S01_T01 E10_S01 E10
  run --separate-stderr bash "$copy/skills/j-break/scripts/render-execution-status.sh"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"board_ids.py"* ]]
}
