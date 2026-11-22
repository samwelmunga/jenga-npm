#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E92_S06_T25: skills/j-status/scripts/render-status-scope-view.sh - the new `j.status <epic|story>` view: a header block
# with a milestone track, complete stories hidden behind one line, per-story task rows with a dependency column, then
# "Ready to take" and "Unlocks after" - taken from `board-progress.sh --graph --within <id>`.
#
# A stub board-progress.sh (the JENGA_BOARD_PROGRESS test seam) prints a fixed --graph JSON fixture, so these tests check
# the LAYOUT ONLY: the renderer does no counting or readiness derivation, and the numbers and lists the stub states are
# the ones it must print. The default label language is en. Line widths are measured in characters by python3.

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO/skills/j-status/scripts/render-status-scope-view.sh"
  unset NO_COLOR JENGA_PROGRESS_LANG LC_CTYPE COLUMNS JENGA_BOARD_PROGRESS JENGA_PROGRESS_LABELS
  export LANG="en_US.UTF-8"
  unset LC_ALL
  ESC=$'\033'
  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
}

# mk_json_stub <json>: a board-progress.sh that records its arguments and prints the given JSON.
mk_json_stub() {
  printf '%s\n' "$1" > "$STUB_DIR/fixture.json"
  cat > "$STUB_DIR/board-progress.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$(dirname "$0")/args.txt"
cat "$(dirname "$0")/fixture.json"
STUB
  chmod +x "$STUB_DIR/board-progress.sh"
  export JENGA_BOARD_PROGRESS="$STUB_DIR/board-progress.sh"
}

# tk <id> <state> <deps json> <blocked_by json> <title>: one task entry of the fixture.
tk() {
  local sid="${1%_T*}"
  printf '{"id":"%s","story_id":"%s","epic_id":"E50","title":"%s","status":"x","bucket":"x","state":"%s","depends_on":%s,"blocked_by":%s,"unlocked_by":null}' \
    "$1" "$sid" "$5" "$2" "$3" "$4"
}

# st <id> <title> <done> <in_progress> <failed> <pending> <complete> <stop> <deps json>: one story entry.
st() {
  local den=$(( $3 + $4 + $5 + $6 ))
  printf '{"id":"%s","epic_id":"E50","title":"%s","depends_on":%s,"totals":{"done":%d,"in_progress":%d,"failed":%d,"pending":%d,"rejected":0,"unknown":0,"denominator":%d},"complete":%s,"stop":"%s","ready_count":0}' \
    "$1" "$2" "$9" "$3" "$4" "$5" "$6" "$den" "$7" "$8"
}

# mk_epic [epic done] [epic denominator]: the main epic fixture. S01 complete; S02 partly done (T01 done, T02 in progress,
# T03 ready, T04 and T05 locked); S03 untouched (T01 ready, T02 and T03 locked); S04 has no tasks. The epic totals are the
# ones the stub states (default 3 of 9 tasks, 33 %); ready is [E50_S02_T03, E50_S03_T01]. Since E92_S09_T04 the stub also
# states epic_progress, the figure the header and the message read: 4 stories, 3 decomposed (S04 has no task), the
# stated task counts and percent floor(100 * done / denominator) as given (the renderer counts nothing).
mk_epic() {
  local ed="${1:-3}" en="${2:-9}"
  local stories tasks ep
  ep="{\"stories\":4,\"decomposed\":3,\"tasks_done\":$ed,\"tasks_denominator\":$en,\"percent\":$(( 100 * ed / en )),\"goal_reached\":false}"
  stories="$(st E50_S01 'Storage layer' 2 0 0 0 true done '[]'),$(st E50_S02 'Sync engine' 1 1 0 3 false in_progress '["E50_S01"]'),$(st E50_S03 'Städa upp och polish' 0 0 0 2 false pending '["E50_S02"]'),$(st E50_S04 'Empty story' 0 0 0 0 false pending '[]')"
  tasks="$(tk E50_S01_T01 done '[]' '[]' 'Create tables'),$(tk E50_S01_T02 done '["E50_S01_T01"]' '[]' 'Add indexes'),"
  tasks="$tasks$(tk E50_S02_T01 done '[]' '[]' 'Define the sync protocol'),$(tk E50_S02_T02 in_progress '["E50_S02_T01"]' '[]' 'Implement the pull side'),"
  tasks="$tasks$(tk E50_S02_T03 ready '["E50_S02_T01"]' '[]' 'Implement the push side'),$(tk E50_S02_T04 locked '["E50_S02_T02","E50_S01_T01"]' '["E50_S02_T02"]' 'Resolve conflicts'),"
  tasks="$tasks$(tk E50_S02_T05 locked '["E50_S02_T03"]' '["E50_S02_T03"]' 'Retry with backoff'),"
  tasks="$tasks$(tk E50_S03_T01 ready '["E50_S01_T02"]' '[]' 'Städa upp gamla filer'),$(tk E50_S03_T02 locked '["E50_S03_T01"]' '["E50_S03_T01"]' 'Polish the output'),"
  tasks="$tasks$(tk E50_S03_T03 locked '["E50_S02_T05"]' '["E50_S02_T05"]' 'Final pass')"
  mk_json_stub "{\"schema_version\":1,\"scope\":{\"type\":\"graph\",\"within\":\"E50\"},\"epics\":[{\"id\":\"E50\",\"title\":\"Offline sync\",\"depends_on\":[],\"stories\":{\"totals\":{\"done\":1,\"in_progress\":0,\"failed\":0,\"pending\":3,\"rejected\":0,\"unknown\":0,\"denominator\":4},\"complete\":1},\"tasks\":{\"totals\":{\"done\":$ed,\"in_progress\":1,\"failed\":0,\"pending\":$(( en - ed - 1 )),\"rejected\":0,\"unknown\":0,\"denominator\":$en}},\"epic_progress\":$ep,\"ready_count\":2}],\"stories\":[$stories],\"tasks\":[$tasks],\"external\":[],\"ready\":[\"E50_S02_T03\",\"E50_S03_T01\"],\"warnings\":[]}"
}

# mk_story: a story scope fixture for E50_S02 (one story, no epics entry, an external story dependency).
mk_story() {
  local tasks
  tasks="$(tk E50_S02_T01 done '[]' '[]' 'Define the sync protocol'),$(tk E50_S02_T02 in_progress '["E50_S02_T01"]' '[]' 'Implement the pull side'),"
  tasks="$tasks$(tk E50_S02_T03 ready '["E50_S02_T01"]' '[]' 'Implement the push side'),$(tk E50_S02_T04 locked '["E50_S02_T02","E50_S01_T01"]' '["E50_S02_T02"]' 'Resolve conflicts')"
  mk_json_stub "{\"schema_version\":1,\"scope\":{\"type\":\"graph\",\"within\":\"E50_S02\"},\"epics\":[],\"stories\":[$(st E50_S02 'Sync engine' 1 1 0 2 false in_progress '["E50_S01"]')],\"tasks\":[$tasks],\"external\":[{\"id\":\"E50_S01\",\"status\":\"Passed\",\"bucket\":\"done\"}],\"ready\":[\"E50_S02_T03\"],\"warnings\":[]}"
}

# width_ok <cols>: stdin must hold no line wider than <cols> characters once colour escapes are removed.
width_ok() {
  python3 -c '
import re, sys
c = int(sys.argv[1]); bad = 0
for l in sys.stdin.read().split("\n"):
    v = re.sub("\x1b\\[[0-9;]*m", "", l)
    if len(v) > c:
        print("too wide (%d > %d): %s" % (len(v), c, v)); bad = 1
sys.exit(bad)' "$1"
}

# line_with <text>: the first output line containing <text>.
line_with() { printf '%s\n' "$output" | grep -F -- "$1" | head -n 1; }
# line_of <text>: the 1-based line number of the first output line containing <text>.
line_of() { printf '%s\n' "$output" | grep -n -F -- "$1" | head -n 1 | cut -d: -f1; }

@test "script has a bash shebang, parses under bash -n and is executable" {
  [ -x "$S" ]
  [ "$(head -n 1 "$S")" = "#!/usr/bin/env bash" ]
  run bash -n "$S"
  [ "$status" -eq 0 ]
}

@test "--help prints the usage on stdout and exits 0" {
  run "$S" --help
  [ "$status" -eq 0 ]
  case "$output" in *"render-status-scope-view.sh <id>"*"--all"*"--cols"*"--color"*"--root"*) ;; *) false ;; esac
}

@test "an epic reads the board once with --graph --within and the normalised id" {
  mk_epic
  run "$S" e50 --cols 80 --color never
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/args.txt")" = "--graph --within E50" ]
  mk_epic
  run "$S" E50 --cols 80 --color never --root /some/root
  [ "$(cat "$STUB_DIR/args.txt")" = "--graph --within E50 --root /some/root" ]
}

@test "epic header block: title and percent, track with one stop per story ending in the goal, labels, message, ready" {
  mk_epic
  run "$S" E50 --cols 80 --color never
  [ "$status" -eq 0 ]
  head1="$(printf '%s\n' "$output" | sed -n 1p)"
  case "$head1" in "E50 · Offline sync"*"33 %") ;; *) echo "head: $head1"; false ;; esac
  track="$(printf '%s\n' "$output" | sed -n 2p)"
  case "$track" in "▸"*"⚑") ;; *) echo "track: $track"; false ;; esac
  # one stop per story (4 stories: done, in progress, pending, no tasks) before the goal
  stops="$(printf '%s' "$track" | tr -cd '●◉○⊘' | wc -m | tr -d ' ')"
  [ "$stops" -eq 4 ]
  case "$track" in *"●"*"◉"*"○"*"⊘"*"⚑") ;; *) false ;; esac
  labels="$(printf '%s\n' "$output" | sed -n 3p)"
  case "$labels" in *S01*S02*S03*S04*Goal) ;; *) echo "labels: $labels"; false ;; esac
  # E92_S09_T04: 3 stories left, not 2: S04 has no task yet and is unfinished (epic_progress.stories minus complete ones)
  [ "$(printf '%s\n' "$output" | sed -n 4p)" = "Good pace! 3 stories left  ›  Ready to take: E50_S02_T03, E50_S03_T01" ]
  case "$head1" in *"3/4 stories decomposed · 33 %") ;; *) echo "head: $head1"; false ;; esac
}

@test "the one-line message follows the stated percent and the stories left" {
  mk_epic 8 9
  run "$S" E50 --cols 100 --color never
  [ "$status" -eq 0 ]
  # E92_S09_T04: the undecomposed S04 is one of the stories left (3, was 2)
  case "$output" in *"Almost there - 3 stories left"*) ;; *) false ;; esac
  mk_epic 5 9
  run "$S" E50 --cols 100 --color never
  case "$output" in *"Past halfway - 3 stories left"*) ;; *) false ;; esac
  mk_epic 0 9
  run "$S" E50 --cols 100 --color never
  case "$output" in *"The first step is just ahead"*) ;; *) false ;; esac
}

@test "complete stories are hidden behind one line and only the remaining stories get a block" {
  mk_epic
  run "$S" E50 --cols 80 --color never
  [ "$status" -eq 0 ]
  case "$output" in *"1 complete story hidden, --all shows it (S01)"*) ;; *) false ;; esac
  # the complete story has no row and no task rows
  case "$output" in *"E50_S01 "*) false ;; esac
  case "$output" in *"Create tables"*) false ;; esac
  case "$output" in *"E50_S02 "*"Sync engine"*"1/5"*) ;; *) false ;; esac
  case "$output" in *"E50_S03 "*"0/2"*) ;; *) false ;; esac
  [ "$(printf '%s\n' "$output" | grep -c 'complete stor')" -eq 1 ]
}

@test "several complete stories use the plural line" {
  json="$(cat <<'JSON'
{"schema_version":1,"scope":{"type":"graph","within":"E51"},"epics":[{"id":"E51","title":"Two done","depends_on":[],"tasks":{"totals":{"done":4,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":4}},"epic_progress":{"stories":2,"decomposed":2,"tasks_done":4,"tasks_denominator":4,"percent":100,"goal_reached":true}}],"stories":[{"id":"E51_S01","title":"A","depends_on":[],"totals":{"done":2,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":2},"complete":true,"stop":"done"},{"id":"E51_S02","title":"B","depends_on":[],"totals":{"done":2,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":2},"complete":true,"stop":"done"}],"tasks":[],"external":[],"ready":[],"warnings":[]}
JSON
)"
  mk_json_stub "$json"
  run "$S" E51 --cols 80 --color never
  [ "$status" -eq 0 ]
  case "$output" in *"2 complete stories hidden, --all shows them (S01, S02)"*) ;; *) false ;; esac
  case "$output" in *"Goal reached - well done!"*) ;; *) false ;; esac
  case "$output" in *"▸━━"*"★"*) ;; *) false ;; esac
}

# E92_S10_T02: e54_json <failed_stories JSON> <percent> <tasks_done>: two stories whose tasks are all done (or 1 of 2 in S02
# when tasks_done is 3), the epic_progress as board-progress.sh states it while a story's own status has failed: no goal,
# the percent at most 99, failed_stories named. The renderer reads it and counts nothing.
e54_json() {
  local s2done=$(( $3 - 2 )) s2pend=$(( 4 - $3 ))
  printf '{"schema_version":1,"scope":{"type":"graph","within":"E54"},"epics":[{"id":"E54","title":"Failed story","depends_on":[],"tasks":{"totals":{"done":%d,"in_progress":0,"failed":0,"pending":%d,"rejected":0,"unknown":0,"denominator":4}},"epic_progress":{"stories":2,"decomposed":2,"tasks_done":%d,"tasks_denominator":4,"percent":%d,"goal_reached":false,"failed_stories":%s}}],"stories":[{"id":"E54_S01","title":"A","depends_on":[],"totals":{"done":2,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":2},"complete":true,"stop":"done"},{"id":"E54_S02","title":"B","depends_on":[],"totals":{"done":%d,"in_progress":0,"failed":0,"pending":%d,"rejected":0,"unknown":0,"denominator":2},"complete":%s,"stop":"%s"}],"tasks":[],"external":[],"ready":[],"warnings":[]}' \
    "$3" "$s2pend" "$3" "$2" "$1" "$s2done" "$s2pend" "$( [ "$s2pend" -eq 0 ] && echo true || echo false )" "$( [ "$s2pend" -eq 0 ] && echo done || echo pending )"
}

@test "E92_S10_T02: a failed story stops the epic at 99 % and the message names it instead of the congratulation" {
  mk_json_stub "$(e54_json '["E54_S02"]' 99 4)"
  run "$S" E54 --cols 80 --color never
  [ "$status" -eq 0 ]
  head1="$(printf '%s\n' "$output" | sed -n 1p)"
  case "$head1" in "E54 · Failed story"*"99 %") ;; *) echo "head: $head1"; false ;; esac
  case "$output" in *"Goal reached"*|*"100 %"*) echo "$output"; false ;; esac
  [ "$(printf '%s\n' "$output" | sed -n 4p)" = "Goal not reached - E54_S02 has failed" ]
  # the milestone track ends in the goal flag, not the star
  track="$(printf '%s\n' "$output" | sed -n 2p)"
  case "$track" in *"⚑") ;; *) echo "track: $track"; false ;; esac
  # coloured: the message is red (31), not the green of the done message
  run "$S" E54 --cols 80 --color always
  case "$output" in *"${ESC}[31mGoal not reached - E54_S02 has failed"*) ;; *) false ;; esac
  # Swedish
  JENGA_PROGRESS_LANG=sv run "$S" E54 --cols 80 --color never
  [ "$(printf '%s\n' "$output" | sed -n 4p)" = "Målet ej nått - E54_S02 har misslyckats" ]
}

@test "E92_S10_T02: two failed stories: the first is named with the count of the others; below 99 % the message is unchanged" {
  mk_json_stub "$(e54_json '["E54_S01","E54_S02"]' 99 4)"
  run "$S" E54 --cols 80 --color never
  [ "$(printf '%s\n' "$output" | sed -n 4p)" = "Goal not reached - E54_S01 and 1 more have failed" ]
  # 3 of 4 tasks done (75 %): one story left, the existing last-story message, no failed line
  mk_json_stub "$(e54_json '["E54_S01"]' 75 3)"
  run "$S" E54 --cols 80 --color never
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 4p)" = "Last story - the goal is in sight!" ]
  case "$output" in *"Goal not reached"*) false ;; esac
}

@test "with --all the complete stories are listed like the others, without it they are not" {
  mk_epic
  run "$S" E50 --cols 80 --color never --all
  [ "$status" -eq 0 ]
  case "$output" in *"E50_S01 "*"Storage layer"*"2/2"*) ;; *) false ;; esac
  case "$output" in *"Create tables"*"Add indexes"*) ;; *) false ;; esac
  case "$output" in *"complete stor"*) false ;; esac
  run "$S" E50 --cols 80 --color never
  case "$output" in *"Storage layer"*) false ;; esac
}

@test "each task row has symbol, short id, state in words, title and the dependency column" {
  mk_epic
  run "$S" E50 --cols 100 --color never
  [ "$status" -eq 0 ]
  l="$(line_with "Define the sync protocol")"
  case "$l" in "    ● T01 done "*"Define the sync protocol") ;; *) echo "[$l]"; false ;; esac
  l="$(line_with "Implement the pull side")"
  case "$l" in "    ◉ T02 in progress "*"Implement the pull side"*"after T01 ✓") ;; *) echo "[$l]"; false ;; esac
  l="$(line_with "Implement the push side")"
  case "$l" in "    + T03 ready "*"after T01 ✓") ;; *) echo "[$l]"; false ;; esac
  l="$(line_with "Resolve conflicts")"
  case "$l" in "    ○ T04 locked "*"waits for T02, E50_S01_T01 ✓") ;; *) echo "[$l]"; false ;; esac
  l="$(line_with "Retry with backoff")"
  case "$l" in *"waits for T03") ;; *) echo "[$l]"; false ;; esac
}

@test "a dependency in another story shows the full id, done or open" {
  mk_epic
  run "$S" E50 --cols 100 --color never
  l="$(line_with "Final pass")"
  case "$l" in *"waits for E50_S02_T05") ;; *) echo "[$l]"; false ;; esac
  l="$(line_with "Städa upp gamla filer")"
  case "$l" in *"after E50_S01_T02 ✓") ;; *) echo "[$l]"; false ;; esac
}

@test "colour: a done dependency is green, an open one grey, and no colour means no escape" {
  mk_epic
  run "$S" E50 --cols 100 --color always
  [ "$status" -eq 0 ]
  l="$(line_with "Implement the pull side")"
  case "$l" in *"${ESC}[32mafter T01 ✓${ESC}[0m"*) ;; *) printf '%s\n' "$l" | cat -v; false ;; esac
  l="$(line_with "Retry with backoff")"
  case "$l" in *"${ESC}[90mwaits for T03${ESC}[0m"*) ;; *) printf '%s\n' "$l" | cat -v; false ;; esac
  run "$S" E50 --cols 100 --color never
  case "$output" in *"$ESC"*) false ;; esac
  NO_COLOR=1 run "$S" E50 --cols 100
  [ "$status" -eq 0 ]
  case "$output" in *"$ESC"*) false ;; esac
}

@test "Ready to take (N) lists every ready task" {
  mk_epic
  run "$S" E50 --cols 100 --color never
  [ "$status" -eq 0 ]
  case "$output" in *"Ready to take (2)"*) ;; *) false ;; esac
  tail_part="$(printf '%s\n' "$output" | sed -n '/^Ready to take (2)/,$p')"
  case "$tail_part" in *"+ E50_S02_T03  Implement the push side"*"+ E50_S03_T01  Städa upp gamla filer"*) ;; *) printf '%s\n' "$tail_part"; false ;; esac
}

@test "Unlocks after lists only locked tasks and names what each waits for; a ready task never appears there" {
  mk_epic
  run "$S" E50 --cols 100 --color never
  [ "$status" -eq 0 ]
  sec="$(printf '%s\n' "$output" | sed -n '/^Unlocks after/,$p')"
  case "$sec" in *"E50_S02_T04 ← E50_S02_T02"*) ;; *) printf '%s\n' "$sec"; false ;; esac
  case "$sec" in *"E50_S02_T05 ← E50_S02_T03"*) ;; *) false ;; esac
  case "$sec" in *"E50_S03_T02 ← E50_S03_T01"*) ;; *) false ;; esac
  case "$sec" in *"E50_S03_T03 ← E50_S02_T05"*) ;; *) false ;; esac
  # ready, in progress and done tasks never appear under it
  for t in E50_S02_T03 E50_S03_T01 E50_S02_T02 E50_S02_T01 E50_S01_T01; do
    printf '%s\n' "$sec" | grep -q "^  $t " && { echo "unexpected $t"; false; }
  done
  [ "$(printf '%s\n' "$sec" | grep -c '←')" -eq 4 ]
}

@test "no locked task means no Unlocks after section, and nothing ready says so" {
  # E92_S09_T04: the stub states epic_progress (the message reads it; without it the epic counts no story left)
  json="$(cat <<'JSON'
{"schema_version":1,"scope":{"type":"graph","within":"E52"},"epics":[{"id":"E52","title":"Busy","depends_on":[],"tasks":{"totals":{"done":0,"in_progress":1,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":1}},"epic_progress":{"stories":1,"decomposed":1,"tasks_done":0,"tasks_denominator":1,"percent":0,"goal_reached":false}}],"stories":[{"id":"E52_S01","title":"Only story","depends_on":[],"totals":{"done":0,"in_progress":1,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":1},"complete":false,"stop":"in_progress"}],"tasks":[{"id":"E52_S01_T01","story_id":"E52_S01","epic_id":"E52","title":"Working","state":"in_progress","depends_on":[],"blocked_by":[],"unlocked_by":null}],"external":[],"ready":[],"warnings":[]}
JSON
)"
  mk_json_stub "$json"
  run "$S" E52 --cols 80 --color never
  [ "$status" -eq 0 ]
  case "$output" in *"Unlocks after"*) false ;; esac
  case "$output" in *"Ready to take (0)"*"Nothing is ready to take right now"*) ;; *) false ;; esac
  case "$output" in *"Ready to take:"*) false ;; esac
  case "$output" in *"Last story - the goal is in sight!"*) ;; *) false ;; esac
}

@test "a story id renders one story block without the milestone track" {
  mk_story
  run "$S" e50_s02 --cols 100 --color never
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/args.txt")" = "--graph --within E50_S02" ]
  head1="$(printf '%s\n' "$output" | sed -n 1p)"
  case "$head1" in "E50_S02 · Sync engine"*"25 %") ;; *) echo "head: $head1"; false ;; esac
  case "$output" in *"▸"*|*"⚑"*|*"Goal"*) false ;; esac
  case "$output" in *"E50_S02 "*"Sync engine"*"1/4"*) ;; *) false ;; esac
  case "$output" in *"E50_S03"*|*"E50_S01 "*) false ;; esac
  case "$output" in *"after T01 ✓"*"waits for T02, E50_S01_T01 ✓"*) ;; *) false ;; esac
  case "$output" in *"Ready to take: E50_S02_T03"*) ;; *) false ;; esac
  case "$output" in *"Unlocks after"*"E50_S02_T04 ← E50_S02_T02"*) ;; *) false ;; esac
}

@test "an epic with one story, an epic with zero stories and a story with zero tasks render without error" {
  # E92_S09_T04: the E53 stub states epic_progress, which the message reads
  mk_json_stub '{"schema_version":1,"scope":{"type":"graph","within":"E53"},"epics":[{"id":"E53","title":"Solo","depends_on":[],"tasks":{"totals":{"done":1,"in_progress":0,"failed":0,"pending":1,"rejected":0,"unknown":0,"denominator":2}},"epic_progress":{"stories":1,"decomposed":1,"tasks_done":1,"tasks_denominator":2,"percent":50,"goal_reached":false}}],"stories":[{"id":"E53_S01","title":"Only","depends_on":[],"totals":{"done":1,"in_progress":0,"failed":0,"pending":1,"rejected":0,"unknown":0,"denominator":2},"complete":false,"stop":"in_progress"}],"tasks":[{"id":"E53_S01_T01","story_id":"E53_S01","epic_id":"E53","title":"One","state":"done","depends_on":[],"blocked_by":[],"unlocked_by":null},{"id":"E53_S01_T02","story_id":"E53_S01","epic_id":"E53","title":"Two","state":"ready","depends_on":["E53_S01_T01"],"blocked_by":[],"unlocked_by":null}],"external":[],"ready":["E53_S01_T02"],"warnings":[]}'
  run "$S" E53 --cols 80 --color never
  [ "$status" -eq 0 ]
  case "$output" in *"▸"*"◉"*"⚑"*) ;; *) false ;; esac
  case "$output" in *"Last story - the goal is in sight!"*) ;; *) false ;; esac
  mk_json_stub '{"schema_version":1,"scope":{"type":"graph","within":"E54"},"epics":[{"id":"E54","title":"Nothing yet","depends_on":[],"tasks":{"totals":{"done":0,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":0}}}],"stories":[],"tasks":[],"external":[],"ready":[],"warnings":[]}'
  run "$S" E54 --cols 80 --color never
  [ "$status" -eq 0 ]
  case "$output" in "E54 · Nothing yet"*"0 %"*"No stories in this scope"*"Ready to take (0)"*) ;; *) printf '%s\n' "$output"; false ;; esac
  case "$output" in *"▸"*) false ;; esac
  mk_json_stub '{"schema_version":1,"scope":{"type":"graph","within":"E55_S01"},"epics":[],"stories":[{"id":"E55_S01","title":"Empty story","depends_on":[],"totals":{"done":0,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":0},"complete":false,"stop":"pending"}],"tasks":[],"external":[],"ready":[],"warnings":[]}'
  run "$S" E55_S01 --cols 80 --color never
  [ "$status" -eq 0 ]
  case "$output" in "E55_S01 · Empty story"*"0 %"*"⊘ E55_S01  Empty story"*"nothing to count"*) ;; *) printf '%s\n' "$output"; false ;; esac
}

@test "at every width tested no line exceeds the width, with and without colour" {
  mk_epic
  for w in 30 49 50 80 200; do
    run "$S" E50 --cols "$w" --color never --all
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | width_ok "$w"
    run "$S" E50 --cols "$w" --color always
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | width_ok "$w"
  done
  mk_story
  for w in 30 49 50 80 200; do
    run "$S" E50_S02 --cols "$w" --color never
    printf '%s\n' "$output" | width_ok "$w"
  done
}

@test "under 50 columns the tree is a flat list, one node per line, with no track and no dependency column" {
  mk_epic
  for w in 30 49; do
    run "$S" E50 --cols "$w" --color never
    [ "$status" -eq 0 ]
    case "$output" in *"▸"*|*"after "*|*"waits for"*) echo "width $w"; false ;; esac
    # every task is its own line: symbol, short id, state in words
    printf '%s\n' "$output" | grep -q '^  ◉ T02 in progress'
    printf '%s\n' "$output" | grep -q '^  ○ T04 locked'
    [ "$(printf '%s\n' "$output" | grep -c '^  . T0[0-9] ')" -eq 8 ]
  done
  run "$S" E50 --cols 80 --color never
  case "$output" in *"after T01 ✓"*) ;; *) false ;; esac
}

@test "a non-UTF-8 locale prints ASCII only, even for non-ASCII titles" {
  mk_epic
  for loc in C POSIX en_US.ISO-8859-1; do
    LANG="" LC_ALL="$loc" run "$S" E50 --cols 100 --color never --all
    [ "$status" -eq 0 ]
    printf '%s' "$output" | LC_ALL=C grep -q -v -P '^[\x00-\x7f]*$' && { echo "non-ASCII for locale '$loc'"; false; }
    LANG="" LC_ALL="$loc" run "$S" E50 --cols 100 --color always
    printf '%s' "$output" | LC_ALL=C grep -q -v -P '^[\x00-\x7f]*$' && { echo "non-ASCII for locale '$loc' (colour)"; false; }
  done
  LANG="" LC_ALL=C run "$S" E50 --cols 100 --color never
  case "$output" in *"after T01 ok"*) ;; *) false ;; esac
  case "$output" in *"E50_S02_T04 <- E50_S02_T02"*) ;; *) false ;; esac
  printf '%s\n' "$output" | width_ok 100
}

@test "all words come from the label library: Swedish with JENGA_PROGRESS_LANG=sv" {
  mk_epic
  JENGA_PROGRESS_LANG=sv run "$S" E50 --cols 100 --color never
  [ "$status" -eq 0 ]
  # E92_S09_T04: 3 stories left (S04 has no task yet), as in the English test
  case "$output" in *"Bra fart! 3 berättelser kvar"*"Redo att ta: E50_S02_T03"*) ;; *) false ;; esac
  case "$output" in *"1 klar berättelse dold, --all visar den"*) ;; *) false ;; esac
  case "$output" in *" Mål"*) ;; *) false ;; esac
  case "$output" in *"Redo att ta (2)"*"Låses upp efter"*) ;; *) false ;; esac
  l="$(line_with "Implement the pull side")"
  case "$l" in *"pågår"*"efter T01 ✓") ;; *) echo "[$l]"; false ;; esac
  l="$(line_with "Retry with backoff")"
  case "$l" in *"låst"*"väntar på T03") ;; *) echo "[$l]"; false ;; esac
  case "$output" in *"Ready to take"*|*"Unlocks after"*|*"after T01"*) false ;; esac
}

@test "the sc_* labels exist in both languages and in the JSON exporter" {
  . "$REPO/scripts/lib/progress-labels.sh"
  for k in sc_hidden sc_hidden_one sc_msg_done sc_msg_last sc_msg_almost sc_msg_half sc_msg_going sc_msg_start sc_after sc_waits sc_unlocks_after sc_no_stories; do
    [ -n "$(progress_label "$k" en)" ]
    [ -n "$(progress_label "$k" sv)" ]
    case " $PROGRESS_LABEL_KEYS " in *" $k "*) ;; *) echo "$k not in the key list"; false ;; esac
  done
  run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  case "$output" in *'"sc_unlocks_after":"Unlocks after"'*) ;; *) false ;; esac
}

@test "no counting or readiness of its own: the stated totals, ready list and states are printed as given" {
  # the epic totals say 7 of 10 (70 %) although the tasks say otherwise; a task in state ready that is NOT in the stated
  # ready list is not listed under Ready to take; a locked task is listed under Unlocks after as stated
  mk_epic 7 10
  run "$S" E50 --cols 100 --color never
  [ "$status" -eq 0 ]
  case "$(printf '%s\n' "$output" | sed -n 1p)" in *"70 %") ;; *) false ;; esac
  json="$(cat "$STUB_DIR/fixture.json" | jq -c '.ready = ["E50_S02_T03"]')"
  mk_json_stub "$json"
  run "$S" E50 --cols 100 --color never
  case "$output" in *"Ready to take (1)"*) ;; *) false ;; esac
  sec="$(printf '%s\n' "$output" | sed -n '/^Ready to take (1)/,/^Unlocks after/p')"
  case "$sec" in *"E50_S03_T01"*) false ;; esac
}

@test "a missing board-progress.sh, failing script, empty output and malformed JSON each warn once, print nothing and exit 0" {
  JENGA_BOARD_PROGRESS="$BATS_TEST_TMPDIR/nope.sh" run --separate-stderr "$S" E50 --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | grep -c 'warning')" -eq 1 ]
  printf '#!/usr/bin/env bash\nexit 3\n' > "$STUB_DIR/board-progress.sh"; chmod +x "$STUB_DIR/board-progress.sh"
  JENGA_BOARD_PROGRESS="$STUB_DIR/board-progress.sh" run --separate-stderr "$S" E50 --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | grep -c 'warning')" -eq 1 ]
  printf '#!/usr/bin/env bash\ntrue\n' > "$STUB_DIR/board-progress.sh"
  JENGA_BOARD_PROGRESS="$STUB_DIR/board-progress.sh" run --separate-stderr "$S" E50 --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | grep -c 'warning')" -eq 1 ]
  mk_json_stub 'this is {not json'
  run --separate-stderr "$S" E50 --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | grep -c 'warning')" -eq 1 ]
  mk_json_stub '[1,2,3]'
  run --separate-stderr "$S" E50 --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  case "$stderr" in *warning*) ;; *) false ;; esac
}

@test "missing labels warn once, print nothing and exit 0" {
  mk_epic
  printf 'progress_label() { return 1; }\n' > "$STUB_DIR/labels.sh"
  JENGA_PROGRESS_LABELS="$STUB_DIR/labels.sh" run --separate-stderr "$S" E50 --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  case "$stderr" in *"progress labels missing"*) ;; *) false ;; esac
}

@test "a missing jq gives one warning, no stdout, exit 0" {
  mk_epic
  tools="$BATS_TEST_TMPDIR/no-jq"
  mkdir -p "$tools"
  ln -s "$(command -v dirname)" "$tools/dirname"
  run --separate-stderr env PATH="$tools" "$BASH" "$S" E50 --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  case "$stderr" in *"jq not found"*) ;; *) false ;; esac
  [ "$(printf '%s\n' "$stderr" | grep -c 'warning')" -eq 1 ]
}

@test "a task id, a missing id, a malformed id and bad flags are usage errors (exit 2)" {
  mk_epic
  for args in "E50_S02_T03" "e1_s2_t3" "" "E50x" "S01" "E50_S" "E50 E51" "--cols" "E50 --cols" "E50 --cols abc" "E50 --cols 0" "E50 --color blue" "E50 --root" "E50 --bogus"; do
    # shellcheck disable=SC2086
    run --separate-stderr "$S" $args
    [ "$status" -eq 2 ] || { echo "args [$args] gave $status"; false; }
    [ -z "$output" ]
    [ -n "$stderr" ]
  done
}

# node_scope <args...>: the Node scope view (the `j.status <id>` default since E92_S08_T06) on the same stub fixture, through
# the JENGA_PROGRESS_SCRIPTS_DIR seam: its board-progress.sh is the stub, its label script the real one.
node_scope() {
  printf '#!/usr/bin/env bash\nexec bash "%s/scripts/progress-labels-json.sh" "$@"\n' "$REPO" > "$STUB_DIR/progress-labels-json.sh"
  JENGA_PROGRESS_SCRIPTS_DIR="$STUB_DIR" LANG= run --separate-stderr node "$REPO/lib/progress/cli.js" scope "$@"
}

# band_rows <title>: the rows of one band of $output (below its header, up to the blank line).
band_rows() { printf '%s\n' "$output" | awk -v t="$1" 'index($0, t) == 1 { on = 1; next } on && $0 == "" { exit } on { print }'; }

@test "E92_S10_T03: the Node scope view of this fixture draws an arrow only along a real dependency (forks, references), in both layouts and charsets" {
  # This file tests render-status-scope-view.sh (the bash view, unchanged by E92_S10_T03). The `j.status <id>` default is the
  # Node view; on the same fixture its bands must draw only real arrows (rapport E92_S08_T08): "Define the sync protocol"
  # forks to the pull and the push side, each locked task hangs under the task it depends on, and the dependencies on
  # another story are references (S01_T01, S01_T02, S02_T05), not arrows from whatever node sits to the left.
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  # E92_S11_T01: "Implement the pull side" (E50_S02_T02) is in progress, so the Node view marks it with the half dot ◐
  # (ascii %), no longer the ready ◉ (ascii @) it shared with "Implement the push side" before; the bash view above is unchanged.
  mk_epic
  node_scope E50 --charset utf8 --color never --cols 120 --layout vertical
  [ "$status" -eq 0 ]
  [ "$(band_rows 'SYNC ENGINE')" = "  ● Define the sync protocol
    ├─▸ ◐ Implement the pull side
    │ └─▸ ○ Resolve conflicts ◂─ S01_T01 →⚑
    └─▸ ◉ Implement the push side
      └─▸ ○ Retry with backoff" ]
  [ "$(band_rows 'STÄDA UPP OCH POLISH')" = "  ◉ Städa upp gamla filer ◂─ S01_T02
    └─▸ ○ Polish the output →⚑
  ○ Final pass ◂─ S02_T05 →⚑" ]
  node_scope E50 --charset utf8 --color never --cols 120 --layout horizontal
  [ "$status" -eq 0 ]
  [ "$(band_rows 'SYNC ENGINE')" = "      ● Define the sy…─┬─▸◐ Implement the…───▸○ Resolve confl… ◂─ S01_T01 ───▸⚑
                       └─▸◉ Implement the…───▸○ Retry with ba…" ]
  printf '%s\n' "$output" | width_ok 120
  node_scope E50 --charset ascii --color never --cols 120 --layout horizontal
  [ "$status" -eq 0 ]
  [ "$(band_rows 'SYNC ENGINE')" = "      * Define the sy~-+->% Implement the~--->o Resolve confl~ <- S01_T01 --->>
                       +->@ Implement the~--->o Retry with ba~" ]
  ! printf '%s' "$output" | LC_ALL=C grep -q '[^ -~]'
}

@test "smoke test on the real board: an epic and a story render and fit the width" {
  [ -f "$REPO/scripts/board-progress.sh" ]
  run "$S" E92 --cols 100 --color never --root "$REPO"
  [ "$status" -eq 0 ]
  case "$output" in "E92 · "*"Ready to take ("*) ;; *) printf '%s\n' "$output" | head -5; false ;; esac
  printf '%s\n' "$output" | width_ok 100
  run "$S" E92_S06 --cols 80 --color never --root "$REPO"
  [ "$status" -eq 0 ]
  case "$output" in "E92_S06 · "*) ;; *) false ;; esac
  printf '%s\n' "$output" | width_ok 80
}
