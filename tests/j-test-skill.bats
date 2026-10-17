#!/usr/bin/env bats
#
# Coverage for the j.test skill as a whole (E72_S02_T05): its registration and the seams between its three scripts.
#
# The four scripts have their own suites (j-test-build-catalog, j-test-parse-selection, j-test-run-suites,
# discover-tests). Each of those tests one script against a fixture written from that script's own header, so none of
# them can notice the scripts drifting apart. The pipeline cases here do: they pipe the real build-catalog.sh output
# into the real parse-selection.sh and run-suites.sh, the same chain skills/j-test/SKILL.md describes.
#
# Static cases: SKILL.md frontmatter, the j-test / j.test / "test" naming trio, the three skill-table rows, the
# allow-list entry, and byte-identity of the .claude/ and .agents/ mirrors against the root.
#
# Pipeline cases run over fixtures only (tests/fixtures/j-test/skill/discovery.json, trivial echo commands), with
# build-catalog.sh's --discovery-file. Nothing here calls discover-tests.sh against the live repo, runs npm test, or
# runs any real project suite. Everything scratch lives under BATS_TEST_TMPDIR; the fixture is only read.

# shellcheck disable=SC2016,SC2086
# SC2016: patterns holding a literal backtick or $ are single-quoted on purpose. SC2086: the suite numbers that
# parse-selection.sh prints, one per line, are passed unquoted so each becomes its own argument, as SKILL.md does.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL_DIR="$REPO_ROOT/skills/j-test"
SKILL_MD="$SKILL_DIR/SKILL.md"
SCRIPTS="$SKILL_DIR/scripts"
FIXTURE="$REPO_ROOT/tests/fixtures/j-test/skill/discovery.json"
ALLOW_LIST="$REPO_ROOT/lib/skill-allow-list.json"
BASH_BIN="$(command -v bash)"

setup() {
  PIPE_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$PIPE_ROOT"
  RUN_MARK="$BATS_TEST_TMPDIR/mark"
  export RUN_MARK
  CATALOG="$BATS_TEST_TMPDIR/catalog.json"
}

# --- helpers -------------------------------------------------------------------------------------------------------

# frontmatter: the YAML block of SKILL.md, without the --- fences.
frontmatter() {
  awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$SKILL_MD"
}

# build_catalog: step 1 of the skill, over the fixture. Writes $CATALOG, leaves discover-tests.sh alone.
build_catalog() {
  run --separate-stderr "$BASH_BIN" "$SCRIPTS/build-catalog.sh" --root "$PIPE_ROOT" --discovery-file "$FIXTURE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$CATALOG"
}

# runnable_count: the N the skill hands to parse-selection.sh.
runnable_count() {
  jq '.runnable | length' "$CATALOG"
}

# pipeline <answer>: steps 4 and 5 of the skill. Sets $status/$output/$stderr from run-suites.sh, or from
# parse-selection.sh when the answer is refused (in which case nothing is run).
pipeline() {
  local answer="$1" n numbers
  n="$(runnable_count)"
  run --separate-stderr "$BASH_BIN" "$SCRIPTS/parse-selection.sh" "$n" "$answer"
  if [ "$status" -ne 0 ]; then
    return 0
  fi
  numbers="$output"
  run --separate-stderr "$BASH_BIN" "$SCRIPTS/run-suites.sh" --catalog "$CATALOG" --root "$PIPE_ROOT" $numbers
}

# marks: what the fixture commands recorded, in run order, joined with commas.
marks() {
  paste -sd, "$RUN_MARK"
}

# --- SKILL.md ------------------------------------------------------------------------------------------------------

@test "SKILL.md frontmatter carries name j.test, a description, keywords and examples, and no prefered_agent" {
  [ -f "$SKILL_MD" ]
  local fm
  fm="$(frontmatter)"
  [ -n "$fm" ]
  assert_contains "$fm" "name: j.test"
  assert_contains "$fm" "description: "
  assert_contains "$fm" "keywords:"
  assert_contains "$fm" "examples:"
  assert_not_contains "$fm" "prefered_agent"
  # The frontmatter only: the body may name the wrong form in prose ("never j.j-test").
  assert_not_contains "$fm" "j.j-test"
}

@test "the directory j-test, the frontmatter name j.test and the allow-listed identifier test agree" {
  [ -d "$REPO_ROOT/skills/j-test" ]
  local name
  name="$(frontmatter | sed -n 's/^name: //p')"
  [ "$name" = "j.test" ]
  # j-<x> directory <-> j.<x> name <-> <x> allow-list entry.
  [ "$(basename "$SKILL_DIR")" = "j-${name#j.}" ]
  run jq -e --arg id "${name#j.}" '.skills | index($id) != null' "$ALLOW_LIST"
  [ "$status" -eq 0 ]
}

@test "SKILL.md calls the three scripts, defaults blank to all suites and states its boundaries" {
  local body script
  body="$(cat "$SKILL_MD")"
  for script in build-catalog.sh parse-selection.sh run-suites.sh; do
    assert_contains "$body" "$script"
  done
  assert_contains "$body" "blank"
  assert_contains "$body" "all suites"
  assert_contains "$body" "never writes board status"
  assert_contains "$body" "tester agent"
  assert_contains "$body" "developer agent never invokes it"
}

@test "SKILL.md keeps the logic in the scripts: it never parses the answer or calls discovery itself" {
  run grep -n 'discover-tests' "$SKILL_MD"
  [ "$status" -eq 1 ]
  run grep -E '^(case|if \[|for [a-z]+ in)' "$SKILL_MD"
  [ "$status" -eq 1 ]
}

# --- registration --------------------------------------------------------------------------------------------------

@test "CLAUDE.md, README.md and AGENTS.md each carry exactly one j.test row, in the file's own form" {
  run grep -c '^| `j\.test` |' "$REPO_ROOT/CLAUDE.md"
  [ "$output" = "1" ]
  run grep -c '^| `j\.test` |' "$REPO_ROOT/README.md"
  [ "$output" = "1" ]
  run grep -c '^| `/j-test` |' "$REPO_ROOT/AGENTS.md"
  [ "$output" = "1" ]
}

@test "the table rows agree with the SKILL.md description" {
  local desc lead
  desc="$(frontmatter | sed -n 's/^description: //p')"
  lead="Discover the project's test suites"
  assert_starts_with "$desc" "$lead"
  assert_contains "$(grep '^| `j\.test` |' "$REPO_ROOT/CLAUDE.md")" "$lead"
  assert_contains "$(grep '^| `/j-test` |' "$REPO_ROOT/AGENTS.md")" "$lead"
  assert_contains "$(grep '^| `j\.test` |' "$REPO_ROOT/README.md")" "pass/fail summary"
}

@test "the allow-list lists test and its skill_count equals the length of the skills array" {
  run jq -e '.skills | index("test") != null' "$ALLOW_LIST"
  [ "$status" -eq 0 ]
  run jq -e '.skill_count == (.skills | length)' "$ALLOW_LIST"
  [ "$status" -eq 0 ]
}

@test "the .claude/ and .agents/ mirrors of skills/j-test/ are byte-identical to the root, scripts stay executable" {
  local mirror file
  for mirror in .claude .agents; do
    if [ ! -d "$REPO_ROOT/$mirror/skills" ]; then
      # A packed or installed checkout does not ship the generated mirrors.
      continue
    fi
    for file in $(cd "$SKILL_DIR" && find . -type f | sed 's|^\./||'); do
      [ -f "$REPO_ROOT/$mirror/skills/j-test/$file" ]
      cmp "$SKILL_DIR/$file" "$REPO_ROOT/$mirror/skills/j-test/$file"
    done
    for file in build-catalog.sh parse-selection.sh run-suites.sh discover-tests.sh; do
      [ -x "$REPO_ROOT/$mirror/skills/j-test/scripts/$file" ]
    done
    cmp "$ALLOW_LIST" "$REPO_ROOT/$mirror/lib/skill-allow-list.json"
  done
}

# --- the script chain, over fixtures only --------------------------------------------------------------------------

@test "step 1: the catalog over the fixture folds the duplicate, numbers 3 suites and lists one not runnable" {
  build_catalog
  [ "$(runnable_count)" = "3" ]
  [ "$(jq -c '[.runnable[] | .id]' "$CATALOG")" = '["fx:alpha","fx:bravo","fx:charlie"]' ]
  [ "$(jq -c '.runnable[0].also | map(.id)' "$CATALOG")" = '["fx:alpha-again"]' ]
  [ "$(jq -c '.not_runnable | map(.id)' "$CATALOG")" = '["config:delta:perf"]' ]
}

@test "step 3: the rendered list ends in a prompt whose N is the catalog's runnable count" {
  build_catalog
  run --separate-stderr "$BASH_BIN" "$SCRIPTS/build-catalog.sh" --render "$CATALOG"
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "Choose which tests to run:"
  assert_output_contains "1. alpha (unit) [also covers: alpha again (unit)]"
  assert_output_contains "delta (perf)"
  assert_contains "$(printf '%s\n' "$output" | tail -n 1)" "blank for 1 through $(runnable_count))"
}

@test "blank input runs every suite in catalog order, continues past the failure and exits 1" {
  build_catalog
  pipeline ""
  [ "$status" -eq 1 ]
  [ "$(marks)" = "alpha,bravo,charlie" ]
  assert_output_contains "$(printf 'Test Results\n============\n✓ alpha (unit)\n✗ bravo (integration)\n✓ charlie (sast)\n\n2 passed, 1 failed. Exit code: 1')"
}

@test "all, in any case, runs the same suites as blank input" {
  build_catalog
  pipeline "ALL"
  [ "$status" -eq 1 ]
  [ "$(marks)" = "alpha,bravo,charlie" ]
  assert_output_contains "2 passed, 1 failed. Exit code: 1"
}

@test "2,1 runs bravo then alpha, in the order given, and exits 1" {
  build_catalog
  pipeline "2,1"
  [ "$status" -eq 1 ]
  [ "$(marks)" = "bravo,alpha" ]
  assert_output_contains "$(printf '✗ bravo (integration)\n✓ alpha (unit)\n\n1 passed, 1 failed. Exit code: 1')"
}

@test "a selection that avoids the failing suite exits 0 and runs only the chosen suites, in order" {
  build_catalog
  pipeline "3,1"
  [ "$status" -eq 0 ]
  [ "$(marks)" = "charlie,alpha" ]
  assert_output_contains "2 passed, 0 failed. Exit code: 0"
}

@test "an invalid answer is refused with the valid range and nothing runs" {
  build_catalog
  pipeline "4"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "choose 1 through 3"
  [ ! -e "$RUN_MARK" ]
  # The not-runnable suite is never selectable: its would-be number is simply out of range.
  pipeline "1,2,3,4"
  [ "$status" -eq 1 ]
  [ ! -e "$RUN_MARK" ]
}

@test "the pipeline reuses one catalog file: run-suites.sh accepts exactly what build-catalog.sh printed" {
  build_catalog
  run --separate-stderr "$BASH_BIN" "$SCRIPTS/run-suites.sh" --catalog "$CATALOG" --root "$PIPE_ROOT" 1
  [ "$status" -eq 0 ]
  [ "$(marks)" = "alpha" ]
  # A number the catalog never numbered (the folded duplicate, the not-runnable entry) is refused before anything runs.
  rm -f "$RUN_MARK"
  run --separate-stderr "$BASH_BIN" "$SCRIPTS/run-suites.sh" --catalog "$CATALOG" --root "$PIPE_ROOT" 4
  [ "$status" -eq 2 ]
  [ ! -e "$RUN_MARK" ]
}
