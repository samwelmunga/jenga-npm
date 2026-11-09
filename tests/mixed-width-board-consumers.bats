#!/usr/bin/env bats
#
# E86_S06_T03: the board index, close-story, bundle-resume, proposed-items and commit-name scripts, run against the
# mixed-width synthetic board (E01 E10 E11 E99 E100 E101 E1001 with S10, S100 and T100 items) from
# tests/helpers/mixed-width-board.sh.
#
# Isolation. setup_file generates the wide fixture once into $BATS_FILE_TMPDIR with TMPDIR and HOME pointed at empty
# directories there, copies it to a "harness" project, and installs plain copies of the scripts under test (plus
# their shared helpers) into that copy. Several of them find the project root from their own location, so running the
# copies is what makes them read the fixture and never this repository's board. Everything is driven with `bash`; no
# network and no write outside $BATS_FILE_TMPDIR / $BATS_TEST_TMPDIR. Every assertion is on real script output.
#
# Known property of the fixture: E10_S01 and E10_S1 (and their tasks) are numerically equal, so any order between
# those two is by text; exact orders below are asserted only where that is deterministic.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup_file() {
  F="$BATS_FILE_TMPDIR"
  export TMPDIR="$F/tmp" HOME="$F/home" PYTHONDONTWRITEBYTECODE=1
  mkdir -p "$TMPDIR" "$HOME"
  bash "$REPO_ROOT/tests/helpers/mixed-width-board.sh" "$F/fx" > "$F/gen.out" 2>&1
  cp -R "$F/fx" "$F/h"
  local rel
  for rel in skills/index/scripts/board_index.py skills/j-close-story/scripts/check-story-closeable.sh \
    skills/j-close-story/scripts/extract-task-diff-stats.sh skills/j-do/scripts/bundle-resume.sh \
    skills/j-uncharted/scripts/validate-proposed-items.sh skills/j-commit/scripts/commit-subject-check.sh \
    scripts/commits-for-item.sh scripts/resolve-root.sh scripts/validate-board.sh scripts/validate-story-format.sh \
    scripts/validate-conventions.sh; do
    mkdir -p "$F/h/$(dirname "$rel")"
    cp "$REPO_ROOT/$rel" "$F/h/$rel"
  done
  cp -R "$REPO_ROOT/scripts/lib" "$F/h/scripts/lib"
  (cd "$F/h" && python3 skills/index/scripts/board_index.py graph::nodes > "$F/nodes.json" &&
    python3 skills/index/scripts/board_index.py graph::edges > "$F/edges.json")
}

setup() {
  F="$BATS_FILE_TMPDIR"
  H="$F/h"
  export TMPDIR="$F/tmp" HOME="$F/home" PYTHONDONTWRITEBYTECODE=1 JENGA_PROJECT_ROOT="$H"
  cd "$H"
}

# ids_of <Type>  - the ids of that node type, in the order the index printed them, space separated.
ids_of() {
  python3 -c 'import json,sys; print(" ".join(n["id"] for n in json.load(open(sys.argv[1])) if n["type"]==sys.argv[2]))' \
    "$F/nodes.json" "$1"
}

# sha_of <subject-prefix>  - the one fixture commit whose subject starts with it.
sha_of() { git -C "$H" log -n1 --format=%H --grep="^$1"; }

# expected_stats <task-id>  - "files lines" computed straight from git, independently of the script under test.
expected_stats() {
  local sha
  for sha in $(git -C "$H" log --no-merges --format=%H -F --grep="($1)"); do
    git -C "$H" diff --numstat "$sha~1" "$sha"
  done | awk '{f++; l+=$1+$2} END {printf "%d %d\n", f, l}'
}

# e10s1_sum  - checksum of every file belonging to story E10_S1 (and only those).
e10s1_sum() { (cd "$H" && find project -type f \( -name 'E10_S1_*' -o -name 'E10_S1-*' \) | sort | xargs cksum); }

@test "index lists epics and tasks in numeric order, E100 after E99 and before E101 and E1001" {
  [ "$(ids_of Epic)" = "E01 E10 E11 E99 E100 E101 E1001" ]
  [ "$(ids_of Task)" = "E01_S01_T01 E01_S01_T02 E10_S01_T01 E10_S1_T1 E10_S10_T10 E11_S01_T01 E99_S99_T99 E100_S10_T10 E100_S100_T99 E100_S100_T100 E101_S01_T01 E1001_S01_T01 E1001_S100_T100" ]
  assert_contains " $(ids_of Story) " " E99_S99 E100_S10 E100_S100 E101_S01 E1001_S01 E1001_S100 "
}

@test "index links E100_S100_T100's plan and summary to that task and the todo entry queues it" {
  run python3 - "$F/nodes.json" "$F/edges.json" <<'PY'
import json, sys
nodes = json.load(open(sys.argv[1])); edges = json.load(open(sys.argv[2]))
tid = "E100_S100_T100"
by_id = {(n["type"], n["id"]): n for n in nodes}
for kind, edge in (("Plan", "plans"), ("Summary", "summarizes")):
    n = by_id[(kind, tid + "-" + kind.lower())]
    assert n["path"] == "project/documentation/%s/%s-%s.md" % ("plans" if kind == "Plan" else "summaries", tid, kind.lower()), n
    assert (n["story_id"], n["task_id"]) == ("E100_S100", tid), n
    assert {"from": n["id"], "to": tid, "type": edge} in edges
    # Every plan/summary edge goes to the item named in its own file name, never to a neighbour.
    for e in edges:
        if e["type"] == edge:
            assert e["from"] == e["to"] + "-" + kind.lower(), e
story_sum = by_id[("Summary", "E100_S100-summary")]
assert story_sum["task_id"] is None and story_sum["story_id"] == "E100_S100"
todo = by_id[("TodoEntry", tid)]
assert todo["board_ref"] == tid and todo["path"] == "project/todo.md"
queued = sorted((e["from"], e["to"]) for e in edges if e["type"] == "queued_as")
assert queued == sorted((i, i) for i in "E01_S01 E10_S10_T10 E99_S99_T99 E100_S100_T100 E101_S01_T01 E1001_S100_T100".split()), queued
print("linked")
PY
  [ "$status" -eq 0 ]
  assert_contains "$output" "linked"
}

@test "index has no edge between an E10 item and an E100 or E1001 item, and each family's edges exist" {
  run python3 - "$F/edges.json" <<'PY'
import json, re, sys
edges = json.load(open(sys.argv[1]))
fam = lambda s: re.match(r"E\d+", s).group(0)
cross = [e for e in edges if fam(e["from"]) != fam(e["to"])]
assert not cross, cross
count = lambda f: sum(1 for e in edges if fam(e["from"]) == f)
contains = {(e["from"], e["to"]) for e in edges if e["type"] == "contains" and e["from"] == "E10"}
assert contains == {("E10", "E10_S01"), ("E10", "E10_S1"), ("E10", "E10_S10")}, contains
print("cross=0 e10=%d e100=%d e1001=%d" % (count("E10"), count("E100"), count("E1001")))
PY
  [ "$status" -eq 0 ]
  assert_contains "$output" "cross=0 "
  case "$output" in *"e10=0"*|*"e100=0"*|*"e1001=0"*) return 1 ;; esac
}

@test "check-story-closeable reports the wide stories closeable and names the open E100_S10_T10 for E100_S10" {
  for s in E100_S100 E1001_S100 E10_S1 E01_S01; do
    run --separate-stderr bash skills/j-close-story/scripts/check-story-closeable.sh "$s"
    [ "$status" -eq 0 ]
    [ "$output" = "CLOSEABLE" ]
  done
  run --separate-stderr bash skills/j-close-story/scripts/check-story-closeable.sh E100_S10
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "OPEN: 'E100_S10_T10' has status 'Pending'"
  run --separate-stderr bash skills/j-close-story/scripts/check-story-closeable.sh E10_S10
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "'E10_S10_T10'"
  assert_not_contains "$stderr" "E100"
}

@test "extract-task-diff-stats counts exactly each task's own commits, E100_S100_T100 and E1001_S100_T100 included" {
  for t in E100_S100_T100 E100_S100_T99 E1001_S100_T100 E100_S10_T10 E10_S10_T10; do
    run --separate-stderr bash skills/j-close-story/scripts/extract-task-diff-stats.sh "$t"
    [ "$status" -eq 0 ]
    set -- $(expected_stats "$t")
    [ "$1" -gt 0 ]
    [ "$output" = "$(printf 'actual_files_changed: %s\nactual_lines_delta: %s' "$1" "$2")" ]
  done
  run --separate-stderr bash skills/j-close-story/scripts/extract-task-diff-stats.sh E100_S100_T10
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'actual_files_changed: 0\nactual_lines_delta: 0')" ]
  run --separate-stderr bash skills/j-close-story/scripts/extract-task-diff-stats.sh E100_S100
  [ "$status" -eq 1 ]
}

@test "bundle-resume resumes E100_S100 from the fixture manifest and leaves E10_S1's files untouched" {
  before="$(e10s1_sum)"
  tree="$(find project -type f | sort | xargs cksum | cksum)"
  [ "$(printf '%s\n' "$before" | wc -l | tr -d ' ')" -eq 5 ]
  run --separate-stderr bash skills/j-do/scripts/bundle-resume.sh E100_S100
  [ "$status" -eq 0 ]
  assert_contains "$output" '"mode": "resume"'
  assert_contains "$output" "\"anchor_sha\": \"$(sha_of 'story(E100_S100):')\""
  assert_contains "$output" '"run": []'
  assert_contains "$output" '"skipped": ["E100_S100_T99", "E100_S100_T100"]'
  assert_not_contains "$output" "E10_S1"
  # A copy where T100 is Failed: only that task runs again, and the note names it, not its E10 look-alikes.
  cp -R "$H" "$BATS_TEST_TMPDIR/h2"
  sed 's/^status: Passed$/status: Failed/' "$H/project/board/tasks/E100_S100_T100_fixture-task.md" > "$BATS_TEST_TMPDIR/t.md"
  mv "$BATS_TEST_TMPDIR/t.md" "$BATS_TEST_TMPDIR/h2/project/board/tasks/E100_S100_T100_fixture-task.md"
  cd "$BATS_TEST_TMPDIR/h2"
  JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/h2" run --separate-stderr bash skills/j-do/scripts/bundle-resume.sh E100_S100
  [ "$status" -eq 0 ]
  assert_contains "$output" '"run": ["E100_S100_T100"]'
  assert_contains "$output" "E100_S100_T100 is Failed and will be run again"
  # The wide story with no manifest is fresh, and nothing in the harness project changed.
  run --separate-stderr bash "$H/skills/j-do/scripts/bundle-resume.sh" E10_S1
  [ "$status" -eq 0 ]
  assert_contains "$output" '"mode": "fresh"'
  assert_contains "$output" '"run": ["E10_S1_T1"]'
  [ "$(e10s1_sum)" = "$before" ]
  [ "$(cd "$H" && find project -type f | sort | xargs cksum | cksum)" = "$tree" ]
  [ -z "$(git -C "$H" status --porcelain -- project)" ]
}

@test "validate-proposed-items accepts a proposed E100_S100 story, and rejects it when its sections are missing" {
  p="$BATS_TEST_TMPDIR/proposed/project/board"
  mkdir -p "$p/epics" "$p/stories" "$p/tasks"
  cp "$H/project/board/epics/E100_fixture-epic.md" "$p/epics/"
  cp "$H/project/board/tasks/E100_S100_T100_fixture-task.md" "$p/tasks/"
  cp "$H/project/board/stories/E100_S100_fixture-story.md" "$p/stories/"
  run --separate-stderr bash skills/j-uncharted/scripts/validate-proposed-items.sh "$p/stories/E100_S100_fixture-story.md"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "story format"
  assert_contains "$stderr" "exit 2"
  printf '\n## Acceptance Criteria\n\n- [ ] It works\n\n## Definition of Done\n\n- [ ] Done\n' >> "$p/stories/E100_S100_fixture-story.md"
  run --separate-stderr bash skills/j-uncharted/scripts/validate-proposed-items.sh \
    "$p/epics/E100_fixture-epic.md" "$p/stories/E100_S100_fixture-story.md" "$p/tasks/E100_S100_T100_fixture-task.md"
  [ "$status" -eq 0 ]
  assert_contains "$output" "3 board file(s) valid (1 story file(s) additionally format-checked)"
}

@test "commit-subject-check classifies every fixture commit subject, wide ids included, as board or non-board" {
  total=0; boards=0; expected=0
  while IFS= read -r subject; do
    total=$((total + 1))
    case "$subject" in *E[0-9]*) want=board; expected=$((expected + 1)) ;; *) want=non-board ;; esac
    run --separate-stderr bash skills/j-commit/scripts/commit-subject-check.sh "$subject"
    [ "$status" -eq 0 ]
    assert_starts_with "$output" "kind=$want;"
    [ "$want" = board ] && boards=$((boards + 1))
  done < <(git -C "$H" log --format=%s)
  [ "$total" -eq "$(git -C "$H" rev-list --count HEAD)" ]
  [ "$total" -gt 30 ]
  [ "$boards" -eq "$expected" ]
  [ "$boards" -gt 30 ]
}

@test "a recorded commit-format convention never applies to wide board subjects but still applies to non-board ones" {
  printf '%s\n' '{"conventions_version":1,"categories":{"commit-format":{"source":"custom","summary":"x","values":{"style":"conventional","message_regex":"^(feat|fix): ."}}}}' > "$BATS_TEST_TMPDIR/conv.json"
  export JENGA_CONVENTIONS_SCHEMA="$REPO_ROOT/templates/conventions-schema.json"
  chk() { bash skills/j-commit/scripts/commit-subject-check.sh --conventions "$BATS_TEST_TMPDIR/conv.json" "$1"; }
  for s in "task(E1001_S100_T100): add fixture task" "chore(E1001_S100_T100): add rapport - fixture sample problem" \
    "merge: land E100_S100_T100-fixture-task into main (Passed)" "epic(E1001): add fixture epic"; do
    run chk "$s"
    [ "$status" -eq 0 ]
    assert_starts_with "$output" "kind=board;"
  done
  run chk "chore: scaffold fixture project"
  [ "$status" -eq 1 ]
  assert_contains "$output" "does not match the recorded message_regex"
  run chk "feat: scaffold fixture project"
  [ "$status" -eq 0 ]
  assert_contains "$output" "conforms"
}

@test "commits-for-item keeps E1001, E100, E10 and their stories and tasks apart in the fixture history" {
  q() { bash scripts/commits-for-item.sh "$@"; }
  top="$(sha_of 'task(E1001_S100_T100):')"; rap="$(sha_of 'chore(E1001_S100_T100):')"
  narrow="$(sha_of 'task(E100_S10_T10):')"; old="$(sha_of 'task(E10_S10_T10):')"
  [ -n "$top" ] && [ -n "$rap" ] && [ -n "$narrow" ] && [ -n "$old" ]
  run --separate-stderr q E1001_S100_T100
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s' "$rap" "$top")" ]
  assert_not_contains "$output" "$narrow"
  run --separate-stderr q E100_S10_T10
  [ "$output" = "$narrow" ]
  run --separate-stderr q E10_S10_T10
  [ "$output" = "$old" ]
  run --separate-stderr q E100_S10
  [ "$output" = "$(sha_of 'story(E100_S10):')" ]
  run --separate-stderr q E10
  [ "$output" = "$(sha_of 'epic(E10):')" ]
  run --separate-stderr q E100_S100_T100
  assert_contains "$output" "$(sha_of 'task(E100_S100_T100):')"
  assert_not_contains "$output" "$(sha_of 'task(E100_S100_T99):')"
  run --separate-stderr q E100_S100_T100 --repo "$H"
  [ "$status" -eq 0 ]
  run --separate-stderr q E100_S100_T10 --require-nonempty
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "E100_S100_T10"
}
