#!/usr/bin/env bats
#
# Structural coverage for E69_S05_T03: the root agent definitions consume the conventions digest and the developer
# carries the explicit-conventions precedence rule.
#
# These are text-level assertions over agents/developer.md, agents/tester.md and agents/scrum-master.md (the
# canonical root files). They prove the wiring is present and that the pre-existing inference sentence no longer
# applies unconditionally; the digest's own behaviour is covered by tests/conventions-digest.bats.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DEV="$REPO_ROOT/agents/developer.md"
TESTER="$REPO_ROOT/agents/tester.md"
SM="$REPO_ROOT/agents/scrum-master.md"

# section_of <file> <heading>: the text from the heading line up to (not including) the next heading of the same level.
section_of() {
  awk -v h="$2" '
    $0 == h { on = 1; print; next }
    on && /^#{1,3} / { exit }
    on { print }
  ' "$1"
}

@test "all three root agent files call scripts/conventions-digest.sh with their own --agent value" {
  run grep -c 'scripts/conventions-digest.sh --agent developer' "$DEV"
  [ "$status" -eq 0 ]
  run grep -c 'scripts/conventions-digest.sh --agent tester' "$TESTER"
  [ "$status" -eq 0 ]
  run grep -c 'scripts/conventions-digest.sh --agent scrum-master' "$SM"
  [ "$status" -eq 0 ]
}

@test "each call uses the consumer-install fallback form so it works from node_modules/@jenga-ai/agent" {
  for f in "$DEV" "$TESTER" "$SM"; do
    run grep -c 'node_modules/@jenga-ai/agent/scripts/conventions-digest.sh' "$f"
    [ "$status" -eq 0 ]
  done
}

@test "developer: explicit conventions beat inference, and the inference rule applies only where nothing is recorded" {
  sec="$(section_of "$DEV" "### Codebase exploration")"
  assert_contains "$sec" "Explicit conventions beat inference"
  assert_contains "$sec" "For every category with no recorded convention"
  assert_contains "$sec" "infer code style and conventions from the existing codebase"
  # the old unconditional sentence is gone: inference is never the first word of the rule any more
  assert_not_contains "$sec" "
Infer code style and conventions from the existing codebase"
}

@test "developer: keeps 'Do not request a style guide from the user'" {
  sec="$(section_of "$DEV" "### Codebase exploration")"
  assert_contains "$sec" "Do not request a style guide from the user"
}

@test "developer: a disagreement is noted in the summary, not overridden" {
  sec="$(section_of "$DEV" "### Codebase exploration")"
  assert_contains "$sec" "follow it anyway and note the disagreement in the execution summary"
}

@test "developer: EST commit naming for board commits is unaffected by a commit-format convention" {
  sec="$(section_of "$DEV" "### Codebase exploration")"
  assert_contains "$sec" "never changes EST commit naming for board commits"
  assert_contains "$sec" "non-board commits only"
  assert_contains "$sec" "task(<E##_S##_T##>):"
}

@test "tester: an advisory convention violation is a remark, never a failure; a confirm item follows checklist semantics" {
  line="$(grep 'Project conventions' "$TESTER" | head -n 1)"
  assert_contains "$line" "violated \`advisory\` convention is a remark"
  assert_contains "$line" "never a \`Failed\`"
  assert_contains "$line" "\`confirm\` machine item follows the existing checklist semantics"
  assert_contains "$line" "\`testing\`"
  assert_contains "$line" "\`formatting-linting\`"
}

@test "scrum-master: respects documentation-placement, file-layout and branching, and keeps this repo's own rule" {
  line="$(grep 'Respect the project' "$SM" | head -n 1)"
  assert_contains "$line" "documentation-placement"
  assert_contains "$line" "file-layout"
  assert_contains "$line" "branching"
  assert_contains "$line" "not this repository's own rule"
  # the existing internal-docs rule for this repository is still stated
  run grep -c 'maintainer-internal documentation lives under `project/documentation/`' "$SM"
  [ "$status" -eq 0 ]
}

@test "none of the digest wiring names .claude/ or .agents/ as an edit target" {
  for f in "$DEV" "$TESTER" "$SM"; do
    run grep 'conventions-digest' "$f"
    [ "$status" -eq 0 ]
    assert_output_not_contains ".claude/"
    assert_output_not_contains ".agents/"
  done
}

@test "the digest script the agents call exists and is executable at the root path" {
  [ -x "$REPO_ROOT/scripts/conventions-digest.sh" ]
}
