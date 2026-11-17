#!/usr/bin/env bats
#
# E92_S06_T24: skills/j-status/scripts/render-status-overview.sh - the default `j.status` overview: a total line, only the
# unfinished epics in four groups, complete epics collapsed to one line, and a footer hint - taken from
# `board-progress.sh --graph --counts-only`.
#
# A stub board-progress.sh (the JENGA_BOARD_PROGRESS test seam) prints a fixed JSON fixture, so these tests check the
# LAYOUT ONLY: the renderer does no counting or classification, and the stub's numbers are the ones it must print.
# The default label language is en. Line widths are measured in characters by python3 (awk and wc count bytes here).

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO/skills/j-status/scripts/render-status-overview.sh"
  COMMON="$REPO/skills/j-status/scripts/lib/status-render-common.sh"
  unset NO_COLOR JENGA_PROGRESS_LANG LC_CTYPE COLUMNS JENGA_BOARD_PROGRESS JENGA_PROGRESS_LABELS
  export LANG="en_US.UTF-8"
  unset LC_ALL
  ESC=$'\033'
  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
}

# ep <id> <title> <done> <in_progress> <failed> <pending> <rejected>: one epic entry (tasks.totals; denominator is
# done + in_progress + failed + pending, as board-progress.sh states it) and, since E92_S09_T04, the epic_progress the
# script states for one story holding every task (the rows show the epic percent, section 5.1).
ep() {
  local den=$(( $3 + $4 + $5 + $6 )) dec=0 pct=0 reached=false
  if [ "$den" -gt 0 ]; then dec=1; pct=$(( 100 * $3 / den )); [ "$3" -eq "$den" ] && reached=true; fi
  printf '{"id":"%s","title":"%s","depends_on":[],"stories":{"totals":{"done":0,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":0},"complete":0},"tasks":{"totals":{"done":%d,"in_progress":%d,"failed":%d,"pending":%d,"rejected":%d,"unknown":0,"denominator":%d}},"epic_progress":{"stories":1,"decomposed":%d,"tasks_done":%d,"tasks_denominator":%d,"percent":%d,"goal_reached":%s},"ready_count":0}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$den" "$dec" "$3" "$den" "$pct" "$reached"
}

# mk_stub <epics json array>: a board-progress.sh that records its arguments and prints the fixture.
mk_stub() {
  {
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$(dirname "$0")/args.txt"\ncat <<'"'"'JSON'"'"'\n'
    printf '{"schema_version":1,"scope":{"type":"graph"},"epics":%s,"stories":[],"warnings":[]}\n' "$1"
    printf 'JSON\n'
  } > "$STUB_DIR/board-progress.sh"
  chmod +x "$STUB_DIR/board-progress.sh"
  export JENGA_BOARD_PROGRESS="$STUB_DIR/board-progress.sh"
}

# mk_main: the main fixture. Two failed epics (50% and 25%), two in progress (75% and 50%), one started (25%), one not
# started, two complete, one with only rejected tasks and one with no tasks. Totals: 10 epics, 17/34 tasks, 50 %.
mk_main() {
  mk_stub "[$(ep E10 'Failing epic ten' 3 0 1 2 0),$(ep E12 'Failing epic twelve' 1 0 1 2 0),$(ep E20 'Busy epic twenty' 2 1 0 1 0),$(ep E21 'Busy epic twenty-one' 3 1 0 0 0),$(ep E30 'Begun epic thirty' 1 0 0 3 0),$(ep E40 'Untouched epic forty' 0 0 0 5 0),$(ep E50 'Finished epic fifty' 3 0 0 0 0),$(ep E51 'Finished epic fifty-one' 4 0 0 0 0),$(ep E60 'Only rejected sixty' 0 0 0 0 3),$(ep E61 'Empty epic sixty-one' 0 0 0 0 0)]"
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

# line_of <text>: the 1-based line number of the first output line containing <text>.
line_of() { printf '%s\n' "$output" | grep -n -F -- "$1" | head -n 1 | cut -d: -f1; }

@test "script has a bash shebang, parses under bash -n and is executable" {
  [ -x "$S" ]
  [ "$(head -n 1 "$S")" = "#!/usr/bin/env bash" ]
  run bash -n "$S"
  [ "$status" -eq 0 ]
  run bash -n "$COMMON"
  [ "$status" -eq 0 ]
}

@test "the shared helper library prints nothing and sets no shell option when sourced" {
  run bash -c 'before="$(set +o)"; . "$1"; after="$(set +o)"; [ "$before" = "$after" ]' _ "$COMMON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--help prints the usage on stdout and exits 0" {
  run "$S" --help
  [ "$status" -eq 0 ]
  case "$output" in *"render-status-overview.sh [--all]"*) ;; *) false ;; esac
}

@test "main fixture: total line, four groups in order, one Complete line, one collapsed line, footer" {
  mk_main
  run "$S" --cols 80 --color never
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -n 1)" = "Board · 10 epics · 17/34 tasks · 50 %" ]
  a="$(line_of 'Needs attention (2)')"; p="$(line_of 'In progress (2)')"
  s="$(line_of 'Started (1)')"; n="$(line_of 'Not started (1)')"
  c="$(line_of 'Complete (2)')"; r="$(line_of 'Only rejected or empty (2): E60, E61')"
  f="$(line_of 'j.status --all')"
  [ -n "$a" ] && [ -n "$p" ] && [ -n "$s" ] && [ -n "$n" ] && [ -n "$c" ] && [ -n "$r" ] && [ -n "$f" ]
  [ "$a" -lt "$p" ] && [ "$p" -lt "$s" ] && [ "$s" -lt "$n" ] && [ "$n" -lt "$c" ] && [ "$c" -lt "$r" ] && [ "$r" -lt "$f" ]
  # one Complete line carrying the task total of the complete epics (3 + 4), and no complete epic listed on its own
  case "$(printf '%s\n' "$output" | sed -n "${c}p")" in *"7 tasks"*) ;; *) false ;; esac
  [ -z "$(line_of 'E50')" ]
  [ -z "$(line_of 'E51')" ]
  # E60 and E61 appear only on the one collapsed line
  [ "$(printf '%s\n' "$output" | grep -c -E 'E60|E61')" -eq 1 ]
  case "$output" in *"j.status <id>"*) ;; *) false ;; esac
}

@test "epics are sorted by percent inside a group, highest first" {
  mk_main
  run "$S" --cols 80 --color never
  [ "$(line_of 'E10')" -lt "$(line_of 'E12')" ]   # 50 % before 25 %
  [ "$(line_of 'E21')" -lt "$(line_of 'E20')" ]   # 75 % before 50 %
}

@test "ties on percent are ordered by numeric id" {
  mk_stub "[$(ep E9 'Nine' 1 0 0 1 0),$(ep E10 'Ten' 1 0 0 1 0),$(ep E02 'Two' 1 0 0 1 0)]"
  run "$S" --cols 80 --color never
  [ "$(line_of 'E02')" -lt "$(line_of 'E9')" ]
  [ "$(line_of 'E9')" -lt "$(line_of 'E10')" ]
}

@test "each epic row carries id, bar, done/total, percent, marker and a title" {
  mk_main
  run "$S" --cols 80 --color never
  row="$(printf '%s\n' "$output" | grep -F 'E10')"
  case "$row" in *E10*━*╌*3/6*50\ %*✕1*"Failing epic ten"*) ;; *) echo "$row"; false ;; esac
  row="$(printf '%s\n' "$output" | grep -F 'E21')"
  case "$row" in *E21*━*3/4*75\ %*◉1*"Busy epic twenty-one"*) ;; *) echo "$row"; false ;; esac
  row="$(printf '%s\n' "$output" | grep -F 'E40')"
  case "$row" in *E40*╌*0/5*"0 %"*"Untouched epic forty"*) ;; *) echo "$row"; false ;; esac
}

@test "board-progress.sh is called once with --graph --counts-only and --root is forwarded" {
  mk_main
  run "$S" --cols 80 --color never --root "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/args.txt")" = "--graph --counts-only --root $BATS_TEST_TMPDIR/proj" ]
}

@test "no counting of its own: the stub's inconsistent numbers are printed as given" {
  # denominator 50 although the buckets sum to 4; done 7 of 50 is 14 %. The renderer must print 7/50 and 14 %.
  mk_stub '[{"id":"E05","title":"Odd","tasks":{"totals":{"done":7,"in_progress":0,"failed":0,"pending":1,"rejected":0,"unknown":0,"denominator":50}},"epic_progress":{"stories":1,"decomposed":1,"tasks_done":7,"tasks_denominator":50,"percent":14,"goal_reached":false}}]'
  run "$S" --cols 80 --color never
  [ "$status" -eq 0 ]
  case "$output" in *"7/50"*"14 %"*) ;; *) false ;; esac
  case "$(printf '%s\n' "$output" | head -n 1)" in *"7/50 tasks · 14 %") ;; *) false ;; esac
}

@test "the overview of a board with 100+ items is a small fraction of one line per epic and story" {
  # 150 epics (120 complete, 7 failed, 8 in progress, 8 started, 7 not started) and, by the legacy list, 1 line each plus 1 per story.
  # E92_S09_T04: each entry states epic_progress (one story holding its tasks); "complete" now means goal_reached.
  arr="$(jq -n -c '[range(150) as $i | ($i | if . < 120 then [4,0,0,0] elif . < 127 then [2,0,1,1] elif . < 135 then [2,1,0,1] elif . < 143 then [1,0,0,3] else [0,0,0,4] end) as $b
    | {id: ("E" + ($i + 1 | tostring)), title: ("Epic number " + ($i | tostring)), tasks: {totals: {done: $b[0], in_progress: $b[1], failed: $b[2], pending: $b[3], rejected: 0, unknown: 0, denominator: ($b | add)}},
      epic_progress: {stories: 1, decomposed: 1, tasks_done: $b[0], tasks_denominator: ($b | add), percent: ((100 * $b[0] / ($b | add)) | floor), goal_reached: ($b[0] == ($b | add))}}]')"
  mk_stub "$arr"
  run "$S" --cols 80 --color never
  [ "$status" -eq 0 ]
  n="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  [ "$n" -lt 60 ]
  [ "$n" -lt 150 ]
  case "$output" in *"Complete (120)"*) ;; *) false ;; esac
}

@test "at every width tested no line exceeds the width, with and without colour" {
  mk_main
  for w in 30 49 50 80 200; do
    run "$S" --cols "$w" --color never
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | width_ok "$w"
    run "$S" --cols "$w" --color always
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | width_ok "$w"
  done
}

@test "under 50 columns the bar is dropped, from 50 columns it is drawn" {
  mk_main
  for w in 30 49; do
    run "$S" --cols "$w" --color never
    case "$output" in *━*|*╌*) echo "bar at $w"; false ;; esac
    # the numbers are still there
    case "$output" in *"3/6"*) ;; *) false ;; esac
  done
  run "$S" --cols 50 --color never
  case "$output" in *━*) ;; *) false ;; esac
  # the total bar line (second line) exists at 50 and is absent at 49
  run "$S" --cols 49 --color never
  case "$(printf '%s\n' "$output" | sed -n 2p)" in *━*|*╌*) false ;; esac
}

@test "COLUMNS is the width when --cols is absent, and --cols wins over COLUMNS" {
  mk_main
  COLUMNS=40 run "$S" --color never
  printf '%s\n' "$output" | width_ok 40
  COLUMNS=40 run "$S" --cols 90 --color never
  printf '%s\n' "$output" | width_ok 90
  [ "$(printf '%s\n' "$output" | awk '{ if (length($0) > m) m = length($0) } END { print m }')" -gt 40 ]
}

@test "NO_COLOR emits no escape sequence, --color always forces colour" {
  mk_main
  NO_COLOR=1 run "$S" --cols 80
  case "$output" in *"$ESC"*) false ;; esac
  run "$S" --cols 80 --color never
  case "$output" in *"$ESC"*) false ;; esac
  # piped stdout (as under bats) is not a TTY, so auto is plain too
  run "$S" --cols 80
  case "$output" in *"$ESC"*) false ;; esac
  run "$S" --cols 80 --color always
  case "$output" in *"$ESC["*) ;; *) false ;; esac
}

@test "a non-UTF-8 locale prints ASCII only, even for non-ASCII titles" {
  mk_stub "[$(ep E10 'Fixa åäö — ändra ⚑' 1 0 1 2 0),$(ep E20 'Plain' 2 1 0 1 0),$(ep E50 'Done' 3 0 0 0 2)]"
  for loc in C POSIX ""; do
    LC_ALL="$loc" LANG=C run "$S" --cols 80 --color never
    [ "$status" -eq 0 ]
    printf '%s' "$output" | LC_ALL=C grep -q -v -P '^[\x00-\x7f]*$' && { echo "non-ASCII for locale '$loc'"; false; }
    case "$output" in *"#"*) ;; *) false ;; esac
  done
  LC_ALL=C LANG=C run "$S" --cols 80 --color never
  case "$output" in *"Fixa aao ? andra ?"*) ;; *) echo "$output"; false ;; esac
  # ASCII mode still honours the width
  LC_ALL=C LANG=C run "$S" --cols 30 --color never
  printf '%s\n' "$output" | width_ok 30
}

@test "a UTF-8 locale prints the UTF-8 glyphs" {
  mk_main
  LC_ALL=en_US.UTF-8 run "$S" --cols 80 --color never
  case "$output" in *━*╌*⚑*) ;; *) false ;; esac
  case "$output" in *★*) ;; *) false ;; esac
}

@test "every word comes from the label library: Swedish replaces the English words" {
  mk_main
  JENGA_PROGRESS_LANG=sv run "$S" --cols 80 --color never
  [ "$status" -eq 0 ]
  case "$output" in *"Behöver uppmärksamhet (2)"*"Pågår (2)"*"Påbörjade (1)"*"Ej påbörjade (1)"*"Klara (2)"*) ;; *) echo "$output"; false ;; esac
  case "$output" in *"17/34 uppgifter"*) ;; *) false ;; esac
  case "$output" in *"Bara avvisade eller tomma (2)"*) ;; *) false ;; esac
  case "$output" in *"Needs attention"*|*"In progress"*|*"Not started"*|*"Complete ("*) echo "english leaked"; false ;; esac
}

@test "the label keys of this task exist in en and sv and in the JSON exporter" {
  keys="ov_board ov_epics ov_tasks ov_pending ov_group_attention ov_group_progress ov_group_started ov_group_notstarted ov_complete ov_hidden ov_rejected_empty ov_footer_scope ov_footer_all"
  for l in en sv; do
    for k in $keys; do
      run bash -c '. "$1"; progress_label "$2" "$3"' _ "$REPO/scripts/lib/progress-labels.sh" "$k" "$l"
      [ "$status" -eq 0 ]
      [ -n "$output" ]
    done
  done
  run bash "$REPO/scripts/progress-labels-json.sh"
  for k in $keys; do case "$output" in *"\"$k\":"*) ;; *) echo "missing $k"; false ;; esac; done
}

@test "control bytes in a title are replaced, never printed" {
  mk_stub "[$(ep E10 'Bad\u001b[31m title' 1 0 0 1 0)]"
  run "$S" --cols 80 --color never
  [ "$status" -eq 0 ]
  case "$output" in *"$ESC"*) false ;; esac
  case "$output" in *"Bad?[31m title"*) ;; *) echo "$output"; false ;; esac
}

@test "all complete: only the total and the Complete line, no group heading" {
  mk_stub "[$(ep E01 'One' 2 0 0 0 0),$(ep E02 'Two' 3 0 0 0 0)]"
  run "$S" --cols 80 --color never
  [ "$status" -eq 0 ]
  case "$output" in *"Board · 2 epics · 5/5 tasks · 100 %"*"Complete (2)"*) ;; *) false ;; esac
  case "$output" in *"Needs attention"*|*"In progress"*|*"Started"*|*"Not started"*) false ;; esac
  case "$output" in *★*) ;; *) false ;; esac
}

# E92_S10_T02: epf <id> <title> <failed_stories JSON> <percent>: an epic whose 4 tasks are all done but which
# board-progress.sh states with a failed story: no goal and the percent capped (99), failed_stories named.
epf() {
  printf '{"id":"%s","title":"%s","depends_on":[],"stories":{"totals":{"done":1,"in_progress":0,"failed":1,"pending":0,"rejected":0,"unknown":0,"denominator":2},"complete":2},"tasks":{"totals":{"done":4,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":4}},"epic_progress":{"stories":2,"decomposed":2,"tasks_done":4,"tasks_denominator":4,"percent":%d,"goal_reached":false,"failed_stories":%s},"ready_count":0}' \
    "$1" "$2" "$4" "$3"
}

@test "E92_S10_T02: an epic with a failed story is not complete, shows 99 % and names the failed story in its row" {
  mk_stub "[$(epf E70 'Failed story epic' '["E70_S02"]' 99),$(epf E71 'Two failed' '["E71_S01","E71_S03"]' 99),$(ep E72 'Open' 1 0 0 1 0),$(ep E73 'Done' 2 0 0 0 0)]"
  run "$S" --cols 120 --color never
  [ "$status" -eq 0 ]
  row="$(printf '%s\n' "$output" | grep -F '  E70 ')"
  case "$row" in *"4/4 99 %"*"Goal not reached - E70_S02 has failed · Failed story epic"*) ;; *) echo "row: $row"; false ;; esac
  row="$(printf '%s\n' "$output" | grep -F '  E71 ')"
  case "$row" in *"99 %"*"Goal not reached - E71_S01 and 1 more have failed"*) ;; *) echo "row: $row"; false ;; esac
  # only E73 is complete; E70 and E71 are open epics, never 100 %
  case "$output" in *"Complete (1)"*) ;; *) echo "$output"; false ;; esac
  case "$(printf '%s\n' "$output" | grep -E '  E7[01] ')" in *"100 %"*) false ;; esac
  # coloured: the failed line is red
  run "$S" --cols 120 --color always
  case "$output" in *"${ESC}[31mGoal not reached - E70_S02 has failed"*) ;; *) false ;; esac
  # Swedish
  JENGA_PROGRESS_LANG=sv run "$S" --cols 120 --color never
  case "$output" in *"Målet ej nått - E70_S02 har misslyckats"*) ;; *) false ;; esac
  # below the cap the row is unchanged: no failed line
  mk_stub "[$(epf E70 'Failed story epic' '["E70_S02"]' 66)]"
  run "$S" --cols 120 --color never
  case "$output" in *"Goal not reached"*) false ;; esac
  # and every width still fits
  mk_stub "[$(epf E70 'Failed story epic' '["E70_S02"]' 99)]"
  for c in 40 60 80; do
    run "$S" --cols "$c" --color never
    printf '%s\n' "$output" | width_ok "$c"
  done
}

@test "--all is accepted and prints nothing (the SKILL.md wiring of E92_S06_T26 prints the full list)" {
  mk_main
  run --separate-stderr "$S" --all --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "an empty board gives one stderr warning, no stdout, exit 0" {
  mk_stub '[]'
  run --separate-stderr "$S" --cols 80 --color never
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | grep -c 'warning')" -eq 1 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "board-progress.sh exiting 3 (no epic file) gives one warning, no stdout, exit 0" {
  printf '#!/usr/bin/env bash\necho "empty" >&2\nexit 3\n' > "$STUB_DIR/board-progress.sh"
  chmod +x "$STUB_DIR/board-progress.sh"
  export JENGA_BOARD_PROGRESS="$STUB_DIR/board-progress.sh"
  run --separate-stderr "$S" --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | grep -c 'warning')" -eq 1 ]
}

@test "a missing board-progress.sh gives one warning, no stdout, exit 0" {
  export JENGA_BOARD_PROGRESS="$BATS_TEST_TMPDIR/does-not-exist.sh"
  run --separate-stderr "$S" --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  case "$stderr" in *"board-progress.sh not found"*) ;; *) false ;; esac
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "malformed JSON gives one warning, no stdout, exit 0" {
  printf '#!/usr/bin/env bash\necho "{not json"\n' > "$STUB_DIR/board-progress.sh"
  chmod +x "$STUB_DIR/board-progress.sh"
  export JENGA_BOARD_PROGRESS="$STUB_DIR/board-progress.sh"
  run --separate-stderr "$S" --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | grep -c 'warning')" -eq 1 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a missing jq gives one warning, no stdout, exit 0" {
  mk_main
  tools="$BATS_TEST_TMPDIR/no-jq"
  mkdir -p "$tools"
  ln -s "$(command -v dirname)" "$tools/dirname"
  run --separate-stderr env PATH="$tools" "$BASH" "$S" --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  case "$stderr" in *"jq not found"*) ;; *) false ;; esac
}

@test "a missing label library gives one warning, no stdout, exit 0" {
  mk_main
  export JENGA_PROGRESS_LABELS="$BATS_TEST_TMPDIR/no-labels.sh"
  run --separate-stderr "$S" --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  case "$stderr" in *"progress-labels.sh not found"*) ;; *) false ;; esac
}

@test "usage errors exit 2 with empty stdout" {
  mk_main
  for args in "--bogus" "--cols" "--cols abc" "--cols 0" "--color" "--color purple" "--root" "E10" "-x"; do
    # shellcheck disable=SC2086
    run --separate-stderr "$S" $args
    [ "$status" -eq 2 ] || { echo "args '$args' gave $status"; false; }
    [ -z "$output" ]
    [ -n "$stderr" ]
  done
}

@test "it never writes to the board: the working directory is unchanged after a run" {
  mk_main
  cd "$BATS_TEST_TMPDIR"
  mkdir -p work && cd work
  run "$S" --cols 80 --color never
  [ "$status" -eq 0 ]
  [ -z "$(ls -A)" ]
}

@test "against the real board it prints a short, valid overview (smoke)" {
  run --separate-stderr "$S" --cols 80 --color never --root "$REPO"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  case "$output" in "Board · "*) ;; *) false ;; esac
  printf '%s\n' "$output" | width_ok 80
}
