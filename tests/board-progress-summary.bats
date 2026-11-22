#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E92_S05_T01: the --summary mode of scripts/board-progress.sh (contract: project/documentation/progress-visualisation.md).
# Fixture only (tests/helpers/progress-fixture.bash); the live project/board/ is never read.
#
# Fixture facts used below: E01_S02 holds five tasks (Passed x3, Rejected, Pending); E01_S01 holds the 15 statuses, one of
# them unknown ("Not Started"); E02 is an empty epic; E01_S03 is an empty story. The default language is en (red is the
# label of the failed bucket), Swedish is selected with JENGA_PROGRESS_LANG=sv.

bats_require_minimum_version 1.5.0

load helpers/assertions
load helpers/progress-fixture

setup() {
  pf_setup
  unset JENGA_PROGRESS_LANG NO_COLOR
}

# expected_line <name> <json-file>: the summary line the JSON totals of that level should produce (en), computed from the
# JSON of the same scope by an independent implementation (python), so a drift between the two outputs shows up here.
expected_line() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[2]))
t = d["levels"][sys.argv[1]]["totals"]
s = "%-8s %d/%d done · %d in progress · %d red · %d pending" % (
    sys.argv[1], t["done"], t["denominator"], t["in_progress"], t["failed"], t["pending"])
if t["unknown"]: s += " · %d unknown" % t["unknown"]
if t["rejected"]: s += " · ⊘ %d rejected (not counted)" % t["rejected"]
print(s)
' "$1" "$2"
}

@test "--all: one line per level (tasks, stories, epics) with the same numbers as the JSON totals" {
  pf_run --all
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/all.json"
  pf_run --all --summary
  [ "$PF_RC" -eq 0 ]
  [ ! -s "$PF_ERR" ]
  [ "$(grep -c '^tasks \|^stories \|^epics ' "$PF_OUT")" -eq 3 ]
  [ "$(sed -n 1p "$PF_OUT")" = "$(expected_line tasks "$BATS_TEST_TMPDIR/all.json")" ]
  [ "$(sed -n 2p "$PF_OUT")" = "$(expected_line stories "$BATS_TEST_TMPDIR/all.json")" ]
  [ "$(sed -n 3p "$PF_OUT")" = "$(expected_line epics "$BATS_TEST_TMPDIR/all.json")" ]
}

@test "a clean scope prints the documented line exactly, the Rejected count only as a note" {
  pf_run --ids E01_S02_T01,E01_S02_T02,E01_S02_T03,E01_S02_T04,E01_S02_T05 --summary
  [ "$PF_RC" -eq 0 ]
  [ "$(cat "$PF_OUT")" = "tasks    3/4 done · 0 in progress · 0 red · 1 pending · ⊘ 1 rejected (not counted)" ]
}

@test "Rejected is not part of done/denominator: 3 Passed + 1 Rejected + 1 Pending is 3/4" {
  pf_run --story E01_S02 --summary
  [ "$PF_RC" -eq 0 ]
  grep -qF -- "3/4 done" "$PF_OUT"
  ! grep -qF -- "3/5" "$PF_OUT"
  ! grep -qF -- "/5 done" "$PF_OUT"
}

@test "the note and the unknown count appear only when greater than 0" {
  pf_run --ids E01_S02_T01 --summary
  [ "$(cat "$PF_OUT")" = "tasks    1/1 done · 0 in progress · 0 red · 0 pending" ]
  pf_run --story E01_S01 --summary
  grep -qF -- " · 1 unknown" "$PF_OUT"
  grep -qF -- " · ⊘ 1 rejected (not counted)" "$PF_OUT"
}

@test "an unknown status adds the unknown count and a warning line after the block" {
  pf_run --story E01_S01 --summary
  [ "$PF_RC" -eq 0 ]
  [ "$(sed -n 1p "$PF_OUT")" = "tasks    8/13 done · 1 in progress · 2 red · 2 pending · 1 unknown · ⊘ 1 rejected (not counted)" ]
  [ "$(sed -n 2p "$PF_OUT")" = 'warning: unknown_status E01_S01_T15: status "Not Started" is not in the status table' ]
  [ "$(wc -l < "$PF_OUT" | tr -d ' ')" -eq 2 ]
}

@test "output is byte-identical across runs and carries no ESC byte" {
  pf_run --all --summary
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/first.txt"
  pf_run --all --summary
  cmp "$PF_OUT" "$BATS_TEST_TMPDIR/first.txt"
  ! grep -q "$(printf '\033')" "$PF_OUT"
  # not even with colour forced on in the environment
  NO_COLOR= CLICOLOR_FORCE=1 FORCE_COLOR=1 pf_run --all --summary
  cmp "$PF_OUT" "$BATS_TEST_TMPDIR/first.txt"
}

@test "an ESC byte in a status never reaches the output" {
  pf_item E07_S01_T01 "$(printf 'Odd\033[31mStatus')"
  pf_run --ids E07_S01_T01 --summary
  [ "$PF_RC" -eq 0 ]
  ! grep -q "$(printf '\033')" "$PF_OUT"
  grep -qF -- "warning: unknown_status E07_S01_T01" "$PF_OUT"
  grep -qF -- " · 1 unknown" "$PF_OUT"
}

@test "JENGA_PROGRESS_LANG=sv switches the labels, an unknown language falls back to en" {
  JENGA_PROGRESS_LANG=sv pf_run --story E01_S01 --summary
  [ "$PF_RC" -eq 0 ]
  [ "$(sed -n 1p "$PF_OUT")" = "tasks    8/13 done · 1 pågår · 2 röd · 2 pending · 1 okända · ⊘ 1 avvisade (ej räknade)" ]
  JENGA_PROGRESS_LANG=fr pf_run --story E01_S01 --summary
  [ "$(sed -n 1p "$PF_OUT")" = "tasks    8/13 done · 1 in progress · 2 red · 2 pending · 1 unknown · ⊘ 1 rejected (not counted)" ]
}

@test "--epic prints the stories and tasks lines only, --story the tasks line only" {
  pf_run --epic E01 --summary
  [ "$PF_RC" -eq 0 ]
  [ "$(grep -c '^tasks ' "$PF_OUT")" -eq 1 ]
  [ "$(grep -c '^stories ' "$PF_OUT")" -eq 1 ]
  ! grep -q '^epics ' "$PF_OUT"
  pf_run --story E01_S02 --summary
  [ "$(grep -c '^tasks ' "$PF_OUT")" -eq 1 ]
  ! grep -q '^stories \|^epics ' "$PF_OUT"
}

@test "--ids with one story id prints only the stories line" {
  pf_run --ids E01_S02 --summary
  [ "$PF_RC" -eq 0 ]
  [ "$(cat "$PF_OUT")" = "stories  0/1 done · 1 in progress · 0 red · 0 pending" ]
}

@test "--backlog --summary counts the queued items and prints todo warnings after the block" {
  pf_todo "Do the first thing: E01_S02_T05" "Ghost: E01_S99_T01" "A line with no id"
  pf_run --backlog --summary
  [ "$PF_RC" -eq 0 ]
  [ "$(sed -n 1p "$PF_OUT")" = "tasks    0/1 done · 0 in progress · 0 red · 1 pending" ]
  [ "$(grep -c '^warning: ' "$PF_OUT")" -eq 2 ]
  grep -qF -- "warning: todo_unknown_id E01_S99_T01" "$PF_OUT"
  grep -qF -- "warning: todo_unresolved_entry" "$PF_OUT"
  [ "$(grep -n '^warning: ' "$PF_OUT" | head -n 1 | cut -d: -f1)" -eq 2 ]
}

@test "--summary leaves the JSON mode unchanged: no --summary, no text block" {
  pf_run --story E01_S02
  [ "$PF_RC" -eq 0 ]
  [ "$(head -c 1 "$PF_OUT")" = "{" ]
  ! grep -q '^warning: ' "$PF_OUT"
}

@test "--items is accepted with --summary and changes nothing" {
  pf_run --story E01_S02 --summary
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/plain.txt"
  pf_run --story E01_S02 --summary --items
  [ "$PF_RC" -eq 0 ]
  cmp "$PF_OUT" "$BATS_TEST_TMPDIR/plain.txt"
}

@test "an empty scope still exits 3 with nothing on stdout" {
  pf_run --epic E02 --summary
  [ "$PF_RC" -eq 3 ]
  [ ! -s "$PF_OUT" ]
  [ -s "$PF_ERR" ]
  pf_run --story E01_S03 --summary
  [ "$PF_RC" -eq 3 ]
  [ ! -s "$PF_OUT" ]
  pf_run --backlog --summary
  [ "$PF_RC" -eq 3 ]
  [ ! -s "$PF_OUT" ]
}

@test "an unknown or malformed id still exits 2 with nothing on stdout" {
  pf_run --epic E10 --summary
  [ "$PF_RC" -eq 2 ]
  [ ! -s "$PF_OUT" ]
  grep -qF -- "board-progress.sh:" "$PF_ERR"
  pf_run --story E01_S77 --summary
  [ "$PF_RC" -eq 2 ]
  [ ! -s "$PF_OUT" ]
  pf_run --ids nonsense --summary
  [ "$PF_RC" -eq 2 ]
  [ ! -s "$PF_OUT" ]
  pf_run --summary
  [ "$PF_RC" -eq 2 ]
  [ ! -s "$PF_OUT" ]
}

@test "--summary writes no file: the fixture tree is unchanged" {
  before="$(pf_tree_sum "$PF_ROOT")"
  pf_run --all --summary
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_tree_sum "$PF_ROOT")" = "$before" ]
}
