#!/usr/bin/env bats
#
# Fixture-based coverage for run-playbook-step.sh's RUNTIME type verification at the
# `advance <state_file> passed "<value>"` chokepoint (E62_S02_T01), which wires E62_S01's registry
# descriptors + `scripts/validate-typed-object.sh` into the point a step's actual output is
# captured.
#
# Fixture-tree convention (same as tests/load-playbooks-type-contract.bats): each case builds its
# own synthetic skills/ tree under $BATS_TEST_TMPDIR and points run-playbook-step.sh at it via
# JENGA_PLAYBOOKS_TEST_ROOT, which this task reuses VERBATIM as the same test-injection override
# load-playbooks.sh already established for "the jenga-agent package root" -- never a second env
# var for the same concept. Because that override redirects PKG_ROOT, each fixture tree carries its
# OWN copies of the real committed `templates/playbook-types.json` and
# `scripts/validate-typed-object.sh`, so these tests exercise the genuine shipped registry and
# validator rather than a hand-written stand-in that could drift from either.
#
# JENGA_PLAYBOOK_RUNS_TEST_ROOT is also exported for the whole suite (same reason
# tests/run-playbook-step-conditionals.bats does it): every `advance ... passed <value>` call
# attempts artifact persistence regardless of what this suite is actually testing, and this keeps
# every test from ever writing into this repository's own real project/logs/.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RPS="$REPO_ROOT/skills/jenga/scripts/run-playbook-step.sh"
REAL_REGISTRY="$REPO_ROOT/templates/playbook-types.json"
REAL_VALIDATOR="$REPO_ROOT/scripts/validate-typed-object.sh"

# Builds a minimal skill directory: FIXTURE_ROOT/skills/<name>/SKILL.md (+ an optional frontmatter
# block -- an `output_types:` declaration -- passed verbatim). Mirrors
# tests/load-playbooks-type-contract.bats's own `write_skill` helper.
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

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-root"
  ARTIFACT_ROOT="$BATS_TEST_TMPDIR/artifact-root"
  mkdir -p "$FIXTURE_ROOT/templates" "$FIXTURE_ROOT/scripts" "$ARTIFACT_ROOT"

  # The fixture tree gets the REAL committed registry and validator, so the vocabulary and
  # semantics under test are the genuinely shipped ones.
  cp "$REAL_REGISTRY" "$FIXTURE_ROOT/templates/playbook-types.json"
  cp "$REAL_VALIDATOR" "$FIXTURE_ROOT/scripts/validate-typed-object.sh"
  chmod +x "$FIXTURE_ROOT/scripts/validate-typed-object.sh"

  export JENGA_PLAYBOOKS_TEST_ROOT="$FIXTURE_ROOT"
  export JENGA_PLAYBOOK_RUNS_TEST_ROOT="$ARTIFACT_ROOT"
}

# Runs `init` once (outside bats' `run`) and captures the STATE_FILE path from stderr.
init_run() {
  local playbook_id="$1" name="$2" steps="$3"
  local stderr_file="$BATS_TEST_TMPDIR/init_stderr_$$_$RANDOM"
  bash "$RPS" init "$playbook_id" "$name" "$steps" >/dev/null 2>"$stderr_file"
  STATE_FILE="$(grep 'STATE_FILE:' "$stderr_file" | sed 's/STATE_FILE: //')"
}

# -----------------------------------------------------------------------------
# Conforming value -- passes straight through
# -----------------------------------------------------------------------------

@test "a value that conforms as given is stored verbatim and advances the chain" {
  write_skill "src-idlist" "output_types: id_list"
  init_run "pb" "PB" "src-idlist,sink"

  # Newline-separated: per_line's regex is checked against each LINE directly, with no comma
  # splitting needed, so this conforms with NO normalization required (unlike a comma-joined
  # single-line value, which needs 'split_on_comma' first -- covered by the normalize test below).
  run bash "$RPS" advance "$STATE_FILE" passed "$(printf 'E01_S02_T03\nE01_S02_T04')"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "step_ready"'
  assert_output_contains '"step": "sink"'

  run bash "$RPS" get-output "$STATE_FILE" src-idlist
  [ "$status" -eq 0 ]
  assert_output_contains '"value": "E01_S02_T03\nE01_S02_T04"'
}

# -----------------------------------------------------------------------------
# Normalize-then-conform
# -----------------------------------------------------------------------------

@test "a value that only conforms after normalize is stored NORMALIZED, and the chain advances" {
  write_skill "src-idlist" "output_types: id_list"
  init_run "pb-norm" "PB Norm" "src-idlist,sink"

  run bash "$RPS" advance "$STATE_FILE" passed "E01_S02_T03 , E01_S02_T04 ,, "
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "step_ready"'

  run bash "$RPS" get-output "$STATE_FILE" src-idlist
  [ "$status" -eq 0 ]
  assert_output_contains '"value": "E01_S02_T03\nE01_S02_T04"'
}

# -----------------------------------------------------------------------------
# Hard failure -- routes through the EXISTING failed/halted path
# -----------------------------------------------------------------------------

@test "a value that is non-conforming even after normalize hard-fails through the existing halted path" {
  write_skill "src-idlist" "output_types: id_list"
  init_run "pb-bad" "PB Bad" "src-idlist,sink"

  run bash "$RPS" advance "$STATE_FILE" passed "prose with no valid ids in it"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "halted"'
  assert_output_contains '"failed_step": "src-idlist"'
  assert_output_contains "does not conform to its declared output_types"
  assert_output_contains "id_list"
  assert_output_contains "prose with no valid ids in it"
  assert_output_contains '"never_run": ["sink"]'
}

@test "a halted type-verification failure rejects a further advance call, same as an explicit 'failed'" {
  write_skill "src-idlist" "output_types: id_list"
  init_run "pb-bad2" "PB Bad2" "src-idlist,sink"
  bash "$RPS" advance "$STATE_FILE" passed "prose with no valid ids" >/dev/null 2>&1

  run bash "$RPS" advance "$STATE_FILE" passed "E01_S02_T03"
  [ "$status" -eq 3 ]
  assert_output_contains "already halted"
}

# -----------------------------------------------------------------------------
# Conditional {when, type} -- conforms if ANY branch accepts it
# -----------------------------------------------------------------------------

@test "a conditional declaration conforms if ANY declared branch accepts the value" {
  write_skill "src-cond" "$(printf 'output_types:\n  - when: some-classifier\n    type: id_list\n  - when: other-classifier\n    type: text')"
  init_run "pb-cond" "PB Cond" "src-cond,sink"

  # Does not conform to id_list, but the second branch is 'text' (verify: null) -- always conforms.
  run bash "$RPS" advance "$STATE_FILE" passed "some free-form prose"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "step_ready"'
}

@test "a conditional declaration fails only when NO declared branch accepts the value" {
  write_skill "src-cond2" "$(printf 'output_types:\n  - when: some-classifier\n    type: id_list\n  - when: other-classifier\n    type: file_list')"
  init_run "pb-cond2" "PB Cond2" "src-cond2,sink"

  run bash "$RPS" advance "$STATE_FILE" passed ""$'\n'"   "
  [ "$status" -eq 0 ]
  # An all-blank value: id_list's per-line check is vacuously true on an empty list after
  # drop_empty (documented KNOWN SEMANTIC EDGE in validate-typed-object.sh), so this actually
  # conforms -- covered here to pin that documented edge down at this chokepoint too.
  assert_output_contains '"status": "step_ready"'
}

@test "a conditional declaration failure note lists every branch checked" {
  # Both branches declare id_list (different 'when' tags) so the failure is reachable at all --
  # id_list is the only registry type whose 'per_line' pattern a plain prose string can actually
  # fail; file_list's pattern ("does not start with whitespace" after trim) accepts almost
  # anything non-blank, so a two-DIFFERENT-type branch set has no value that fails both.
  write_skill "src-cond3" "$(printf 'output_types:\n  - when: a\n    type: id_list\n  - when: b\n    type: id_list')"
  init_run "pb-cond3" "PB Cond3" "src-cond3,sink"

  run bash "$RPS" advance "$STATE_FILE" passed "no valid ids in this prose"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "halted"'
  assert_output_contains "when='a'"
  assert_output_contains "when='b'"
}

# -----------------------------------------------------------------------------
# `text` is a verification no-op -- never fails
# -----------------------------------------------------------------------------

@test "'text' never fails a step, regardless of value" {
  write_skill "src-text" "output_types: text"
  init_run "pb-text" "PB Text" "src-text,sink"

  run bash "$RPS" advance "$STATE_FILE" passed "!!! totally unstructured 12345 prose ???"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "step_ready"'
}

# -----------------------------------------------------------------------------
# No-op cases -- binding backward compatibility
# -----------------------------------------------------------------------------

@test "a step with no declared output_types is completely unaffected" {
  write_skill "src-notypes" ""
  init_run "pb-notypes" "PB No Types" "src-notypes,sink"

  run bash "$RPS" advance "$STATE_FILE" passed "anything goes here, no verification applies"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "step_ready"'
}

@test "a passed outcome with no typed-output value is completely unaffected" {
  write_skill "src-idlist" "output_types: id_list"
  init_run "pb-noval" "PB No Value" "src-idlist,sink"

  run bash "$RPS" advance "$STATE_FILE" passed
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "step_ready"'
}

@test "a step name with no resolvable SKILL.md (synthetic/legacy step) is completely unaffected" {
  init_run "pb-synthetic" "PB Synthetic" "stepA,stepB"

  run bash "$RPS" advance "$STATE_FILE" passed "totally not an id list at all"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "step_ready"'
  assert_output_contains '"step": "stepB"'
}

# -----------------------------------------------------------------------------
# Environment-level failures are NOT conflated with a non-conforming value
# -----------------------------------------------------------------------------

@test "a declared type outside the registry vocabulary is an environment error, not a board halt" {
  write_skill "src-unknown" "output_types: not-a-real-type"
  init_run "pb-unknown" "PB Unknown" "src-unknown,sink"

  run bash "$RPS" advance "$STATE_FILE" passed "some-value"
  [ "$status" -eq 2 ]
  assert_output_contains "environment-level failure"
}
