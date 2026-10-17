#!/usr/bin/env bats
#
# End-to-end coverage for j.test over a real project on disk (E72_S05_T02).
#
# What this adds over tests/j-test-skill.bats: that suite pipes the real build-catalog.sh, parse-selection.sh and
# run-suites.sh together, but over a hand-written discovery file (--discovery-file, trivial echo commands), so
# discover-tests.sh is never part of the chain. tests/discover-tests.bats exercises discovery alone. Nothing else
# drives the whole chain
#
#     discover-tests.sh -> build-catalog.sh -> parse-selection.sh -> run-suites.sh
#
# against a project on disk, which is exactly what a consuming project is. That is the only way to prove that what
# discovery detects (ecosystem, id, command) is what the runner then executes, and that the folds, the not-runnable
# listing and the fixtures exclusion hold across the seams.
#
# Cases 1 to 7 build a throwaway consuming project (npm + pytest) under BATS_TEST_TMPDIR; nothing is checked in as a
# fixture tree. The suites inside it are stubs: the npm script and the pytest test only append a line to "$RUN_MARK"
# (so "what ran, in which order" and "nothing ran" are proved by that file, not by trusting output), and `shellcheck`
# is a stub first on PATH. The stub is there for determinism: discovery lists a `shellcheck:all` suite whenever the
# linter is on PATH, so without it the fixture's catalog (and so every suite number) would depend on the host, and the
# suite would run a real linter. With it the fixture's catalog is always npm:test, pytest:tests and shellcheck:all.
# Suite numbers are looked up by id, never hard-coded.
#
# Cases that execute npm or pytest skip, with a message, when the tool is missing; they never fail for that. Everything
# that does not execute them (detection, catalog, render, refused selections, not-runnable, fixtures exclusion) runs
# regardless.
#
# Case 8 scans THIS repository (no --root) and only builds and inspects the catalog. It never calls run-suites.sh, never
# runs npm test and never runs the repository's own suites. It is the heavy case: discovery walks the whole tree, which
# the scripts' headers put at 25-35 seconds on a large or cold tree (measured here: well under a second on a warm one),
# which is why it is a single case. It asserts facts (npm:test with the bats suites folded under `also`, shellcheck:all,
# no fixtures entry), not a suite count, so a future ecosystem here does not break it.
#
# No network, no writes outside BATS_TEST_TMPDIR; the repository is only read (case 8 checks that git status is
# unchanged by the scan).

# shellcheck disable=SC2016,SC2030,SC2031,SC2086
# SC2016: the stub, the package.json script and the jq programs are single-quoted on purpose ($RUN_MARK must reach the
# suite command unexpanded). SC2030/SC2031: bats runs every @test in its own subshell, so reading $status after `run`
# is correct. SC2086: the suite numbers parse-selection.sh prints, one per line, are passed unquoted so each becomes
# its own argument, as skills/j-test/SKILL.md does.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS="$REPO_ROOT/skills/j-test/scripts"
BASH_BIN="$(command -v bash)"
# Captured at load time, before setup() puts the stub shellcheck on PATH; case 8 goes back to it.
ORIG_PATH="$PATH"

setup() {
  PROJ="$BATS_TEST_TMPDIR/consumer"
  RUN_MARK="$BATS_TEST_TMPDIR/mark"
  CATALOG="$BATS_TEST_TMPDIR/catalog.json"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$PROJ" "$STUB_BIN"

  printf '#!/bin/sh\necho shellcheck >> "$RUN_MARK"\nexit 0\n' > "$STUB_BIN/shellcheck"
  chmod +x "$STUB_BIN/shellcheck"
  PATH="$STUB_BIN:$PATH"

  # Keep the real npm and pytest offline and free of side files while they execute the stub suites.
  export npm_config_update_notifier=false npm_config_audit=false npm_config_fund=false NO_UPDATE_NOTIFIER=1
  export PYTHONDONTWRITEBYTECODE=1 PYTEST_ADDOPTS="-p no:cacheprovider"
  export RUN_MARK PATH
}

# --- helpers -------------------------------------------------------------------------------------------------------

need_npm() {
  command -v npm >/dev/null 2>&1 || skip "npm is not on PATH; this case executes the npm suite"
}

need_pytest() {
  command -v pytest >/dev/null 2>&1 || skip "pytest is not on PATH; this case executes the pytest suite"
}

# write_pytest_file <file> <final statement>: a test that records itself in $RUN_MARK, then runs the statement.
write_pytest_file() {
  cat > "$1" <<EOF
import os


def test_records_itself_then_asserts():
    with open(os.environ["RUN_MARK"], "a") as mark:
        mark.write("pytest\n")
    $2
EOF
}

# make_project <dir>: fixture project A. The npm suite appends `npm` to $RUN_MARK, the pytest suite appends `pytest`,
# the stub shellcheck appends `shellcheck`. scripts/ok.sh gives the shellcheck suite exactly one file to feed to xargs,
# so the stub runs once under both BSD and GNU xargs.
make_project() {
  local dir="$1"
  mkdir -p "$dir/tests" "$dir/scripts"
  jq -n --arg cmd 'echo npm >> "$RUN_MARK"' \
    '{name: "consumer-a", version: "1.0.0", private: true, scripts: {test: $cmd}}' > "$dir/package.json"
  write_pytest_file "$dir/tests/test_ok.py" "assert 1 + 1 == 2"
  printf '#!/bin/sh\necho ok\n' > "$dir/scripts/ok.sh"
}

# tree_digest <dir>: every directory and the checksum of every file, for before/after comparison.
tree_digest() {
  (cd "$1" && { find . -type d; find . -type f -exec cksum {} +; } | sort)
}

# discover <root>: step 1, the real discover-tests.sh. Sets $status, $output and $stderr.
discover() {
  run --separate-stderr "$BASH_BIN" "$SCRIPTS/discover-tests.sh" --root "$1"
}

# build_catalog <root>: the real build-catalog.sh (which runs the real discovery). Writes $CATALOG.
build_catalog() {
  run --separate-stderr "$BASH_BIN" "$SCRIPTS/build-catalog.sh" --root "$1"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$CATALOG"
}

# json_check <jq expression> [<json>]: the document (default: $output) must satisfy the expression.
json_check() {
  local doc="${2:-$output}"
  if ! printf '%s' "$doc" | jq -e "$1" >/dev/null; then
    printf 'jq check failed: %s\n--- document ---\n%s\n----------------\n' "$1" "$doc" >&2
    return 1
  fi
}

# catalog_check <jq expression>: the saved catalog must satisfy the expression.
catalog_check() {
  json_check "$1" "$(cat "$CATALOG")"
}

runnable_count() {
  jq '.runnable | length' "$CATALOG"
}

# number_of <suite id>: the catalog number of a runnable suite.
number_of() {
  jq -r --arg id "$1" '.runnable[] | select(.id == $id) | .n' "$CATALOG"
}

# select_and_run <root> <answer>: steps 4 and 5 of the skill. Sets $status/$output/$stderr from run-suites.sh, or from
# parse-selection.sh when the answer is refused (in which case nothing is run).
select_and_run() {
  local root="$1" answer="$2" numbers
  run --separate-stderr "$BASH_BIN" "$SCRIPTS/parse-selection.sh" "$(runnable_count)" "$answer"
  if [ "$status" -ne 0 ]; then
    return 0
  fi
  numbers="$output"
  run --separate-stderr "$BASH_BIN" "$SCRIPTS/run-suites.sh" --catalog "$CATALOG" --root "$root" $numbers
}

# marks: what the stub suites recorded, in run order, joined with commas.
marks() {
  paste -sd, "$RUN_MARK"
}

# --- 1. detection --------------------------------------------------------------------------------------------------

@test "1. discovery over the consuming project reports its npm, pytest and shellcheck suites and executes nothing" {
  make_project "$PROJ"
  local before
  before="$(tree_digest "$PROJ")"

  discover "$PROJ"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ] || { printf 'unexpected stderr: %s\n' "$stderr" >&3; false; }
  json_check '[.suites[].id] == ["npm:test","pytest:tests","shellcheck:all"]'
  json_check '.suites[] | select(.id == "npm:test")
    | .name == "npm test" and .type == "unit" and .ecosystem == "npm" and .command == "npm test" and .paths == []'
  json_check '.suites[] | select(.id == "pytest:tests")
    | .name == "pytest tests" and .type == "unit" and .ecosystem == "pytest" and .command == "pytest tests"
      and .paths == ["tests/**/*_test.py","tests/**/test_*.py"]'
  json_check '.suites[] | select(.id == "shellcheck:all")
    | .ecosystem == "shellcheck" and .type == "sast" and (.command | startswith("find . -type f"))'
  json_check '.warnings | type == "array"'

  # Discovery is manifest and file inspection only: neither the npm script, the pytest file nor the stub linter ran,
  # and it left the project exactly as it found it.
  [ ! -e "$RUN_MARK" ]
  [ "$(tree_digest "$PROJ")" = "$before" ]
}

# --- 2. catalog ----------------------------------------------------------------------------------------------------

@test "2. the catalog numbers the runnable suites 1..N with also as an array, and the rendered list ends in the N prompt" {
  make_project "$PROJ"
  build_catalog "$PROJ"

  catalog_check '[.runnable[].n] == [1,2,3]'
  catalog_check '[.runnable[].id] == ["npm:test","pytest:tests","shellcheck:all"]'
  catalog_check '[.runnable[] | (.also | type)] | all(. == "array")'
  catalog_check '[.runnable[] | (.also | length)] == [0,0,0]'
  catalog_check '.not_runnable == []'
  catalog_check '(.runnable[] | select(.id == "npm:test") | .command) == "npm test"'
  catalog_check '(.runnable[] | select(.id == "pytest:tests") | .command) == "pytest tests"'
  [ "$(runnable_count)" = "3" ]

  run --separate-stderr "$BASH_BIN" "$SCRIPTS/build-catalog.sh" --render "$CATALOG"
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "Choose which tests to run:"
  assert_output_contains "1. npm test (unit)"
  assert_output_contains "2. pytest tests (unit)"
  assert_output_contains "3. shellcheck (sast)"
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "Enter selection (comma-separated, or 'all' for all, or blank for 1 through $(runnable_count)):" ]
}

# --- 3. blank selection --------------------------------------------------------------------------------------------

@test "3. a blank selection runs every runnable suite once, in catalog order, and exits 0 with an N passed summary" {
  need_npm
  need_pytest
  make_project "$PROJ"
  build_catalog "$PROJ"

  select_and_run "$PROJ" ""
  [ "$status" -eq 0 ]
  [ "$(marks)" = "npm,pytest,shellcheck" ]
  assert_output_contains "$(printf 'Test Results\n============\n✓ npm test (unit)\n✓ pytest tests (unit)\n✓ shellcheck (sast)\n\n3 passed, 0 failed. Exit code: 0')"
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "$(runnable_count) passed, 0 failed. Exit code: 0" ]
}

# --- 4. subset selection -------------------------------------------------------------------------------------------

@test "4. choosing only the pytest suite runs only it" {
  need_pytest
  make_project "$PROJ"
  build_catalog "$PROJ"

  select_and_run "$PROJ" "$(number_of pytest:tests)"
  [ "$status" -eq 0 ]
  [ "$(marks)" = "pytest" ]
  assert_output_contains "$(printf '✓ pytest tests (unit)\n\n1 passed, 0 failed. Exit code: 0')"
  assert_output_not_contains "npm test"
  assert_output_not_contains "shellcheck"
}

@test "4b. choosing only the npm suite runs only it" {
  need_npm
  make_project "$PROJ"
  build_catalog "$PROJ"

  select_and_run "$PROJ" "$(number_of npm:test)"
  [ "$status" -eq 0 ]
  [ "$(marks)" = "npm" ]
  assert_output_contains "$(printf '✓ npm test (unit)\n\n1 passed, 0 failed. Exit code: 0')"
  assert_output_not_contains "pytest tests"
  assert_output_not_contains "shellcheck"
}

# --- 5. failure path -----------------------------------------------------------------------------------------------

@test "5. a failing pytest suite does not stop the run: it is marked failed, the next suite still runs, exit is 1" {
  need_pytest
  make_project "$PROJ"
  write_pytest_file "$PROJ/tests/test_ok.py" "assert False"
  build_catalog "$PROJ"

  select_and_run "$PROJ" "$(number_of pytest:tests),$(number_of shellcheck:all)"
  [ "$status" -eq 1 ]
  # The suite after the failing one ran to completion.
  [ "$(marks)" = "pytest,shellcheck" ]
  assert_output_contains "$(printf 'Test Results\n============\n✗ pytest tests (unit)\n✓ shellcheck (sast)\n\n1 passed, 1 failed. Exit code: 1')"
}

# --- 6. not runnable -----------------------------------------------------------------------------------------------

# A test-config.json naming a tool that detection found nothing for yields a config-only suite with no command.
add_semgrep_config() {
  mkdir -p "$PROJ/project/configs"
  printf '{"tools":[{"tool_name":"semgrep","type":"sast"}]}\n' > "$PROJ/project/configs/test-config.json"
}

@test "6. a command-less configured tool is listed as not runnable, cannot be selected and runs nothing" {
  make_project "$PROJ"
  add_semgrep_config
  build_catalog "$PROJ"

  catalog_check '[.runnable[].id] == ["npm:test","pytest:tests","shellcheck:all"]'
  catalog_check '[.not_runnable[].id] == ["config:semgrep:sast"]'
  catalog_check '.not_runnable[0].reason == "no command declared"'
  catalog_check '.warnings | index("configured tool not detected on disk: semgrep (sast)") != null'
  [ "$(runnable_count)" = "3" ]

  run --separate-stderr "$BASH_BIN" "$SCRIPTS/build-catalog.sh" --render "$CATALOG"
  [ "$status" -eq 0 ]
  assert_output_contains "Not runnable (listed only, cannot be selected):"
  assert_output_contains "- semgrep (sast): no command declared"
  assert_output_not_contains "4. "

  # Its would-be number 4 is simply out of range: refused by parse-selection.sh, with the range, before anything runs.
  select_and_run "$PROJ" "4"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "choose 1 through 3"
  select_and_run "$PROJ" "1,2,3,4"
  [ "$status" -eq 1 ]
  [ ! -e "$RUN_MARK" ]

  # Handing run-suites.sh the number directly is refused too, as a validation error, with nothing executed.
  run --separate-stderr "$BASH_BIN" "$SCRIPTS/run-suites.sh" --catalog "$CATALOG" --root "$PROJ" 4
  [ "$status" -eq 2 ]
  [ ! -e "$RUN_MARK" ]
}

@test "6b. a run beside a not-runnable suite counts only the runnable suites" {
  need_npm
  need_pytest
  make_project "$PROJ"
  add_semgrep_config
  build_catalog "$PROJ"

  select_and_run "$PROJ" ""
  [ "$status" -eq 0 ]
  [ "$(marks)" = "npm,pytest,shellcheck" ]
  assert_output_contains "3 passed, 0 failed. Exit code: 0"
  assert_output_not_contains "semgrep"
}

# --- 7. fixtures exclusion -----------------------------------------------------------------------------------------

@test "7. a fixtures subtree inside the project yields no suite, in discovery or in the catalog" {
  make_project "$PROJ"
  mkdir -p "$PROJ/tests/fixtures/nested" "$PROJ/tests/__fixtures__"
  # Each of these would be a suite of its own if the subtree were scanned: a directory of test files, a nested one, a
  # dunder-named one, and a package.json with a test script.
  write_pytest_file "$PROJ/tests/fixtures/test_x.py" "assert True"
  write_pytest_file "$PROJ/tests/fixtures/nested/test_x.py" "assert True"
  write_pytest_file "$PROJ/tests/__fixtures__/test_y.py" "assert True"
  jq -n --arg cmd 'echo fixture-npm >> "$RUN_MARK"' '{name: "inert", scripts: {test: $cmd}}' > "$PROJ/tests/fixtures/package.json"

  discover "$PROJ"
  [ "$status" -eq 0 ]
  json_check '[.suites[].id] == ["npm:test","pytest:tests","shellcheck:all"]'
  json_check '[.. | strings | select(contains("fixtures"))] | length == 0'

  build_catalog "$PROJ"
  catalog_check '[.runnable[].id] == ["npm:test","pytest:tests","shellcheck:all"]'
  catalog_check '[.runnable[], (.runnable[].also[]), .not_runnable[] | .id, .name | select(contains("fixtures"))] | length == 0'
  catalog_check '[.. | strings | select(contains("fixtures"))] | length == 0'
  [ ! -e "$RUN_MARK" ]
}

# --- 8. this repository, discovery only ----------------------------------------------------------------------------

# HEAVY: no --root, so discovery walks this repository's whole tree (25-35 seconds per the scripts' headers on a large
# or cold tree; under a second measured on a warm one). Discovery and catalog only: run-suites.sh is never called here,
# and neither npm test nor any of the repository's own suites is ever run.
@test "8. the catalog of this repository lists npm:test with the bats suites folded under also, and shellcheck:all, with no fixtures entry" {
  # The real PATH, not the stub: this case is about what the real tools make discovery report.
  PATH="$ORIG_PATH"
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck is not on PATH; discovery lists no shellcheck:all suite"

  local before="" after="" tracked=0
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked=1
    before="$(git -C "$REPO_ROOT" status --porcelain)"
  fi

  cd "$REPO_ROOT"
  unset JENGA_PROJECT_ROOT
  run --separate-stderr "$BASH_BIN" "$SCRIPTS/build-catalog.sh"
  [ "$status" -eq 0 ]

  json_check '.runnable | length >= 2'
  json_check '[.runnable[].id] | index("npm:test") != null'
  json_check '[.runnable[].id] | index("shellcheck:all") != null'
  # The bats suites are covered by npm test, so they ride along under `also` and are never entries of their own.
  json_check '[.runnable[] | select(.id == "npm:test") | .also[].id] | index("bats:tests") != null'
  json_check '[.runnable[].id | select(startswith("bats:"))] | length == 0'
  json_check '[.runnable[], (.runnable[].also[]), .not_runnable[] | .id, .name | select(contains("fixtures"))] | length == 0'
  json_check '[.runnable[].n] == [range(1; (.runnable | length) + 1)]'

  # A scan only reads: no tracked or untracked file in the repository changed.
  if [ "$tracked" -eq 1 ]; then
    after="$(git -C "$REPO_ROOT" status --porcelain)"
    [ "$after" = "$before" ]
  fi
}
