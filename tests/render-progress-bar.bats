#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E92_S02_T02, E92_S02_T03 and E92_S05_T03: scripts/render-progress-bar.sh - board-progress JSON in, one progress line out, fitted to the
# terminal width (the width tests are at the end of the file).
# Every fixture is hand-written contract JSON (project/documentation/progress-visualisation.md, section 3); the one
# exception is the last test, which pipes the real scripts/board-progress.sh output (skipped while that script is absent).
# Default label language is en; JENGA_PROGRESS_LANG=sv selects Swedish. bats runs with stdout that is not a TTY, so colour
# is off unless a test asks for --color always.
#
# bash prints a setlocale warning on stderr when LC_ALL names a locale the machine lacks, so tests that read the line use
# --separate-stderr and compare $output (stdout) only.

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  R="$REPO/scripts/render-progress-bar.sh"
  unset NO_COLOR JENGA_PROGRESS_LANG LC_CTYPE COLUMNS
  export LANG="en_US.UTF-8"
  unset LC_ALL
  ESC=$'\033'
}

# mk <name> <done> <in_progress> <failed> <pending> <rejected> <unknown> <denominator>: writes $BATS_TEST_TMPDIR/<name>.json
mk() {
  printf '{"schema_version":1,"scope":{"type":"story","ids":["E00_S00"]},"levels":{"tasks":{"counts":{},"totals":{"done":%s,"in_progress":%s,"failed":%s,"pending":%s,"rejected":%s,"unknown":%s,"denominator":%s}}},"warnings":[]}\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" > "$BATS_TEST_TMPDIR/$1.json"
}

# render <name> [options...]: runs the renderer on the named fixture via stdin. Since E92_S02_T03 the renderer fits the line
# to the terminal width (80 by default); the E92_S02_T02 tests are about bars and text, not width, so this helper gives
# them a wide terminal. An explicit --cols in the options wins (the last one counts).
render() {
  local name="$1"; shift
  run --separate-stderr bash "$R" --cols 1000 "$@" < "$BATS_TEST_TMPDIR/$name.json"
}

strip_ansi() { printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*m//g"; }

# vlen <string>: visible length in characters (not bytes, whatever the locale): ANSI escapes stripped first, every glyph
# one cell. Sets VLEN.
vlen() {
  VLEN="$(strip_ansi "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' ')"
}

@test "script has a bash shebang, parses under bash -n and is executable" {
  [ -x "$R" ]
  [ "$(head -n 1 "$R")" = "#!/usr/bin/env bash" ]
  run bash -n "$R"
  [ "$status" -eq 0 ]
}

@test "all passed: full bar, 10/10 and no extra segments" {
  mk allpass 10 0 0 0 0 0 10
  render allpass
  [ "$status" -eq 0 ]
  [ "$output" = "[━━━━━━━━━━]★ 10/10" ]
}

@test "mixed in sv: the example line of the task" {
  mk mixed 8 1 1 0 0 0 10
  JENGA_PROGRESS_LANG=sv render mixed
  [ "$status" -eq 0 ]
  [ "$output" = "[━━━━━━━━╌╌]⚑ 8/10 · 1 pågår · 1 röd" ]
}

@test "mixed in en (the default language)" {
  mk mixed 8 1 1 0 0 0 10
  render mixed
  [ "$status" -eq 0 ]
  [ "$output" = "[━━━━━━━━╌╌]⚑ 8/10 · 1 in progress · 1 red" ]
}

@test "with failures only: failed segment appears, in-progress segment does not" {
  mk fail 6 0 2 2 0 0 10
  JENGA_PROGRESS_LANG=sv render fail
  [ "$status" -eq 0 ]
  [ "$output" = "[━━━━━━╌╌╌╌]⚑ 6/10 · 2 röd" ]
}

@test "with rejections: the note is present and the rejected count is not part of done/denominator" {
  mk rej 8 1 1 0 2 0 10
  JENGA_PROGRESS_LANG=sv render rej
  [ "$status" -eq 0 ]
  [ "$output" = "[━━━━━━━━╌╌]⚑ 8/10 · 1 pågår · 1 röd · ⊘ 2 avvisade (ej räknade)" ]
  mk rej2 4 0 0 0 3 0 4
  render rej2
  [ "$output" = "[━━━━━━━━━━]★ 4/4 · ⊘ 3 rejected (not counted)" ]
}

@test "the rejected note is omitted when rejected is 0" {
  mk norej 8 1 1 0 0 0 10
  render norej
  case "$output" in *"⊘"*|*rejected*) false ;; esac
}

@test "Rejected is never drawn: the bar is the same whatever the rejected count" {
  mk r0 3 1 1 5 0 0 10
  mk r9 3 1 1 5 99 0 10
  render r0
  bar0="${output%%]*}"
  render r9
  bar9="${output%%]*}"
  [ "$bar0" = "$bar9" ]
}

@test "unknown statuses are reported as text with their number" {
  mk unk 5 0 0 3 0 2 8
  render unk
  [ "$status" -eq 0 ]
  case "$output" in *"5/8 · 2 unknown"*) ;; *) false ;; esac
}

@test "nothing started: all-grey bar, 0/0 and the nothing label, no division by zero" {
  mk none 0 0 0 0 0 0 0
  render none
  [ "$status" -eq 0 ]
  [ "$output" = "[╌╌╌╌╌╌╌╌╌╌] 0/0 · nothing to count" ]
  JENGA_PROGRESS_LANG=sv render none
  [ "$output" = "[╌╌╌╌╌╌╌╌╌╌] 0/0 · inget att räkna" ]
}

@test "99 of 100 done is never rendered full, at any width" {
  mk near 99 0 0 1 0 0 100
  local w
  for w in 1 2 3 5 10 20 40 100; do
    render near --cells "$w"
    [ "$status" -eq 0 ]
    bar="${output%%]*}"; bar="${bar#[}"
    [ "${#bar}" -eq "$w" ]
    case "$bar" in *╌*) ;; *) echo "full bar at width $w: $bar"; false ;; esac
  done
}

@test "1 of 100 done still shows one filled cell" {
  mk one 1 0 0 99 0 0 100
  render one
  [ "$output" = "[━╌╌╌╌╌╌╌╌╌]⚑ 1/100" ]
}

@test "cells always sum to the bar width and a bar is full only when nothing is open" {
  local w d p f q
  for w in 1 2 4 7 13 33; do
    for d in 0 1 7; do
      for p in 0 3; do
        for f in 0 1; do
          for q in 0 5; do
            den=$((d + p + f + q))
            [ "$den" -gt 0 ] || continue
            mk grid "$d" "$p" "$f" "$q" 2 0 "$den"
            render grid --cells "$w"
            [ "$status" -eq 0 ]
            bar="${output%%]*}"; bar="${bar#[}"
            [ "${#bar}" -eq "$w" ] || { echo "w=$w d=$d p=$p f=$f q=$q bar=$bar"; false; }
            filled="${bar//╌/}"
            if [ $((p + f + q)) -gt 0 ]; then
              [ "${#filled}" -lt "$w" ] || { echo "full with open work: w=$w d=$d p=$p f=$f q=$q bar=$bar"; false; }
            else
              [ "${#filled}" -eq "$w" ] || { echo "not full when done: w=$w bar=$bar"; false; }
            fi
            if [ "$d" -gt 0 ] && [ "$w" -ge 4 ] && [ $((p + f + q)) -gt 0 ]; then
              [ "${#filled}" -ge 1 ] || { echo "done bucket vanished: w=$w d=$d bar=$bar"; false; }
            fi
          done
        done
      done
    done
  done
}

@test "--cells sets the width" {
  mk w 5 0 0 5 0 0 10
  render w --cells 4
  [ "$output" = "[━━╌╌]⚑ 5/10" ]
  render w --cells=20
  [ "$output" = "[━━━━━━━━━━╌╌╌╌╌╌╌╌╌╌]⚑ 5/10" ]
}

@test "colour is off with NO_COLOR=1, off for a non-TTY, and off with --color never" {
  mk mixed 8 1 1 0 2 0 10
  NO_COLOR=1 render mixed
  case "$output" in *"$ESC"*) false ;; esac
  render mixed
  case "$output" in *"$ESC"*) false ;; esac
  render mixed --color never
  case "$output" in *"$ESC"*) false ;; esac
  render mixed --color auto
  case "$output" in *"$ESC"*) false ;; esac
  NO_COLOR=1 render mixed --color auto
  case "$output" in *"$ESC"*) false ;; esac
}

@test "--color always emits green, yellow, red and grey for the right segments" {
  mk allfour 4 3 2 1 0 0 10
  render allfour --color always
  [ "$status" -eq 0 ]
  [ "$output" = "[${ESC}[32m━━━━${ESC}[0m${ESC}[33m╌╌╌${ESC}[0m${ESC}[31m╌╌${ESC}[0m${ESC}[90m╌${ESC}[0m]⚑ 4/10 · 3 in progress · 2 red" ]
}

@test "--color always omits the escape for an empty bucket" {
  mk twice 5 0 0 5 0 0 10
  render twice --color always
  case "$output" in *"${ESC}[33m"*|*"${ESC}[31m"*) false ;; esac
  case "$output" in *"${ESC}[32m"*"${ESC}[90m"*) ;; *) false ;; esac
}

@test "counts and the note are text in every colour mode: stripped colour equals plain" {
  mk mixed 8 1 1 0 2 3 12
  JENGA_PROGRESS_LANG=sv render mixed --color never
  plain="$output"
  JENGA_PROGRESS_LANG=sv render mixed --color always
  [ "$(strip_ansi "$output")" = "$plain" ]
  case "$plain" in *"8/12"*"1 pågår"*"1 röd"*"3 okända"*"⊘ 2 avvisade (ej räknade)"*) ;; *) false ;; esac
}

@test "non-UTF-8 locale falls back to ASCII glyphs" {
  mk mixed 8 1 1 0 2 0 10
  LC_ALL=C render mixed
  [ "$status" -eq 0 ]
  [ "$output" = "[########--]> 8/10 - 1 in progress - 1 red - (x) 2 rejected (not counted)" ]
  LC_ALL=C JENGA_PROGRESS_LANG=sv render mixed
  [ "$output" = "[########--]> 8/10 - 1 pågår - 1 röd - (x) 2 avvisade (ej räknade)" ]
}

@test "locale precedence: LC_ALL beats LC_CTYPE beats LANG" {
  mk mixed 8 1 1 0 0 0 10
  LC_ALL=C LANG=en_US.UTF-8 render mixed
  case "$output" in "[#"*) ;; *) false ;; esac
  unset LC_ALL
  LC_CTYPE=C LANG=en_US.UTF-8 render mixed
  case "$output" in "[#"*) ;; *) false ;; esac
  unset LC_CTYPE
  LANG=C render mixed
  case "$output" in "[#"*) ;; *) false ;; esac
  LANG=sv_SE.utf8 render mixed
  case "$output" in "[━"*) ;; *) false ;; esac
}

@test "--file reads the document from a path" {
  mk mixed 8 1 1 0 0 0 10
  run --separate-stderr bash "$R" --file "$BATS_TEST_TMPDIR/mixed.json"
  [ "$status" -eq 0 ]
  [ "$output" = "[━━━━━━━━╌╌]⚑ 8/10 · 1 in progress · 1 red" ]
}

@test "--level selects a block; the default level is tasks" {
  printf '%s' '{"schema_version":1,"levels":{"tasks":{"totals":{"done":1,"in_progress":0,"failed":0,"pending":1,"rejected":0,"unknown":0,"denominator":2}},"stories":{"totals":{"done":3,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":3}}}}' > "$BATS_TEST_TMPDIR/two.json"
  render two
  [ "$output" = "[━━━━━╌╌╌╌╌]⚑ 1/2" ]
  render two --level stories
  [ "$output" = "[━━━━━━━━━━]★ 3/3" ]
}

@test "without --level and without a tasks level, the first present level is used" {
  printf '%s' '{"schema_version":1,"levels":{"epics":{"totals":{"done":1,"in_progress":0,"failed":0,"pending":3,"rejected":0,"unknown":0,"denominator":4}}}}' > "$BATS_TEST_TMPDIR/ep.json"
  render ep
  [ "$status" -eq 0 ]
  [ "$output" = "[━━╌╌╌╌╌╌╌╌]⚑ 1/4" ]
}

@test "malformed JSON exits 2 with a stderr message and empty stdout" {
  printf '%s' '{"levels": {' > "$BATS_TEST_TMPDIR/bad.json"
  render bad
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "empty input and non-contract JSON exit 2 with empty stdout" {
  : > "$BATS_TEST_TMPDIR/empty.json"
  render empty
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
  printf '%s' '[1,2,3]' > "$BATS_TEST_TMPDIR/arr.json"
  render arr
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "a missing level exits 2 with a stderr message and empty stdout" {
  mk mixed 8 1 1 0 0 0 10
  render mixed --level epics
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  case "$stderr" in *epics*) ;; *) false ;; esac
  printf '%s' '{"schema_version":1,"levels":{}}' > "$BATS_TEST_TMPDIR/nolevels.json"
  render nolevels
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "totals that are not non-negative integers exit 2" {
  printf '%s' '{"levels":{"tasks":{"totals":{"done":"8","in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":8}}}}' > "$BATS_TEST_TMPDIR/str.json"
  render str
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  printf '%s' '{"levels":{"tasks":{"totals":{"done":-1,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":8}}}}' > "$BATS_TEST_TMPDIR/neg.json"
  render neg
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  printf '%s' '{"levels":{"tasks":{"totals":{"done":1}}}}' > "$BATS_TEST_TMPDIR/part.json"
  render part
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "a missing jq exits 2 naming jq, with empty stdout" {
  mk mixed 8 1 1 0 0 0 10
  empty_path="$BATS_TEST_TMPDIR/no-tools"
  mkdir -p "$empty_path"
  run --separate-stderr env PATH="$empty_path" "$BASH" "$R" --file "$BATS_TEST_TMPDIR/mixed.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  case "$stderr" in *jq*) ;; *) false ;; esac
}

@test "usage errors exit 2 with empty stdout" {
  mk mixed 8 1 1 0 0 0 10
  run --separate-stderr bash "$R" --bogus < "$BATS_TEST_TMPDIR/mixed.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]; [ -n "$stderr" ]
  run --separate-stderr bash "$R" --cells 0 < "$BATS_TEST_TMPDIR/mixed.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr bash "$R" --cells abc < "$BATS_TEST_TMPDIR/mixed.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr bash "$R" --color purple < "$BATS_TEST_TMPDIR/mixed.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr bash "$R" --level jobs < "$BATS_TEST_TMPDIR/mixed.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr bash "$R" --file "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]; [ -n "$stderr" ]
}

@test "--help prints usage and exits 0" {
  run --separate-stderr bash "$R" --help
  [ "$status" -eq 0 ]
  case "$output" in *"--level"*"--cells"*"--color"*) ;; *) false ;; esac
}

@test "the renderer holds no status names" {
  run grep -n -E 'Passed|In Progress|Failed|Rejected|Blocked|Pending' "$R"
  [ "$status" -eq 1 ]
}

@test "the renderer writes nothing: a run leaves the working directory unchanged" {
  mk mixed 8 1 1 0 2 0 10
  work="$BATS_TEST_TMPDIR/cwd"
  mkdir -p "$work"
  cd "$work"
  run --separate-stderr bash "$R" --file "$BATS_TEST_TMPDIR/mixed.json" --color always
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$work")" ]
}

@test "integration: the real board-progress.sh output for a fixture board renders" {
  BP="$REPO/scripts/board-progress.sh"
  [ -f "$BP" ] || skip "scripts/board-progress.sh does not exist yet (E92_S01_T02 is not merged)"
  fx="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$fx/project/configs" "$fx/project/board/epics" "$fx/project/board/stories" "$fx/project/board/tasks"
  cp "$REPO/project/configs/workflow.json" "$fx/project/configs/workflow.json"
  printf -- '---\nid: E90\ntitle: "Fixture epic"\nstatus: In Progress\n---\n' > "$fx/project/board/epics/E90_fixture.md"
  printf -- '---\nid: E90_S01\nepic_id: E90\ntitle: "Fixture story"\nstatus: In Progress\n---\n' > "$fx/project/board/stories/E90_S01_fixture.md"
  local i=0 st
  for st in "Passed" "Passed with remarks" "In Progress" "Failed" "Rejected"; do
    i=$((i + 1))
    printf -- '---\nid: E90_S01_T0%s\nstory_id: E90_S01\nepic_id: E90\ntitle: "Fixture task %s"\nstatus: %s\n---\n' "$i" "$i" "$st" \
      > "$fx/project/board/tasks/E90_S01_T0${i}_fixture.md"
  done
  run --separate-stderr bash -c 'bash "$1" --story E90_S01 --root "$2" | bash "$3"' _ "$BP" "$fx" "$R"
  [ "$status" -eq 0 ]
  case "$output" in "["*"]⚑ 2/4 · 1 in progress · 1 red · ⊘ 1 rejected (not counted)") ;; *) echo "got: $output"; false ;; esac
}

# ---------------------------------------------------------------------------------------------------------------------
# E92_S02_T03: terminal width. Fixtures: "rej" = mixed with rejections (8 done, 1 in progress, 1 failed, 2 rejected, of 10),
# "mixed" = the same without rejections, "wide" = rej plus 3 unknown. Language sv unless a test says otherwise.
# ---------------------------------------------------------------------------------------------------------------------

REJ_SV_FULL="[━━━━━━━━╌╌]⚑ 8/10 · 1 pågår · 1 röd · ⊘ 2 avvisade (ej räknade)"

# wcheck <width> <expected-line-or-empty>: renders "rej" in sv at the width, colour off and then on, and asserts for both
# that the visible length is within the width and that the output is exactly one line. Leaves the colour-off output in
# $PLAIN and the colour-on output stripped of ANSI in $STRIPPED.
wcheck() {
  local w="$1" mode
  for mode in never always; do
    JENGA_PROGRESS_LANG=sv run --separate-stderr bash "$R" --cols "$w" --color "$mode" < "$BATS_TEST_TMPDIR/${FIXTURE:-rej}.json"
    [ "$status" -eq 0 ]
    vlen "$output"
    if [ "$VLEN" -gt "$w" ]; then echo "mode=$mode width=$w visible=$VLEN line=$output"; return 1; fi
    # exactly one line: one terminating newline and no other
    JENGA_PROGRESS_LANG=sv bash "$R" --cols "$w" --color "$mode" < "$BATS_TEST_TMPDIR/${FIXTURE:-rej}.json" > "$BATS_TEST_TMPDIR/out.txt"
    [ "$(wc -l < "$BATS_TEST_TMPDIR/out.txt" | tr -d ' ')" = "1" ]
    [ "$(tail -c 1 "$BATS_TEST_TMPDIR/out.txt" | od -An -c | tr -d ' ')" = '\n' ]
    if [ "$mode" = "never" ]; then PLAIN="$output"; else STRIPPED="$(strip_ansi "$output")"; fi
  done
  # colour never changes the visible line
  [ "$PLAIN" = "$STRIPPED" ]
}

@test "width: MIN_BAR_CELLS is documented in the script header and defined as a variable, and both say 4" {
  header="$(sed -n '/^# WIDTH/,/^# EXIT CODES/p' "$R" | grep -E '^#[[:space:]]+MIN_BAR_CELLS=[0-9]+' | head -n 1 | sed -E 's/^#[[:space:]]+MIN_BAR_CELLS=([0-9]+).*/\1/')"
  var="$(grep -E '^MIN_BAR_CELLS=[0-9]+$' "$R" | head -n 1 | sed -E 's/^MIN_BAR_CELLS=//')"
  [ -n "$header" ]; [ -n "$var" ]
  [ "$header" = "$var" ]
  [ "$var" -eq 4 ]
}

@test "width: the header documents the drop order, the width source and the final truncation" {
  hdr="$(sed -n '/^# WIDTH/,/^# EXIT CODES/p' "$R")"
  case "$hdr" in *"unknown, then the rejected note, then in_progress"*) ;; *) false ;; esac
  case "$hdr" in *"done/denominator and failed are never dropped"*) ;; *) false ;; esac
  case "$hdr" in *"--cols N; the COLUMNS environment variable"*"stty size"*"otherwise 80"*) ;; *) false ;; esac
  case "$hdr" in *'single "…"'*) ;; *) false ;; esac
}

@test "width 120 and 80: the full line with a 10-cell bar is printed unchanged" {
  mk rej 8 1 1 0 2 0 10
  local w
  for w in 120 80; do
    wcheck "$w"
    [ "$PLAIN" = "$REJ_SV_FULL" ]
  done
}

@test "width 60: the bar shrinks and the line fits, with colour on and off" {
  mk rej 8 1 1 0 2 0 10
  wcheck 60
  case "$PLAIN" in "["*"]⚑ 8/10 · 1 pågår · 1 röd · ⊘ 2 avvisade (ej räknade)") ;; *) echo "got: $PLAIN"; false ;; esac
  bar="${PLAIN%%\]*}"; bar="${bar#\[}"
  vlen "$bar"
  [ "$VLEN" -lt 10 ]
  [ "$VLEN" -ge 4 ]
  # the bar uses all the room that the text leaves: the line is exactly 60 wide
  vlen "$PLAIN"; [ "$VLEN" -eq 60 ]
}

@test "width 40 and 30: fewer than MIN_BAR_CELLS fit with the rejection note, so the text-only line is printed" {
  mk rej 8 1 1 0 2 0 10
  wcheck 40
  [ "$PLAIN" = "8/10 · 1 pågår · 1 röd" ]
  wcheck 30
  [ "$PLAIN" = "8/10 · 1 pågår · 1 röd" ]
}

@test "width 40 and 30 with a shorter line: the bar stays at 10 cells and then shrinks to 4 and the line fits" {
  mk mixed 8 1 1 0 0 0 10
  FIXTURE=mixed wcheck 40
  [ "$PLAIN" = "[━━━━━━━━╌╌]⚑ 8/10 · 1 pågår · 1 röd" ]
  FIXTURE=mixed wcheck 30
  [ "$PLAIN" = "[━━╌╌]⚑ 8/10 · 1 pågår · 1 röd" ]
  bar="${PLAIN%%\]*}"; bar="${bar#\[}"
  vlen "$bar"; [ "$VLEN" -eq 4 ]
}

@test "width 20 and 8: at most the width, starts with done/denominator, one line" {
  mk rej 8 1 1 0 2 0 10
  wcheck 20
  [ "$PLAIN" = "8/10 · 1 röd" ]
  case "$PLAIN" in "8/10"*) ;; *) false ;; esac
  wcheck 8
  case "$PLAIN" in "8/10"*) ;; *) echo "got: $PLAIN"; false ;; esac
  [ "$PLAIN" = "8/10…" ]
}

@test "width sweep: for every width from 1 to 130 the visible length never exceeds the width (colour on and off)" {
  mk rej 8 1 1 0 2 0 10
  local w
  for w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 \
           45 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 70 100 130; do
    wcheck "$w"
    # below 5 columns even "8/10…" does not fit; from 5 up the line starts with a bar or done/denominator
    if [ "$w" -ge 5 ]; then case "$PLAIN" in "["*|"8/10"*) ;; *) echo "w=$w got: $PLAIN"; false ;; esac; fi
  done
}

@test "width: MIN_BAR_CELLS is the boundary between a shrunken bar and the text-only line (reads the constant)" {
  min="$(grep -E '^MIN_BAR_CELLS=[0-9]+$' "$R" | head -n 1 | sed -E 's/^MIN_BAR_CELLS=//')"
  [ -n "$min" ]
  mk mixed 8 1 1 0 0 0 10
  text="8/10 · 1 pågår · 1 röd"
  vlen "$text"; tl=$VLEN
  # exactly MIN_BAR_CELLS fit: the bar has MIN_BAR_CELLS cells
  FIXTURE=mixed wcheck $((tl + 4 + min))
  bar="${PLAIN%%\]*}"; bar="${bar#\[}"
  vlen "$bar"; [ "$VLEN" -eq "$min" ]
  # one cell less: bar and brackets are dropped and the whole text is printed
  FIXTURE=mixed wcheck $((tl + 4 + min - 1))
  [ "$PLAIN" = "$text" ]
}

@test "width: an explicit --cells below MIN_BAR_CELLS that fits is kept (the minimum only governs shrinking)" {
  mk mixed 8 1 1 0 0 0 10
  JENGA_PROGRESS_LANG=sv run --separate-stderr bash "$R" --cells 2 --cols 80 < "$BATS_TEST_TMPDIR/mixed.json"
  [ "$status" -eq 0 ]
  case "$output" in "["??"]⚑ 8/10"*) ;; *) echo "got: $output"; false ;; esac
}

@test "width source: --cols, then COLUMNS, then 80; --cols wins over COLUMNS" {
  mk wide 8 1 1 0 2 3 10
  # the full line of this fixture is 81 wide with a 10-cell bar, so only widths below that change it
  run --separate-stderr bash "$R" --cols 200 < "$BATS_TEST_TMPDIR/wide.json"
  full="$output"
  vlen "$full"; [ "$VLEN" -gt 80 ]
  # the 80 default: nothing set
  run --separate-stderr bash "$R" < "$BATS_TEST_TMPDIR/wide.json"
  [ "$status" -eq 0 ]; vlen "$output"; [ "$VLEN" -le 80 ]; [ "$output" != "$full" ]
  default80="$output"
  run --separate-stderr bash "$R" --cols 80 < "$BATS_TEST_TMPDIR/wide.json"
  [ "$output" = "$default80" ]
  # COLUMNS alone is used
  COLUMNS=200 run --separate-stderr bash "$R" < "$BATS_TEST_TMPDIR/wide.json"
  [ "$output" = "$full" ]
  COLUMNS=30 run --separate-stderr bash "$R" < "$BATS_TEST_TMPDIR/wide.json"
  vlen "$output"; [ "$VLEN" -le 30 ]; [ "$output" != "$default80" ]
  # --cols wins over COLUMNS, in both directions
  COLUMNS=30 run --separate-stderr bash "$R" --cols 200 < "$BATS_TEST_TMPDIR/wide.json"
  [ "$output" = "$full" ]
  COLUMNS=200 run --separate-stderr bash "$R" --cols 30 < "$BATS_TEST_TMPDIR/wide.json"
  vlen "$output"; [ "$VLEN" -le 30 ]; [ "$output" != "$full" ]
  run --separate-stderr bash "$R" --cols=200 < "$BATS_TEST_TMPDIR/wide.json"
  [ "$output" = "$full" ]
}

@test "width source: an invalid COLUMNS is ignored (80 applies); an invalid --cols is a usage error" {
  mk wide 8 1 1 0 2 3 10
  run --separate-stderr bash "$R" < "$BATS_TEST_TMPDIR/wide.json"
  default80="$output"
  local bad
  for bad in abc 0 "" -5 "12x"; do
    COLUMNS="$bad" run --separate-stderr bash "$R" < "$BATS_TEST_TMPDIR/wide.json"
    [ "$status" -eq 0 ]; [ "$output" = "$default80" ]
  done
  for bad in abc 0 -5 10001 ""; do
    run --separate-stderr bash "$R" --cols "$bad" < "$BATS_TEST_TMPDIR/wide.json"
    [ "$status" -eq 2 ]; [ -z "$output" ]; [ -n "$stderr" ]
  done
  run --separate-stderr bash "$R" --cols < "$BATS_TEST_TMPDIR/wide.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]
}

@test "width: segments are dropped in the order unknown, rejected note, in_progress; done/denominator and failed stay" {
  mk wide 8 1 1 0 2 3 10
  full="8/10 · 1 pågår · 1 röd · 3 okända · ⊘ 2 avvisade (ej räknade)"
  no_unk="8/10 · 1 pågår · 1 röd · ⊘ 2 avvisade (ej räknade)"
  no_rej="8/10 · 1 pågår · 1 röd"
  no_prog="8/10 · 1 röd"
  local case_ w expect
  for case_ in "$full" "$no_unk" "$no_rej" "$no_prog"; do
    vlen "$case_"; w=$VLEN
    FIXTURE=wide wcheck "$w"
    [ "$PLAIN" = "$case_" ] || { echo "w=$w expected: $case_ got: $PLAIN"; false; }
  done
  # one column less than each level falls to the next level down
  vlen "$full";    FIXTURE=wide wcheck $((VLEN - 1)); [ "$PLAIN" = "$no_unk" ]
  vlen "$no_unk";  FIXTURE=wide wcheck $((VLEN - 1)); [ "$PLAIN" = "$no_rej" ]
  vlen "$no_rej";  FIXTURE=wide wcheck $((VLEN - 1)); [ "$PLAIN" = "$no_prog" ]
  # below the done/denominator + failed line the text is hard-truncated with a single ellipsis
  vlen "$no_prog"; FIXTURE=wide wcheck $((VLEN - 1))
  [ "$PLAIN" = "8/10 · 1 r…" ]
  case "$PLAIN" in *"…") ;; *) false ;; esac
  rest="${PLAIN%…}"; case "$rest" in *"…"*) false ;; esac
}

@test "width: hard truncation keeps the start, ends with one ellipsis and trims a dangling separator" {
  mk rej 8 1 1 0 2 0 10
  FIXTURE=rej wcheck 8;  [ "$PLAIN" = "8/10…" ]
  FIXTURE=rej wcheck 9;  [ "$PLAIN" = "8/10 · 1…" ]
  FIXTURE=rej wcheck 7;  [ "$PLAIN" = "8/10…" ]
  FIXTURE=rej wcheck 10; [ "$PLAIN" = "8/10 · 1…" ]
  FIXTURE=rej wcheck 11; [ "$PLAIN" = "8/10 · 1 r…" ]
  FIXTURE=rej wcheck 1;  [ "$PLAIN" = "…" ]
  # a multibyte character is never cut in half: stdout is valid UTF-8 at every width
  local w
  for w in 11 12 14 15 16 17 18 19; do
    JENGA_PROGRESS_LANG=sv run --separate-stderr bash "$R" --cols "$w" < "$BATS_TEST_TMPDIR/rej.json"
    printf '%s' "$output" | iconv -f UTF-8 -t UTF-8 >/dev/null
  done
}

@test "width: the ASCII fallback counts '(x)' as three cells and truncates with a single '~'" {
  mk rej 8 1 1 0 2 0 10
  line="8/10 - 1 in progress - 1 red - (x) 2 rejected (not counted)"
  vlen "$line"; tl=$VLEN
  LC_ALL=C run --separate-stderr bash "$R" --cols "$tl" --cells 1 < "$BATS_TEST_TMPDIR/rej.json"
  [ "$output" = "$line" ]
  # one cell less than the text-only line: the rejected note goes
  LC_ALL=C run --separate-stderr bash "$R" --cols $((tl - 1)) < "$BATS_TEST_TMPDIR/rej.json"
  [ "$output" = "8/10 - 1 in progress - 1 red" ]
  LC_ALL=C run --separate-stderr bash "$R" --cols 8 < "$BATS_TEST_TMPDIR/rej.json"
  [ "$output" = "8/10~" ]
  local w
  for w in 1 5 8 12 20 30 45 60 70 80; do
    LC_ALL=C JENGA_PROGRESS_LANG=sv run --separate-stderr bash "$R" --cols "$w" --color always < "$BATS_TEST_TMPDIR/rej.json"
    [ "$status" -eq 0 ]
    vlen "$output"
    if [ "$VLEN" -gt "$w" ]; then echo "w=$w visible=$VLEN line=$output"; false; fi
  done
}

@test "width: denominator 0 and a wide count still fit and never wrap" {
  mk empty 0 0 0 0 0 0 0
  JENGA_PROGRESS_LANG=sv run --separate-stderr bash "$R" --cols 80 < "$BATS_TEST_TMPDIR/empty.json"
  [ "$output" = "[╌╌╌╌╌╌╌╌╌╌] 0/0 · inget att räkna" ]
  FIXTURE=empty wcheck 12
  case "$PLAIN" in "0/0"*) ;; *) false ;; esac
  mk big 123456 12345 1234 0 0 0 136935
  FIXTURE=big wcheck 12
  case "$PLAIN" in "123456/"*) ;; *) echo "got: $PLAIN"; false ;; esac
}

@test "width: --help documents --cols" {
  run --separate-stderr bash "$R" --help
  [ "$status" -eq 0 ]
  case "$output" in *"--cols"*) ;; *) false ;; esac
}

@test "width: works under the system bash 3.2 (macOS) when it is present" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  mk rej 8 1 1 0 2 0 10
  JENGA_PROGRESS_LANG=sv run --separate-stderr /bin/bash "$R" --cols 20 < "$BATS_TEST_TMPDIR/rej.json"
  [ "$status" -eq 0 ]
  [ "$output" = "8/10 · 1 röd" ]
  JENGA_PROGRESS_LANG=sv run --separate-stderr /bin/bash "$R" --cols 60 < "$BATS_TEST_TMPDIR/rej.json"
  vlen "$output"; [ "$VLEN" -eq 60 ]
}

@test "width: the real board-progress.sh output, fitted to a narrow terminal, stays within the width" {
  BP="$REPO/scripts/board-progress.sh"
  [ -f "$BP" ] || skip "scripts/board-progress.sh does not exist"
  fx="$BATS_TEST_TMPDIR/fxw"
  mkdir -p "$fx/project/configs" "$fx/project/board/epics" "$fx/project/board/stories" "$fx/project/board/tasks"
  cp "$REPO/project/configs/workflow.json" "$fx/project/configs/workflow.json"
  printf -- '---\nid: E90\ntitle: "Fixture epic"\nstatus: In Progress\n---\n' > "$fx/project/board/epics/E90_fixture.md"
  printf -- '---\nid: E90_S01\nepic_id: E90\ntitle: "Fixture story"\nstatus: In Progress\n---\n' > "$fx/project/board/stories/E90_S01_fixture.md"
  local i=0 st
  for st in "Passed" "Passed with remarks" "In Progress" "Failed" "Rejected"; do
    i=$((i + 1))
    printf -- '---\nid: E90_S01_T0%s\nstory_id: E90_S01\nepic_id: E90\ntitle: "Fixture task %s"\nstatus: %s\n---\n' "$i" "$i" "$st" \
      > "$fx/project/board/tasks/E90_S01_T0${i}_fixture.md"
  done
  local w
  for w in 120 60 30 20; do
    run --separate-stderr bash -c 'bash "$1" --story E90_S01 --root "$2" | bash "$3" --cols "$4" --color always' _ "$BP" "$fx" "$R" "$w"
    [ "$status" -eq 0 ]
    vlen "$output"
    if [ "$VLEN" -gt "$w" ]; then echo "w=$w visible=$VLEN line=$output"; false; fi
    case "$(strip_ansi "$output")" in *"2/4"*|"2/"*) ;; *) echo "got: $output"; false ;; esac
  done
}

# pty_render <columns> [options]: runs the renderer with stdout on a pseudo-terminal of the given width (COLUMNS unset,
# TERM=xterm) and prints what it wrote. Exit status 77 means no pty could be made here.
pty_render() {
  local cols="$1"; shift
  python3 - "$cols" "$R" "${PTY_FIXTURE:-$BATS_TEST_TMPDIR/rej.json}" "$@" <<'PY'
import os, pty, sys, fcntl, termios, struct, select
cols, script, fixture = int(sys.argv[1]), sys.argv[2], sys.argv[3]
extra = sys.argv[4:]
try:
    master, slave = pty.openpty()
except OSError:
    sys.exit(77)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, cols, 0, 0))
env = {k: v for k, v in os.environ.items() if k != "COLUMNS"}
env["TERM"] = "xterm"
pid = os.fork()
if pid == 0:
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(master)
    fin = os.open(fixture, os.O_RDONLY)
    os.dup2(fin, 0)
    shell = os.environ.get("PTY_BASH", "bash")
    os.execvpe(shell, [shell, script] + extra, env)
os.close(slave)
out = b""
while True:
    r, _, _ = select.select([master], [], [], 10)
    if not r:
        break
    try:
        d = os.read(master, 4096)
    except OSError:
        break
    if not d:
        break
    out += d
os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8").replace("\r\n", "\n"))
PY
}

@test "width: on a TTY with neither --cols nor COLUMNS the terminal's width is used (stty size)" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is needed to make a pseudo-terminal"
  command -v stty >/dev/null 2>&1 || skip "stty is not installed"
  mk rej 8 1 1 0 2 0 10
  export JENGA_PROGRESS_LANG=sv
  run --separate-stderr pty_render 100 --color never
  [ "$status" -ne 77 ] || skip "no pseudo-terminal available"
  [ "$status" -eq 0 ]
  [ "$output" = "$REJ_SV_FULL" ]
  run --separate-stderr pty_render 40 --color never
  [ "$status" -eq 0 ]
  vlen "$output"
  if [ "$VLEN" -gt 40 ]; then echo "visible=$VLEN line=$output"; false; fi
  [ "$output" = "8/10 · 1 pågår · 1 röd" ]
  # --cols still wins over the terminal
  run --separate-stderr pty_render 40 --color never --cols 100
  [ "$output" = "$REJ_SV_FULL" ]
}

# ---- E92_S05_T03: --each batch mode -----------------------------------------------------------------------------------

# mk_parent: a hand-written --by-parent document (shape of E92_S05_T02) with three epics and four stories, mixed on purpose.
mk_parent() {
  cat > "$BATS_TEST_TMPDIR/parent.json" <<'JSON'
{"schema_version":1,"scope":{"type":"by-parent"},
 "epics":[
  {"id":"E01","level":"stories","totals":{"done":1,"in_progress":1,"failed":0,"pending":1,"rejected":0,"unknown":0,"denominator":3}},
  {"id":"E02","level":"stories","totals":{"done":0,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":0}},
  {"id":"E100","level":"stories","totals":{"done":4,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":4}}],
 "stories":[
  {"id":"E01_S01","level":"tasks","totals":{"done":8,"in_progress":1,"failed":1,"pending":0,"rejected":2,"unknown":0,"denominator":10}},
  {"id":"E01_S02","level":"tasks","totals":{"done":0,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":0}},
  {"id":"E01_S10","level":"tasks","totals":{"done":3,"in_progress":0,"failed":2,"pending":5,"rejected":0,"unknown":0,"denominator":10}},
  {"id":"E02_S01","level":"tasks","totals":{"done":5,"in_progress":0,"failed":0,"pending":0,"rejected":1,"unknown":3,"denominator":5}}],
 "warnings":[]}
JSON
}

# each_matches_single <each-key> [options...]: the batch lines for the --by-parent fixture are, one by one, exactly the id, a
# tab and what single mode prints for that element's totals (same options), in input order. Sets EACH_OUT to the batch output.
each_matches_single() {
  local key="$1" i n id line expect; shift
  local opts=("$@") f="$BATS_TEST_TMPDIR/parent.json"
  run --separate-stderr bash "$R" --each "$key" "${opts[@]}" < "$f"
  [ "$status" -eq 0 ]
  EACH_OUT="$output"
  n="$(jq ".$key | length" "$f")"
  [ "$(printf '%s\n' "$EACH_OUT" | wc -l | tr -d ' ')" -eq "$n" ]
  for i in $(seq 0 $((n - 1))); do
    id="$(jq -r ".$key[$i].id" "$f")"
    set -- $(jq -r ".$key[$i].totals | [.done,.in_progress,.failed,.pending,.rejected,.unknown,.denominator] | map(tostring) | join(\" \")" "$f")
    mk "one$i" "$1" "$2" "$3" "$4" "$5" "$6" "$7"
    run --separate-stderr bash "$R" "${opts[@]}" < "$BATS_TEST_TMPDIR/one$i.json"
    expect="$id"$'\t'"$output"
    line="$(printf '%s\n' "$EACH_OUT" | sed -n "$((i + 1))p")"
    [ "$line" = "$expect" ] || { echo "element $i expected: $expect got: $line"; false; }
  done
}

@test "each: stories of a --by-parent document print id<TAB>line in input order, each equal to single mode" {
  mk_parent
  each_matches_single stories --cols 80
  [ "$(printf '%s\n' "$EACH_OUT" | cut -f1 | tr '\n' ' ')" = "E01_S01 E01_S02 E01_S10 E02_S01 " ]
  [ "$(printf '%s\n' "$EACH_OUT" | sed -n 3p)" = $'E01_S10\t[━━━╌╌╌╌╌╌╌]⚑ 3/10 · 2 red' ]
  case "$(printf '%s\n' "$EACH_OUT" | sed -n 2p)" in $'E01_S02\t[╌╌╌╌╌╌╌╌╌╌] 0/0 · '*) ;; *) false ;; esac
}

@test "each: epics key, a top-level array and the same input via --file" {
  mk_parent
  each_matches_single epics --cols 80
  jq -c '.stories' "$BATS_TEST_TMPDIR/parent.json" > "$BATS_TEST_TMPDIR/arr.json"
  run --separate-stderr bash "$R" --each array --cols 80 --file "$BATS_TEST_TMPDIR/arr.json"
  [ "$status" -eq 0 ]
  local a="$output"
  run --separate-stderr bash "$R" --each stories --cols 80 < "$BATS_TEST_TMPDIR/parent.json"
  [ "$a" = "$output" ]
}

@test "each: width 80 and width 20 behave as single mode, and no line exceeds the width" {
  mk_parent
  local w
  for w in 80 20; do
    each_matches_single stories --cols "$w"
    run --separate-stderr bash "$R" --each stories --cols "$w" < "$BATS_TEST_TMPDIR/parent.json"
    while IFS=$'\t' read -r _id _line; do
      vlen "$_line"
      if [ "$VLEN" -gt "$w" ]; then echo "w=$w id=$_id visible=$VLEN line=$_line"; false; fi
    done <<< "$output"
  done
}

@test "each: NO_COLOR, non-TTY and --color always behave as single mode" {
  mk_parent
  each_matches_single stories --cols 80 --color always
  case "$EACH_OUT" in *"${ESC}[32m"*) ;; *) false ;; esac
  # non-TTY (bats) and NO_COLOR: no escape at all
  run --separate-stderr bash "$R" --each stories --cols 80 < "$BATS_TEST_TMPDIR/parent.json"
  case "$output" in *"$ESC"*) false ;; esac
  NO_COLOR=1 run --separate-stderr bash "$R" --each stories --cols 80 < "$BATS_TEST_TMPDIR/parent.json"
  case "$output" in *"$ESC"*) false ;; esac
}

@test "each: glyph fallback in a non-UTF-8 locale matches single mode" {
  mk_parent
  export LC_ALL=C
  each_matches_single stories --cols 80
  run --separate-stderr bash "$R" --each stories --cols 80 < "$BATS_TEST_TMPDIR/parent.json"
  [ "$(printf '%s\n' "$output" | sed -n 3p)" = $'E01_S10\t[###-------]> 3/10 - 2 red' ]
  [ "$(printf '%s' "$output" | LC_ALL=C tr -d '\011\012\040-\176' | wc -c | tr -d ' ')" -eq 0 ]
}

@test "each: bad input exits 2 with nothing on stdout" {
  mk_parent
  run --separate-stderr bash "$R" --each stories --level tasks < "$BATS_TEST_TMPDIR/parent.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr bash "$R" --each bogus < "$BATS_TEST_TMPDIR/parent.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  printf '[{"id":"A","totals":{"done":1,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":1}},{"id":"B"}]' > "$BATS_TEST_TMPDIR/bad.json"
  run --separate-stderr bash "$R" --each array < "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  printf '{"epics":[]}' > "$BATS_TEST_TMPDIR/noarr.json"
  run --separate-stderr bash "$R" --each stories < "$BATS_TEST_TMPDIR/noarr.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  printf '[]' > "$BATS_TEST_TMPDIR/empty-arr.json"
  run --separate-stderr bash "$R" --each array < "$BATS_TEST_TMPDIR/empty-arr.json"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "each: 625 synthetic entries render in under 10 seconds in one process" {
  jq -n -c '[range(625) | {id: "E\(. / 7 | floor)_S\(. % 7)", totals: {done: (. % 11), in_progress: (. % 3), failed: (. % 2), pending: (. % 5), rejected: (. % 4), unknown: (. % 6), denominator: ((. % 11) + (. % 3) + (. % 2) + (. % 5))}}]' > "$BATS_TEST_TMPDIR/big.json"
  local t0=$SECONDS
  run --separate-stderr bash "$R" --each array --cols 60 --file "$BATS_TEST_TMPDIR/big.json"
  local took=$((SECONDS - t0))
  echo "625 entries: ${took}s" >&3
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 625 ]
  [ "$took" -lt 10 ]
}

@test "each: on a TTY the lines use the terminal's width (stty size), --cols still wins" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is needed to make a pseudo-terminal"
  command -v stty >/dev/null 2>&1 || skip "stty is not installed"
  mk_parent
  export PTY_FIXTURE="$BATS_TEST_TMPDIR/parent.json"
  export JENGA_PROGRESS_LANG=sv
  run --separate-stderr pty_render 100 --each stories --color never
  [ "$status" -ne 77 ] || skip "no pseudo-terminal available"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = $'E01_S01\t'"$REJ_SV_FULL" ]
  local narrow="$output"
  run --separate-stderr pty_render 40 --each stories --color never
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = $'E01_S01\t8/10 · 1 pågår · 1 röd' ]
  [ "$output" != "$narrow" ]
  run --separate-stderr pty_render 40 --each stories --color never --cols 100
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = $'E01_S01\t'"$REJ_SV_FULL" ]
}

@test "each and single: on a TTY the terminal's width is also used under the system bash 3.2 (no COLUMNS refresh there)" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is needed to make a pseudo-terminal"
  [ -x /bin/bash ] || skip "no /bin/bash"
  mk rej 8 1 1 0 2 0 10
  mk_parent
  export PTY_BASH=/bin/bash JENGA_PROGRESS_LANG=sv
  run --separate-stderr pty_render 40 --color never
  [ "$status" -ne 77 ] || skip "no pseudo-terminal available"
  [ "$output" = "8/10 · 1 pågår · 1 röd" ]
  PTY_FIXTURE="$BATS_TEST_TMPDIR/parent.json" run --separate-stderr pty_render 40 --each stories --color never
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = $'E01_S01\t8/10 · 1 pågår · 1 röd' ]
  PTY_FIXTURE="$BATS_TEST_TMPDIR/parent.json" run --separate-stderr pty_render 100 --each stories --color never
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = $'E01_S01\t'"$REJ_SV_FULL" ]
}

# ---------------------------------------------------------------------------------------------------------------------
# E92_S06_T12: the concept symbols. Cells are drawn with the heavy and light horizontal lines, the goal end carries a flag
# while work remains and a star once the whole scope is done.
# ---------------------------------------------------------------------------------------------------------------------

@test "symbols: the bar uses the heavy line for done and the light dashed line for the rest, and nothing of the old blocks" {
  mk mixed 8 1 1 0 0 0 10
  render mixed
  [ "$status" -eq 0 ]
  case "$output" in *"━"*"╌"*) ;; *) false ;; esac
  case "$output" in *"█"*|*"░"*) false ;; esac
}

@test "symbols: the star appears only when the denominator is above 0 and everything counted is done" {
  mk done10 10 0 0 0 0 0 10
  render done10
  case "$output" in *"★"*) ;; *) echo "got: $output"; false ;; esac
  mk done_rej 4 0 0 0 3 0 4
  render done_rej
  case "$output" in *"★"*) ;; *) echo "got: $output"; false ;; esac
  local f
  for f in "9 1 0 0 0 0 10" "9 0 1 0 0 0 10" "9 0 0 1 0 0 10" "9 0 0 0 0 1 10"; do
    # shellcheck disable=SC2086
    mk open $f
    render open
    case "$output" in *"★"*) echo "star on an open scope: $output"; false ;; esac
    case "$output" in *"⚑"*) ;; *) echo "no flag: $output"; false ;; esac
  done
}

@test "symbols: 0/0 prints the nothing label and no star and no flag" {
  mk none 0 0 0 0 0 0 0
  render none
  case "$output" in *"nothing to count"*) ;; *) false ;; esac
  case "$output" in *"★"*|*"⚑"*) false ;; esac
}

@test "symbols: the ASCII fallback prints no non-ASCII byte and still carries every number and the goal stand-in" {
  mk rej 8 1 1 0 2 3 15
  LC_ALL=C run --separate-stderr bash "$R" --cols 1000 --color never < "$BATS_TEST_TMPDIR/rej.json"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | LC_ALL=C tr -d '\000-\177')" ]
  case "$output" in "[########--]> 8/15 - 1 in progress - 1 red - 3 unknown - (x) 2 rejected (not counted)") ;; *) echo "got: $output"; false ;; esac
  mk done10 10 0 0 0 0 0 10
  LC_ALL=C run --separate-stderr bash "$R" --cols 1000 < "$BATS_TEST_TMPDIR/done10.json"
  [ "$output" = "[##########]* 10/10" ]
}

@test "symbols: NO_COLOR gives no ESC byte, --color always keeps colour and a non-TTY is plain, with the new symbols" {
  mk mixed 8 1 1 0 0 0 10
  NO_COLOR=1 render mixed --color auto
  case "$output" in *"$ESC"*) false ;; esac
  NO_COLOR=1 render mixed --color always
  case "$output" in *"$ESC["*) ;; *) false ;; esac
  case "$(strip_ansi "$output")" in "[━━━━━━━━╌╌]⚑ 8/10"*) ;; *) echo "got: $output"; false ;; esac
  render mixed
  case "$output" in *"$ESC"*) false ;; esac
}
