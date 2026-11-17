#!/usr/bin/env bats
#
# E92_S11_T02: skills/j-reconcile/scripts/detect-done-before-dependency.sh, the j.reconcile finding "a task is done although
# its dependency is not done" (user decision 2026-11-15, story E92_S11). The detection is board-progress.sh --graph's
# unfinished_deps; this script collects the flagged tasks and names each dependency with its status. Report-only: it never
# writes. Fixture only, built under $BATS_TEST_TMPDIR; the live board is never read.

bats_require_minimum_version 1.5.0

REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
S="$REPO/skills/j-reconcile/scripts/detect-done-before-dependency.sh"

item() {
  local id="$1" status="$2" dir f l
  shift 2
  case "$id" in
    *_T*) dir=tasks ;;
    *_S*) dir=stories ;;
    *)    dir=epics ;;
  esac
  f="$ROOT/project/board/$dir/${id}_x.md"
  { printf -- '---\nid: %s\ntitle: "Title of %s"\nstatus: %s\n' "$id" "$id" "$status"
    case "$id" in
      *_T*) printf 'story_id: %s\nepic_id: %s\n' "${id%_T*}" "${id%%_*}" ;;
      *_S*) printf 'epic_id: %s\n' "${id%%_*}" ;;
    esac
    for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n\n# body\n'
  } > "$f"
}

mkroot() {
  ROOT="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$ROOT/project/configs" "$ROOT/project/board/epics" "$ROOT/project/board/stories" "$ROOT/project/board/tasks"
  printf '{}\n' > "$ROOT/project/configs/workflow.json"
}

# E01_S01_T03 is done although its own dependency E01_S01_T02 was reopened (Failed); E01_S02_T01 is done although its story
# depends on E01_S01 (In Progress); E01_S02_T02 has both; E01_S01_T04 depends on a rejected task (satisfied); E01_S01_T05 is
# in progress on the failed task (it waits, it is not a contradiction).
contradiction() {
  mkroot contradiction
  item E01 "In Progress"
  item E01_S01 "In Progress"
  item E01_S02 Pending "depends_on: E01_S01"
  item E01_S01_T01 Passed
  item E01_S01_T02 Failed
  item E01_S01_T03 Passed "depends_on: [E01_S01_T01, E01_S01_T02]"
  item E01_S01_T04 Passed "depends_on: E01_S01_T06"
  item E01_S01_T05 "In Progress" "depends_on: E01_S01_T02"
  item E01_S01_T06 Rejected
  item E01_S02_T01 Passed
  item E01_S02_T02 Passed "depends_on: E01_S01_T02"
}

# Nothing contradictory: every done task's dependencies are done or rejected.
clean() {
  mkroot clean
  item E01 "In Progress"
  item E01_S01 Passed
  item E01_S02 Pending "depends_on: E01_S01"
  item E01_S01_T01 Passed
  item E01_S01_T02 Passed "depends_on: E01_S01_T01"
  item E01_S02_T01 Pending "depends_on: E01_S01_T02"
}

py() { python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); v=eval(sys.argv[2]); print(v if isinstance(v,str) else json.dumps(v,separators=(",",":"),ensure_ascii=False))' "$output" "$1"; }

@test "a done task whose dependency is not done is reported with the dependency and its status; nothing else is" {
  contradiction
  run --separate-stderr bash "$S" --root "$ROOT"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(py 'd["count"]')" = "3" ]
  [ "$(py '[f["task"] for f in d["findings"]]')" = '["E01_S01_T03","E01_S02_T01","E01_S02_T02"]' ]
  [ "$(py 'd["findings"][0]')" = '{"task":"E01_S01_T03","title":"Title of E01_S01_T03","status":"Passed","story_id":"E01_S01","epic_id":"E01","unfinished_deps":[{"id":"E01_S01_T02","level":"task","status":"Failed"}]}' ]
  [ "$(py 'd["findings"][1]["unfinished_deps"]')" = '[{"id":"E01_S01","level":"story","status":"In Progress"}]' ]
  # own dependency first, then the story's
  [ "$(py '[x["id"] for x in d["findings"][2]["unfinished_deps"]]')" = '["E01_S01_T02","E01_S01"]' ]
}

@test "a board with no contradiction reports nothing new (count 0, empty findings)" {
  clean
  run --separate-stderr bash "$S" --root "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"count":0,"findings":[]}' ]
}

@test "--within restricts to one story or epic; satisfaction is still judged over the whole board" {
  contradiction
  run --separate-stderr bash "$S" --root "$ROOT" --within E01_S02
  [ "$status" -eq 0 ]
  [ "$(py '[f["task"] for f in d["findings"]]')" = '["E01_S02_T01","E01_S02_T02"]' ]
  run --separate-stderr bash "$S" --root "$ROOT" --within E1
  [ "$(py 'd["count"]')" = "3" ]
}

@test "report-only: the board is byte-identical after a run, and the output is byte-identical across runs" {
  contradiction
  before="$(find "$ROOT" -type f | sort | xargs cksum)"
  run bash "$S" --root "$ROOT"
  first="$output"
  run bash "$S" --root "$ROOT"
  [ "$output" = "$first" ]
  [ "$(find "$ROOT" -type f | sort | xargs cksum)" = "$before" ]
  # and the script holds no write to a board file and no status edit
  ! grep -Eq "sed -i|> *\"?\\\$ROOT|status: *(Pending|Failed|Passed)" "$S"
}

@test "a board with no epic file gives count 0; a missing board-progress.sh exits 4; a bad argument exits 2" {
  mkroot empty
  run --separate-stderr bash "$S" --root "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"count":0,"findings":[]}' ]
  JENGA_BOARD_PROGRESS="$BATS_TEST_TMPDIR/nope.sh" run --separate-stderr bash "$S" --root "$ROOT"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [[ "$stderr" == *"board-progress.sh not found"* ]]
  run --separate-stderr bash "$S" --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$S" --within
  [ "$status" -eq 2 ]
}

@test "j.reconcile's SKILL.md runs the script and presents the finding as report-only" {
  SKILL="$REPO/skills/j-reconcile/SKILL.md"
  grep -qF 'skills/j-reconcile/scripts/detect-done-before-dependency.sh' "$SKILL"
  grep -qF 'DONE BEFORE ITS DEPENDENCY' "$SKILL"
  grep -qF 'DONE BEFORE ITS DEPENDENCY' "$REPO/skills/j-reconcile/assets/report_format.md"
  awk '/^#### Done before its dependency/{f=1} f && /^### 5\./{exit} f' "$SKILL" | grep -qi 'report-only'
}
