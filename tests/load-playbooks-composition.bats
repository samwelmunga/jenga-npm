#!/usr/bin/env bats
#
# Fixture-based coverage for load-playbooks.sh's playbook-to-playbook COMPOSITION resolution
# (E53_S05_T01/T02) -- existence, cycle detection, configurable depth limit, recursive flattening
# with _origin_playbook/_origin_depth annotation, duplicate-skill-name collision detection, and
# cross-boundary forward_from transparency.
#
# Fixture-tree convention (E43_S01_T01, following tests/load-playbooks-stepobject.bats E53_S03_T05
# precedent): every case builds its OWN synthetic skills/ and playbooks/ tree under
# $BATS_TEST_TMPDIR and points load-playbooks.sh at it via JENGA_PLAYBOOKS_TEST_ROOT -- never
# against this repository's own skills/, except the one deliberate real-catalog check at the
# bottom that the story's own Definition of Done requires (the committed
# understand-then-ship.json composition, E53_S05_T05).

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

write_playbook() {
  local id="$1" steps_json="$2"
  mkdir -p "$FIXTURE_ROOT/skills/jenga/playbooks"
  cat > "$FIXTURE_ROOT/skills/jenga/playbooks/$id.json" <<EOF
{
  "id": "$id",
  "name": "Fixture $id",
  "description": "fixture playbook $id",
  "keywords": ["fixture"],
  "examples": ["fixture example"],
  "steps": [$steps_json]
}
EOF
}

run_loader() {
  JENGA_PLAYBOOKS_TEST_ROOT="$FIXTURE_ROOT" run bash "$LOADER"
}

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-root"
  mkdir -p "$FIXTURE_ROOT/skills/jenga/playbooks"
  write_skill "alpha" "output_types: text"
  write_skill "beta" ""
  write_skill "gamma" "output_types: text"
  write_skill "delta" ""
}

# -----------------------------------------------------------------------------
# Case 1: a two-level valid composition -- correct flattening + origin annotation
# -----------------------------------------------------------------------------

@test "a two-level valid composition flattens correctly with origin annotation" {
  write_playbook "leaf" '"alpha", "beta"'
  write_playbook "composed" '{"playbook": "leaf"}, "gamma"'

  run_loader
  [ "$status" -eq 0 ]
  # The composed entry exists and its steps are fully flattened + origin-annotated.
  assert_output_contains '"id": "composed"'
  assert_output_contains '"_origin_playbook": "leaf"'
  assert_output_contains '"_origin_depth": 2'
  # gamma is the composed playbook's OWN (depth-1) step -- emitted unchanged, no annotation.
  assert_output_not_contains '"skill": "gamma"'
  # leaf ALSO appears as its own independent, unannotated top-level catalog entry.
  assert_output_contains '"id": "leaf"'
}

@test "a playbook with no composition at all is emitted byte-for-byte unchanged (no annotation)" {
  write_playbook "plain" '"alpha", "beta"'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "plain"'
  assert_output_not_contains '_origin_playbook'
  assert_output_not_contains '_origin_depth'
  assert_output_not_contains '"skill": "alpha"'
}

# -----------------------------------------------------------------------------
# Case 2: cyclic reference -- direct self-reference and mutual cycle
# -----------------------------------------------------------------------------

@test "a direct self-reference is dropped with a cyclic-composition warning, never a crash" {
  write_playbook "selfref" '{"playbook": "selfref"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "selfref"'
  assert_output_contains "cyclic composition reference"
}

@test "a mutual (2-playbook) cycle drops both playbooks with a cyclic-composition warning" {
  write_playbook "cyca" '{"playbook": "cycb"}'
  write_playbook "cycb" '{"playbook": "cyca"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "cyca"'
  assert_output_not_contains '"id": "cycb"'
  assert_output_contains "cyclic composition reference"
}

# -----------------------------------------------------------------------------
# Case 3: depth-limit violation (default limit is 3)
# -----------------------------------------------------------------------------

@test "a composition chain exceeding the default max depth (3) is dropped with a warning" {
  write_playbook "d1" '"alpha"'
  write_playbook "d2" '{"playbook": "d1"}'
  write_playbook "d3" '{"playbook": "d2"}'
  write_playbook "d4" '{"playbook": "d3"}'

  run_loader
  [ "$status" -eq 0 ]
  # d1 (depth 1), d2 (depth 2 when composed), d3 (depth 3 when composed) are all fine on their own.
  assert_output_contains '"id": "d1"'
  assert_output_contains '"id": "d2"'
  assert_output_contains '"id": "d3"'
  # d4 would nest d1's steps at depth 4, exceeding the default limit of 3 -- dropped.
  assert_output_not_contains '"id": "d4"'
  assert_output_contains "exceeds the configured max composition depth"
}

@test "raising max_composition_depth via playbook-config.json allows a deeper chain to load" {
  write_playbook "e1" '"alpha"'
  write_playbook "e2" '{"playbook": "e1"}'
  write_playbook "e3" '{"playbook": "e2"}'
  write_playbook "e4" '{"playbook": "e3"}'
  mkdir -p "$FIXTURE_ROOT/project/configs"
  cat > "$FIXTURE_ROOT/project/configs/playbook-config.json" <<'EOF'
{"config_version": 1, "max_composition_depth": 4}
EOF

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "e4"'
}

# -----------------------------------------------------------------------------
# Case 4: forward_from crossing a composition boundary, BOTH directions
# -----------------------------------------------------------------------------

@test "a nested step can forward_from an OUTER (earlier) step -- both directions in one fixture" {
  write_playbook "nested" '"alpha", {"skill": "beta", "forward_from": "gamma"}'
  write_playbook "outerchain" '"gamma", {"playbook": "nested"}, {"skill": "delta", "forward_from": "alpha"}'

  # "nested" alone is INVALID: its own 2nd step forwards from "gamma", which is not an earlier
  # step within nested's own two-step list.
  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "nested"'

  # But composed inside "outerchain" (gamma first, then nested spliced in, then an outer delta
  # step forwarding from nested's own alpha), BOTH directions resolve with zero special-casing:
  # nested's "beta" step forwards from the OUTER "gamma" step (outer -> nested direction), and the
  # outer trailing "delta" step forwards from nested's own "alpha" step (nested -> outer
  # direction).
  assert_output_contains '"id": "outerchain"'
  assert_output_contains '"forward_from": "gamma"'
  assert_output_contains '"skill": "delta"'
}

@test "an outer step can forward_from a NESTED (earlier, spliced-in) step" {
  write_playbook "inner" '"alpha"'
  write_playbook "outer2" '{"playbook": "inner"}, {"skill": "delta", "forward_from": "alpha"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "outer2"'
  assert_output_contains '"skill": "delta"'
  assert_output_contains '"forward_from": "alpha"'
}

# -----------------------------------------------------------------------------
# Case 5: existence -- a reference to a nonexistent playbook id
# -----------------------------------------------------------------------------

@test "a playbook-type step referencing a nonexistent playbook id is dropped with a warning" {
  write_playbook "ghostref" '{"playbook": "does-not-exist"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "ghostref"'
  assert_output_contains "does not exist"
}

# -----------------------------------------------------------------------------
# Case 6: duplicate skill-name collision after flattening
# -----------------------------------------------------------------------------

@test "a flattened composition with a duplicate skill name is dropped with a warning" {
  write_playbook "dupleaf" '"alpha"'
  write_playbook "dupparent" '{"playbook": "dupleaf"}, "alpha"'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "dupparent"'
  assert_output_contains "duplicate skill name 'alpha'"
}

# -----------------------------------------------------------------------------
# The one deliberate real-catalog check the story's DoD requires: the committed
# understand-then-ship.json (E53_S05_T05) loads cleanly with correct flattening.
# -----------------------------------------------------------------------------

@test "the real committed understand-then-ship.json composes brainstorm-to-mirror cleanly" {
  run bash "$LOADER"
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "understand-then-ship"'
  assert_output_contains '"_origin_playbook": "brainstorm-to-mirror"'
  assert_output_contains '"_origin_depth": 2'
  assert_output_contains '"id": "brainstorm-to-mirror"'
}
