#!/usr/bin/env bats
#
# E80_S01_T09: project/documentation/workflows.md keeps its seven required sections (in order; other sections may be added), and the one complete
# example definition in it (between the workflow-example:begin / :end markers, in a ```json fence) passes
# scripts/workflow/validate-workflow.sh, so the documented format cannot drift from the validator.
#
# Read-only against the repository: the extracted example goes to $BATS_TEST_TMPDIR.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DOC="$REPO_ROOT/project/documentation/workflows.md"
VALIDATOR="$REPO_ROOT/scripts/workflow/validate-workflow.sh"

# extract_example <doc> <out>: writes the fenced JSON between the markers to <out>; fails when it is absent.
extract_example() {
  awk '
    /<!-- workflow-example:begin -->/ { inblock = 1; next }
    /<!-- workflow-example:end -->/   { inblock = 0; next }
    inblock && /^```json[[:space:]]*$/ { infence = 1; next }
    inblock && /^```[[:space:]]*$/     { infence = 0; next }
    inblock && infence                 { print }
  ' "$1" > "$2"
  [ -s "$2" ]
}

@test "the workflows doc exists" {
  [ -f "$DOC" ]
}

@test "the doc has each of the seven required headings, verbatim and exactly once" {
  for h in \
    'Overview' \
    'Definition format' \
    'Validating and loading' \
    'How workflows differ from playbooks' \
    'Non-goals for v1' \
    'How E81, E82 and E83 use this' \
    'Public mirror'; do
    run grep -Fxc "## $h" "$DOC"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
  done
}

@test "the seven required headings appear in the required order (later stories may add other sections)" {
  run grep -E '^## ' "$DOC"
  [ "$status" -eq 0 ]
  required='Overview
Definition format
Validating and loading
How workflows differ from playbooks
Non-goals for v1
How E81, E82 and E83 use this
Public mirror'
  # Keep only the required headings, in document order; extra sections are allowed anywhere.
  found=$(printf '%s\n' "$output" | sed 's/^## //' | grep -Fx -f <(printf '%s\n' "$required"))
  [ "$found" = "$required" ]
}

@test "the example definition is present in the doc" {
  run extract_example "$DOC" "$BATS_TEST_TMPDIR/example.json"
  [ "$status" -eq 0 ]
  run jq -e '.steps | length > 0' "$BATS_TEST_TMPDIR/example.json"
  [ "$status" -eq 0 ]
}

@test "the example definition covers all five step types" {
  extract_example "$DOC" "$BATS_TEST_TMPDIR/example.json"
  run jq -r '[.steps[].type] | unique | join(",")' "$BATS_TEST_TMPDIR/example.json"
  [ "$status" -eq 0 ]
  [ "$output" = "compute,confirm,playbook,render,skill" ]
}

@test "the example definition passes validate-workflow.sh with no output" {
  extract_example "$DOC" "$BATS_TEST_TMPDIR/example.json"
  run bash "$VALIDATOR" "$BATS_TEST_TMPDIR/example.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "negative: extraction fails on a doc with no example, so the check cannot pass by matching nothing" {
  printf '# No example here\n\n## Overview\n' > "$BATS_TEST_TMPDIR/empty.md"
  run extract_example "$BATS_TEST_TMPDIR/empty.md" "$BATS_TEST_TMPDIR/none.json"
  [ "$status" -ne 0 ]
}
