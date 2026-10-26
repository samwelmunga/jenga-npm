#!/usr/bin/env bats
#
# E80_S06_T01: the two example-report `compute` scripts (scripts/workflow/examples/) and their fixture.
# Read only against this repository: every test that needs a scratch file builds it under $BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SELECT="$REPO_ROOT/scripts/workflow/examples/example-report-select.sh"
SUMMARIZE="$REPO_ROOT/scripts/workflow/examples/example-report-summarize.sh"
FIXTURE="$REPO_ROOT/tests/fixtures/workflow/example-report/items.json"
REGISTRY="$REPO_ROOT/templates/playbook-types.json"
EXPECTED="E90_S01_T01,E90_S02_T01,E90_S03_T01"

@test "both scripts exist, are executable, pass bash -n and document usage and exit codes" {
  for s in "$SELECT" "$SUMMARIZE"; do
    [ -x "$s" ]
    run bash -n "$s"
    [ "$status" -eq 0 ]
    run grep -c -E '^# (USAGE|EXIT CODES)' "$s"
    [ "$output" -eq 2 ]
  done
}

@test "fixture has 5 items, 3 of them high priority" {
  [ "$(jq 'length' "$FIXTURE")" -eq 5 ]
  [ "$(jq '[.[] | select(.priority == "high")] | length' "$FIXTURE")" -eq 3 ]
}

@test "select prints exactly the 3 high-priority ids in fixture order" {
  run --separate-stderr "$SELECT" "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "$EXPECTED" ]
}

@test "select output passes the id_list verification of the type registry" {
  pattern="$(jq -r '.types.id_list.verify.per_line' "$REGISTRY")"
  [ -n "$pattern" ]
  out="$("$SELECT" "$FIXTURE")"
  n=0
  while IFS= read -r el; do
    [ -n "$el" ]
    printf '%s\n' "$el" | grep -E -q "$pattern"
    n=$((n + 1))
  done < <(printf '%s\n' "$out" | tr ',' '\n')
  [ "$n" -eq 3 ]
}

@test "summarize prints one line with the count and the ids" {
  run --separate-stderr "$SUMMARIZE" "$EXPECTED"
  [ "$status" -eq 0 ]
  [ "$output" = "3 high-priority items: E90_S01_T01, E90_S02_T01, E90_S03_T01" ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "summarize chained after select reads the select output" {
  run --separate-stderr "$SUMMARIZE" "$("$SELECT" "$FIXTURE")"
  [ "$status" -eq 0 ]
  [ "$output" = "3 high-priority items: E90_S01_T01, E90_S02_T01, E90_S03_T01" ]
}

@test "summarize exits 2 on an empty list with a stderr message and empty stdout" {
  for arg in "" " " ",,"; do
    run --separate-stderr "$SUMMARIZE" "$arg"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [ -n "$stderr" ]
  done
}

@test "summarize exits 2 with no argument" {
  run --separate-stderr "$SUMMARIZE"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "select exits 2 on a missing file, naming it, with empty stdout" {
  run --separate-stderr "$SELECT" "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"$BATS_TEST_TMPDIR/nope.json"* ]]
}

@test "select exits 2 on malformed JSON, naming the file, with empty stdout" {
  printf '{not json' > "$BATS_TEST_TMPDIR/bad.json"
  run --separate-stderr "$SELECT" "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"$BATS_TEST_TMPDIR/bad.json"* ]]
}

@test "select exits 2 on valid JSON of the wrong shape, naming the file" {
  printf '{"id":"E1"}' > "$BATS_TEST_TMPDIR/obj.json"
  run --separate-stderr "$SELECT" "$BATS_TEST_TMPDIR/obj.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"$BATS_TEST_TMPDIR/obj.json"* ]]
}

@test "select on an empty array exits 0 with empty stdout" {
  printf '[]' > "$BATS_TEST_TMPDIR/empty.json"
  run --separate-stderr "$SELECT" "$BATS_TEST_TMPDIR/empty.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "running either script twice yields byte-identical stdout" {
  a="$("$SELECT" "$FIXTURE")"; b="$("$SELECT" "$FIXTURE")"
  [ "$a" = "$b" ]
  c="$("$SUMMARIZE" "$EXPECTED")"; d="$("$SUMMARIZE" "$EXPECTED")"
  [ "$c" = "$d" ]
}

@test "neither script writes a file: no scratch files appear next to the fixture or in the working directory" {
  cd "$BATS_TEST_TMPDIR"
  before="$(find "$BATS_TEST_TMPDIR" "$(dirname "$FIXTURE")" | sort)"
  "$SELECT" "$FIXTURE" >/dev/null
  "$SUMMARIZE" "$EXPECTED" >/dev/null
  after="$(find "$BATS_TEST_TMPDIR" "$(dirname "$FIXTURE")" | sort)"
  [ "$before" = "$after" ]
}

@test "neither script contains a project/ path literal or a file-writing redirect" {
  run grep -n 'project/' "$SELECT" "$SUMMARIZE"
  [ "$status" -eq 1 ]
  # Executable lines only, minus the usage strings and the sanctioned >&2 / 2>/dev/null redirects.
  run bash -c 'grep -h -v "^#" "$@" | grep -v "usage:" | sed -e "s/>&2//g" -e "s#2>/dev/null##g" | grep -c ">"' _ "$SELECT" "$SUMMARIZE"
  [ "$output" = "0" ]
}
