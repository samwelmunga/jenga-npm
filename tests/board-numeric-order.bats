#!/usr/bin/env bats
#
# E86_S02_T03: board-scan.sh and board_index.py list board items in numeric order of their IDs, taken from the
# shared sort key in scripts/lib/board_ids.py (board_id_sort_key), so E10 < E11 < E100 < E1001 and
# E10_S2 < E10_S10 < E10_S100 rather than the filename text order (E100 before E11).
# Runs the real scripts and the real scripts/lib against a throwaway fixture git repo (never this repo's board),
# in the source layout and in a .claude/ mirror layout.
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$FX/skills/jenga/scripts" "$FX/skills/index/scripts" "$FX/scripts" "$FX/project/board/epics" \
    "$FX/project/board/stories" "$FX/project/board/tasks" "$FX/project/documentation/plans" \
    "$FX/project/documentation/summaries"
  git -C "$FX" init -q
  git -C "$FX" config user.email "test@example.com"
  git -C "$FX" config user.name "Test"
  git -C "$FX" commit -q --allow-empty -m "fixture: empty init"
  cp "$REPO_ROOT/skills/jenga/scripts/board-scan.sh" "$FX/skills/jenga/scripts/"
  cp "$REPO_ROOT/skills/index/scripts/board_index.py" "$FX/skills/index/scripts/"
  cp -R "$REPO_ROOT/scripts/lib" "$FX/scripts/lib"
}

# Writes the files in an order that is neither numeric nor the expected one (so a directory listing is not luck).
write_board() {
  local e s t
  for e in E1001 E10 E100 E11; do
    printf -- '---\nid: %s\ntitle: Epic %s\nstatus: Not Started\n---\n\n# Epic\n\n## Purpose\n\nPurpose %s\n' \
      "$e" "$e" "$e" > "$FX/project/board/epics/${e}_epic.md"
  done
  for s in E10_S100 E10_S2 E10_S10; do
    printf -- '---\nid: %s\nepic_id: E10\ntitle: Story %s\nstatus: Not Started\n---\n\n# Story: %s\n' \
      "$s" "$s" "$s" > "$FX/project/board/stories/${s}_story.md"
  done
  for t in E10_S2_T100 E10_S2_T2 E10_S2_T10; do
    printf -- '---\nid: %s\nstory_id: E10_S2\nepic_id: E10\ntitle: Task %s\nstatus: Not Started\n---\n\n# Task\n\n## Description\n\nDesc\n' \
      "$t" "$t" > "$FX/project/board/tasks/${t}_task.md"
  done
  for t in E10_S2_T100 E10_S2_T2 E10_S2_T10 E10_S100 E10_S2; do
    printf '# Plan %s\n' "$t" > "$FX/project/documentation/plans/${t}-plan.md"
    printf '# Summary %s\n' "$t" > "$FX/project/documentation/summaries/${t}-summary.md"
  done
  # A plan that is not named after a board ID keeps its text position between the epic's other names.
  printf '# Notes\n' > "$FX/project/documentation/plans/E10-notes-plan.md"
  printf '# Notes\n' > "$FX/project/documentation/plans/zz-unrelated.md"
}

# scan <root> -> board-scan.sh JSON on stdout (the harness may export CLAUDE_PROJECT_DIR; the fixture must not see it).
scan() {
  local root="${1:-$FX}"
  env -u CLAUDE_PROJECT_DIR -u JENGA_PROJECT_DIR -u COPILOT_WORKSPACE_FOLDER \
    bash "$root/${2:-skills}/jenga/scripts/board-scan.sh"
}

# ids_of <json-file> <type> -> one id per line, in file order
ids_of() {
  python3 - "$1" "$2" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1])):
    if item["type"] == sys.argv[2]:
        print(item["id"])
PY
}

run_index() { # <root> <subcommand> <outfile>
  (cd "$1" && env -u CLAUDE_PROJECT_DIR -u JENGA_PROJECT_DIR python3 "${4:-skills}/index/scripts/board_index.py" "$2" > "$3")
}

@test "board-scan.sh lists epics, stories and tasks in numeric order" {
  write_board
  scan > "$BATS_TEST_TMPDIR/scan.json"
  [ "$(ids_of "$BATS_TEST_TMPDIR/scan.json" epic | tr '\n' ' ')" = "E10 E11 E100 E1001 " ]
  [ "$(ids_of "$BATS_TEST_TMPDIR/scan.json" story | tr '\n' ' ')" = "E10_S2 E10_S10 E10_S100 " ]
  [ "$(ids_of "$BATS_TEST_TMPDIR/scan.json" task | tr '\n' ' ')" = "E10_S2_T2 E10_S2_T10 E10_S2_T100 " ]
}

@test "board-scan.sh keeps epics, then stories, then tasks" {
  write_board
  scan > "$BATS_TEST_TMPDIR/scan.json"
  run python3 - "$BATS_TEST_TMPDIR/scan.json" <<'PY'
import json, sys
types = [i["type"] for i in json.load(open(sys.argv[1]))]
sys.exit(0 if types == sorted(types, key=["epic", "story", "task"].index) else 1)
PY
  [ "$status" -eq 0 ]
}

@test "the index emits Epic, Story and Task nodes in numeric order" {
  write_board
  run_index "$FX" graph::nodes "$BATS_TEST_TMPDIR/nodes.json"
  [ "$(ids_of "$BATS_TEST_TMPDIR/nodes.json" Epic | tr '\n' ' ')" = "E10 E11 E100 E1001 " ]
  [ "$(ids_of "$BATS_TEST_TMPDIR/nodes.json" Story | tr '\n' ' ')" = "E10_S2 E10_S10 E10_S100 " ]
  [ "$(ids_of "$BATS_TEST_TMPDIR/nodes.json" Task | tr '\n' ' ')" = "E10_S2_T2 E10_S2_T10 E10_S2_T100 " ]
}

@test "the index emits Plan and Summary nodes in numeric order of their target ID" {
  write_board
  run_index "$FX" graph::nodes "$BATS_TEST_TMPDIR/nodes.json"
  [ "$(ids_of "$BATS_TEST_TMPDIR/nodes.json" Plan | tr '\n' ' ')" = \
    "E10-notes-plan E10_S2-plan E10_S2_T2-plan E10_S2_T10-plan E10_S2_T100-plan E10_S100-plan zz-unrelated " ]
  [ "$(ids_of "$BATS_TEST_TMPDIR/nodes.json" Summary | tr '\n' ' ')" = \
    "E10_S2-summary E10_S2_T2-summary E10_S2_T10-summary E10_S2_T100-summary E10_S100-summary " ]
}

@test "the index emits contains and plans edges in numeric order" {
  write_board
  printf -- '---\nid: E10\ntitle: Epic E10\nstatus: Not Started\nstories:\n  - E10_S100\n  - E10_S2\n  - E10_S10\n---\n\n# Epic\n' \
    > "$FX/project/board/epics/E10_epic.md"
  run_index "$FX" graph::edges "$BATS_TEST_TMPDIR/edges.json"
  run python3 - "$BATS_TEST_TMPDIR/edges.json" <<'PY'
import json, sys
edges = json.load(open(sys.argv[1]))
contains = [e["to"] for e in edges if e["type"] == "contains" and e["from"] == "E10"]
plans = [e["to"] for e in edges if e["type"] == "plans"]
assert contains == ["E10_S2", "E10_S10", "E10_S100"], contains
assert plans == ["E10_S2", "E10_S2_T2", "E10_S2_T10", "E10_S2_T100", "E10_S100"], plans
PY
  [ "$status" -eq 0 ]
}

@test "non-board nodes keep their text order" {
  write_board
  run_index "$FX" graph::nodes "$BATS_TEST_TMPDIR/nodes.json"
  run python3 - "$BATS_TEST_TMPDIR/nodes.json" <<'PY'
import json, sys
nodes = json.load(open(sys.argv[1]))
for node_type in {n["type"] for n in nodes} - {"Epic", "Story", "Task", "Plan", "Summary"}:
    ids = [n["id"] for n in nodes if n["type"] == node_type]
    assert ids == sorted(ids), (node_type, ids)
PY
  [ "$status" -eq 0 ]
}

@test "a .claude mirror layout orders the same way (board-scan.sh and the index)" {
  write_board
  mkdir -p "$FX/.claude/skills/jenga/scripts" "$FX/.claude/skills/index/scripts"
  cp "$FX/skills/jenga/scripts/board-scan.sh" "$FX/.claude/skills/jenga/scripts/"
  cp "$FX/skills/index/scripts/board_index.py" "$FX/.claude/skills/index/scripts/"
  cp -R "$FX/scripts" "$FX/.claude/scripts"
  rm -rf "$FX/skills/jenga" "$FX/skills/index" "$FX/scripts"
  scan "$FX" .claude/skills > "$BATS_TEST_TMPDIR/scan.json"
  [ "$(ids_of "$BATS_TEST_TMPDIR/scan.json" epic | tr '\n' ' ')" = "E10 E11 E100 E1001 " ]
  run_index "$FX" graph::nodes "$BATS_TEST_TMPDIR/nodes.json" .claude/skills
  [ "$(ids_of "$BATS_TEST_TMPDIR/nodes.json" Epic | tr '\n' ' ')" = "E10 E11 E100 E1001 " ]
}

@test "a node_modules/@jenga-ai/agent layout orders the same way" {
  write_board
  PKG="$FX/node_modules/@jenga-ai/agent"
  mkdir -p "$PKG/skills/jenga/scripts" "$PKG/skills/index/scripts"
  cp "$FX/skills/jenga/scripts/board-scan.sh" "$PKG/skills/jenga/scripts/"
  cp "$FX/skills/index/scripts/board_index.py" "$PKG/skills/index/scripts/"
  cp -R "$FX/scripts" "$PKG/scripts"
  rm -rf "$FX/skills/jenga" "$FX/skills/index" "$FX/scripts"
  scan "$FX" node_modules/@jenga-ai/agent/skills > "$BATS_TEST_TMPDIR/scan.json"
  [ "$(ids_of "$BATS_TEST_TMPDIR/scan.json" epic | tr '\n' ' ')" = "E10 E11 E100 E1001 " ]
  run_index "$FX" graph::nodes "$BATS_TEST_TMPDIR/nodes.json" node_modules/@jenga-ai/agent/skills
  [ "$(ids_of "$BATS_TEST_TMPDIR/nodes.json" Epic | tr '\n' ' ')" = "E10 E11 E100 E1001 " ]
}

@test "board-scan.sh fails loudly, with no fallback sort, when the shared lib is missing" {
  write_board
  rm -rf "$FX/scripts/lib"
  run scan
  [ "$status" -eq 1 ]
  assert_output_contains "board_ids.py not found"
}

@test "equal-width two-digit IDs order exactly as filename text order (existing board unchanged)" {
  local n
  for n in 20 03 11 02 10 99; do
    printf -- '---\nid: E%s\ntitle: Epic\nstatus: Not Started\n---\n\n# Epic\n' "$n" \
      > "$FX/project/board/epics/E${n}_epic.md"
  done
  scan > "$BATS_TEST_TMPDIR/scan.json"
  [ "$(ids_of "$BATS_TEST_TMPDIR/scan.json" epic | tr '\n' ' ')" = "E02 E03 E10 E11 E20 E99 " ]
  run_index "$FX" graph::nodes "$BATS_TEST_TMPDIR/nodes.json"
  [ "$(ids_of "$BATS_TEST_TMPDIR/nodes.json" Epic | tr '\n' ' ')" = "E02 E03 E10 E11 E20 E99 " ]
}
