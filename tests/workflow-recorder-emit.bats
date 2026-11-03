#!/usr/bin/env bats
#
# skills/j-workflow-recorder/scripts/emit-workflow.sh — the emission layer (E89, E89_S04_T01).
#
# What this suite pins, and why each one is here rather than left to review:
#
#   1. THE DEFINITION IS VALID BY THE EXISTING VALIDATOR, NOT BY OUR OWN OPINION. Every emitted file is
#      checked by scripts/workflow/validate-workflow.sh in the test itself, independently of the check
#      the script makes, and the script is asserted to invoke that validator rather than carry a copy.
#   2. EXCLUSION WINS OVER RELEVANCE. A step can carry deviation out-of-process AND a relevance body (a
#      detour inside a continuing process, E89_S06_T17). It must be excluded, and the relevance body must
#      not appear ANYWHERE in the emitted file. This is the binding precedence rule; a weaker test (the
#      step's id is absent) would still pass if the body leaked into a neighbour's description.
#   3. A VALIDATION FAILURE LEAVES NOTHING. No file at the destination, no candidate beside it, the
#      recording not cross-linked, and the validator's own text on stderr, with a non-zero exit. Asserted
#      by listing the destination directory including hidden files, not by checking one name.
#   4. THE JUDGMENT IS MADE ONCE AND WRITTEN DOWN. An annotated step type is used verbatim and cannot be
#      silently re-judged; an unannotated one is reported (exit 9), answered through --answer, persisted
#      into the recording through record-answer.sh, and a second emission is byte-identical.
#   5. THE CROSS-LINK RUNS BOTH WAYS in the same pass, and touches nothing below the frontmatter.
#
# Isolation: every test writes only inside $BATS_TEST_TMPDIR. JENGA_PROJECT_ROOT points at a throwaway
# project whose workflow.json moves the workflows directory to an unconventional place, so the suite
# proves the destination is RESOLVED, and never reads or writes this repository's real definitions.
# The validator and schema are the repository's own and are only read.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/emit-workflow.sh"
FILE_SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/recording-file.sh"
ANSWER_SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/record-answer.sh"
CLOSE_SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/close-recording.sh"
VALIDATOR="$REPO_ROOT/scripts/workflow/validate-workflow.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  mkdir -p "$PROJ/project/configs"
  printf '%s\n' '{"paths":{"workflows":"out/defs"}}' > "$PROJ/project/configs/workflow.json"
  DEFS="$PROJ/out/defs"
  REC="$T/ship-the-site_RECORDING.md"
  DEST="$DEFS/ship-the-site.json"

  unset JENGA_WORKFLOWS_TEST_ROOT JENGA_RECORDING_DIR
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_RECORDER_NOW=2026-11-02T01:02:03Z
  export JENGA_RECORDING_STATE_DIR="$T/pointer-state"
  export JENGA_RECORDING_SESSION_ID="emit-suite-$BATS_TEST_NUMBER"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

new_recording() { bash "$FILE_SCRIPT" create "$REC" "ship the site" >/dev/null; }
add_step() { bash "$FILE_SCRIPT" append "$REC" "$1" >/dev/null; }
ann() { bash "$ANSWER_SCRIPT" "$REC" "$1" "$2" "${@:3}" >/dev/null; }
seal() { bash "$CLOSE_SCRIPT" "$REC" >/dev/null 2>&1; }

# A closed, fully step-typed recording of four steps, none of them deviating:
#   step-001 skill   step-002 confirm   step-003 compute   step-004 render
full_recording() {
  new_recording
  add_step "/j-commit commit the staged work"
  add_step "Ask whether the build looks right before shipping"
  add_step "scripts/check-release-ready.sh --strict"
  add_step "templates/report.md"
  ann step-001 step-type skill
  ann step-002 step-type confirm
  ann step-003 step-type compute
  ann step-004 step-type render
  seal
}

emit() { run --separate-stderr bash "$SCRIPT" "$@"; }

step_field() { jq -r --arg id "$1" ".steps[] | select(.id == \$id) | .$2" "$DEST"; }

fm_value() {
  awk -v key="$2:" '
    NR == 1 { next }
    $0 == "---" { exit }
    index($0, key) == 1 { v = substr($0, length(key) + 1); sub(/^[ \t]+/, "", v); print v; exit }
  ' "$1"
}

# Everything after the frontmatter's closing --- (the part an emission must not touch).
body_of() {
  awk '
    NR == 1 { next }
    seen != 1 && $0 == "---" { seen = 1; next }
    seen == 1 { print }
  ' "$1"
}

# Every entry in $1 including hidden ones, one per line, or nothing if it does not exist.
listing() { [ -d "$1" ] && ls -A "$1" || true; }

# ---------------------------------------------------------------------------
# The script itself
# ---------------------------------------------------------------------------

@test "emit-workflow.sh exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the script names no project/.workflows literal and resolves the destination" {
  run grep -F 'project/.workflows' "$SCRIPT"
  [ "$status" -eq 1 ]
  run grep -F 'get workflows' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "no second validator: the existing validate-workflow.sh is the one invoked" {
  run grep -F 'validate-workflow.sh' "$SCRIPT"
  [ "$status" -eq 0 ]
  # Exactly one validator script exists, and the recorder's own scripts directory holds none. Plain filesystem
  # globs rather than git, so the check also holds in a checkout with no .git (the public mirror).
  run bash -c "ls '$REPO_ROOT'/scripts/workflow/*valid*.sh | wc -l | tr -d ' '"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run bash -c "ls '$REPO_ROOT'/skills/j-workflow-recorder/scripts/*valid* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "--help prints usage and exits 0; no arguments is a usage error" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "emit-workflow.sh [--answer <step-id>=<type>]... <recording-path>"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [ "$output" = "" ]
}

@test "a missing recording is exit 3 and an unclosed one is exit 4, with nothing written" {
  emit "$T/nope_RECORDING.md"
  [ "$status" -eq 3 ]
  new_recording
  add_step "/j-commit x"
  ann step-001 step-type skill
  emit "$REC"
  [ "$status" -eq 4 ]
  [ "$output" = "" ]
  [ -z "$(listing "$DEFS")" ]
}

@test "a recording whose name is not <slug>_RECORDING.md is refused (exit 5)" {
  REC="$T/not-a-recording.md"
  new_recording
  add_step "/j-commit x"
  ann step-001 step-type skill
  seal
  emit "$REC"
  [ "$status" -eq 5 ]
  [ -z "$(listing "$DEFS")" ]
}

# ---------------------------------------------------------------------------
# A clean emission
# ---------------------------------------------------------------------------

@test "clean emission: path on stdout and nothing else, file named for its id, in the resolved directory" {
  full_recording
  emit "$REC"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "$DEST" ]
  [ "$stderr" = "" ]
  [ -f "$DEST" ]
  # The directory came from workflow.json's paths.workflows, not from a default.
  [ "$(dirname "$DEST")" = "$PROJ/out/defs" ]
  [ ! -e "$PROJ/project/.workflows" ]
  [ "$(jq -r .id "$DEST")" = "ship-the-site" ]
  [ "$(basename "$DEST" .json)" = "$(jq -r .id "$DEST")" ]
  [ "$(listing "$DEFS")" = "ship-the-site.json" ]
}

@test "clean emission: the id matches the schema's id_pattern and the top-level keys are present" {
  full_recording
  emit "$REC"
  [ "$status" -eq 0 ]
  pattern="$(jq -r .top_level.id_pattern "$REPO_ROOT/templates/workflow-schema.json")"
  printf '%s\n' "$(jq -r .id "$DEST")" | grep -Eq "$pattern"
  [ "$(jq -r .name "$DEST")" = "ship the site" ]
  [ -n "$(jq -r .description "$DEST")" ]
  [ "$(jq '.steps | length' "$DEST")" -eq 4 ]
}

@test "clean emission: step ids match the underscore rule and are unique; types are among the five" {
  full_recording
  emit "$REC"
  [ "$status" -eq 0 ]
  jq -r '.steps[].id' "$DEST" | while IFS= read -r id; do
    printf '%s\n' "$id" | grep -Eq '^[a-z][a-z0-9_]*$'
  done
  [ "$(jq -r '.steps[].id' "$DEST" | sort | uniq -d | wc -l | tr -d ' ')" = "0" ]
  [ "$(jq -r '.steps[].type' "$DEST" | tr '\n' ' ')" = "skill confirm compute render " ]
  [ "$(jq -r '[.steps[].type] | map(select(. as $t | ["skill","playbook","confirm","compute","render"] | index($t) | not)) | length' "$DEST")" = "0" ]
}

@test "clean emission: each type's required fields are filled from the step text" {
  full_recording
  emit "$REC"
  [ "$status" -eq 0 ]
  [ "$(step_field step_001 skill)" = "j.commit" ]
  [ "$(step_field step_001 args.input)" = "commit the staged work" ]
  [ "$(step_field step_002 prompt)" = "Ask whether the build looks right before shipping" ]
  [ "$(step_field step_002 'options | join(",")')" = "Yes,No" ]
  [ "$(step_field step_003 command)" = "scripts/check-release-ready.sh" ]
  [ "$(step_field step_003 'args | join(",")')" = "--strict" ]
  [ "$(step_field step_004 template)" = "templates/report.md" ]
}

@test "schema validation: the emitted file passes the existing validator, run independently here" {
  full_recording
  emit "$REC"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$VALIDATOR" "$DEST"
  [ "$status" -eq 0 ]
  [ "$stderr" = "" ]
}

@test "a playbook step is filled from 'j.playbook <id>'" {
  new_recording
  add_step "/j-playbook release-notes"
  ann step-001 step-type playbook
  seal
  emit "$REC"
  [ "$status" -eq 0 ]
  [ "$(step_field step_001 playbook)" = "release-notes" ]
  run bash "$VALIDATOR" "$DEST"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Exclusion and relevance
# ---------------------------------------------------------------------------

@test "exclusion: a step confirmed out-of-process is absent, and was never asked for a type" {
  new_recording
  add_step "/j-commit commit the staged work"
  add_step "By the way, what is the weather like"
  add_step "Ask whether the build looks right"
  ann step-001 step-type skill
  ann step-002 deviation out-of-process
  ann step-003 step-type confirm
  seal
  emit "$REC"
  [ "$status" -eq 0 ]
  [ "$(jq '.steps | length' "$DEST")" -eq 2 ]
  [ "$(jq -r '.steps[].id' "$DEST" | tr '\n' ' ')" = "step_001 step_003 " ]
  run grep -F "weather" "$DEST"
  [ "$status" -eq 1 ]
}

@test "an in-process verdict is the same as no deviation annotation at all" {
  new_recording
  add_step "/j-commit commit the staged work"
  ann step-001 step-type skill
  ann step-001 deviation in-process
  seal
  emit "$REC"
  [ "$status" -eq 0 ]
  [ "$(jq '.steps | length' "$DEST")" -eq 1 ]
}

@test "relevance: a stated relevance becomes the step's description" {
  new_recording
  add_step "/j-commit commit the staged work"
  add_step "Ask whether the build looks right"
  ann step-001 step-type skill
  ann step-001 relevance "Records the work so the release has something to ship"
  ann step-002 step-type confirm
  seal
  emit "$REC"
  [ "$status" -eq 0 ]
  [ "$(step_field step_001 description)" = "Records the work so the release has something to ship" ]
  # Without a stated relevance the description is the recorded text, verbatim.
  [ "$(step_field step_002 description)" = "Ask whether the build looks right" ]
}

@test "relevance: a multi-line relevance body round trips into the description" {
  new_recording
  add_step "/j-commit commit the staged work"
  ann step-001 step-type skill
  printf 'First line\nSecond line\n' | bash "$ANSWER_SCRIPT" "$REC" step-001 relevance - >/dev/null
  seal
  emit "$REC"
  [ "$status" -eq 0 ]
  [ "$(step_field step_001 description)" = "$(printf 'First line\nSecond line')" ]
}

@test "precedence: out-of-process wins over a relevance body, and that body is emitted nowhere" {
  new_recording
  add_step "/j-commit commit the staged work"
  add_step "Check the weather before deploying"
  add_step "Ask whether the build looks right"
  ann step-001 step-type skill
  ann step-002 deviation out-of-process
  ann step-002 relevance "DETOUR-RATIONALE-MUST-NOT-LEAK"
  ann step-003 step-type confirm
  seal
  emit "$REC"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.steps[].id' "$DEST" | tr '\n' ' ')" = "step_001 step_003 " ]
  run grep -F "DETOUR-RATIONALE-MUST-NOT-LEAK" "$DEST"
  [ "$status" -eq 1 ]
  run grep -F "Check the weather" "$DEST"
  [ "$status" -eq 1 ]
}

@test "precedence: an in-process step with a relevance body IS emitted with that body" {
  new_recording
  add_step "/j-commit commit the staged work"
  ann step-001 step-type skill
  ann step-001 deviation in-process
  ann step-001 relevance "IN-PROCESS-RATIONALE"
  seal
  emit "$REC"
  [ "$status" -eq 0 ]
  [ "$(step_field step_001 description)" = "IN-PROCESS-RATIONALE" ]
}

# ---------------------------------------------------------------------------
# The judgment: persisted, verbatim, asked once
# ---------------------------------------------------------------------------

@test "a persisted step-type annotation is used verbatim: it is not re-judged from the text" {
  new_recording
  # The text looks like a skill invocation; the persisted judgment says confirm, and wins.
  add_step "/j-commit are you sure"
  ann step-001 step-type confirm
  seal
  emit "$REC"
  [ "$status" -eq 0 ]
  [ "$(step_field step_001 type)" = "confirm" ]
  [ "$(step_field step_001 prompt)" = "/j-commit are you sure" ]
}

@test "an unannotated included step is reported on stdout with exit 9 and nothing is written" {
  new_recording
  add_step "/j-commit commit the staged work"
  add_step "Ask whether the build looks right"
  ann step-001 step-type skill
  seal
  before="$(cat "$REC")"
  emit "$REC"
  [ "$status" -eq 9 ]
  [ "$output" = "$(printf 'step-002\tAsk whether the build looks right')" ]
  assert_contains "$stderr" "--answer"
  [ -z "$(listing "$DEFS")" ]
  [ "$(cat "$REC")" = "$before" ]
}

@test "--answer persists the judgment into the recording before emission continues" {
  new_recording
  add_step "/j-commit commit the staged work"
  add_step "Ask whether the build looks right"
  seal
  emit --answer step-001=skill --answer step-002=confirm "$REC"
  [ "$status" -eq 0 ]
  [ "$(bash "$ANSWER_SCRIPT" --value "$REC" step-001 step-type)" = "skill" ]
  [ "$(bash "$ANSWER_SCRIPT" --value "$REC" step-002 step-type)" = "confirm" ]
  [ "$(step_field step_002 type)" = "confirm" ]
}

@test "--answer given for only some steps persists those, then asks for the rest (exit 9)" {
  new_recording
  add_step "/j-commit commit the staged work"
  add_step "Ask whether the build looks right"
  seal
  emit --answer step-001=skill "$REC"
  [ "$status" -eq 9 ]
  [ "$(bash "$ANSWER_SCRIPT" --value "$REC" step-001 step-type)" = "skill" ]
  [ -z "$(listing "$DEFS")" ]
  # The remaining answer completes it, and the first is not asked for again.
  emit --answer step-002=confirm "$REC"
  [ "$status" -eq 0 ]
}

@test "--answer is refused, with nothing written, for an unknown step, a bad type, an excluded step or an annotated step" {
  new_recording
  add_step "/j-commit commit the staged work"
  add_step "Check the weather"
  add_step "Ask whether the build looks right"
  ann step-002 deviation out-of-process
  ann step-003 step-type confirm
  seal
  before="$(cat "$REC")"

  emit --answer step-009=skill "$REC"
  [ "$status" -eq 2 ]
  emit --answer step-001=banana "$REC"
  [ "$status" -eq 2 ]
  emit --answer step-002=skill "$REC"
  [ "$status" -eq 2 ]
  emit --answer step-003=skill "$REC"
  [ "$status" -eq 2 ]
  emit --answer step-001 "$REC"
  [ "$status" -eq 2 ]

  [ "$(cat "$REC")" = "$before" ]
  [ -z "$(listing "$DEFS")" ]
}

@test "a judged type its text cannot fill is exit 10 naming the step, with nothing written" {
  new_recording
  add_step "Think about the release for a moment"
  seal
  emit --answer step-001=compute "$REC"
  [ "$status" -eq 10 ]
  assert_contains "$stderr" "step-001"
  assert_contains "$stderr" "--replace"
  [ -z "$(listing "$DEFS")" ]
  # The judgment itself was persisted (it is the Scrum Master's); changing it is deliberate.
  [ "$(bash "$ANSWER_SCRIPT" --value "$REC" step-001 step-type)" = "compute" ]
}

@test "a compute step may not name an absolute or parent-relative path" {
  new_recording
  add_step "../escape/run.sh now"
  add_step "/etc/passwd"
  seal
  emit --answer step-001=compute --answer step-002=compute "$REC"
  [ "$status" -eq 10 ]
  assert_contains "$stderr" "step-001"
  assert_contains "$stderr" "step-002"
  [ -z "$(listing "$DEFS")" ]
}

# ---------------------------------------------------------------------------
# Determinism
# ---------------------------------------------------------------------------

@test "emitting twice from the same fully-annotated recording produces byte-identical JSON" {
  full_recording
  emit "$REC"
  [ "$status" -eq 0 ]
  cp "$DEST" "$T/first.json"
  cp "$REC" "$T/first.rec"
  emit "$REC"
  [ "$status" -eq 0 ]
  cmp "$T/first.json" "$DEST"
  # The cross-linked recording is a fixed point as well.
  cmp "$T/first.rec" "$REC"
  [ "$(listing "$DEFS")" = "ship-the-site.json" ]
}

@test "a re-emission after answering through --answer is byte-identical to the next plain emission" {
  new_recording
  add_step "/j-commit commit the staged work"
  add_step "Ask whether the build looks right"
  seal
  emit --answer step-001=skill --answer step-002=confirm "$REC"
  [ "$status" -eq 0 ]
  cp "$DEST" "$T/first.json"
  emit "$REC"
  [ "$status" -eq 0 ]
  cmp "$T/first.json" "$DEST"
}

# ---------------------------------------------------------------------------
# The cross-link, both ways
# ---------------------------------------------------------------------------

@test "cross-link: the recording names the workflow id and the definition names the recording" {
  full_recording
  emit "$REC"
  [ "$status" -eq 0 ]
  [ "$(fm_value "$REC" emitted_workflow)" = "ship-the-site" ]
  [ "$(jq -r .source_recording "$DEST")" = "ship-the-site_RECORDING.md" ]
  # The name, not a path: nothing machine-specific is committed into the definition.
  run grep -F "$T" "$DEST"
  [ "$status" -eq 1 ]
}

@test "cross-link: only the frontmatter of the recording changes; every step and annotation is byte-identical" {
  full_recording
  body_before="$(body_of "$REC")"
  fm_before="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$REC")"
  emit "$REC"
  [ "$status" -eq 0 ]
  [ "$(body_of "$REC")" = "$body_before" ]
  fm_after="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$REC")"
  [ "$fm_after" = "$(printf '%s\nemitted_workflow: ship-the-site' "$fm_before")" ]
  [ "$(fm_value "$REC" status)" = "closed" ]
}

@test "cross-link: the rewritten recording still accepts annotations and parses" {
  full_recording
  emit "$REC"
  [ "$status" -eq 0 ]
  run bash "$FILE_SCRIPT" steps "$REC"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  # Annotating still works on the cross-linked recording, so the rewrite damaged no marker.
  run bash "$ANSWER_SCRIPT" "$REC" step-001 relevance "added after emission"
  [ "$status" -eq 0 ]
  [ "$(bash "$ANSWER_SCRIPT" --text "$REC" step-001 relevance)" = "added after emission" ]
}

@test "a destination that belongs to another definition is refused (exit 7) and left untouched" {
  full_recording
  mkdir -p "$DEFS"
  printf '%s\n' '{"id":"ship-the-site","name":"someone else","description":"d","steps":[]}' > "$DEST"
  before="$(cat "$DEST")"
  emit "$REC"
  [ "$status" -eq 7 ]
  [ "$(cat "$DEST")" = "$before" ]
  [ -z "$(fm_value "$REC" emitted_workflow)" ]
}

# ---------------------------------------------------------------------------
# A validation failure leaves nothing
# ---------------------------------------------------------------------------

# A confirm prompt carrying a malformed reference: the structural JSON is fine, the validator rejects it.
bad_recording() {
  new_recording
  add_step 'Proceed with ${inputs.Bad} now'
  ann step-001 step-type confirm
  seal
}

@test "failed validation: the validator's own text is printed and the exit code is non-zero" {
  bad_recording
  emit "$REC"
  [ "$status" -eq 8 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "inputs.Bad"
  assert_contains "$stderr" "failed validation"
}

@test "failed validation: nothing at the destination, no candidate left in the directory, recording not cross-linked" {
  bad_recording
  before="$(cat "$REC")"
  emit "$REC"
  [ "$status" -eq 8 ]
  [ ! -e "$DEST" ]
  # The directory this run created is gone again; if it were not, it must hold nothing at all, hidden files included.
  [ -z "$(listing "$DEFS")" ]
  [ "$(cat "$REC")" = "$before" ]
  [ -z "$(fm_value "$REC" emitted_workflow)" ]
  [ -z "$(ls -A "$T" | grep -F '.tmp-' || true)" ]
}

@test "failed validation: an existing directory keeps exactly what it had before" {
  bad_recording
  mkdir -p "$DEFS"
  printf '%s\n' '{"id":"other","name":"n","description":"d","steps":[{"id":"a","type":"confirm","prompt":"p","options":["x"]}]}' > "$DEFS/other.json"
  emit "$REC"
  [ "$status" -eq 8 ]
  [ "$(listing "$DEFS")" = "other.json" ]
}
