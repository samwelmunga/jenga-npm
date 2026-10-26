#!/usr/bin/env bats
#
# E79_S04_T01: the read-only `default <field>` subcommand of scripts/commit-settings.sh. It prints the schema's default
# for a field whether or not the project is opted in, so a caller that must work for a project that has not opted in
# (scripts/commit-ref.sh) reads a schema default through this script instead of holding a copy of it.
#
# This file is separate from tests/commit-settings.bats on purpose: that suite pins the opted-in/show contract and is
# not edited. Everything the cases create lives under $BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/commit-settings.sh"
SCHEMA="$REPO_ROOT/templates/conventions-schema.json"
REAL_CONFIGS="$REPO_ROOT/project/configs"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs"
  printf '{}\n' > "$PROJ/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  cd "$BATS_TEST_TMPDIR" || return 1
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

cs() { run --separate-stderr bash "$SCRIPT" "$@"; }

@test "default prints the schema default of a field, with no conventions file at all" {
  [ ! -e "$PROJ/project/configs/conventions.json" ]
  cs default ref_pattern
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -r '.categories["commit-format"].values.ref_pattern.default' "$SCHEMA")" ]
  [ -z "$stderr" ]
}

@test "default finds a field in the opt-in categories as well as the core ones" {
  cs default trailer_key
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -r '.opt_in_categories["commit-trace"].values.trailer_key.default' "$SCHEMA")" ]
}

@test "default prints a boolean default as plain text" {
  cs default apply_to_board_commits
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "default follows JENGA_CONVENTIONS_SCHEMA" {
  jq '.categories["commit-format"].values.ref_pattern.default = "[a-z]+-[0-9]+"' "$SCHEMA" > "$BATS_TEST_TMPDIR/schema.json"
  JENGA_CONVENTIONS_SCHEMA="$BATS_TEST_TMPDIR/schema.json" cs default ref_pattern
  [ "$status" -eq 0 ]
  [ "$output" = "[a-z]+-[0-9]+" ]
}

@test "default exits 3 with a message naming the field when the schema declares no such field or no default" {
  cs default no_such_field
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  assert_contains "$stderr" "no_such_field"
  cs default template
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  assert_contains "$stderr" "template"
}

@test "default treats the field name as data: shell metacharacters in it run nothing" {
  cs default 'x$(touch '"$BATS_TEST_TMPDIR"'/canary)'
  [ "$status" -eq 3 ]
  [ ! -e "$BATS_TEST_TMPDIR/canary" ]
  cs default 'x`touch '"$BATS_TEST_TMPDIR"'/canary`'
  [ "$status" -eq 3 ]
  [ ! -e "$BATS_TEST_TMPDIR/canary" ]
}

@test "default usage errors exit 2: no field, a second subcommand, and --conventions" {
  cs default
  [ "$status" -eq 2 ]
  cs show default ref_pattern
  [ "$status" -eq 2 ]
  cs default ref_pattern show
  [ "$status" -eq 2 ]
  cs --conventions "$BATS_TEST_TMPDIR/x.json" default ref_pattern
  [ "$status" -eq 2 ]
}

@test "--help lists default, and opted-in and show still behave as before" {
  cs --help
  [ "$status" -eq 0 ]
  assert_output_contains "default <field>"
  assert_output_contains "opted-in"
  assert_output_contains "show"
  cs opted-in
  [ "$status" -eq 1 ]
  cs show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
