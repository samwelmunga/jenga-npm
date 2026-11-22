#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E92_S09_T03: the epic percent that counts undecomposed stories, printed by scripts/board-progress.sh as the
# `epic_progress` object (section 5 of project/documentation/progress-visualisation.md):
#
#   percent = floor(100 * tasks_done * decomposed / (tasks_denominator * stories))
#
# stories = the epic's counted stories (own bucket not rejected, not unknown); decomposed = counted stories with at least
# one counted task; tasks_done / tasks_denominator = done and denominator over those stories' tasks (rejected and
# unknown-status tasks excluded, as everywhere). 0 with no counted or no decomposed story; goal_reached iff percent is 100.
# E92_S10_T02 (user decision 2026-11-15, "'Goal reached' när en story är Failed: hindra det"): failed_stories lists the
# counted stories whose own status is in the failed bucket (Failed and Blocked), numeric id order; while it is not empty
# goal_reached is false and percent is capped at 99 (below 100 unchanged).
# Fixture only, built under $BATS_TEST_TMPDIR; the live project/board/ is never read.

bats_require_minimum_version 1.5.0

load helpers/assertions

SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/board-progress.sh"

# item <id> <status> [raw frontmatter lines...]: writes one board file under $ROOT (story_id/epic_id derived from the id
# unless a raw line overrides them; a later duplicate key wins in the script's frontmatter reader).
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

# One epic per case.
#   E01  5 stories, 3 decomposed (2 tasks each), half their tasks done            -> 30 %
#   E02  5 stories, 3 decomposed, all their tasks done                             -> 60 %
#   E03  5 stories, all decomposed, all done (Passed, Merged, Done, Passed w/ r.)  -> 100 %, goal reached
#   E04  no stories                                                                -> 0 %
#   E05  3 stories, no tasks                                                       -> 0 %
#   E06  rejected tasks: S01 Passed+Passed+Rejected, S02 only Rejected tasks       -> S02 not decomposed: 1/2 x 2/2 = 50 %
#   E07  rejected and unknown-status stories are not counted, nor their tasks      -> 1 story, 1/2 done = 50 %
#   E08  1 story, 200 tasks, 199 done: 99.5 % floors to 99, never 100              -> 99 %, goal not reached
#   E09  a task whose epic_id names another epic is not counted under its story    -> 1/1 x 1/1 = 100 %
#   E10  one story, its only task rejected; the epic is not decomposed at all      -> 0 %
#   E11  3 stories all done by their tasks, S02's own status Failed (E92_S10_T02)  -> 99 %, no goal, [E11_S02]
#   E12  1 story, its tasks done, its own status Blocked                          -> 99 %, no goal, [E12_S01]
#   E13  S01 Failed (task done), S02 tasks 1/2 done: 2/3 x 2/2 = 66 %              -> 66 % unchanged, no goal, [E13_S01]
#   E14  S1 done, S9 Blocked, S10 Failed, every task done (numeric order S9, S10)  -> 99 %, no goal, [E14_S9, E14_S10]
board() {
  mkroot board
  local s t
  item E01 Pending
  for s in 1 2 3 4 5; do item "E01_S0$s" Pending; done
  for s in 1 2 3; do item "E01_S0${s}_T01" Passed; item "E01_S0${s}_T02" Pending; done

  item E02 "In Progress"
  for s in 1 2 3 4 5; do item "E02_S0$s" Pending; done
  for s in 1 2 3; do item "E02_S0${s}_T01" Passed; item "E02_S0${s}_T02" Merged; done

  item E03 Pending
  for s in 1 2 3 4 5; do item "E03_S0$s" Passed; done
  item E03_S01_T01 Passed; item E03_S02_T01 Merged; item E03_S03_T01 Done
  item E03_S04_T01 "Passed with remarks"; item E03_S05_T01 "Deployed to Prod"

  item E04 Pending

  item E05 Pending
  for s in 1 2 3; do item "E05_S0$s" Pending; done

  item E06 Pending
  item E06_S01 Passed; item E06_S01_T01 Passed; item E06_S01_T02 Passed; item E06_S01_T03 Rejected
  item E06_S02 Pending; item E06_S02_T01 Rejected

  item E07 Pending
  item E07_S01 Pending; item E07_S01_T01 Passed; item E07_S01_T02 Pending; item E07_S01_T03 "Not Started"
  item E07_S02 Rejected; item E07_S02_T01 Pending; item E07_S02_T02 Pending
  item E07_S03 "Not Started"; item E07_S03_T01 Pending

  item E08 Pending
  item E08_S01 Pending
  t=1
  while [ "$t" -le 200 ]; do
    if [ "$t" -le 199 ]; then item "E08_S01_T$t" Passed; else item "E08_S01_T$t" Pending; fi
    t=$((t + 1))
  done

  item E09 Pending
  item E09_S01 Pending; item E09_S01_T01 Passed
  item E09_S01_T02 Pending "epic_id: E10"

  item E10 Pending
  item E10_S01 Pending; item E10_S01_T01 Rejected

  item E11 "In Progress"
  item E11_S01 Passed; item E11_S01_T01 Passed
  item E11_S02 Failed; item E11_S02_T01 Passed; item E11_S02_T02 Merged
  item E11_S03 Passed; item E11_S03_T01 Passed

  item E12 Pending
  item E12_S01 Blocked; item E12_S01_T01 Passed; item E12_S01_T02 Passed

  item E13 Pending
  item E13_S01 Failed; item E13_S01_T01 Passed
  item E13_S02 Pending; item E13_S02_T01 Passed; item E13_S02_T02 Pending

  item E14 Pending
  item E14_S1 Passed; item E14_S1_T01 Passed
  item E14_S9 Blocked; item E14_S9_T01 Passed
  item E14_S10 Failed; item E14_S10_T01 Passed
}

run_bp() {
  RC=0
  bash "$SCRIPT" --root "$ROOT" "$@" > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err" || RC=$?
}

# py '<expression over d>' [file]: the expression evaluated on the JSON of the last run (compact for containers).
py() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = eval(sys.argv[2])
print(v if isinstance(v, str) else json.dumps(v, separators=(",", ":")))
' "${2:-$BATS_TEST_TMPDIR/out}" "$1"
}

# graph_ep <epic id>: the compact epic_progress object of that epic in the last --graph run.
graph_ep() { py "[e for e in d['epics'] if e['id'] == '$1'][0]['epic_progress']"; }

# ep <stories> <decomposed> <tasks_done> <tasks_denominator> <percent> <goal> [<failed_stories JSON>]: the expected
# compact object; failed_stories (E92_S10_T02) defaults to [].
ep() { printf '{"stories":%d,"decomposed":%d,"tasks_done":%d,"tasks_denominator":%d,"percent":%d,"goal_reached":%s,"failed_stories":%s}' "$1" "$2" "$3" "$4" "$5" "$6" "${7:-[]}"; }

setup() { board; }

@test "30 %: 5 stories, 3 decomposed, half their tasks done" {
  run_graph_ok
  [ "$(graph_ep E01)" = "$(ep 5 3 3 6 30 false)" ]
}

@test "60 %: 5 stories, 3 decomposed, all their tasks done (not 100 %)" {
  run_graph_ok
  [ "$(graph_ep E02)" = "$(ep 5 3 6 6 60 false)" ]
  # the task totals alone would say 6/6: they keep their meaning, the new figure is a separate key
  [ "$(py "[e for e in d['epics'] if e['id'] == 'E02'][0]['tasks']['totals']['done']")" = "6" ]
  [ "$(py "[e for e in d['epics'] if e['id'] == 'E02'][0]['tasks']['totals']['denominator']")" = "6" ]
}

@test "100 % and goal_reached only when every story is decomposed and every task done (done-bucket statuses all count)" {
  run_graph_ok
  [ "$(graph_ep E03)" = "$(ep 5 5 5 5 100 true)" ]
  # goal_reached is true for no other epic of the fixture
  [ "$(py "[e['id'] for e in d['epics'] if e['epic_progress']['goal_reached']]")" = '["E03","E09"]' ]
  [ "$(py "[e['id'] for e in d['epics'] if e['epic_progress']['percent'] == 100]")" = '["E03","E09"]' ]
}

@test "floor rounding: 99.5 % prints 99 and the goal is not reached" {
  run_graph_ok
  [ "$(graph_ep E08)" = "$(ep 1 1 199 200 99 false)" ]
}

@test "0 %: an epic with no stories, and an epic whose stories have no tasks (no division by zero)" {
  run_graph_ok
  [ "$(graph_ep E04)" = "$(ep 0 0 0 0 0 false)" ]
  [ "$(graph_ep E05)" = "$(ep 3 0 0 0 0 false)" ]
  [ "$(graph_ep E10)" = "$(ep 1 0 0 0 0 false)" ]
}

@test "rejected tasks are excluded: they neither count nor make a story decomposed" {
  run_graph_ok
  # S01: 2 of 2 counted tasks done (the rejected one is out); S02: its only task is rejected, so it is not decomposed
  [ "$(graph_ep E06)" = "$(ep 2 1 2 2 50 false)" ]
}

@test "rejected and unknown-status stories are not counted, nor their tasks; unknown-status tasks are excluded" {
  run_graph_ok
  [ "$(graph_ep E07)" = "$(ep 1 1 1 2 50 false)" ]
  # stories equals the stories' own denominator (section 5 applied to stories)
  [ "$(py "[e for e in d['epics'] if e['id'] == 'E07'][0]['stories']['totals']['denominator']")" = "1" ]
}

@test "a task counts under its story only when its own epic_id names the story's epic" {
  run_graph_ok
  [ "$(graph_ep E09)" = "$(ep 1 1 1 1 100 true)" ]
  # and --epic E09, whose records are chosen by each item's own epic_id, agrees
  run_bp --epic E09
  [ "$RC" -eq 0 ]
  [ "$(py 'd["epic_progress"]')" = "$(ep 1 1 1 1 100 true)" ]
}

@test "invariants on every epic: stories = stories.totals.denominator, decomposed <= stories, tasks within tasks.totals" {
  run_graph_ok
  [ "$(py "all(e['epic_progress']['stories'] == e['stories']['totals']['denominator'] for e in d['epics'])")" = "true" ]
  [ "$(py "all(e['epic_progress']['decomposed'] <= e['epic_progress']['stories'] for e in d['epics'])")" = "true" ]
  [ "$(py "all(e['epic_progress']['tasks_denominator'] <= e['tasks']['totals']['denominator'] for e in d['epics'])")" = "true" ]
  [ "$(py "all(e['epic_progress']['tasks_done'] <= e['epic_progress']['tasks_denominator'] for e in d['epics'])")" = "true" ]
  [ "$(py "all(0 <= e['epic_progress']['percent'] <= 100 for e in d['epics'])")" = "true" ]
}

@test "the same object in --graph, --graph --counts-only, --graph --within, --by-parent and --epic" {
  local e mode
  run_bp --graph
  cp "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/graph.json"
  run_bp --graph --counts-only
  cp "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/cards.json"
  run_bp --by-parent
  [ "$RC" -eq 0 ]
  cp "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/byparent.json"
  [ "$(py "list(d['epics'][0].keys())" "$BATS_TEST_TMPDIR/byparent.json")" = '["id","level","totals","epic_progress"]' ]
  [ "$(py "list(d['stories'][0].keys())" "$BATS_TEST_TMPDIR/byparent.json")" = '["id","level","totals"]' ]
  for e in E01 E02 E03 E05 E06 E07 E08 E09 E10 E11 E12 E13 E14; do
    want="$(py "[x for x in d['epics'] if x['id'] == '$e'][0]['epic_progress']" "$BATS_TEST_TMPDIR/graph.json")"
    [ "$(py "[x for x in d['epics'] if x['id'] == '$e'][0]['epic_progress']" "$BATS_TEST_TMPDIR/cards.json")" = "$want" ]
    [ "$(py "[x for x in d['epics'] if x['id'] == '$e'][0]['epic_progress']" "$BATS_TEST_TMPDIR/byparent.json")" = "$want" ]
    run_bp --graph --within "$e"
    [ "$RC" -eq 0 ]
    [ "$(py "d['epics'][0]['epic_progress']")" = "$want" ]
    run_bp --epic "$e"
    [ "$RC" -eq 0 ] || { echo "--epic $e exited $RC"; return 1; }
    [ "$(py 'd["epic_progress"]')" = "$want" ] || { echo "--epic $e: $(py 'd["epic_progress"]') != $want"; return 1; }
  done
  # E04 has no stories or tasks: --epic exits 3 (empty scope), --by-parent still lists it with the zero object
  [ "$(py "[x for x in d['epics'] if x['id'] == 'E04'][0]['epic_progress']" "$BATS_TEST_TMPDIR/byparent.json")" = "$(ep 0 0 0 0 0 false)" ]
  run_bp --epic E04
  [ "$RC" -eq 3 ]
}

@test "--epic: epic_progress is a top-level key between levels and warnings; other scopes do not carry it" {
  run_bp --epic E01
  [ "$RC" -eq 0 ]
  [ "$(py 'list(d.keys())')" = '["schema_version","scope","levels","epic_progress","warnings"]' ]
  [ "$(py 'd["schema_version"]')" = "1" ]
  run_bp --story E01_S01
  [ "$(py '"epic_progress" in d')" = "false" ]
  run_bp --ids E01
  [ "$(py '"epic_progress" in d')" = "false" ]
  run_bp --all
  [ "$(py '"epic_progress" in d')" = "false" ]
}

@test "--epic --summary: one epic line after the level lines, the same figures as the JSON" {
  run_bp --epic E01 --summary
  [ "$RC" -eq 0 ]
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/out")" = "tasks    3/6 done · 0 in progress · 0 red · 3 pending" ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/out")" = "stories  0/5 done · 0 in progress · 0 red · 5 pending" ]
  [ "$(sed -n 3p "$BATS_TEST_TMPDIR/out")" = "epic     30% · 3/5 stories decomposed · 3/6 tasks done" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/out" | tr -d ' ')" = "3" ]
  run_bp --epic E03 --summary
  [ "$(grep '^epic ' "$BATS_TEST_TMPDIR/out")" = "epic     100% · 5/5 stories decomposed · 5/5 tasks done" ]
  # other scopes print no epic line
  run_bp --story E01_S01 --summary
  ! grep -q '^epic ' "$BATS_TEST_TMPDIR/out"
  run_bp --all --summary
  ! grep -q '^epic ' "$BATS_TEST_TMPDIR/out"
}

@test "deterministic: byte-identical across runs in every mode that carries the figure" {
  local args
  for args in "--graph" "--graph --counts-only" "--by-parent" "--epic E07" "--epic E01 --summary" "--epic E14" "--epic E14 --summary"; do
    # shellcheck disable=SC2086
    run_bp $args
    [ "$RC" -eq 0 ]
    cp "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/first"
    # shellcheck disable=SC2086
    run_bp $args
    cmp "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/first" || { echo "not byte-identical: $args"; return 1; }
  done
}

@test "E92_S10_T02: a story whose own status is Failed blocks the goal and caps the percent at 99, and is named" {
  run_graph_ok
  [ "$(graph_ep E11)" = "$(ep 3 3 4 4 99 false '["E11_S02"]')" ]
}

@test "E92_S10_T02: a Blocked story (the failed bucket) blocks the goal the same way" {
  run_graph_ok
  [ "$(graph_ep E12)" = "$(ep 1 1 2 2 99 false '["E12_S01"]')" ]
}

@test "E92_S10_T02: a Failed story with the percent already below 99 leaves the percent unchanged, goal false" {
  run_graph_ok
  [ "$(graph_ep E13)" = "$(ep 2 2 2 3 66 false '["E13_S01"]')" ]
}

@test "E92_S10_T02: two failed stories are both listed, in numeric id order (S9 before S10)" {
  run_graph_ok
  [ "$(graph_ep E14)" = "$(ep 3 3 3 3 99 false '["E14_S9","E14_S10"]')" ]
}

@test "E92_S10_T02: no failed story gives [] and the goal as before (100, true); 100 is never printed without the goal" {
  run_graph_ok
  [ "$(graph_ep E03)" = "$(ep 5 5 5 5 100 true)" ]
  [ "$(py "[e['id'] for e in d['epics'] if e['epic_progress']['failed_stories']]")" = '["E11","E12","E13","E14"]' ]
  [ "$(py "all((e['epic_progress']['percent'] == 100) == e['epic_progress']['goal_reached'] for e in d['epics'])")" = "true" ]
  [ "$(py "all(e['epic_progress']['percent'] <= 99 for e in d['epics'] if e['epic_progress']['failed_stories'])")" = "true" ]
  # failed_stories is the last key of the object (an added key)
  [ "$(py "list(d['epics'][0]['epic_progress'].keys())")" = '["stories","decomposed","tasks_done","tasks_denominator","percent","goal_reached","failed_stories"]' ]
  [ "$(py 'd["schema_version"]')" = "1" ]
}

@test "E92_S10_T02: --epic --summary names the failed stories on the epic line, and only then" {
  run_bp --epic E11 --summary
  [ "$RC" -eq 0 ]
  [ "$(grep '^epic ' "$BATS_TEST_TMPDIR/out")" = "epic     99% · 3/3 stories decomposed · 4/4 tasks done · failed stories: E11_S02" ]
  run_bp --epic E14 --summary
  [ "$(grep '^epic ' "$BATS_TEST_TMPDIR/out")" = "epic     99% · 3/3 stories decomposed · 3/3 tasks done · failed stories: E14_S9, E14_S10" ]
  run_bp --epic E03 --summary
  [ "$(grep '^epic ' "$BATS_TEST_TMPDIR/out")" = "epic     100% · 5/5 stories decomposed · 5/5 tasks done" ]
}

# run_graph_ok: --graph over the fixture, exit 0, nothing on stderr.
run_graph_ok() {
  run_bp --graph
  [ "$RC" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
}
