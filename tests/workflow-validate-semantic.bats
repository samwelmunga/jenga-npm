#!/usr/bin/env bats
#
# E80_S01_T04: scripts/workflow/validate-workflow.sh, the semantic half of the workflow definition validator.
# Covers: an output type that is (and is not) a key of `types` in templates/playbook-types.json, an invalid output
# kind, a duplicate output name inside one step, `${inputs.<name>}` references to declared and undeclared run
# inputs, and `${steps.<id>.outputs.<name>}` references to an unknown step, a later step, the same step and an
# undeclared output, in every string-bearing field (args, options, prompt, command args, template, render inputs).
# Also: a malformed reference, a shell `${VAR}` that is not a reference, several problems in one run, structural and
# semantic problems together, and the type registry being read from the package root (and required only when an
# output is declared).
#
# Every fixture is built under $BATS_TEST_TMPDIR from one valid chained definition by a jq edit, so each rejection
# case differs from the valid one by exactly the thing it tests. The registry tests work on COPIES under a synthetic
# package root selected with JENGA_WORKFLOWS_TEST_ROOT; the committed schema and registry are never modified.
# Nothing reads this repository's board or any private path.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/workflow/validate-workflow.sh"
REAL_SCHEMA="$REPO_ROOT/templates/workflow-schema.json"
REAL_TYPES="$REPO_ROOT/templates/playbook-types.json"

setup() {
  unset JENGA_WORKFLOWS_TEST_ROOT JENGA_PROJECT_ROOT
  VALID="$BATS_TEST_TMPDIR/valid.json"
  # Step 'fetch' produces two outputs and consumes a run input; step 'ask' and 'show' consume fetch's output.
  cat > "$VALID" <<'EOF'
{
  "id": "chain-flow",
  "name": "Chain flow",
  "description": "A valid chained definition used as the base for every fixture.",
  "inputs": [ { "name": "topic" }, { "name": "depth", "default": "2" } ],
  "steps": [
    { "id": "fetch", "type": "skill", "skill": "j.status",
      "args": { "topic": "${inputs.topic}", "depth": "${inputs.depth}" },
      "outputs": [
        { "name": "rows", "kind": "data", "type": "text" },
        { "name": "report", "kind": "artifact", "type": "file_list" }
      ] },
    { "id": "ask", "type": "confirm", "prompt": "Use ${steps.fetch.outputs.rows} for ${inputs.topic}?",
      "options": ["yes", "no ${steps.fetch.outputs.report}"],
      "outputs": [ { "name": "answer", "kind": "data", "type": "text" } ] },
    { "id": "calc", "type": "compute", "command": "scripts/x.sh",
      "args": ["--rows", "${steps.fetch.outputs.rows}", "--home", "${HOME}"] },
    { "id": "show", "type": "render", "template": "templates/x.md",
      "inputs": { "rows": "${steps.fetch.outputs.rows}", "answer": "${steps.ask.outputs.answer}" } }
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

# --- a valid chained definition ----------------------------------------------------------------------------------

@test "a chained definition with real registry types and resolving references exits 0 silently" {
  validate "$VALID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "every type in the registry is accepted as an output type" {
  local t
  for t in $(jq -r '.types | keys[]' "$REAL_TYPES"); do
    mutate "type-$t" ".steps[0].outputs[0].type = \"$t\""
    validate "$FIXTURE"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
  done
}

@test "a step output used by a step that is not adjacent (steps two apart) resolves" {
  mutate non-adjacent '.steps[3].inputs.rows = "${steps.fetch.outputs.report}"'
  validate "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "a definition without outputs or inputs and without references is valid" {
  mutate plain 'del(.inputs) | .steps |= map(del(.outputs) | del(.args) | del(.inputs) | if .type == "confirm" then .prompt = "ok" | .options = ["a"] else . end)'
  validate "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# --- output type -------------------------------------------------------------------------------------------------

@test "an output type that is not in the registry is rejected, naming file, step id, output name and type" {
  mutate bad-type '.steps[0].outputs[1].type = "spreadsheet"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$FIXTURE: steps[0].outputs[1].type: step 'fetch' output 'report' has unknown type 'spreadsheet'"
  assert_contains "$stderr" "templates/playbook-types.json"
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
}

@test "the type check is case sensitive: 'Text' is not 'text'" {
  mutate case-type '.steps[1].outputs[0].type = "Text"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[1].outputs[0].type: step 'ask' output 'answer' has unknown type 'Text'"
}

@test "a non-string output type is rejected" {
  mutate num-type '.steps[0].outputs[0].type = 5'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].outputs[0].type: step 'fetch' output 'rows' type must be a string"
}

@test "an output missing name, kind or type is rejected for each missing field" {
  mutate no-kind 'del(.steps[0].outputs[0].kind)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].outputs[0].kind: missing required field 'kind' for output 'rows' of step 'fetch'"

  mutate no-type 'del(.steps[0].outputs[0].type)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].outputs[0].type: missing required field 'type' for output 'rows' of step 'fetch'"

  mutate no-name 'del(.steps[0].outputs[0].name)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].outputs[0].name: missing required field 'name' for output (no name) of step 'fetch'"
}

@test "outputs that is not an array, and an output that is not an object, are rejected" {
  mutate outputs-object '.steps[0].outputs = {"name": "rows"}'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].outputs: step 'fetch' outputs must be an array"

  mutate output-scalar '.steps[0].outputs[1] = "report"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].outputs[1]: step 'fetch' output must be an object"
}

# --- output kind and duplicate output name -----------------------------------------------------------------------

@test "an invalid output kind is rejected, naming the step, the output and the allowed kinds" {
  mutate bad-kind '.steps[0].outputs[0].kind = "blob"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].outputs[0].kind: step 'fetch' output 'rows' has invalid kind 'blob' (expected one of: artifact, data)"
}

@test "a non-string output kind (including an array of valid kinds) is rejected" {
  local v
  for v in '["artifact"]' '["artifact","data"]' '[]' '5' '{}' '""'; do
    mutate "kind-$RANDOM" ".steps[0].outputs[0].kind = $v"
    validate "$FIXTURE"
    [ "$status" -eq 1 ]
    assert_contains "$stderr" "$FIXTURE: steps[0].outputs[0].kind: step 'fetch' output 'rows' has invalid kind"
  done
}

@test "a duplicate output name within one step is rejected, naming both positions" {
  mutate dup-output '.steps[0].outputs[1].name = "rows"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].outputs[1].name: step 'fetch' declares output 'rows' more than once (first at outputs[0])"
}

@test "the same output name in two different steps is allowed" {
  mutate same-name-two-steps '.steps[1].outputs[0].name = "rows" | .steps[3].inputs.answer = "${steps.ask.outputs.rows}"'
  validate "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# --- references to run inputs ------------------------------------------------------------------------------------

@test "a reference to an undeclared run input is rejected, naming the step, the field path and the reference" {
  mutate bad-input '.steps[0].args.topic = "${inputs.nope}"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].args.topic: step 'fetch' reference '\${inputs.nope}' names an undeclared run input 'nope'"
}

@test "any inputs reference is undeclared when the definition has no inputs array" {
  mutate no-inputs 'del(.inputs)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].args.topic: step 'fetch' reference '\${inputs.topic}' names an undeclared run input 'topic'"
  assert_contains "$stderr" "$FIXTURE: steps[1].prompt: step 'ask' reference '\${inputs.topic}' names an undeclared run input 'topic'"
}

# --- references to step outputs ----------------------------------------------------------------------------------

@test "a reference to an unknown step is rejected, naming the step id, the field path and the reference" {
  mutate unknown-step '.steps[3].inputs.rows = "${steps.ghost.outputs.rows}"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[3].inputs.rows: step 'show' reference '\${steps.ghost.outputs.rows}' names an unknown step 'ghost'"
}

@test "a reference to a later step is rejected" {
  mutate later-step '.steps[0].args.topic = "${steps.show.outputs.out}" | .steps[3].outputs = [{"name": "out", "kind": "data", "type": "text"}]'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].args.topic: step 'fetch' reference '\${steps.show.outputs.out}' refers to later step 'show'"
}

@test "a reference to the step itself is rejected" {
  mutate self-ref '.steps[1].prompt = "again ${steps.ask.outputs.answer}?"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[1].prompt: step 'ask' reference '\${steps.ask.outputs.answer}' refers to its own step"
}

@test "a reference to an output the earlier step does not declare is rejected" {
  mutate undeclared-output '.steps[2].args[1] = "${steps.fetch.outputs.nothing}"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[2].args[1]: step 'calc' reference '\${steps.fetch.outputs.nothing}' names an output that step 'fetch' does not declare"
}

@test "a reference to an earlier step that declares no outputs at all is rejected" {
  mutate no-outputs-step '.steps[2].args[1] = "${steps.ask.outputs.answer}" | del(.steps[1].outputs)'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[2].args[1]: step 'calc' reference '\${steps.ask.outputs.answer}' names an output that step 'ask' does not declare"
}

# --- every string-bearing field is scanned -----------------------------------------------------------------------

@test "a bad reference is found in each field: prompt, options, args (map and array), template and render inputs" {
  local ref='${steps.ghost.outputs.x}'
  mutate in-prompt ".steps[1].prompt = \"p $ref\""
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[1].prompt: "

  mutate in-options ".steps[1].options[0] = \"$ref\""
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[1].options[0]: "

  mutate in-args-map ".steps[0].args.depth = \"$ref\""
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].args.depth: "

  mutate in-args-array ".steps[2].args[0] = \"$ref\""
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[2].args[0]: "

  mutate in-command ".steps[2].command = \"scripts/x.sh $ref\""
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[2].command: "

  mutate in-template ".steps[3].template = \"templates/$ref.md\""
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[3].template: "

  mutate in-render-inputs ".steps[3].inputs.answer = \"$ref\""
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[3].inputs.answer: "
}

@test "nested args values (maps inside arrays) are scanned too" {
  mutate nested '.steps[0].args.extra = {"deep": ["${inputs.nope}"]}'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].args.extra.deep[0]: step 'fetch' reference '\${inputs.nope}'"
}

@test "two references in one field are each checked" {
  mutate two-refs '.steps[1].prompt = "${steps.fetch.outputs.rows} ${steps.fetch.outputs.nope} ${inputs.nope}"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "'\${steps.fetch.outputs.nope}' names an output that step 'fetch' does not declare"
  assert_contains "$stderr" "'\${inputs.nope}' names an undeclared run input 'nope'"
  assert_not_contains "$stderr" "'\${steps.fetch.outputs.rows}'"
}

# --- tokens that are not references ------------------------------------------------------------------------------

@test "a malformed reference in the inputs or steps namespace is rejected" {
  mutate malformed-input '.steps[0].args.topic = "${inputs.Bad-Name}"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[0].args.topic: step 'fetch' has malformed reference '\${inputs.Bad-Name}'"

  mutate malformed-step '.steps[1].prompt = "${steps.fetch.rows}"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: steps[1].prompt: step 'ask' has malformed reference '\${steps.fetch.rows}'"
}

@test "a shell-style \${VAR} outside the inputs and steps namespaces is not a reference and is accepted" {
  mutate shell-var '.steps[2].command = "echo ${HOME} ${PATH}"'
  validate "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "id, type, skill and playbook values are not scanned for references" {
  mutate unscanned '.steps[0].skill = "j.${inputs.nope}"'
  validate "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# --- all problems in one run, and alongside structural problems --------------------------------------------------

@test "several semantic problems are all reported in one run, one line each" {
  mutate many '.steps[0].outputs[0].type = "nope" | .steps[0].outputs[1].kind = "x" | .steps[1].options[0] = "${steps.ghost.outputs.a}" | .steps[2].args[1] = "${inputs.zzz}" | .steps[3].inputs.rows = "${steps.show.outputs.q}"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$FIXTURE: steps[0].outputs[0].type: "
  assert_contains "$stderr" "$FIXTURE: steps[0].outputs[1].kind: "
  assert_contains "$stderr" "$FIXTURE: steps[1].options[0]: "
  assert_contains "$stderr" "$FIXTURE: steps[2].args[1]: "
  assert_contains "$stderr" "$FIXTURE: steps[3].inputs.rows: "
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 5 ]
}

@test "structural and semantic problems are reported together" {
  mutate both 'del(.id) | del(.steps[3].template) | .steps[0].outputs[0].type = "nope"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$FIXTURE: id: missing required field"
  assert_contains "$stderr" "$FIXTURE: steps[3].template: missing required field 'template'"
  assert_contains "$stderr" "$FIXTURE: steps[0].outputs[0].type: step 'fetch' output 'rows' has unknown type 'nope'"
}

@test "every stderr line has the <file>: <field path>: <reason> shape" {
  mutate shape '.steps[0].outputs[0].type = "nope" | .steps[1].prompt = "${steps.ghost.outputs.a}" | .steps[0].outputs[1].name = "rows"'
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

@test "a structurally broken document does not crash the semantic pass" {
  mutate broken '.steps = [5, {"id": 3, "outputs": 7}, {"id": "x", "type": "skill", "skill": "s", "outputs": [1], "args": {"a": "${steps.x.outputs.n}"}}] | .inputs = "oops"'
  validate "$FIXTURE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$FIXTURE: steps[0]: step must be an object"
  assert_not_contains "$stderr" "jq:"
  assert_not_contains "$stderr" "could not run"
}

# --- the registry is read from the package root ------------------------------------------------------------------

@test "a registry copy without a type makes that type unknown without editing the script" {
  local root="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$root/templates"
  cp "$REAL_SCHEMA" "$root/templates/workflow-schema.json"
  cp "$REAL_TYPES" "$root/templates/playbook-types.json"
  export JENGA_WORKFLOWS_TEST_ROOT="$root"

  validate "$VALID"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]

  jq 'del(.types.file_list)' "$REAL_TYPES" > "$root/templates/playbook-types.json"
  validate "$VALID"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "$VALID: steps[0].outputs[1].type: step 'fetch' output 'report' has unknown type 'file_list'"
}

@test "a missing or unusable registry is an exit 2 naming the registry when outputs are declared" {
  local root="$BATS_TEST_TMPDIR/pkg-no-types"
  mkdir -p "$root/templates"
  cp "$REAL_SCHEMA" "$root/templates/workflow-schema.json"
  export JENGA_WORKFLOWS_TEST_ROOT="$root"

  validate "$VALID"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$root/templates/playbook-types.json: output type registry not found or unreadable"

  printf '{ not json\n' > "$root/templates/playbook-types.json"
  validate "$VALID"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "$root/templates/playbook-types.json"

  printf '{"verify_rules": {}}\n' > "$root/templates/playbook-types.json"
  validate "$VALID"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "no types object"
}

@test "the registry is not required when the definition declares no output" {
  local root="$BATS_TEST_TMPDIR/pkg-schema-only"
  mkdir -p "$root/templates"
  cp "$REAL_SCHEMA" "$root/templates/workflow-schema.json"
  export JENGA_WORKFLOWS_TEST_ROOT="$root"
  mutate no-outputs 'del(.steps[].outputs) | .steps[1].prompt = "ok" | .steps[1].options = ["a"] | .steps[2].args = [] | .steps[3].inputs = {}'
  validate "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "the validator never writes anything next to the definition" {
  local box="$BATS_TEST_TMPDIR/box" before after
  mkdir -p "$box"
  jq '.steps[0].outputs[0].type = "nope"' "$VALID" > "$box/def.json"
  before="$(ls -A "$box" | LC_ALL=C sort)"
  validate "$box/def.json"
  [ "$status" -eq 1 ]
  after="$(ls -A "$box" | LC_ALL=C sort)"
  [ "$before" = "$after" ]
}
