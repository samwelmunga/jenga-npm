#!/usr/bin/env bats
#
# Coverage for scripts/workflow/verify-output.sh (E80_S03_T02): the thin wrapper that checks a step output
# against its templates/playbook-types.json type by calling scripts/validate-typed-object.sh.
#
# Real types from the shipped registry are used (id_list: per_line rule plus split_on_comma/trim/drop_empty
# normalisation; text: verify null). The unknown-type and environment cases use a fixture package root reached
# through JENGA_PLAYBOOKS_TEST_ROOT, the same override load-playbooks.sh and run-playbook-step.sh honour.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VERIFY="$REPO_ROOT/scripts/workflow/verify-output.sh"

setup() {
  unset JENGA_PLAYBOOKS_TEST_ROOT JENGA_PLAYBOOK_TYPES_FILE
  # Point mktemp at a directory we can inspect afterwards, to prove the temp file is removed.
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
}

# Fixture package root holding the REAL registry and validator (so the behaviour under test is the shipped one).
make_fixture() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-root"
  mkdir -p "$FIXTURE_ROOT/templates" "$FIXTURE_ROOT/scripts"
  cp "$REPO_ROOT/templates/playbook-types.json" "$FIXTURE_ROOT/templates/playbook-types.json"
  cp "$REPO_ROOT/scripts/validate-typed-object.sh" "$FIXTURE_ROOT/scripts/validate-typed-object.sh"
  chmod +x "$FIXTURE_ROOT/scripts/validate-typed-object.sh"
  export JENGA_PLAYBOOKS_TEST_ROOT="$FIXTURE_ROOT"
}

@test "the script exists, is executable, passes bash -n and documents its exit codes in the header" {
  [ -x "$VERIFY" ]
  run bash -n "$VERIFY"
  [ "$status" -eq 0 ]
  run sed -n '1,60p' "$VERIFY"
  assert_output_contains 'EXIT CODES'
  assert_output_contains '1  the value is non-conforming'
  assert_output_contains '2  the check could not be performed'
}

@test "--help prints the usage and exits 0" {
  run bash "$VERIFY" --help
  [ "$status" -eq 0 ]
  assert_output_contains 'verify-output.sh <type> <value>'
}

@test "exit 0: a conforming value is printed unchanged" {
  run bash "$VERIFY" id_list "$(printf 'E80_S03_T02\nE80_S03_T03')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'E80_S03_T02\nE80_S03_T03')" ]
}

@test "exit 0: a type with no verify rule accepts any value" {
  run bash "$VERIFY" text "anything at all, with | punctuation"
  [ "$status" -eq 0 ]
  [ "$output" = "anything at all, with | punctuation" ]
}

@test "exit 0: a value that conforms only after normalisation prints the normalised value" {
  run --separate-stderr bash "$VERIFY" id_list "E80_S03_T02, E80_S03_T03 ,, E80"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'E80_S03_T02\nE80_S03_T03\nE80')" ]
  [ -z "$stderr" ]
}

@test "exit 1: a violating value prints the failing rule on stderr and nothing on stdout" {
  run --separate-stderr bash "$VERIFY" id_list "E80_S03_T02, not-an-id"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"per_line"* ]]
  [[ "$stderr" == *"not-an-id"* ]]
}

@test "exit 1: a ranked_list value that breaks its per_line rule is rejected" {
  run --separate-stderr bash "$VERIFY" ranked_list "first, no number"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"does not conform"* ]]
}

@test "exit 2: an unknown type is an environment-style failure naming the type, never a pass" {
  run --separate-stderr bash "$VERIFY" no_such_type "E1"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unknown type 'no_such_type'"* ]]
}

@test "exit 2: a missing validator names the cause" {
  export JENGA_PLAYBOOKS_TEST_ROOT="$BATS_TEST_TMPDIR/empty-root"
  mkdir -p "$JENGA_PLAYBOOKS_TEST_ROOT"
  run --separate-stderr bash "$VERIFY" id_list "E1"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"validator not found"* ]]
  [[ "$stderr" == *"validate-typed-object.sh"* ]]
}

@test "exit 2: an unreadable registry (validator exit 5) is reported as an environment failure, not non-conforming" {
  make_fixture
  export JENGA_PLAYBOOK_TYPES_FILE="$BATS_TEST_TMPDIR/does-not-exist.json"
  run --separate-stderr bash "$VERIFY" id_list "E1"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"could not be checked"* ]]
}

@test "exit 2: a registry contract violation (validator exit 6) is reported as an environment failure" {
  make_fixture
  # A descriptor using a rule kind the closed vocabulary does not admit.
  jq '.types.id_list.verify = {"bogus_rule": "x"}' "$FIXTURE_ROOT/templates/playbook-types.json" > "$FIXTURE_ROOT/templates/bad.json"
  mv "$FIXTURE_ROOT/templates/bad.json" "$FIXTURE_ROOT/templates/playbook-types.json"
  run --separate-stderr bash "$VERIFY" id_list "E1"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"could not be checked"* ]]
}

@test "exit 2: wrong argument count is a usage error" {
  run --separate-stderr bash "$VERIFY" id_list
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage"* ]]
}

@test "the fixture override is honoured: a fixture registry's own type is verified" {
  make_fixture
  jq '.types.shouty = {"verify": {"per_line": "^[A-Z]+$"}, "normalize": []}' "$FIXTURE_ROOT/templates/playbook-types.json" > "$FIXTURE_ROOT/templates/new.json"
  mv "$FIXTURE_ROOT/templates/new.json" "$FIXTURE_ROOT/templates/playbook-types.json"
  run bash "$VERIFY" shouty "LOUD"
  [ "$status" -eq 0 ]
  run bash "$VERIFY" shouty "quiet"
  [ "$status" -eq 1 ]
}

@test "the temp file is removed on every branch (conforming, normalised, violating, unknown type)" {
  run bash "$VERIFY" id_list "E1"
  [ "$status" -eq 0 ]
  run bash "$VERIFY" id_list "E1, E2"
  [ "$status" -eq 0 ]
  run bash "$VERIFY" id_list "bad value"
  [ "$status" -eq 1 ]
  run bash "$VERIFY" no_such_type "E1"
  [ "$status" -eq 2 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "a value containing shell metacharacters and a leading dash is passed through safely" {
  run bash "$VERIFY" text '-n $(echo pwned) `id` ; rm -rf /'
  [ "$status" -eq 0 ]
  [ "$output" = '-n $(echo pwned) `id` ; rm -rf /' ]
}
