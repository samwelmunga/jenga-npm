#!/usr/bin/env bats
#
# E86_S01_T05: board_index.py takes its board-ID patterns from the shared module scripts/lib/board_ids.py,
# so IDs wider than two digits (E100, E100_S100, E1001_S100_T100) are indexed and linked like any other.
# Runs the real script plus the real scripts/lib against a throwaway fixture git repo
# (same layout convention as tests/board-index-root-climb.bats).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TASK=E1001_S100_T100

setup() {
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$FX/skills/index/scripts" "$FX/scripts" "$FX/project/board/epics" "$FX/project/board/stories" \
    "$FX/project/board/tasks" "$FX/project/documentation/plans" "$FX/project/documentation/summaries"
  git -C "$FX" init -q
  git -C "$FX" config user.email "test@example.com"
  git -C "$FX" config user.name "Test"
  git -C "$FX" commit -q --allow-empty -m "fixture: empty init"
  cp "$REPO_ROOT/skills/index/scripts/board_index.py" "$FX/skills/index/scripts/"
  cp -R "$REPO_ROOT/scripts/lib" "$FX/scripts/lib"
}

write_board() {
  printf -- '---\nid: E100\ntitle: Wide epic\nstatus: Not Started\nstories:\n  - E100_S100\n---\n\n# Epic\n' \
    > "$FX/project/board/epics/E100_wide.md"
  printf -- '---\nid: E100_S100\nepic_id: E100\ntitle: Wide story\nstatus: Not Started\ntasks:\n  - %s\n---\n\n# Story\n' "$TASK" \
    > "$FX/project/board/stories/E100_S100_wide.md"
  printf -- '---\nid: %s\nstory_id: E100_S100\nepic_id: E100\ntitle: Wide task\nstatus: Not Started\n---\n\n# Task\n' "$TASK" \
    > "$FX/project/board/tasks/${TASK}_wide.md"
}

# Prints the node/edge lists the script emits, as JSON, into $1 / $2.
run_index() {
  python3 "$FX/skills/index/scripts/board_index.py" graph::nodes > "$BATS_TEST_TMPDIR/nodes.json"
  python3 "$FX/skills/index/scripts/board_index.py" graph::edges > "$BATS_TEST_TMPDIR/edges.json"
}

# has_edge <type> <from-prefix> <to>
has_edge() {
  python3 - "$BATS_TEST_TMPDIR/edges.json" "$1" "$2" "$3" <<'PY'
import json, sys
path, etype, frm, to = sys.argv[1:]
edges = json.load(open(path))
sys.exit(0 if any(e["type"] == etype and e["from"].startswith(frm) and e["to"] == to for e in edges) else 1)
PY
}

has_node() {
  python3 - "$BATS_TEST_TMPDIR/nodes.json" "$1" "$2" <<'PY'
import json, sys
path, ntype, nid = sys.argv[1:]
sys.exit(0 if any(n["type"] == ntype and n["id"] == nid for n in json.load(open(path))) else 1)
PY
}

@test "epic, story and task with wide IDs become board nodes" {
  write_board
  run_index
  has_node Epic E100
  has_node Story E100_S100
  has_node Task "$TASK"
}

@test "plan, summary and todo entry for a wide task ID link to that task" {
  write_board
  printf -- '# Plan\n' > "$FX/project/documentation/plans/${TASK}-plan.md"
  printf -- '# Summary\n' > "$FX/project/documentation/summaries/${TASK}-summary.md"
  printf -- '- [ ] Do the wide thing %s\n' "$TASK" > "$FX/project/todo.md"
  run_index
  has_edge plans "" "$TASK"
  has_edge summarizes "" "$TASK"
  has_edge queued_as "" "$TASK"
  has_edge contains E100_S100 "$TASK"
}

@test "malformed IDs are not linked: plan/summary stems and todo refs that are not board IDs yield no edges" {
  write_board
  for bad in E1_ E01_T01 e01_s01_t01 E01_S01_T01x; do
    printf -- '# Plan\n' > "$FX/project/documentation/plans/${bad}-plan.md"
    printf -- '# Summary\n' > "$FX/project/documentation/summaries/${bad}-summary.md"
  done
  printf -- '- [ ] one E01_T01\n- [ ] two e01_s01_t01\n- [ ] three E1_\n' > "$FX/project/todo.md"
  run_index
  run python3 - "$BATS_TEST_TMPDIR/edges.json" <<'PY'
import json, sys
bad = [e for e in json.load(open(sys.argv[1])) if e["type"] in ("plans", "summarizes", "queued_as")]
print(bad)
sys.exit(1 if bad else 0)
PY
  [ "$status" -eq 0 ]
}
