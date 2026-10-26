#!/usr/bin/env bats
#
# Coverage for templates/workflow-schema.json (E80_S01_T01), the v1 (linear) workflow definition contract.
#
# Every test reads the REAL committed schema file, never a fixture copy: the claim under test is "this file, as
# shipped, states the contract", and the validator tasks (E80_S01_T03/T04) will read the same file.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCHEMA="$REPO_ROOT/templates/workflow-schema.json"
TYPES="$REPO_ROOT/templates/playbook-types.json"
PLAYBOOK_NEW="$REPO_ROOT/skills/j-playbook-new/scripts/playbook-new.sh"

# jq_eq <filter> <expected>: assert a jq filter over the schema prints exactly <expected>.
jq_eq() {
  local got
  got="$(jq -c "$1" "$SCHEMA")"
  [ "$got" = "$2" ]
}

@test "schema exists and is valid JSON" {
  [ -f "$SCHEMA" ]
  jq -e . "$SCHEMA" >/dev/null
}

@test "schema carries no commentary outside _comment" {
  # Every top-level key is either _comment or a known contract section; all string-valued top-level keys other
  # than _comment would be free commentary, so there must be none.
  run jq -r 'to_entries | map(select(.key != "_comment" and (.value | type) == "string")) | length' "$SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  jq_eq '[keys[] | select(. != "_comment")] | sort' \
    '["inputs","non_goals_v1","outputs","schema_version","step_common","step_types","substitution","top_level"]'
  run jq -r '._comment | type' "$SCHEMA"
  [ "$output" = "string" ]
}

@test "_comment records the key names the validator will read" {
  local comment key
  comment="$(jq -r '._comment' "$SCHEMA")"
  for key in top_level inputs step_common step_types outputs substitution non_goals_v1 type_registry; do
    assert_contains "$comment" "$key"
  done
}

@test "defines exactly the five step types" {
  jq_eq '.step_types | keys | sort' '["compute","confirm","playbook","render","skill"]'
}

@test "each step type lists its per-type required fields" {
  jq_eq '.step_types.skill.required' '["skill"]'
  jq_eq '.step_types.playbook.required' '["playbook"]'
  jq_eq '.step_types.confirm.required' '["prompt","options"]'
  jq_eq '.step_types.compute.required' '["command"]'
  jq_eq '.step_types.render.required' '["template"]'
}

@test "optional fields named by the task are present on compute and render" {
  run jq -e '.step_types.compute.optional | index("args")' "$SCHEMA"
  [ "$status" -eq 0 ]
  run jq -e '.step_types.render.optional | index("inputs")' "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "every required and optional field of a step type has a declared field type" {
  run jq -e '[.step_types[] | ((.required + .optional) - (.field_types | keys)) | length] | all(. == 0)' "$SCHEMA"
  [ "$status" -eq 0 ]
  run jq -e '[.step_types[] | (.field_types | keys) - (.required + .optional) | length] | all(. == 0)' "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "top-level required keys are id, name, description and steps" {
  jq_eq '.top_level.required' '["id","name","description","steps"]'
  run jq -e '(.top_level.optional | index("keywords")) and (.top_level.optional | index("examples")) and (.top_level.optional | index("inputs"))' "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "top-level id pattern accepts and rejects the same ids as the playbook slug rule" {
  local pattern id
  pattern="$(jq -r '.top_level.id_pattern' "$SCHEMA")"
  for id in sprint my-flow a1 a-b-c-2; do
    run grep -Eq "$pattern" <<<"$id"
    [ "$status" -eq 0 ]
  done
  for id in Sprint -x x- a--b a_b "a b" ""; do
    run grep -Eq "$pattern" <<<"$id"
    [ "$status" -ne 0 ]
  done
}

@test "id pattern is the slug rule playbook-new.sh enforces for playbook ids" {
  local pattern
  pattern="$(jq -r '.top_level.id_pattern' "$SCHEMA")"
  run grep -F "SLUG_RE = re.compile(r'$pattern')" "$PLAYBOOK_NEW"
  [ "$status" -eq 0 ]
}

@test "step_common requires id and type and offers checkpoint and outputs" {
  jq_eq '.step_common.required' '["id","type"]'
  run jq -e '(.step_common.optional | index("checkpoint")) and (.step_common.optional | index("outputs"))' "$SCHEMA"
  [ "$status" -eq 0 ]
  jq_eq '.step_common.checkpoint_type' '"boolean"'
  jq_eq '.step_common.step_id_unique_within_file' 'true'
}

@test "inputs entries need a name and may carry description and default" {
  jq_eq '.inputs.required' '["name"]'
  jq_eq '.inputs.optional' '["description","default"]'
}

@test "output entries are name, kind and type with kind restricted to artifact and data" {
  jq_eq '.outputs.entry_required' '["name","kind","type"]'
  jq_eq '.outputs.kind_values' '["artifact","data"]'
}

@test "the schema lists no output type names and points at the playbook type registry" {
  local name
  jq_eq '.outputs.type_registry' '"templates/playbook-types.json"'
  [ -f "$REPO_ROOT/$(jq -r '.outputs.type_registry' "$SCHEMA")" ]
  # No outputs key other than the shape members, so no enum/list of type names can hide there.
  jq_eq '.outputs | keys | sort' '["entry_required","kind_values","name_pattern","type_registry"]'
  # No registered type name appears as a JSON string value anywhere in the schema outside _comment.
  while IFS= read -r name; do
    run jq -e --arg n "$name" '[del(._comment) | .. | strings | select(. == $n)] | length == 0' "$SCHEMA"
    [ "$status" -eq 0 ]
  done < <(jq -r '.types | keys[]' "$TYPES")
}

@test "substitution documents both reference forms and a working POSIX ERE" {
  local pattern
  jq_eq '.substitution.syntax' '["${inputs.<name>}","${steps.<step_id>.outputs.<output_name>}"]'
  jq_eq '.substitution.pattern_flavor' '"posix-ere"'
  pattern="$(jq -r '.substitution.pattern' "$SCHEMA")"
  run grep -Eqx "$pattern" <<<'${inputs.sprint_name}'
  [ "$status" -eq 0 ]
  run grep -Eqx "$pattern" <<<'${steps.plan_1.outputs.report}'
  [ "$status" -eq 0 ]
  run grep -Eqx "$pattern" <<<'${steps.plan_1.report}'
  [ "$status" -ne 0 ]
  run grep -Eqx "$pattern" <<<'${env.HOME}'
  [ "$status" -ne 0 ]
  run grep -Eqx "$pattern" <<<'${inputs.Bad}'
  [ "$status" -ne 0 ]
}

@test "substitution states the earlier-steps-only rule" {
  local rule
  rule="$(jq -r '.substitution.rule' "$SCHEMA")"
  assert_contains "$rule" "EARLIER"
  assert_contains "$rule" "run inputs"
  assert_contains "$rule" "later step"
}

@test "non-goals record branching, parallel steps and conditionals" {
  jq_eq '.non_goals_v1' '["branching","parallel steps","conditionals"]'
}
