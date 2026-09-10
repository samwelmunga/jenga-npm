#!/usr/bin/env bats
#
# Fixture-based coverage for E53_S06 ("`resolve` Transform, Failure Handling, and Direct
# Invocation"): the `resolve` load-time shape/pass-through behavior, the pre-existing
# `resolve`+`playbook` confirmation-gate rejection re-verified against this story's own fixtures
# (E53_S06_T01's third Acceptance Criterion; the load-time rejection itself was implemented by
# E53_S05_T01 -- this file adds no new load-time logic, only verification), and
# `load-playbooks.sh lookup <id>`'s three structured outcomes (E53_S06_T02), including the claim
# that `lookup`'s `valid` output is a drop-in substitute for `match-playbook.sh`'s output when fed
# into `render-playbook-confirmation.sh` (start mode) and `run-playbook-step.sh init`
# (E53_S06_T03's data path).
#
# Fixture-tree convention (E43_S01_T01, following tests/load-playbooks-stepobject.bats and
# tests/load-playbooks-composition.bats precedent): every case builds its OWN synthetic skills/
# and playbooks/ tree under $BATS_TEST_TMPDIR and points load-playbooks.sh at it via
# JENGA_PLAYBOOKS_TEST_ROOT -- never against this repository's own skills/.
#
# -----------------------------------------------------------------------------------------------
# UNRESOLVABLE TRANSFORM HARD-FAIL (OUT OF BATS SCOPE) -- E53_S06_T01's third Acceptance Criterion
# -----------------------------------------------------------------------------------------------
# `resolve`'s actual transform judgment ("can this natural-language instruction cleanly reshape
# this raw value?") is agent-facing LLM-mediated prose living entirely in
# skills/jenga/SKILL.md's Natural-language branch step 5e-ii (E53_S06_T01) -- there is no script
# to invoke here, so this scenario cannot be deterministically scripted under bats (a
# shell/python script cannot exercise LLM judgment). Documented here, per the story's explicit
# requirement, as a fixture-and-expected-behavior note for a manual/agent-driven verification
# pass instead:
#
#   FIXTURE PLAYBOOK (would load successfully -- `resolve`'s runtime behavior is invisible to
#   load-playbooks.sh, only its SHAPE is validated there):
#     {
#       "id": "manual-resolve-hard-fail-check",
#       "name": "Manual resolve hard-fail check",
#       "description": "fixture for manual verification of resolve's hard-fail path",
#       "keywords": ["fixture"], "examples": ["fixture example"],
#       "steps": [
#         "alpha",
#         {"skill": "beta", "forward_from": "alpha",
#          "resolve": "extract the RFC-3339 timestamp from this value"}
#       ]
#     }
#     (where "alpha" is a skill declaring `output_types: text` whose actual output, when run, is
#     something with no plausible timestamp in it at all, e.g. the literal string "no data".)
#
#   EXPECTED BEHAVIOR (per E53_S06_T01's step 5e-ii): the agent driving this playbook must NOT
#   invoke "beta" and must NOT guess or pass through "no data" (or any other differently-shaped
#   value) as if it were a timestamp. It must call
#     run-playbook-step.sh advance <state_file> failed "resolve failed on step 'beta': could not
#     apply \"extract the RFC-3339 timestamp from this value\" to raw value no data -- no
#     timestamp is present in the value"
#   (exact wording per E53_S06_T01's own documented format), then report the `halted` result
#   exactly as any other step failure -- `failed_step: "beta"`, `failed_note` containing the raw
#   pre-transform value `no data`, `completed: ["alpha"]`, `never_run` covering anything after
#   "beta". A verification pass should drive this fixture through `/jenga`'s natural-language
#   branch (or `j.playbook`) and confirm exactly this halted shape, with no step silently
#   skipped ahead and no guessed value forwarded.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LOADER="$REPO_ROOT/skills/jenga/scripts/load-playbooks.sh"
RPC="$REPO_ROOT/skills/jenga/scripts/render-playbook-confirmation.sh"
RPS="$REPO_ROOT/skills/jenga/scripts/run-playbook-step.sh"

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
# Case 1: a valid forward_from + resolve step loads successfully, resolve passes through
# -----------------------------------------------------------------------------

@test "a step with forward_from and resolve loads successfully; resolve passes through unchanged" {
  write_playbook "case-valid-resolve" \
    '"alpha", {"skill": "beta", "forward_from": "alpha", "resolve": "pick the first three items"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-valid-resolve"'
  assert_output_contains '"forward_from": "alpha"'
  assert_output_contains '"resolve": "pick the first three items"'
}

# -----------------------------------------------------------------------------
# Case 2: resolve targeting a downstream confirmation gate is rejected at load time
# (re-verifies E53_S05_T01's normalize_step() rejection against this story's own fixture --
# closes E53_S06's second Acceptance Criterion's verification requirement; no new load-time
# logic is added by this task)
# -----------------------------------------------------------------------------

@test "a resolve step targeting a playbook-composition step (confirmation gate) is rejected at load time" {
  write_playbook "case-resolve-gate-target" '"alpha", "beta"'
  write_playbook "case-resolve-gate" \
    '"alpha", {"playbook": "case-resolve-gate-target", "resolve": "pick the first three"}'

  run_loader
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "case-resolve-gate-target"'
  assert_output_not_contains '"id": "case-resolve-gate"'
}

# -----------------------------------------------------------------------------
# Case 3: `lookup <id>`'s three outcomes (E53_S06_T02)
# -----------------------------------------------------------------------------

@test "lookup <id> on a valid id emits {status: valid, playbook: {...}}" {
  write_playbook "case-lookup-valid" '"alpha", "beta"'

  run_lookup "case-lookup-valid"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "valid"'
  assert_output_contains '"id": "case-lookup-valid"'
  assert_output_contains '"steps"'
  assert_output_not_contains '"reason"'
}

@test "lookup <id> on a known-but-invalid id emits {status: invalid, reason: <specific reason>}" {
  write_playbook "case-lookup-invalid" '{"skill": "beta", "forward_from": "ghost-step"}'

  run_lookup "case-lookup-invalid"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "invalid"'
  assert_output_contains "forward_from' names 'ghost-step'"
  assert_output_not_contains '"playbook"'
}

@test "lookup <id> on a nonexistent id emits {status: not_found}, nothing else" {
  run_lookup "case-lookup-totally-nonexistent"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "not_found"'
  assert_output_not_contains '"reason"'
  assert_output_not_contains '"playbook"'
}

@test "lookup with no id argument exits 2 with a usage message" {
  JENGA_PLAYBOOKS_TEST_ROOT="$FIXTURE_ROOT" run bash "$LOADER" lookup
  [ "$status" -eq 2 ]
  assert_output_contains "Usage:"
}

@test "an unrecognized first argument exits 2 with an error message" {
  JENGA_PLAYBOOKS_TEST_ROOT="$FIXTURE_ROOT" run bash "$LOADER" bogus-argument
  [ "$status" -eq 2 ]
  assert_output_contains "unrecognized argument"
}

# -----------------------------------------------------------------------------
# Case 4: lookup's valid output is a drop-in substitute for match-playbook.sh's output when fed
# into render-playbook-confirmation.sh (start mode) and run-playbook-step.sh init (E53_S06_T03)
# -----------------------------------------------------------------------------

@test "lookup's valid output feeds render-playbook-confirmation.sh (start mode) with no schema mismatch" {
  write_playbook "case-lookup-driveable" '"alpha", "beta"'

  run_lookup "case-lookup-driveable"
  [ "$status" -eq 0 ]
  local lookup_json="$output"

  # Extract id/name/comma-separated-steps exactly as skills/playbook/SKILL.md's step 1/2 would.
  local playbook_id name steps_csv
  playbook_id="$(printf '%s' "$lookup_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['playbook']['id'])")"
  name="$(printf '%s' "$lookup_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['playbook']['name'])")"
  steps_csv="$(printf '%s' "$lookup_json" | python3 -c "
import json, sys
pb = json.load(sys.stdin)['playbook']
names = [s if isinstance(s, str) else s.get('skill', '') for s in pb['steps']]
print(','.join(names))
")"

  run bash "$RPC" "$playbook_id" "$name" "$steps_csv"
  [ "$status" -eq 0 ]
  assert_output_contains "$playbook_id"
  assert_output_contains "1. alpha"
  assert_output_contains "2. beta"
}

@test "lookup's valid output feeds run-playbook-step.sh init with no schema mismatch" {
  write_playbook "case-lookup-driveable-init" '"alpha", "beta"'

  run_lookup "case-lookup-driveable-init"
  [ "$status" -eq 0 ]
  local lookup_json="$output"

  local playbook_id name steps_csv
  playbook_id="$(printf '%s' "$lookup_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['playbook']['id'])")"
  name="$(printf '%s' "$lookup_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['playbook']['name'])")"
  steps_csv="$(printf '%s' "$lookup_json" | python3 -c "
import json, sys
pb = json.load(sys.stdin)['playbook']
names = [s if isinstance(s, str) else s.get('skill', '') for s in pb['steps']]
print(','.join(names))
")"

  run bash "$RPS" init "$playbook_id" "$name" "$steps_csv"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "step_ready"'
  assert_output_contains '"step": "alpha"'
}

@test "lookup's valid playbook object has the same steps shape as the equivalent full-catalog entry" {
  write_playbook "case-lookup-vs-catalog" '"alpha", {"skill": "beta", "forward_from": "alpha"}'

  run_lookup "case-lookup-vs-catalog"
  [ "$status" -eq 0 ]
  local lookup_steps
  lookup_steps="$(printf '%s' "$output" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['playbook']['steps'], sort_keys=True))")"

  run_loader
  [ "$status" -eq 0 ]
  local catalog_steps
  catalog_steps="$(printf '%s' "$output" | python3 -c "
import json, sys
catalog = json.load(sys.stdin)
entry = next(e for e in catalog if e['id'] == 'case-lookup-vs-catalog')
print(json.dumps(entry['steps'], sort_keys=True))
")"

  [ "$lookup_steps" = "$catalog_steps" ]
}
