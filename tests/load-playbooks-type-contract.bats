#!/usr/bin/env bats
#
# Fixture-based coverage for load-playbooks.sh's TWO load-time type-contract checks (E62_S01_T04):
#
#   CHECK 1 -- registry vocabulary: every `output_types`/`input_types` value declared by a skill
#              named in a playbook's flattened step list must be a key in
#              `templates/playbook-types.json`'s `types` map.
#   CHECK 2 -- output/input compatibility under the all-branches rule, on BOTH sides: compatible
#              iff every type the SOURCE could produce is accepted under EVERY CONSUMER branch.
#
# See load-playbooks.sh's own header section "TYPE REGISTRY" for the full contract, including the
# consumer-side dual ratified by this task (2026-09-19) and the binding backward-compatibility
# guarantee for a consumer that declares no `input_types` at all.
#
# Fixture-tree convention (E43_S01_T01, same as tests/load-playbooks-stepobject.bats): every case
# below builds its OWN synthetic skills/ + playbooks/ tree under $BATS_TEST_TMPDIR and points
# load-playbooks.sh at it via JENGA_PLAYBOOKS_TEST_ROOT -- never against this repository's own
# skills/ tree. Because that same override also redirects PKG_ROOT (and therefore the registry
# path), each fixture tree carries its OWN copy of the real committed
# `templates/playbook-types.json` -- so these tests exercise the genuine shipped vocabulary
# (`text`, `id_list`, `file_list`) rather than a hand-written stand-in that could drift from it.
#
# The TWO deliberate real-catalog exceptions are the last two tests, which the task's Acceptance
# Criteria explicitly require: all five committed playbooks must still load with empty stderr, and
# the one live forward edge in the repo must stay compatible.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LOADER="$REPO_ROOT/skills/jenga/scripts/load-playbooks.sh"
REAL_REGISTRY="$REPO_ROOT/templates/playbook-types.json"

# Builds a minimal skill directory: FIXTURE_ROOT/skills/<name>/SKILL.md (+ an optional frontmatter
# block -- an `output_types:`/`input_types:` declaration -- passed verbatim).
write_skill() {
  local name="$1" types_block="${2:-}"
  mkdir -p "$FIXTURE_ROOT/skills/$name"
  {
    printf -- '---\n'
    printf 'name: j.%s\n' "$name"
    printf 'description: fixture skill %s.\n' "$name"
    if [ -n "$types_block" ]; then
      printf '%s\n' "$types_block"
    fi
    printf -- '---\n# %s\n' "$name"
  } > "$FIXTURE_ROOT/skills/$name/SKILL.md"
}

# Writes an executable classifier script at FIXTURE_ROOT/skills/<name>/scripts/<script>.sh, so a
# `{when, type}` branch naming a classifier survives the pre-existing Blocker-1 existence check
# (E53_S03_T04) and actually reaches this task's checks.
write_classifier_script() {
  local name="$1" script="$2"
  mkdir -p "$FIXTURE_ROOT/skills/$name/scripts"
  printf '#!/usr/bin/env bash\necho ok\n' > "$FIXTURE_ROOT/skills/$name/scripts/$script.sh"
}

# Writes a playbook JSON file at FIXTURE_ROOT/skills/jenga/playbooks/<id>.json. $2 is the `steps`
# array body (already JSON-formatted, comma-separated entries).
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
  mkdir -p "$FIXTURE_ROOT/skills/jenga/playbooks" "$FIXTURE_ROOT/templates"

  # The fixture tree gets the REAL committed registry, so the vocabulary under test is the shipped
  # one. JENGA_PLAYBOOKS_TEST_ROOT redirects PKG_ROOT, so this is the file the loader reads.
  cp "$REAL_REGISTRY" "$FIXTURE_ROOT/templates/playbook-types.json"

  # --- sources ---------------------------------------------------------------------------------
  write_skill "src-idlist" "output_types: id_list"
  write_skill "src-text"   "output_types: text"
  # An unknown vocabulary value -- Check 1's reject path.
  write_skill "src-banana" "output_types: banana"
  # A conditional source whose branches produce DIFFERENT types: one accepted by an id_list
  # consumer, one not. Shaped exactly like j.jenga's `{when: <classifier>, type: id_list}`.
  write_classifier_script "src-mixed" "fake-classify"
  write_skill "src-mixed" "$(printf 'output_types:\n  - when: fake-classify\n    type: id_list\n  - when: argument_empty\n    type: text')"
  # A conditional source shaped exactly like j.jenga's real declaration: a single classifier-script
  # branch producing id_list. Must pass with NO special-casing.
  write_classifier_script "src-jenga-shaped" "detect-nl-intent"
  write_skill "src-jenga-shaped" "$(printf 'output_types:\n  - when: detect-nl-intent\n    type: id_list')"

  # --- consumers -------------------------------------------------------------------------------
  write_skill "sink-idlist" "input_types: id_list"
  # Declares NO input_types at all -- the binding backward-compatible case.
  write_skill "sink-none" ""
  # A conditional consumer whose branches AGREE: the intersection is {id_list}.
  write_skill "sink-cond-agree" "$(printf 'input_types:\n  - when: argument_empty\n    type: id_list\n  - when: argument_nonempty\n    type: id_list')"
  # A conditional consumer whose branches DISAGREE: the intersection is EMPTY, so under the
  # ratified dual nothing is compatible with it.
  write_skill "sink-cond-disagree" "$(printf 'input_types:\n  - when: argument_empty\n    type: id_list\n  - when: argument_nonempty\n    type: text')"
}

# -----------------------------------------------------------------------------
# CHECK 1 -- registry vocabulary
# -----------------------------------------------------------------------------

@test "an output_types value absent from the registry rejects the playbook, naming the value" {
  write_playbook "case-unknown-type" '"src-banana"'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-unknown-type"'
  assert_output_contains "declares output_types 'banana'"
  assert_output_contains "not a type in templates/playbook-types.json"
}

@test "an unknown input_types value on a consumer is rejected by the same check" {
  write_skill "sink-banana" "input_types: banana"
  write_playbook "case-unknown-input-type" '"src-idlist", {"skill": "sink-banana", "forward_from": "src-idlist"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-unknown-input-type"'
  assert_output_contains "declares input_types 'banana'"
}

@test "the vocabulary check covers a BARE-STRING step, not only StepObjects and forward sources" {
  # The pre-existing forward_from/conditional loop skips every non-dict step; Check 1 runs in its
  # own loop precisely so a bare-string step like this one is still covered. No forward_from
  # anywhere in this playbook.
  write_playbook "case-bare-string-unknown" '"src-idlist", "src-banana"'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-bare-string-unknown"'
  assert_output_contains "skill 'src-banana' declares output_types 'banana'"
}

@test "the error names the offending branch when the unknown value is in a {when, type} list" {
  write_classifier_script "src-branch-banana" "fake-classify"
  write_skill "src-branch-banana" "$(printf 'output_types:\n  - when: fake-classify\n    type: banana')"
  write_playbook "case-branch-unknown" '"src-branch-banana"'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-branch-unknown"'
  assert_output_contains "(branch when='fake-classify')"
}

@test "the type vocabulary is read from the registry, never hardcoded in the script" {
  # Proves the vocabulary is DATA: adding a type to the fixture's own registry copy makes a value
  # that was rejected a moment ago load cleanly, with no change to the script.
  write_playbook "case-registry-is-data" '"src-banana"'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-registry-is-data"'

  python3 - "$FIXTURE_ROOT/templates/playbook-types.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    registry = json.load(fh)
registry["types"]["banana"] = {"verify": None, "normalize": []}
with open(path, "w") as fh:
    json.dump(registry, fh, indent=2)
PY

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-registry-is-data"'
}

@test "a missing registry file makes the vocabulary check a silent no-op (documented fail-open)" {
  write_playbook "case-no-registry" '"src-banana"'
  rm "$FIXTURE_ROOT/templates/playbook-types.json"

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-no-registry"'
  assert_output_not_contains "not a type in templates/playbook-types.json"
}

# -----------------------------------------------------------------------------
# CHECK 2 -- compatibility under the all-branches rule
# -----------------------------------------------------------------------------

@test "a compatible single-type forward loads (the shape of the repo's one live edge)" {
  write_playbook "case-compatible-single" '"src-idlist", {"skill": "sink-idlist", "forward_from": "src-idlist"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-compatible-single"'
}

@test "an incompatible single-type forward is rejected, naming both types" {
  write_playbook "case-incompatible-single" '"src-text", {"skill": "sink-idlist", "forward_from": "src-text"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-incompatible-single"'
  assert_output_contains "static output_types produces type 'text'"
  assert_output_contains "accepted under all branches: id_list"
}

@test "a source branch producing an unaccepted type is rejected, naming the offending branch" {
  # src-mixed's fake-classify branch produces id_list (accepted); its argument_empty branch
  # produces text (not accepted). ANY branch failing rejects the whole playbook.
  write_playbook "case-incompatible-branch" '"src-mixed", {"skill": "sink-idlist", "forward_from": "src-mixed"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-incompatible-branch"'
  assert_output_contains "output_types branch when='argument_empty' produces type 'text'"
}

@test "a conditional source whose EVERY branch is accepted loads" {
  write_playbook "case-all-branches-ok" '"src-jenga-shaped", {"skill": "sink-idlist", "forward_from": "src-jenga-shaped"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-all-branches-ok"'
}

@test "a j.jenga-shaped conditional declaration passes with no special-casing" {
  # Same declaration shape as skills/jenga/SKILL.md's own `{when: detect-nl-intent, type: id_list}`
  # -- the only conditional declaration in the repo -- used BOTH as a plain step (Check 1) and as a
  # forward source (Check 2). Nothing in the script special-cases it.
  write_playbook "case-jenga-shaped" '"src-jenga-shaped", {"skill": "sink-cond-agree", "forward_from": "src-jenga-shaped"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-jenga-shaped"'
}

# -----------------------------------------------------------------------------
# CHECK 2 -- the CONSUMER side of the all-branches rule (ratified 2026-09-19)
# -----------------------------------------------------------------------------

@test "a conditional consumer whose branches all accept the source type is compatible" {
  write_playbook "case-cond-consumer-agree" '"src-idlist", {"skill": "sink-cond-agree", "forward_from": "src-idlist"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-cond-consumer-agree"'
}

@test "a conditional consumer whose branches disagree accepts nothing (empty intersection)" {
  # The conservative dual: the source type must be accepted under EVERY consumer branch. Branches
  # declaring different types intersect to nothing, so even a source type ONE branch would accept
  # is rejected. This is the intended outcome of the ruling, not an implementation accident.
  write_playbook "case-cond-consumer-disagree" '"src-idlist", {"skill": "sink-cond-disagree", "forward_from": "src-idlist"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-cond-consumer-disagree"'
  assert_output_contains "accepted under all branches: <none>"
}

@test "a malformed input_types entry (missing when or type) rejects the playbook" {
  write_skill "sink-malformed" "$(printf 'input_types:\n  - type: id_list')"
  write_playbook "case-malformed-input" '"src-idlist", {"skill": "sink-malformed", "forward_from": "src-idlist"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-malformed-input"'
  assert_output_contains "malformed input_types entry (missing 'when' or 'type')"
}

# -----------------------------------------------------------------------------
# BACKWARD COMPATIBILITY -- binding
# -----------------------------------------------------------------------------

@test "a consumer declaring NO input_types keeps today's behavior exactly" {
  # src-text's output type is accepted by NO declared input_types in this fixture tree, yet the
  # forward is still allowed: the absence of a declaration is not a violation, and the forward
  # rides on the pre-existing source-declaredness check alone.
  write_playbook "case-no-input-types" '"src-text", {"skill": "sink-none", "forward_from": "src-text"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-no-input-types"'
  assert_output_not_contains "does not accept under every input_types branch"
}

@test "an undeclared-input consumer is NOT treated as a consumer that accepts nothing" {
  # The distinction that makes the guarantee binding: "no declaration" (allow) must never collapse
  # into "an empty accepted set" (reject). If it ever did, this case would fail with the same
  # '<none>' message the disagreeing-branches case produces.
  write_playbook "case-undeclared-not-empty" '"src-idlist", {"skill": "sink-none", "forward_from": "src-idlist"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-undeclared-not-empty"'
  assert_output_not_contains "accepted under all branches: <none>"
}

@test "the source-declaredness check still owns its own rejection, ahead of compatibility" {
  # A source with no output_types at all must still fail with the PRE-EXISTING message, not with a
  # compatibility message -- Check 2 runs after it and never reinterprets that failure.
  write_skill "src-undeclared" ""
  write_playbook "case-source-undeclared" '"src-undeclared", {"skill": "sink-idlist", "forward_from": "src-undeclared"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_not_contains '"id": "case-source-undeclared"'
  assert_output_contains "has no declared output_types in its SKILL.md frontmatter"
}

# -----------------------------------------------------------------------------
# The two real-catalog checks the task's Acceptance Criteria require
# -----------------------------------------------------------------------------

@test "all five committed playbooks still load, with empty stderr" {
  # No fixture override: the real committed builtin + project-local catalog. stderr is captured to
  # its own file rather than merged into $output, so "empty stderr" can be asserted as emptiness
  # rather than as the absence of a substring.
  local stderr_file="$BATS_TEST_TMPDIR/real-catalog.err"
  run bash -c "'$LOADER' 2> '$stderr_file'"
  [ "$status" -eq 0 ]
  [ ! -s "$stderr_file" ]
  assert_output_contains '"id": "board-hygiene"'
  assert_output_contains '"id": "brainstorm-to-mirror"'
  assert_output_contains '"id": "idea-to-committed"'
  assert_output_contains '"id": "understand-then-commit"'
  assert_output_contains '"id": "improve-to-commit"'
}

@test "the repo's one live forward edge (j-reconcile id_list -> j-todo id_list) stays compatible" {
  run bash "$LOADER" lookup board-hygiene
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "valid"'
  assert_output_contains '"forward_from": "j-reconcile"'
}
