#!/usr/bin/env bats
#
# E80_S03_T08: scripts/workflow/complete-step.sh - how the driving agent reports a step as passed or failed.
# `passed` verifies typed outputs (verify-output.sh), stores them, completes the step and writes a checkpoint when
# the step has `checkpoint: true`; `failed` marks the step failed and halts the run so next-step.sh returns
# `halted`. A confirm step is refused with a pointer to step-confirm.sh reply.
#
# Every test builds its own throwaway working-file tree under $BATS_TEST_TMPDIR, selects it with
# JENGA_PROJECT_ROOT, writes a fixture definition into <tree>/.workflows/ and starts a real run with run-state.sh,
# so the repository's own runs directory is never read or written. step-state.sh, verify-output.sh (with the real
# playbook type registry) and next-step.sh are the real ones.
#
# Mirror safety: depends only on scripts/workflow/*.sh, scripts/*.sh, templates/ and fixtures it builds.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/complete-step.sh"
STEP_STATE="$REPO_ROOT/scripts/workflow/step-state.sh"
RUN_STATE="$REPO_ROOT/scripts/workflow/run-state.sh"
NEXT_STEP="$REPO_ROOT/scripts/workflow/next-step.sh"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS JENGA_WORKFLOWS_TEST_ROOT JENGA_PLAYBOOKS_TEST_ROOT JENGA_PLAYBOOK_TYPES_FILE
  mkdir -p "$BATS_TEST_TMPDIR/anchor/project/configs" "$BATS_TEST_TMPDIR/anchor/project/.workflows"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/anchor/project/configs/workflow.json"
  ANCHOR="$(cd "$BATS_TEST_TMPDIR/anchor" && pwd)"
  RUNS="$ANCHOR/project/data/workflow-runs"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  cd "$BATS_TEST_TMPDIR" || return 1
  cat > "$ANCHOR/project/.workflows/cs.json" <<'JSON'
{
  "id": "cs",
  "name": "Complete-step fixture",
  "description": "Fixture.",
  "steps": [
    {"id": "one", "type": "skill", "skill": "j.status", "checkpoint": true,
     "outputs": [{"name": "ids", "kind": "data", "type": "id_list"}]},
    {"id": "plain", "type": "skill", "skill": "j.status"},
    {"id": "multi", "type": "skill", "skill": "j.status",
     "outputs": [{"name": "items", "kind": "data", "type": "id_list"}, {"name": "summary", "kind": "data", "type": "text"}]},
    {"id": "text", "type": "skill", "skill": "j.status",
     "outputs": [{"name": "body", "kind": "data", "type": "text"}]},
    {"id": "gate", "type": "confirm", "prompt": "Go on?", "options": ["Yes", "No"]},
    {"id": "last", "type": "skill", "skill": "j.status"}
  ]
}
JSON
  RUN="$(bash "$RUN_STATE" start cs)" || return 1
}

# cs <args...>: runs the script with stdout ($output) and stderr ($stderr) captured separately.
cs() {
  run --separate-stderr bash "$SCRIPT" "$@"
}

# begin <step>: puts a step in_progress, as next-step.sh does when it hands the step out.
begin() {
  bash "$STEP_STATE" set-step "$RUN" "$1" in_progress
}

# snap: a checksum of the current run's state file, to prove a command left it byte-identical.
snap() {
  cksum < "$RUNS/$RUN.json"
}

# state_is <jq filter>: the current run's state satisfies the filter.
state_is() {
  jq -e "$1" "$RUNS/$RUN.json" >/dev/null
}

# sstatus <step>: the status of a step.
sstatus() {
  jq -r --arg s "$1" '.steps[] | select(.id == $s) | .status' "$RUNS/$RUN.json"
}

# ---------------------------------------------------------------------------
# shape
# ---------------------------------------------------------------------------

@test "script exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "header documents arguments, output shapes and the exit codes 0 to 5" {
  local header word
  header=$(sed -n '1,/^set -u$/p' "$SCRIPT")
  for word in 'complete-step.sh <run_id> <step_id> passed' 'complete-step.sh <run_id> <step_id> failed' \
              '"status": "completed"' '"status": "halted"' 'checkpoint' 'step-confirm.sh reply' 'verify-output.sh' \
              'EXIT CODES' '  0  ' '  1  ' '  2  ' '  3  ' '  4  ' '  5  '; do
    printf '%s\n' "$header" | grep -qF -- "$word" || { echo "header lacks: $word"; return 1; }
  done
}

@test "--help prints the usage on stdout and exits 0" {
  cs --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'complete-step.sh <run_id> <step_id> passed'
}

@test "the script does not touch the pre-flight situation marker" {
  run bash -c "grep -v -E '^[[:space:]]*#' '$SCRIPT' | grep -c 'checklist-marker'"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# passed
# ---------------------------------------------------------------------------

@test "passed with a conforming value completes the step, stores the normalised output and writes the checkpoint" {
  begin one
  cs "$RUN" one passed "E80_S03_T01, E80_S03_T02"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .)" = '{"status":"completed","step_id":"one","checkpoint":true}' ]
  [ "$(sstatus one)" = "completed" ]
  state_is '.last_checkpoint == "one"'
  state_is '.steps[0].outputs.ids == "E80_S03_T01\nE80_S03_T02"'
  state_is '.steps[0].finished_at != null'
}

@test "passed advances: next-step.sh returns the following step" {
  run bash "$NEXT_STEP" "$RUN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "one" ]
  cs "$RUN" one passed "E80_S03_T01"
  [ "$status" -eq 0 ]
  run bash "$NEXT_STEP" "$RUN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .signal)" = "step" ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "plain" ]
}

@test "a step without checkpoint: true writes no checkpoint and reports checkpoint false" {
  begin plain
  cs "$RUN" plain passed
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .)" = '{"status":"completed","step_id":"plain","checkpoint":false}' ]
  [ "$(sstatus plain)" = "completed" ]
  state_is '.last_checkpoint == null'
}

@test "a step with no declared outputs stores nothing and ignores a supplied value with a stderr note" {
  begin plain
  cs "$RUN" plain passed "stray value"
  [ "$status" -eq 0 ]
  [ "$(sstatus plain)" = "completed" ]
  state_is '.steps[1].outputs == {}'
  printf '%s\n' "$stderr" | grep -qi 'declares no outputs'
}

@test "passed with a value that violates the declared type exits 1, names the failing rule and changes nothing" {
  begin one
  local before
  before=$(snap)
  cs "$RUN" one passed "not-an-id"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "per_line"
  printf '%s\n' "$stderr" | grep -q "'ids'"
  [ "$output" = "" ]
  [ "$(sstatus one)" = "in_progress" ]
  state_is '.steps[0].outputs == {}'
  state_is '.last_checkpoint == null'
  [ "$(snap)" = "$before" ]
}

@test "after a type violation the agent can retry passed with a corrected value" {
  begin one
  cs "$RUN" one passed "not-an-id"
  [ "$status" -eq 1 ]
  cs "$RUN" one passed "E80"
  [ "$status" -eq 0 ]
  [ "$(sstatus one)" = "completed" ]
  state_is '.steps[0].outputs.ids == "E80"'
}

@test "passed for a step with a declared output but no value exits 1 and changes nothing" {
  begin one
  local before
  before=$(snap)
  cs "$RUN" one passed
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "needs a value"
  [ "$(sstatus one)" = "in_progress" ]
  [ "$(snap)" = "$before" ]
}

@test "an empty value is a value: it is verified against the type rather than treated as missing" {
  begin text
  cs "$RUN" text passed ""
  [ "$status" -eq 0 ]
  state_is '.steps[3].outputs.body == ""'
}

@test "a value with trailing newlines is stored exactly" {
  begin text
  cs "$RUN" text passed $'line one\n\n\nx\n\n'
  [ "$status" -eq 0 ]
  state_is '.steps[3].outputs.body == "line one\n\n\nx\n\n"'
}

@test "a verifier environment failure (exit 2) is relayed as exit 2 and changes nothing" {
  begin one
  mkdir -p "$BATS_TEST_TMPDIR/empty-root"
  export JENGA_PLAYBOOKS_TEST_ROOT="$BATS_TEST_TMPDIR/empty-root"
  local before
  before=$(snap)
  cs "$RUN" one passed "E80"
  [ "$status" -eq 2 ]
  printf '%s\n' "$stderr" | grep -qi 'validator not found'
  [ "$(sstatus one)" = "in_progress" ]
  [ "$(snap)" = "$before" ]
}

# ---------------------------------------------------------------------------
# multi-output steps
# ---------------------------------------------------------------------------

@test "a multi-output step accepts a JSON object and verifies each output against its own type" {
  begin multi
  cs "$RUN" multi passed '{"items": "E80_S03, E80_S04", "summary": "free text, any shape"}'
  [ "$status" -eq 0 ]
  [ "$(sstatus multi)" = "completed" ]
  state_is '.steps[2].outputs.items == "E80_S03\nE80_S04"'
  state_is '.steps[2].outputs.summary == "free text, any shape"'
}

@test "a multi-output step stores a non-string member as compact JSON text" {
  begin multi
  cs "$RUN" multi passed '{"items": "E80", "summary": {"a": [1, 2]}}'
  [ "$status" -eq 0 ]
  state_is '.steps[2].outputs.summary == "{\"a\":[1,2]}"'
}

@test "a multi-output step with one violating output exits 1 naming it and stores none of the outputs" {
  begin multi
  local before
  before=$(snap)
  cs "$RUN" multi passed '{"items": "zzz", "summary": "fine"}'
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "'items'"
  printf '%s\n' "$stderr" | grep -q "per_line"
  [ "$(sstatus multi)" = "in_progress" ]
  [ "$(snap)" = "$before" ]
}

@test "a multi-output step refuses a missing key, an undeclared key and a value that is not an object" {
  begin multi
  local before
  before=$(snap)
  cs "$RUN" multi passed '{"items": "E80"}'
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "lacks the output(s): summary"
  cs "$RUN" multi passed '{"items": "E80", "summary": "s", "extra": "x"}'
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "undeclared output(s): extra"
  cs "$RUN" multi passed "E80"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "JSON object"
  [ "$(snap)" = "$before" ]
}

# ---------------------------------------------------------------------------
# failed
# ---------------------------------------------------------------------------

@test "failed marks the step failed with the note, sets the run failed and prints halted" {
  begin plain
  cs "$RUN" plain failed "the skill errored out"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "halted" ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "plain" ]
  [ "$(printf '%s' "$output" | jq -r .note)" = "the skill errored out" ]
  [ "$(sstatus plain)" = "failed" ]
  state_is '.status == "failed"'
  state_is '.steps[1].note == "the skill errored out"'
  state_is '.history | last | (.from == "running" and .to == "failed")'
}

@test "failed without a note is accepted" {
  begin plain
  cs "$RUN" plain failed
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "halted" ]
  [ "$(sstatus plain)" = "failed" ]
  state_is '.status == "failed"'
}

@test "after failed, next-step.sh returns halted on every call, carrying the failed step and note" {
  begin plain
  cs "$RUN" plain failed "boom"
  [ "$status" -eq 0 ]
  local i
  for i in 1 2 3; do
    run bash "$NEXT_STEP" "$RUN"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r .signal)" = "halted" ]
    [ "$(printf '%s' "$output" | jq -r .payload.failed_step)" = "plain" ]
    [ "$(printf '%s' "$output" | jq -r .payload.note)" = "boom" ]
  done
  state_is '.status == "failed"'
}

@test "complete-step.sh never resets a failed run: the run stays halted until run-state.sh resume" {
  begin plain
  cs "$RUN" plain failed "boom"
  [ "$status" -eq 0 ]
  # a further report is refused and the run stays failed
  cs "$RUN" last passed
  [ "$status" -eq 1 ]
  state_is '.status == "failed"'
  run bash "$NEXT_STEP" "$RUN"
  [ "$(printf '%s' "$output" | jq -r .signal)" = "halted" ]
  # the explicit resume is what lifts the halt
  run bash "$RUN_STATE" resume "$RUN"
  [ "$status" -eq 0 ]
  state_is '.status == "running"'
  run bash "$NEXT_STEP" "$RUN"
  [ "$(printf '%s' "$output" | jq -r .signal)" = "step" ]
}

# ---------------------------------------------------------------------------
# steps that are not in_progress
# ---------------------------------------------------------------------------

@test "a passed or failed report for a pending step is rejected with no state change" {
  local before
  before=$(snap)
  cs "$RUN" one passed "E80"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "not 'in_progress'"
  cs "$RUN" one failed "x"
  [ "$status" -eq 1 ]
  [ "$(snap)" = "$before" ]
}

@test "a passed or failed report for an already completed step is rejected with no state change" {
  begin plain
  cs "$RUN" plain passed
  [ "$status" -eq 0 ]
  local before
  before=$(snap)
  cs "$RUN" plain passed
  [ "$status" -eq 1 ]
  cs "$RUN" plain failed "late"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "'completed'"
  [ "$(snap)" = "$before" ]
}

@test "a report for an already failed step is rejected with no state change" {
  begin plain
  cs "$RUN" plain failed "first"
  [ "$status" -eq 0 ]
  local before
  before=$(snap)
  cs "$RUN" plain failed "second"
  [ "$status" -eq 1 ]
  cs "$RUN" plain passed
  [ "$status" -eq 1 ]
  [ "$(snap)" = "$before" ]
}

# ---------------------------------------------------------------------------
# confirm steps
# ---------------------------------------------------------------------------

@test "a report for a confirm step is rejected with the pointer to step-confirm.sh reply" {
  begin gate
  local before
  before=$(snap)
  cs "$RUN" gate passed
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -qF "step-confirm.sh reply $RUN gate"
  cs "$RUN" gate failed "no"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -qF "step-confirm.sh reply"
  [ "$(snap)" = "$before" ]
}

@test "a confirm step is rejected even when it is still pending" {
  cs "$RUN" gate passed
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -qF "step-confirm.sh reply"
}

# ---------------------------------------------------------------------------
# usage and environment errors
# ---------------------------------------------------------------------------

@test "usage errors exit 2: wrong argument count, an unknown report word, an unknown step" {
  cs "$RUN" one
  [ "$status" -eq 2 ]
  cs "$RUN" one passed a b
  [ "$status" -eq 2 ]
  cs "$RUN" one maybe
  [ "$status" -eq 2 ]
  cs "$RUN" nosuchstep passed
  [ "$status" -eq 2 ]
  printf '%s\n' "$stderr" | grep -q "steps of this run"
}

@test "an unknown run exits 3 and a corrupt state file exits 4 without being modified" {
  cs no-such-run one passed "E80"
  [ "$status" -eq 3 ]
  printf 'not json' > "$RUNS/$RUN.json"
  local before
  before=$(snap)
  cs "$RUN" one passed "E80"
  [ "$status" -eq 4 ]
  [ "$(snap)" = "$before" ]
}
