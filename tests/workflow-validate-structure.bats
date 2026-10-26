#!/usr/bin/env bats
#
# E80_S01_T03: scripts/workflow/validate-workflow.sh, the structural half of the workflow definition validator.
# Covers: missing id / steps, an empty or non-array steps, an unknown step type, a duplicate step id, a missing
# type-specific required field for each of the five step types, several problems reported in one run, unparseable
# JSON and a missing file, and the rule that the per-type required fields come from the schema file, not the script.
#
# Every fixture is built under $BATS_TEST_TMPDIR from one valid definition by a jq edit, so each rejection case
# differs from the valid one by exactly the thing it tests. The one test that edits the schema works on a COPY
# placed under a synthetic package root and selected with JENGA_WORKFLOWS_TEST_ROOT; the committed schema is never
# modified. Nothing reads this repository's board or any private path.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/workflow/validate-workflow.sh"
REAL_SCHEMA="$REPO_ROOT/templates/workflow-schema.json"

setup() {
  unset JENGA_WORKFLOWS_TEST_ROOT JENGA_PROJECT_ROOT
  VALID="$BATS_TEST_TMPDIR/valid.json"
  # One step of each of the five types, each with exactly its required fields.
  cat > "$VALID" <<'EOF'
{
  "id": "demo-flow",
  "name": "Demo flow",
  "description": "A valid definition used as the base for every fixture.",
  "steps": [
    { "id": "run_skill", "type": "skill", "skill": "j.status" },
    { "id": "run_playbook", "type": "playbook", "playbook": "release" },
    { "id": "ask", "type": "confirm", "prompt": "Proceed?", "options": ["yes", "no"] },
    { "id": "calc", "type": "compute", "command": "scripts/x.sh" },
    { "id": "show", "type": "render", "template": "templates/x.md" }
  ]
}
EOF
}

# mutate <name> <jq filter>: writes $BATS_TEST_TMPDIR/<name>.json = the valid definition with the edit applied and
# sets FIXTURE to its path.
mutate() {
  FIXTURE="$BATS_TEST_TMPDIR/$1.json"
  jq "$2" "$VALID" > "$FIXTURE"
}

# validate <file>: runs the validator with stdout in $output and stderr in $stderr.
validate() {
  run --separate-stderr bash "$VALIDATOR" "$1"
}

# --- the script itself -------------------------------------------------------------------------------------------

@test "validate-workflow.sh exists, is executable and passes bash -n" {
  [ -f "$VALIDATOR" ]
  [ -x "$VALIDATOR" ]
  run bash -n "$VALIDATOR"
  [ "$status" -eq 0 ]
}

@test "the header documents usage, exit codes and the stderr line format" {
  local header
  header="$(sed -n '1,60p' "$VALIDATOR")"
  assert_contains "$header" "USAGE"
  assert_contains "$header" "EXIT CODES"
  assert_contains "$header" "STDERR LINE FORMAT"
  assert_contains "$header" "<file>: <field path>: <reason>"
}

@test "--help prints usage on stdout and exits 0" {
  run --separate-stderr bash "$VALIDATOR" --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: validate-workflow.sh <file>"
  [ -z "$stderr" ]
}

@test "no argument and too many arguments are a usage error (exit 2)" {
  run --separate-stderr bash "$VALIDATOR"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "Usage:"
  run --separate-stderr bash "$VALIDATOR" "$VALID" "$VALID"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "Usage:"
}

# --- a valid definition ------------------------------------------------------------------------------------------

@test "a valid definition exits 0 with empty stdout and empty stderr" {
  validate "$VALID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "optional keys do not make a valid definition invalid" {
  mutate with-optional '. + {keywords: ["a"], examples: ["b"], inputs: [{name: "x"}]} | .steps[0].checkpoint = true'
  validate "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# --- top level ---------------------------------------------------------------------------------------------------

@test "missing id is rejected, naming the file and the field" {
  mutate no-id 'del(.id)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$FIXTURE: id: missing required field"
}

@test "missing steps is rejected, naming the file and the field" {
  mutate no-steps 'del(.steps)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps: missing required field"
}

@test "an empty steps array is rejected" {
  mutate empty-steps '.steps = []'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps: must not be empty"
}

@test "a non-array steps is rejected" {
  mutate object-steps '.steps = {"id": "a"}'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps: must be an array"
}

@test "a null id is treated as missing" {
  mutate null-id '.id = null'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: id: missing required field"
}

@test "a top-level value that is not an object is rejected" {
  printf '[1, 2]\n' > "$BATS_TEST_TMPDIR/array.json"
  validate "$BATS_TEST_TMPDIR/array.json"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$BATS_TEST_TMPDIR/array.json: (root): definition must be a JSON object"
}

# --- step type and step id ---------------------------------------------------------------------------------------

@test "an unknown step type is rejected with the step path and the type" {
  mutate bad-type '.steps[2].type = "branch"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[2].type: unknown step type 'branch'"
}

@test "a step without a type is rejected" {
  mutate no-type 'del(.steps[1].type)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[1].type: missing required field"
}

@test "a step without an id is rejected" {
  mutate no-step-id 'del(.steps[3].id)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[3].id: missing required field"
}

@test "a step that is not an object is rejected" {
  mutate scalar-step '.steps[0] = 5'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0]: step must be an object"
}

@test "a duplicate step id is rejected, naming both positions" {
  mutate dup-id '.steps[3].id = "run_skill"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[3].id: duplicate step id 'run_skill' (first used at steps[0])"
}

# --- type-specific required fields: every step type, every required field ----------------------------------------

@test "a skill step without 'skill' is rejected, naming the step id and the field" {
  mutate skill-missing 'del(.steps[0].skill)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].skill: missing required field 'skill' for skill step 'run_skill'"
}

@test "a playbook step without 'playbook' is rejected, naming the step id and the field" {
  mutate playbook-missing 'del(.steps[1].playbook)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[1].playbook: missing required field 'playbook' for playbook step 'run_playbook'"
}

@test "a confirm step without 'prompt' is rejected, naming the step id and the field" {
  mutate confirm-no-prompt 'del(.steps[2].prompt)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[2].prompt: missing required field 'prompt' for confirm step 'ask'"
  assert_not_contains "$stderr" "options"
}

@test "a confirm step without 'options' is rejected, naming the step id and the field" {
  mutate confirm-no-options 'del(.steps[2].options)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[2].options: missing required field 'options' for confirm step 'ask'"
}

@test "a compute step without 'command' is rejected, naming the step id and the field" {
  mutate compute-missing 'del(.steps[3].command)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[3].command: missing required field 'command' for compute step 'calc'"
}

@test "a render step without 'template' is rejected, naming the step id and the field" {
  mutate render-missing 'del(.steps[4].template)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[4].template: missing required field 'template' for render step 'show'"
}

@test "a field required by another step type does not count for this one" {
  # A skill step carrying 'command' (a compute field) but no 'skill' is still missing 'skill'.
  mutate wrong-type-field '.steps[0] |= (del(.skill) + {command: "x"})'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "steps[0].skill: missing required field 'skill' for skill step 'run_skill'"
}

# --- all problems in one run -------------------------------------------------------------------------------------

@test "several problems are all reported in one run, one line each" {
  mutate many 'del(.id) | .steps[0].type = "branch" | .steps[2].id = "run_skill" | del(.steps[3].command) | del(.steps[4].template)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$FIXTURE: id: missing required field"
  assert_contains "$stderr" "$FIXTURE: steps[0].type: unknown step type 'branch'"
  assert_contains "$stderr" "$FIXTURE: steps[2].id: duplicate step id 'run_skill'"
  assert_contains "$stderr" "$FIXTURE: steps[3].command: missing required field 'command'"
  assert_contains "$stderr" "$FIXTURE: steps[4].template: missing required field 'template'"
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 5 ]
}

@test "every stderr line has the <file>: <field path>: <reason> shape" {
  mutate shape 'del(.id) | del(.steps[0].skill)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  local line
  while IFS= read -r line; do
    case "$line" in
      "$FIXTURE: "*": "*) ;;
      *) printf 'bad line shape: %s\n' "$line" >&2; return 1 ;;
    esac
  done <<EOF
$stderr
EOF
}

# --- unusable input: exit 2, a message naming the file, no jq noise ----------------------------------------------

@test "unparseable JSON exits 2 with a message naming the file and no jq noise" {
  printf '{ "id": "x", \n' > "$BATS_TEST_TMPDIR/broken.json"
  validate "$BATS_TEST_TMPDIR/broken.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$BATS_TEST_TMPDIR/broken.json: not a valid JSON document"
  assert_not_contains "$stderr" "jq:"
  assert_not_contains "$stderr" "parse error"
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
}

@test "an empty file is treated as unparseable (exit 2)" {
  : > "$BATS_TEST_TMPDIR/empty.json"
  validate "$BATS_TEST_TMPDIR/empty.json"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "$BATS_TEST_TMPDIR/empty.json: not a valid JSON document"
}

@test "a nonexistent file exits 2 with a message naming the file and no jq noise" {
  validate "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$BATS_TEST_TMPDIR/does-not-exist.json: file not found or unreadable"
  assert_not_contains "$stderr" "jq:"
}

@test "a directory given as the file exits 2" {
  validate "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "$BATS_TEST_TMPDIR: file not found or unreadable"
}

# --- the rules live in the schema, not in the script -------------------------------------------------------------

@test "editing a required field in a schema copy changes the verdict without editing the script" {
  local root="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$root/templates"
  cp "$REAL_SCHEMA" "$root/templates/workflow-schema.json"
  export JENGA_WORKFLOWS_TEST_ROOT="$root"

  # 1. Unchanged copy of the schema: the valid fixture is valid.
  validate "$VALID"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]

  # 2. Add a required field to the skill type: the same valid fixture is now rejected for it.
  jq '.step_types.skill.required += ["owner"]' "$REAL_SCHEMA" > "$root/templates/workflow-schema.json"
  validate "$VALID"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$VALID: steps[0].owner: missing required field 'owner' for skill step 'run_skill'"

  # 3. Drop a required field from the playbook type: a playbook step without it is now accepted.
  jq '.step_types.playbook.required = []' "$REAL_SCHEMA" > "$root/templates/workflow-schema.json"
  mutate playbook-optional 'del(.steps[1].playbook)'
  validate "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]

  # 4. Remove a step type from the schema: steps of that type are now unknown.
  jq 'del(.step_types.render)' "$REAL_SCHEMA" > "$root/templates/workflow-schema.json"
  validate "$VALID"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$VALID: steps[4].type: unknown step type 'render'"

  # 5. Add a required top-level key.
  jq '.top_level.required += ["owner"]' "$REAL_SCHEMA" > "$root/templates/workflow-schema.json"
  validate "$VALID"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$VALID: owner: missing required field"
}

@test "an unusable schema is an exit 2, not a verdict on the definition" {
  local root="$BATS_TEST_TMPDIR/pkg-broken"
  mkdir -p "$root/templates"
  printf '{ not json\n' > "$root/templates/workflow-schema.json"
  export JENGA_WORKFLOWS_TEST_ROOT="$root"
  validate "$VALID"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "$root/templates/workflow-schema.json"
}

@test "a missing schema is an exit 2 naming the schema path" {
  local root="$BATS_TEST_TMPDIR/pkg-empty"
  mkdir -p "$root"
  export JENGA_WORKFLOWS_TEST_ROOT="$root"
  validate "$VALID"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "$root/templates/workflow-schema.json"
}

# --- the real definition shape, real schema ---------------------------------------------------------------------

@test "the committed schema is the one used when no override is set" {
  mutate real-schema 'del(.steps[0].skill)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.step_types.skill.required[0]' "$REAL_SCHEMA")" = "skill" ]
  assert_contains "$stderr" "steps[0].skill: missing required field 'skill'"
}

@test "the validator never writes anything next to the definition" {
  # The fixture lives in its own directory so bats' own capture files in $BATS_TEST_TMPDIR do not count.
  local box="$BATS_TEST_TMPDIR/box" before after
  mkdir -p "$box"
  jq 'del(.id)' "$VALID" > "$box/def.json"
  before="$(ls -A "$box" | LC_ALL=C sort)"
  validate "$box/def.json"
  [ "$status" -eq 1 ]
  after="$(ls -A "$box" | LC_ALL=C sort)"
  [ "$before" = "$after" ]
}
