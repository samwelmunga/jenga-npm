#!/usr/bin/env bats
#
# Fixture-based coverage for skills/j-playbook-new/scripts/playbook-new.sh (E53_S09_T02) -- the
# deterministic helper behind the j.playbook-new guided wizard. Covers all three subcommands:
# validate-id, validate-skill, write.
#
# Fixture-tree convention (following tests/load-playbooks-project-source.bats,
# tests/load-playbooks-stepobject.bats precedent): validate-id and write cases build their OWN
# synthetic skills/ and playbooks/ tree under $BATS_TEST_TMPDIR and point the script at it via
# JENGA_PLAYBOOKS_TEST_ROOT -- the SAME override variable load-playbooks.sh itself defines, never
# a second test-only one -- rather than against this repository's own project/.playbooks/.
#
# validate-skill is deliberately exercised against THIS REPOSITORY'S OWN real, live skill catalog
# (load-nl-catalog.sh does not honor JENGA_PLAYBOOKS_TEST_ROOT -- confirmed during implementation)
# -- that is the entire point of this subcommand's Acceptance Criterion: validate against the real
# generated catalog, never a fixture stand-in or a hand-maintained list.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-playbook-new/scripts/playbook-new.sh"

write_skill() {
  local name="$1"
  mkdir -p "$FIXTURE_ROOT/skills/$name"
  {
    printf -- '---\n'
    printf 'name: j.%s\n' "$name"
    printf 'description: fixture skill %s.\n' "$name"
    printf -- '---\n# %s\n' "$name"
  } > "$FIXTURE_ROOT/skills/$name/SKILL.md"
}

write_builtin_playbook() {
  local id="$1" steps_json="$2"
  mkdir -p "$FIXTURE_ROOT/skills/jenga/playbooks"
  cat > "$FIXTURE_ROOT/skills/jenga/playbooks/$id.json" <<EOF
{
  "id": "$id",
  "name": "Fixture builtin $id",
  "description": "fixture builtin playbook $id",
  "keywords": ["fixture"],
  "examples": ["fixture example"],
  "steps": [$steps_json]
}
EOF
}

write_project_playbook() {
  local id="$1" steps_json="$2"
  mkdir -p "$FIXTURE_ROOT/project/.playbooks"
  cat > "$FIXTURE_ROOT/project/.playbooks/$id.json" <<EOF
{
  "id": "$id",
  "name": "Fixture project $id",
  "description": "fixture project playbook $id",
  "keywords": ["fixture"],
  "examples": ["fixture example"],
  "steps": [$steps_json]
}
EOF
}

run_validate_id() {
  local id="$1"
  JENGA_PLAYBOOKS_TEST_ROOT="$FIXTURE_ROOT" run bash "$SCRIPT" validate-id "$id"
}

run_write() {
  local payload="$1"
  local payload_file="$BATS_TEST_TMPDIR/write-payload.json"
  printf '%s' "$payload" > "$payload_file"
  JENGA_PLAYBOOKS_TEST_ROOT="$FIXTURE_ROOT" run bash "$SCRIPT" write < "$payload_file"
}

run_lookup() {
  local id="$1"
  JENGA_PLAYBOOKS_TEST_ROOT="$FIXTURE_ROOT" run bash "$REPO_ROOT/skills/jenga/scripts/load-playbooks.sh" lookup "$id"
}

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-root"
  mkdir -p "$FIXTURE_ROOT/skills/jenga/playbooks"
  write_skill "alpha"
  write_skill "beta"
}

# -----------------------------------------------------------------------------
# validate-id
# -----------------------------------------------------------------------------

@test "validate-id: a fresh, slug-safe id with no collision is valid" {
  run_validate_id "my-fresh-playbook"
  [ "$status" -eq 0 ]
  assert_output_contains '"valid": true'
}

@test "validate-id: a slug-unsafe id is rejected" {
  run_validate_id "Not_Slug_Safe"
  [ "$status" -eq 0 ]
  assert_output_contains '"valid": false'
  assert_output_contains "not slug-safe"
}

@test "validate-id: an id colliding with a loaded builtin playbook is rejected" {
  write_builtin_playbook "builtin-one" '"alpha", "beta"'
  run_validate_id "builtin-one"
  [ "$status" -eq 0 ]
  assert_output_contains '"valid": false'
  assert_output_contains "collides with an already-loaded builtin playbook"
}

@test "validate-id: an id colliding with a loaded project playbook is rejected" {
  # The raw-file-existence check (which fires first, ahead of the catalog scan -- see the
  # script's own header) is a strict superset of a project-source catalog collision: any
  # successfully-loaded project playbook already has a file at this exact path, so the reported
  # reason is the file-existence message, not the catalog-collision one (that branch is reserved
  # for builtin collisions, which live under a different directory -- see the next test).
  write_project_playbook "proj-one" '"alpha", "beta"'
  run_validate_id "proj-one"
  [ "$status" -eq 0 ]
  assert_output_contains '"valid": false'
  assert_output_contains "a file already exists at"
}

@test "validate-id: an id matching an existing but currently-invalid project file is rejected" {
  # A single-step playbook fails schema minItems, so it never loads into the catalog -- but the
  # file still exists on disk and must not be silently overwritten.
  write_project_playbook "broken-one" '"alpha"'
  run_validate_id "broken-one"
  [ "$status" -eq 0 ]
  assert_output_contains '"valid": false'
  assert_output_contains "a file already exists at"
}

# -----------------------------------------------------------------------------
# validate-skill (against the real, live repo catalog -- see file header)
# -----------------------------------------------------------------------------

@test "validate-skill: a real, currently-loadable skill directory name is valid" {
  run bash "$SCRIPT" validate-skill "j-brainstorm"
  [ "$status" -eq 0 ]
  assert_output_contains '"valid": true'
}

@test "validate-skill: an unrecognized skill name is rejected" {
  run bash "$SCRIPT" validate-skill "definitely-not-a-real-skill-xyz"
  [ "$status" -eq 0 ]
  assert_output_contains '"valid": false'
  assert_output_contains "not a recognized skill directory name"
}

# -----------------------------------------------------------------------------
# write
# -----------------------------------------------------------------------------

@test "write: a payload missing required fields is rejected and nothing is written" {
  run_write '{"id": "incomplete", "name": "Incomplete"}'
  [ "$status" -eq 0 ]
  assert_output_contains '"written": false'
  assert_output_contains "missing required field"
  [ ! -f "$FIXTURE_ROOT/project/.playbooks/incomplete.json" ]
}

@test "write: fewer than 2 steps is rejected and nothing is written" {
  run_write '{"id": "one-step", "name": "One Step", "description": "d", "keywords": ["k"], "examples": ["e"], "steps": ["alpha"]}'
  [ "$status" -eq 0 ]
  assert_output_contains '"written": false'
  assert_output_contains "at least 2"
  [ ! -f "$FIXTURE_ROOT/project/.playbooks/one-step.json" ]
}

@test "write: a full, valid payload is written and load-playbooks.sh reports it valid" {
  run_write '{"id": "my-happy-path", "name": "My Happy Path", "description": "d", "keywords": ["k1", "k2"], "examples": ["e1"], "steps": ["alpha", "beta"]}'
  [ "$status" -eq 0 ]
  assert_output_contains '"written": true'
  [ -f "$FIXTURE_ROOT/project/.playbooks/my-happy-path.json" ]

  run_lookup "my-happy-path"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "valid"'
  assert_output_contains '"source": "project"'
}

@test "write: refuses to overwrite an already-existing file for the same id" {
  write_project_playbook "already-there" '"alpha", "beta"'
  run_write '{"id": "already-there", "name": "Dup", "description": "d", "keywords": ["k"], "examples": ["e"], "steps": ["alpha", "beta"]}'
  [ "$status" -eq 0 ]
  assert_output_contains '"written": false'
  assert_output_contains "refusing to overwrite"
}
