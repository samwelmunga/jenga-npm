#!/usr/bin/env bats
#
# E80_S01_T06: `scripts/workflow/load-workflows.sh lookup <id>`.
# Covers: a builtin id and a project id each print exactly that one definition as valid JSON with the right `source`
# and `file` (exit 0); an unknown id, and an id that exists only in a dropped (invalid) file, each exit 2 with an empty
# stdout and a stderr message that names the id and lists the available ids; `lookup` with no argument, an empty
# argument or extra arguments is a usage error; on a builtin/project collision the builtin definition is returned; and
# bare output is the same catalog as before (the full bare behaviour is covered by workflow-load-catalog.bats).
#
# Every tree is synthetic, under $BATS_TEST_TMPDIR, selected with JENGA_WORKFLOWS_TEST_ROOT. Nothing reads this
# repository's board or any private path.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LOADER="$REPO_ROOT/scripts/workflow/load-workflows.sh"

setup() {
  unset JENGA_PROJECT_ROOT
  ROOT="$BATS_TEST_TMPDIR/box"
  mkdir -p "$ROOT/templates/workflows"
  cp "$REPO_ROOT/templates/workflow-schema.json" "$REPO_ROOT/templates/playbook-types.json" "$ROOT/templates/"
  export JENGA_WORKFLOWS_TEST_ROOT="$ROOT"
  BUILTIN="$ROOT/templates/workflows"
  PROJECT="$ROOT/project/.workflows"
}

# wf <id> [name]: prints a minimal valid definition with that id.
wf() {
  jq -n --arg id "$1" --arg name "${2:-Flow $1}" '{id: $id, name: $name, description: "Fixture.",
    steps: [ { id: "only", type: "skill", skill: "j.status" } ]}'
}

# put <dir> <file name> <id> [name]: writes a valid definition into <dir>.
put() {
  mkdir -p "$1"
  wf "$3" "${4:-}" > "$1/$2"
}

# run_lookup <args...>: runs the loader keeping stdout and stderr apart ($output is stdout, $stderr is stderr).
run_lookup() {
  run --separate-stderr bash "$LOADER" "$@"
}

@test "a builtin id prints exactly that one definition with source builtin and its file" {
  put "$BUILTIN" alpha.json alpha
  put "$PROJECT" beta.json beta
  run_lookup lookup alpha
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'type == "object" and .id == "alpha" and .source == "builtin"
    and .file == "'"$BUILTIN"'/alpha.json" and .name == "Flow alpha" and (.steps | length) == 1'
  [ -z "$stderr" ]
}

@test "a project id prints exactly that one definition with source project" {
  put "$BUILTIN" alpha.json alpha
  put "$PROJECT" beta.json beta
  run_lookup lookup beta
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'type == "object" and .id == "beta" and .source == "project"
    and .file == "'"$PROJECT"'/beta.json"'
  [ -z "$stderr" ]
}

@test "an id that never existed exits 2, stdout empty, stderr names the id and the available ids" {
  put "$BUILTIN" alpha.json alpha
  put "$PROJECT" beta.json beta
  run_lookup lookup nosuch
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "nosuch"
  assert_contains "$stderr" "alpha"
  assert_contains "$stderr" "beta"
}

@test "an unknown id with an empty catalog still exits 2 with empty stdout and names the id" {
  run_lookup lookup nosuch
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "nosuch"
}

@test "an id that exists only in a dropped (invalid) file exits 2, stdout empty, stderr names the id" {
  put "$BUILTIN" alpha.json alpha
  mkdir -p "$PROJECT"
  jq -n '{id: "broken", name: "Broken", description: "Fixture.",
    steps: [ { id: "only", type: "no-such-type" } ]}' > "$PROJECT/broken.json"
  run_lookup lookup broken
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "broken"
  # the available list does not offer the dropped id as a valid choice
  assert_contains "$stderr" "available ids: alpha"
}

@test "lookup with no argument exits non-zero with a usage message and empty stdout" {
  put "$BUILTIN" alpha.json alpha
  run_lookup lookup
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  assert_contains "$stderr" "Usage: load-workflows.sh"
  assert_contains "$stderr" "lookup <id>"
}

@test "lookup with an empty id, or with extra arguments, is a usage error" {
  put "$BUILTIN" alpha.json alpha
  run_lookup lookup ""
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  assert_contains "$stderr" "Usage:"
  run_lookup lookup alpha extra
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  assert_contains "$stderr" "Usage:"
}

@test "on a builtin/project id collision lookup returns the builtin definition" {
  put "$BUILTIN" same.json same "Builtin Name"
  put "$PROJECT" same.json same "Project Name"
  run_lookup lookup same
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.source == "builtin" and .name == "Builtin Name"
    and .file == "'"$BUILTIN"'/same.json"'
  # the shared catalog build still reports the collision on stderr
  assert_contains "$stderr" "same"
}

@test "lookup returns the first file's definition when two project files share an id" {
  put "$PROJECT" a.json dup "From A"
  put "$PROJECT" b.json dup "From B"
  run_lookup lookup dup
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.name == "From A"'
}

@test "bare output is still the id-sorted catalog array and -h still exits 0" {
  put "$BUILTIN" zeta.json zeta
  put "$PROJECT" alpha.json alpha
  run_lookup
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.[].id] | join(",")')" = "alpha,zeta" ]
  run bash "$LOADER" -h
  [ "$status" -eq 0 ]
}

@test "the header documents the lookup subcommand" {
  head -n 70 "$LOADER" > "$BATS_TEST_TMPDIR/header.txt"
  run cat "$BATS_TEST_TMPDIR/header.txt"
  assert_output_contains "lookup <id>"
}

@test "the loader stays executable" {
  [ -x "$LOADER" ]
}
