#!/usr/bin/env bats
#
# Fixture-based coverage for load-playbooks.sh's StepObject / type-registry load-time
# validation (E53_S03_T05), added by E53_S03_T01 (StepObject shape + bare-string back-compat),
# E53_S03_T03 (forward_from resolution + resolve/confirmation-gate rejection), and E53_S03_T04
# (Blocker 1's structural {when, type} check for classifier-script sources).
#
# Fixture-tree convention (E43_S01_T01): every case below builds its OWN synthetic skills/
# and playbooks/ tree under $BATS_TEST_TMPDIR and points load-playbooks.sh at it via the
# JENGA_PLAYBOOKS_TEST_ROOT override (E53_S03_T05) -- never against this repository's own
# skills/ tree, and never asserting on the repository root. The ONE deliberate exception is
# the "brainstorm-to-mirror.json still loads unchanged" test near the bottom, which the story's
# own Acceptance Criteria explicitly requires to run against the real committed catalog.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LOADER="$REPO_ROOT/skills/jenga/scripts/load-playbooks.sh"

# Builds a minimal skill directory: FIXTURE_ROOT/skills/<name>/SKILL.md (+ optional
# output_types frontmatter block passed verbatim).
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

# Writes an executable classifier script at FIXTURE_ROOT/skills/<name>/scripts/<script>.sh.
write_classifier_script() {
  local name="$1" script="$2"
  mkdir -p "$FIXTURE_ROOT/skills/$name/scripts"
  printf '#!/usr/bin/env bash\necho ok\n' > "$FIXTURE_ROOT/skills/$name/scripts/$script.sh"
}

# Writes a playbook JSON file at FIXTURE_ROOT/skills/jenga/playbooks/<id>.json. $2 is the
# `steps` array body (already JSON-formatted, comma-separated entries).
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

  # A plain skill with a declared single-static-type output_types (a valid forward source).
  write_skill "alpha" "output_types: text"
  # A plain skill with NO declared output_types (never a valid forward source).
  write_skill "beta" ""
  # A classifier-script skill shaped exactly like j.jenga: output_types is a {when, type} list
  # whose `when` is a classifier-script reference (not a built-in predicate), and the script it
  # references genuinely exists on disk.
  write_skill "jclassifier" "$(printf 'output_types:\n  - when: fake-classify\n    type: id_list')"
  write_classifier_script "jclassifier" "fake-classify"
  # Same shape, but the referenced classifier script does NOT exist -- the Blocker 1 reject path.
  write_skill "jclassifier-bad" "$(printf 'output_types:\n  - when: fake-classify-missing\n    type: id_list')"
}

# -----------------------------------------------------------------------------
# Case 1: a valid StepObject step (accepted)
# -----------------------------------------------------------------------------

@test "a valid StepObject step ({skill: ...} with optional instruction) is accepted" {
  write_playbook "case-valid-stepobject" '"alpha", {"skill": "beta", "instruction": "do the thing"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-valid-stepobject"'
  assert_output_contains '"instruction": "do the thing"'
}

# -----------------------------------------------------------------------------
# Case 2: a bare-string step (still valid, unchanged)
# -----------------------------------------------------------------------------

@test "a bare-string step is still valid and is emitted unchanged as a plain string" {
  write_playbook "case-bare-string" '"alpha", "beta"'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-bare-string"'
  assert_output_contains '"alpha",'
  assert_output_not_contains '"skill": "alpha"'
}

# -----------------------------------------------------------------------------
# Case 3: a skill+playbook conflict on the same step (rejected)
# -----------------------------------------------------------------------------

@test "a step carrying both skill and playbook is rejected with a stderr warning" {
  write_playbook "case-conflict" '{"skill": "alpha", "playbook": "case-bare-string"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-conflict"'
  assert_output_contains "has both 'skill' and 'playbook'"
}

# -----------------------------------------------------------------------------
# Case 4: an unresolvable forward_from (rejected)
# -----------------------------------------------------------------------------

@test "a forward_from naming a step that does not exist earlier in the playbook is rejected" {
  write_playbook "case-unresolvable-forward" '{"skill": "beta", "forward_from": "nonexistent-step"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-unresolvable-forward"'
  assert_output_contains "which is not an earlier skill step in this playbook"
}

# -----------------------------------------------------------------------------
# Case 5: an undeclared-type forward source (rejected)
# -----------------------------------------------------------------------------

@test "a forward_from naming a source with no declared output_types is rejected" {
  write_playbook "case-undeclared-type" '"beta", {"skill": "alpha", "forward_from": "beta"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-undeclared-type"'
  assert_output_contains "which has no declared output_types in its SKILL.md frontmatter"
}

# -----------------------------------------------------------------------------
# Case 6: a resolve step whose target is a downstream confirmation gate (rejected)
# -----------------------------------------------------------------------------

@test "a step with resolve targeting a playbook (a confirmation gate) is rejected" {
  write_playbook "case-resolve-target-ok" '"alpha"'
  write_playbook "case-resolve-confirmation-gate" \
    '"alpha", {"playbook": "case-resolve-target-ok", "resolve": "pick the first three"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-resolve-target-ok"'
  assert_output_not_contains '"id": "case-resolve-confirmation-gate"'
  assert_output_contains "which is always a downstream confirmation gate"
}

# -----------------------------------------------------------------------------
# Case 7: the j.jenga structural {when, type} check specifically (E53_S03_T04)
# -----------------------------------------------------------------------------

@test "Blocker 1 -- a classifier-script forward source whose script exists is accepted" {
  write_playbook "case-classifier-ok" \
    '"jclassifier", {"skill": "beta", "forward_from": "jclassifier"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-classifier-ok"'
}

@test "Blocker 1 -- a classifier-script forward source whose script is missing is rejected" {
  write_playbook "case-classifier-missing-script" \
    '"jclassifier-bad", {"skill": "beta", "forward_from": "jclassifier-bad"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-classifier-missing-script"'
  assert_output_contains "classifier-script when 'fake-classify-missing' but no script exists"
}

@test "Blocker 1 -- the check never invokes the classifier script itself, only checks its existence" {
  # If this loader ever shells out to the classifier script to "check" the structural claim, a
  # script that exits non-zero would surface as a setup failure rather than a clean accept. This
  # guards that the check truly stays load-time/structural, per the story's explicit Blocker 1
  # requirement never to claim knowledge of the runtime classification result.
  write_skill "jclassifier-explodes" "$(printf 'output_types:\n  - when: exploding-classify\n    type: id_list')"
  mkdir -p "$FIXTURE_ROOT/skills/jclassifier-explodes/scripts"
  printf '#!/usr/bin/env bash\nexit 17\n' > "$FIXTURE_ROOT/skills/jclassifier-explodes/scripts/exploding-classify.sh"
  write_playbook "case-classifier-explodes" \
    '"jclassifier-explodes", {"skill": "beta", "forward_from": "jclassifier-explodes"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-classifier-explodes"'
}

# -----------------------------------------------------------------------------
# Sanity: the JENGA_PLAYBOOKS_TEST_ROOT override actually redirects the loader
# -----------------------------------------------------------------------------

@test "JENGA_PLAYBOOKS_TEST_ROOT actually redirects the loader away from the real skills/ tree" {
  # An empty fixture tree (no playbooks beyond what setup() wrote skill dirs for -- no playbook
  # JSON files at all) must never see the real committed brainstorm-to-mirror.json.
  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains 'brainstorm-to-mirror'
}

# -----------------------------------------------------------------------------
# The one deliberate real-catalog check the story's AC requires: the committed
# brainstorm-to-mirror.json (all bare-string steps) still loads unchanged.
#
# NOTE (E53_S05_T05/T06): the real catalog now also contains a SECOND playbook,
# understand-then-ship.json, which composes brainstorm-to-mirror -- so the full catalog output
# legitimately DOES contain '"skill": "brainstorm"' as part of THAT OTHER entry's flattened,
# origin-annotated steps (depth > 1 steps are annotated objects by design, see
# load-playbooks.sh's header "COMPOSITION RESOLUTION"). A whole-output substring check can no
# longer distinguish "brainstorm-to-mirror's own bare-string steps" from "understand-then-ship's
# composed copy of the same skill name" -- so this assertion is scoped to brainstorm-to-mirror's
# OWN catalog entry specifically, via a small JSON-parsing check, rather than a blanket substring
# search over the entire multi-playbook catalog.
# -----------------------------------------------------------------------------

@test "the real committed brainstorm-to-mirror.json still loads unchanged (no fixture override)" {
  run bash "$LOADER"
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "brainstorm-to-mirror"'
  assert_output_contains '"steps": ['
  assert_output_contains '"brainstorm",'
  assert_output_contains '"mirror-public"'

  # Bare-string steps in brainstorm-to-mirror's OWN entry must stay bare strings -- never
  # rewritten into {"skill": "..."} objects. Scoped to that one entry (see NOTE above). Written
  # to a temp file first, rather than interpolated into a python -c string, to avoid any shell/
  # JSON quoting hazard.
  CATALOG_FILE="$BATS_TEST_TMPDIR/real_catalog_$$.json"
  printf '%s' "$output" > "$CATALOG_FILE"
  run python3 -c "
import json
with open('$CATALOG_FILE', encoding='utf-8') as f:
    catalog = json.load(f)
entry = next(pb for pb in catalog if pb['id'] == 'brainstorm-to-mirror')
assert all(isinstance(s, str) for s in entry['steps']), entry['steps']
print('all bare strings')
"
  [ "$status" -eq 0 ]
  assert_output_contains "all bare strings"
}
