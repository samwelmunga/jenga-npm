#!/usr/bin/env bats
#
# Fixture-based coverage for load-playbooks.sh's PROJECT-LOCAL playbook search path
# (E53_S09_T01): a second source directory, `project/.playbooks/`, merged into the same catalog
# and validation pipeline as the built-in `skills/jenga/playbooks/` tree, an id-collision-reject
# rule (built-in always wins, never silently overridden), a `source` field on every catalog entry
# (`"builtin"` | `"project"`), and a silent no-op when `project/.playbooks/` does not exist.
#
# Fixture-tree convention (E43_S01_T01, following tests/load-playbooks-stepobject.bats and
# tests/load-playbooks-composition.bats precedent): every case builds its OWN synthetic skills/
# and playbooks/ tree under $BATS_TEST_TMPDIR and points load-playbooks.sh at it via
# JENGA_PLAYBOOKS_TEST_ROOT -- never against this repository's own skills/. Because
# JENGA_PLAYBOOKS_TEST_ROOT also becomes the PROJECT root (see the script's own header "TESTING
# OVERRIDE"), a project-local playbook fixture lives at
# `$FIXTURE_ROOT/project/.playbooks/<id>.json` -- no second, project-specific test variable is
# introduced.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LOADER="$REPO_ROOT/skills/jenga/scripts/load-playbooks.sh"

write_skill() {
  local name="$1" output_types_block="${2:-}"
  mkdir -p "$FIXTURE_ROOT/skills/$name"
  {
    printf -- '---\n'
    printf 'name: j.%s\n' "$name"
    printf 'description: fixture skill %s.\n' "$name"
    if [ -n "$output_types_block" ]; then
      printf '%s\n' "$output_types_block"
    fi
    printf -- '---\n# %s\n' "$name"
  } > "$FIXTURE_ROOT/skills/$name/SKILL.md"
}

# Writes a BUILT-IN playbook fixture at skills/jenga/playbooks/<id>.json.
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

# Writes a PROJECT-LOCAL playbook fixture at project/.playbooks/<id>.json.
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

run_loader() {
  JENGA_PLAYBOOKS_TEST_ROOT="$FIXTURE_ROOT" run bash "$LOADER"
}

run_lookup() {
  local id="$1"
  JENGA_PLAYBOOKS_TEST_ROOT="$FIXTURE_ROOT" run bash "$LOADER" lookup "$id"
}

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-root"
  mkdir -p "$FIXTURE_ROOT/skills/jenga/playbooks"
  write_skill "alpha" "output_types: text"
  write_skill "beta" ""
}

# -----------------------------------------------------------------------------
# Case 1: a project-only playbook loads with source: "project"
# -----------------------------------------------------------------------------

@test "a project-only playbook loads with source: project" {
  write_project_playbook "proj-only" '"alpha", "beta"'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "proj-only"'
  assert_output_contains '"source": "project"'
}

@test "a builtin playbook loads with source: builtin" {
  write_builtin_playbook "built-only" '"alpha"'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "built-only"'
  assert_output_contains '"source": "builtin"'
}

@test "a distinct builtin and project playbook coexist in one catalog, each with its own correct source (E53_S09_T03 fixture requirement)" {
  write_builtin_playbook "built-side" '"alpha"'
  write_project_playbook "proj-side" '"beta"'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "built-side"'
  assert_output_contains '"id": "proj-side"'
  assert_output_contains '"source": "builtin"'
  assert_output_contains '"source": "project"'
}

# -----------------------------------------------------------------------------
# Case 2: an id collision between a builtin and a project playbook
# -----------------------------------------------------------------------------

@test "a builtin/project id collision is rejected: builtin survives, both paths named in the warning" {
  write_builtin_playbook "shared-id" '"alpha"'
  write_project_playbook "shared-id" '"gamma"'
  write_skill "gamma" ""

  run_loader
  [ "$status" -eq 0 ]
  # The surviving catalog entry for "shared-id" is the builtin one.
  assert_output_contains '"id": "shared-id"'
  assert_output_contains '"source": "builtin"'
  # The builtin's own step ("alpha") is present; the project variant's distinguishing step
  # ("gamma", used nowhere else in this fixture) never made it into the output at all.
  assert_output_contains '"alpha"'
  assert_output_not_contains '"gamma"'
  # The stderr warning names BOTH file paths.
  assert_output_contains "$FIXTURE_ROOT/project/.playbooks/shared-id.json"
  assert_output_contains "$FIXTURE_ROOT/skills/jenga/playbooks/shared-id.json"
  assert_output_contains "collides with a built-in playbook"
}

@test "a builtin/project id collision leaves only one shared-id entry in the catalog (no duplicate)" {
  write_builtin_playbook "shared-id2" '"alpha"'
  write_project_playbook "shared-id2" '"beta"'

  run_loader
  [ "$status" -eq 0 ]
  local count
  count="$(printf '%s' "$output" | grep -c '"id": "shared-id2"')"
  [ "$count" = "1" ]
}

# -----------------------------------------------------------------------------
# Case 3: missing/empty project/.playbooks/ is a silent no-op
# -----------------------------------------------------------------------------

@test "a missing project/.playbooks/ directory is a silent no-op (no warning, no error)" {
  write_builtin_playbook "solo-builtin" '"alpha"'
  # Deliberately do NOT create $FIXTURE_ROOT/project/.playbooks at all.

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "solo-builtin"'
  assert_output_not_contains "project/.playbooks"
  assert_output_not_contains "Warning:"
}

@test "an empty project/.playbooks/ directory contributes nothing and is not an error" {
  write_builtin_playbook "solo-builtin2" '"alpha"'
  mkdir -p "$FIXTURE_ROOT/project/.playbooks"

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "solo-builtin2"'
  assert_output_not_contains "Warning:"
}

# -----------------------------------------------------------------------------
# Case 4: a project playbook with a genuine schema error is skipped with the same specific
# reason a builtin one would get -- same pipeline, no special-casing
# -----------------------------------------------------------------------------

@test "a project playbook with a genuine schema error is skipped with the same specific reason as a builtin one" {
  write_project_playbook "proj-bad-forward" '{"skill": "beta", "forward_from": "ghost-step"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "proj-bad-forward"'
  assert_output_contains "forward_from' names 'ghost-step'"
  assert_output_contains "which is not an earlier"
}

@test "a project playbook whose id does not match its filename is skipped (same rule as builtin)" {
  mkdir -p "$FIXTURE_ROOT/project/.playbooks"
  cat > "$FIXTURE_ROOT/project/.playbooks/mismatched.json" <<'EOF'
{
  "id": "different-id",
  "name": "Mismatched",
  "description": "id does not match filename",
  "keywords": ["fixture"],
  "examples": ["fixture example"],
  "steps": ["alpha"]
}
EOF

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "different-id"'
  assert_output_contains "does not match its filename"
}

# -----------------------------------------------------------------------------
# Case 5: `lookup <id>` resolves against the merged catalog and includes `source`
# -----------------------------------------------------------------------------

@test "lookup <id> resolves a project-sourced id and includes source: project" {
  write_project_playbook "lookup-proj" '"alpha", "beta"'

  run_lookup "lookup-proj"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "valid"'
  assert_output_contains '"id": "lookup-proj"'
  assert_output_contains '"source": "project"'
}

@test "lookup <id> resolves a builtin-sourced id and includes source: builtin" {
  write_builtin_playbook "lookup-built" '"alpha"'

  run_lookup "lookup-built"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "valid"'
  assert_output_contains '"id": "lookup-built"'
  assert_output_contains '"source": "builtin"'
}

@test "lookup <id> on a colliding id resolves to the surviving builtin entry" {
  write_builtin_playbook "lookup-shared" '"alpha"'
  write_project_playbook "lookup-shared" '"beta"'

  run_lookup "lookup-shared"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "valid"'
  assert_output_contains '"source": "builtin"'
}
