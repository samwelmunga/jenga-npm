#!/usr/bin/env bats
#
# E92_S01_T02: ordering, determinism, read-only behaviour, exit codes and the JSON shape of scripts/board-progress.sh.
# Fixture only (tests/helpers/progress-fixture.bash); the live project/board/ is never read.
#
# Not covered here: E99-before-E100 at the `epics` level. A single --epic or --story run lists the stories and tasks
# of one epic, so the two epics are never in one output until --ids/--all exist (later tasks of E92_S01); those tasks
# add that assertion against this same fixture. What is proved here is the numeric order of S2/S10/S100 and
# T2/T10/T100 inside E99 and inside E100, and that E99, E100 and the absent E10 are never confused.

bats_require_minimum_version 1.5.0

load helpers/assertions
load helpers/progress-fixture

setup() { pf_setup; }

@test "stories and tasks are ordered numerically: S2 before S10 before S100, T2 before T10 before T100" {
  local e
  for e in E99 E100; do
    pf_run --epic "$e" --items
    [ "$PF_RC" -eq 0 ]
    [ "$(pf_py "[i['id'] for i in d['levels']['stories']['items']]")" = "[\"${e}_S2\",\"${e}_S10\",\"${e}_S100\"]" ]
    [ "$(pf_py "[i['id'] for i in d['levels']['tasks']['items']]")" = "[\"${e}_S2_T2\",\"${e}_S2_T10\",\"${e}_S2_T100\",\"${e}_S10_T2\",\"${e}_S10_T10\",\"${e}_S10_T100\",\"${e}_S100_T2\",\"${e}_S100_T10\",\"${e}_S100_T100\"]" ]
  done
}

@test "a story scope orders its tasks numerically" {
  pf_run --story E100_S10 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "[i['id'] for i in d['levels']['tasks']['items']]")" = '["E100_S10_T2","E100_S10_T10","E100_S10_T100"]' ]
}

@test "E99, E100 and the absent E10 are never confused" {
  pf_run --epic E99
  [ "$(pf_py "d['levels']['tasks']['totals']['denominator']")" = "9" ]
  pf_run --epic E100
  [ "$(pf_py "d['levels']['tasks']['totals']['denominator']")" = "9" ]
  pf_run --epic E10
  [ "$PF_RC" -eq 2 ]
  [ ! -s "$PF_OUT" ]
  pf_run --story E99_S1
  [ "$PF_RC" -eq 2 ]
  [ ! -s "$PF_OUT" ]
}

@test "a padded id parses like an unpadded one: E01 and E1 give the same counts" {
  pf_run --epic E01 --items
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/padded.json"
  pf_run --epic E1 --items
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "d['levels']")" = "$(python3 -I -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["levels"], separators=(",",":")))' "$BATS_TEST_TMPDIR/padded.json")" ]
}

@test "two runs on the same fixture are byte-identical" {
  pf_run --epic E01 --items
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/first.json"
  pf_run --epic E01 --items
  [ "$PF_RC" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/first.json" "$PF_OUT"
}

@test "the same board at another path, with other file times, gives byte-identical output" {
  local other="$BATS_TEST_TMPDIR/elsewhere/second-copy"
  pf_run --epic E06 --items
  cp "$PF_OUT" "$BATS_TEST_TMPDIR/first.json"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  cp -R "$PF_ROOT" "$other"
  find "$other" -type f -name '*.md' -exec touch -t 200001010000 {} +
  PF_RC=0
  bash "$PF_SCRIPT" --root "$other" --epic E06 --items > "$PF_OUT" 2> "$PF_ERR" || PF_RC=$?
  [ "$PF_RC" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/first.json" "$PF_OUT"
}

@test "the script writes nothing: the fixture tree has the same checksum after a run" {
  local before after s
  before="$(pf_tree_sum "$PF_ROOT")"
  for s in "--epic E01 --items" "--story E01_S01" "--epic E99 --items" "--epic E02" "--epic E10"; do
    # shellcheck disable=SC2086
    pf_run $s
  done
  after="$(pf_tree_sum "$PF_ROOT")"
  [ "$before" = "$after" ]
}

@test "the run reads the fixture, not the repository board" {
  # E92 exists on the repository's own board but not in the fixture
  pf_run --epic E92
  [ "$PF_RC" -eq 2 ]
  [ ! -s "$PF_OUT" ]
  grep -q 'unknown epic id' "$PF_ERR"
}

@test "JSON shape: schema_version 1, scope, levels, warnings; items only with --items" {
  pf_run --epic E01
  [ "$PF_RC" -eq 0 ]
  [ ! -s "$PF_ERR" ]
  [ "$(pf_py "list(d)")" = '["schema_version","scope","levels","warnings"]' ]
  [ "$(pf_py "d['schema_version']")" = "1" ]
  [ "$(pf_py "d['scope']")" = '{"type":"epic","ids":["E01"]}' ]
  [ "$(pf_py "list(d['levels'])")" = '["tasks","stories"]' ]
  [ "$(pf_py "list(d['levels']['tasks'])")" = '["counts","totals"]' ]
  [ "$(pf_py "list(d['levels']['tasks']['totals'])")" = '["done","in_progress","failed","pending","rejected","unknown","denominator"]' ]
  pf_run --epic E01 --items
  [ "$(pf_py "list(d['levels']['tasks'])")" = '["counts","totals","items"]' ]
  pf_run --story E01_S02
  [ "$(pf_py "d['scope']")" = '{"type":"story","ids":["E01_S02"]}' ]
  [ "$(pf_py "list(d['levels'])")" = '["tasks"]' ]
}

@test "orphans are counted where their ids place them and warned about" {
  pf_run --epic E03
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "d['levels']['tasks']['totals']['pending']")" = "1" ]
  [ "$(pf_py "d['warnings']")" = '[{"kind":"orphan_task","id":"E03_S01_T01","detail":"story E03_S01 has no board file"}]' ]
  pf_run --story E04_S01
  [ "$PF_RC" -eq 0 ]
  [ "$(pf_py "d['warnings']")" = '[{"kind":"orphan_task","id":"E04_S01_T01","detail":"epic E04 has no board file"}]' ]
}

@test "empty scopes exit 3 with a message on stderr and nothing on stdout" {
  pf_run --epic E02
  [ "$PF_RC" -eq 3 ]
  [ ! -s "$PF_OUT" ]
  [ -s "$PF_ERR" ]
  pf_run --story E01_S03
  [ "$PF_RC" -eq 3 ]
  [ ! -s "$PF_OUT" ]
  [ -s "$PF_ERR" ]
}

@test "unknown and malformed ids exit 2 with a message on stderr and nothing on stdout" {
  local a
  for a in "--epic E77" "--story E01_S77" "--epic X" "--epic e01" "--epic E01_S01" "--story E01" "--story E01_S01_T01" "--epic" "--epic E01 --story E01_S01" "--bogus" ""; do
    # shellcheck disable=SC2086
    pf_run $a
    [ "$PF_RC" -eq 2 ] || { echo "args [$a]: rc $PF_RC"; return 1; }
    [ ! -s "$PF_OUT" ] || { echo "args [$a]: stdout not empty"; return 1; }
    [ -s "$PF_ERR" ] || { echo "args [$a]: stderr empty"; return 1; }
  done
}

@test "an unresolvable root exits 2" {
  PF_RC=0
  bash "$PF_SCRIPT" --root "$BATS_TEST_TMPDIR/no-such-dir" --epic E01 > "$PF_OUT" 2> "$PF_ERR" || PF_RC=$?
  [ "$PF_RC" -eq 2 ]
  [ ! -s "$PF_OUT" ]
  [ -s "$PF_ERR" ]
}
