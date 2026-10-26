#!/usr/bin/env bats
#
# E80_S03_T06: scripts/workflow/step-confirm.sh - the executor for a workflow `confirm` step. `start` renders the
# question and persists a pending gate in the run state, `reply` consumes the user's answer, `status` reads the gate.
#
# Every test builds its own throwaway working-file tree under $BATS_TEST_TMPDIR, selects it with
# JENGA_PROJECT_ROOT, writes a fixture definition into <tree>/.workflows/ and starts a real run with run-state.sh,
# so the repository's own runs directory is never read or written. step-state.sh and resolve-refs.sh are the real
# ones.
#
# Mirror safety: depends only on scripts/workflow/*.sh, scripts/*.sh, templates/ and fixtures it builds.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/step-confirm.sh"
STEP_STATE="$REPO_ROOT/scripts/workflow/step-state.sh"
RUN_STATE="$REPO_ROOT/scripts/workflow/run-state.sh"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS JENGA_WORKFLOWS_TEST_ROOT
  mkdir -p "$BATS_TEST_TMPDIR/anchor/project/configs" "$BATS_TEST_TMPDIR/anchor/project/.workflows"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/anchor/project/configs/workflow.json"
  ANCHOR="$(cd "$BATS_TEST_TMPDIR/anchor" && pwd)"
  RUNS="$ANCHOR/project/data/workflow-runs"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  cd "$BATS_TEST_TMPDIR" || return 1
  cat > "$ANCHOR/project/.workflows/cf.json" <<'JSON'
{
  "id": "cf",
  "name": "Confirm fixture",
  "description": "Fixture.",
  "inputs": [{"name": "scope", "default": "E80"}],
  "steps": [
    {"id": "survey", "type": "skill", "skill": "j.status",
     "outputs": [{"name": "items", "kind": "data", "type": "text"}]},
    {"id": "ask", "type": "confirm", "prompt": "Save ${inputs.scope}?", "options": ["Save", "Skip"]},
    {"id": "ask_own", "type": "confirm", "prompt": "Pick one", "options": ["Alpha", "Other, please say"]},
    {"id": "ask_ref", "type": "confirm", "prompt": "Items: ${steps.survey.outputs.items}", "options": ["Go"]},
    {"id": "ask_two", "type": "confirm", "prompt": "Second?", "options": ["Yes", "No"]},
    {"id": "after", "type": "skill", "skill": "j.status"}
  ]
}
JSON
  RUN="$(bash "$RUN_STATE" start cf)" || return 1
}

# sc <args...>: runs the script with stdout ($output) and stderr ($stderr) captured separately.
sc() {
  run --separate-stderr bash "$SCRIPT" "$@"
}

# snap: a checksum of the current run's state file, to prove a command left it byte-identical.
snap() {
  cksum < "$RUNS/$RUN.json"
}

# state_is <jq filter>: the current run's state satisfies the filter.
state_is() {
  jq -e "$1" "$RUNS/$RUN.json" >/dev/null
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

@test "header documents the start, reply and status modes and exit codes 0 to 5" {
  local header code word
  header=$(sed -n '1,/^set -u$/p' "$SCRIPT")
  for word in 'step-confirm.sh start <run_id> <step_id>' 'step-confirm.sh reply <run_id> <step_id>' 'step-confirm.sh status <run_id>' \
              awaiting_confirmation set-gate clear-gate 'Other (describe below)' answer; do
    printf '%s\n' "$header" | grep -qF -- "$word" || { echo "header lacks: $word"; return 1; }
  done
  for code in 0 1 2 3 4 5; do
    printf '%s\n' "$header" | grep -Eq "^#   $code  " || { echo "header lacks exit code $code"; return 1; }
  done
}

@test "-h prints usage and exits 0; no arguments and unknown commands are usage errors (exit 2)" {
  sc --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"step-confirm.sh start"* ]]
  sc
  [ "$status" -eq 2 ]
  sc frobnicate "$RUN"
  [ "$status" -eq 2 ]
  sc start "$RUN"
  [ "$status" -eq 2 ]
  sc reply "$RUN" ask
  [ "$status" -eq 2 ]
  sc status
  [ "$status" -eq 2 ]
}

@test "script does not read or write the pre-flight situation marker and names no working-file tree" {
  run grep -n -i -E 'marker|\.?project/' "$SCRIPT"
  # the only hits allowed are comment lines that say it does NOT use the marker
  [ -z "$(printf '%s\n' "$output" | grep -v -E '^([0-9]+:#|$)')" ]
  run grep -n 'checklist' "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "start and reply create no marker file or directory anywhere under the tree" {
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  bash "$SCRIPT" reply "$RUN" ask 1 >/dev/null
  run find "$ANCHOR" -iname '*marker*'
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------

@test "start persists the gate, leaves the run awaiting_confirmation and prints numbered options, free text last" {
  sc start "$RUN" ask
  [ "$status" -eq 0 ]
  [ "$output" = $'Save E80?\n\n1. Save\n2. Skip\n3. Other (describe below)' ]
  state_is '.status == "awaiting_confirmation"'
  state_is '.pending_gate.step_id == "ask"'
  state_is '.pending_gate.gate.step_id == "ask" and .pending_gate.gate.prompt == "Save E80?"'
  state_is '.pending_gate.gate.options == ["Save","Skip","Other (describe below)"]'
  state_is '.pending_gate.gate.rendered == "Save E80?\n\n1. Save\n2. Skip\n3. Other (describe below)"'
  state_is '.history[-1].to == "awaiting_confirmation"'
}

@test "start does not append Other when the options already end with an other/free-text entry" {
  sc start "$RUN" ask_own
  [ "$status" -eq 0 ]
  [ "$output" = $'Pick one\n\n1. Alpha\n2. Other, please say' ]
  state_is '.pending_gate.gate.options == ["Alpha","Other, please say"]'
}

@test "start resolves references in the prompt before rendering" {
  bash "$STEP_STATE" set-output "$RUN" survey items "E80_S01,E80_S02"
  bash "$STEP_STATE" set-step "$RUN" survey completed
  sc start "$RUN" ask_ref
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Items: E80_S01,E80_S02" ]
}

@test "a second start reprints the stored rendering and changes nothing" {
  sc start "$RUN" ask
  [ "$status" -eq 0 ]
  local first="$output" before
  before="$(snap)"
  sc start "$RUN" ask
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  [ "$(snap)" = "$before" ]
}

@test "start refuses a different step while a gate is pending, a non-confirm step, an unknown step, a completed step" {
  local before
  sc start "$RUN" ask
  before="$(snap)"
  sc start "$RUN" ask_two
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"already has a gate pending for step 'ask'"* ]]
  [ "$(snap)" = "$before" ]
  sc reply "$RUN" ask 1
  [ "$status" -eq 0 ]
  before="$(snap)"
  sc start "$RUN" after
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"not a confirm step"* ]]
  sc start "$RUN" nosuchstep
  [ "$status" -eq 2 ]
  sc start "$RUN" ask
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"already completed"* ]]
  [ "$(snap)" = "$before" ]
}

@test "start in a run that is not running is refused and writes nothing" {
  bash "$RUN_STATE" pause "$RUN" >/dev/null
  local before
  before="$(snap)"
  sc start "$RUN" ask
  [ "$status" -eq 1 ]
  [ "$(snap)" = "$before" ]
  state_is 'has("pending_gate") | not'
}

@test "an unresolvable reference in the prompt fails start with exit 2 and writes nothing" {
  local before
  before="$(snap)"
  sc start "$RUN" ask_ref
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(snap)" = "$before" ]
}

@test "start on a missing run is exit 4 and on a corrupt state file is exit 4, nothing created" {
  sc start nosuchrun ask
  [ "$status" -eq 4 ]
  [ ! -e "$RUNS/nosuchrun.json" ]
  printf 'not json' > "$RUNS/$RUN.json"
  sc start "$RUN" ask
  [ "$status" -eq 4 ]
  [ "$(cat "$RUNS/$RUN.json")" = "not json" ]
}

# ---------------------------------------------------------------------------
# reply: valid
# ---------------------------------------------------------------------------

@test "reply with a number records the answer, completes the step, clears the gate and resumes the run" {
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  sc reply "$RUN" ask 2
  [ "$status" -eq 0 ]
  [ "$output" = '{"index":2,"option":"Skip","free_text":false,"text":null,"answer":"Skip"}' ]
  state_is '.status == "running"'
  state_is 'has("pending_gate") | not'
  state_is '(.steps[] | select(.id == "ask")) | .status == "completed" and .outputs.answer == "Skip" and .finished_at != null'
  run bash "$STEP_STATE" get-output "$RUN" ask answer
  [ "$status" -eq 0 ]
  [ "$output" = "Skip" ]
  state_is '.history[-1].to == "running"'
}

@test "reply with the exact text of an option is accepted, and surrounding whitespace is ignored" {
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  sc reply "$RUN" ask "  Save  "
  [ "$status" -eq 0 ]
  [ "$output" = '{"index":1,"option":"Save","free_text":false,"text":null,"answer":"Save"}' ]
  state_is '(.steps[] | select(.id == "ask")) | .status == "completed" and .outputs.answer == "Save"'
}

@test "the next step can start after a reply (run is back to running)" {
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  bash "$SCRIPT" reply "$RUN" ask 1 >/dev/null
  sc start "$RUN" ask_two
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Second?" ]
  state_is '.status == "awaiting_confirmation" and .pending_gate.step_id == "ask_two"'
}

@test "reply with no pending gate, or for a different step than the gate's, is refused (exit 1) and writes nothing" {
  local before
  before="$(snap)"
  sc reply "$RUN" ask 1
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no pending gate"* ]]
  [ "$(snap)" = "$before" ]
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  before="$(snap)"
  sc reply "$RUN" ask_two 1
  [ "$status" -eq 1 ]
  [ "$(snap)" = "$before" ]
}

@test "reply to a paused run is refused (exit 1) and writes nothing" {
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  bash "$RUN_STATE" pause "$RUN" >/dev/null
  local before
  before="$(snap)"
  sc reply "$RUN" ask 1
  [ "$status" -eq 1 ]
  [ "$(snap)" = "$before" ]
}

@test "a reply interrupted before the gate was cleared is finished by repeating it" {
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  # simulate a crash after set-output, set-step and the run transition but before clear-gate
  bash "$STEP_STATE" set-output "$RUN" ask answer Save
  bash "$STEP_STATE" set-step "$RUN" ask completed
  bash "$STEP_STATE" set-run-status "$RUN" running
  sc reply "$RUN" ask 1
  [ "$status" -eq 0 ]
  state_is 'has("pending_gate") | not'
  state_is '.status == "running"'
}

# ---------------------------------------------------------------------------
# reply: invalid
# ---------------------------------------------------------------------------

@test "an invalid reply exits 3, re-prompts with a one-line error and leaves the state file byte-identical" {
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  local before reply
  before="$(snap)"
  cp "$RUNS/$RUN.json" "$BATS_TEST_TMPDIR/before.json"
  for reply in "" "   " "0" "4" "99" "banana" "skip" "1 2" "-1" "1: text" "Save please" "1234567"; do
    sc reply "$RUN" ask "$reply"
    [ "$status" -eq 3 ] || { echo "reply '$reply' exited $status"; return 1; }
    [ -z "$stderr" ]
    [ "${lines[0]%%:*}" = "Invalid reply" ] || { echo "reply '$reply': first line '${lines[0]}'"; return 1; }
    [[ "$output" == *$'\n\nSave E80?\n\n1. Save\n2. Skip\n3. Other (describe below)' ]] || { echo "reply '$reply': no rendering"; return 1; }
    [ "$(snap)" = "$before" ] || { echo "reply '$reply' changed the state"; return 1; }
  done
  cmp "$RUNS/$RUN.json" "$BATS_TEST_TMPDIR/before.json"
  state_is '.status == "awaiting_confirmation" and .pending_gate.step_id == "ask"'
  state_is '(.steps[] | select(.id == "ask")) | .status == "pending" and .outputs == {}'
}

@test "after an invalid reply a valid one still works" {
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  sc reply "$RUN" ask nonsense
  [ "$status" -eq 3 ]
  sc reply "$RUN" ask 1
  [ "$status" -eq 0 ]
  state_is '.status == "running"'
}

# ---------------------------------------------------------------------------
# reply: free text
# ---------------------------------------------------------------------------

@test "a bare free-text number or the bare free-text label re-prompts (exit 3, state untouched)" {
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  local before reply
  before="$(snap)"
  for reply in "3" "3:" "3:   " "Other (describe below)"; do
    sc reply "$RUN" ask "$reply"
    [ "$status" -eq 3 ] || { echo "reply '$reply' exited $status"; return 1; }
    [[ "$output" == "Invalid reply: option 3 takes free text"* ]] || { echo "reply '$reply': $output"; return 1; }
    [ "$(snap)" = "$before" ]
  done
}

@test "a free-text selection with text stores the text as the answer" {
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  sc reply "$RUN" ask "3: it is too late: really"
  [ "$status" -eq 0 ]
  [ "$output" = '{"index":3,"option":"Other (describe below)","free_text":true,"text":"it is too late: really","answer":"it is too late: really"}' ]
  state_is '(.steps[] | select(.id == "ask")) | .status == "completed" and .outputs.answer == "it is too late: really"'
  state_is 'has("pending_gate") | not'
  state_is '.status == "running"'
}

@test "the colon form tolerates spaces and a definition-supplied free-text option works the same" {
  bash "$SCRIPT" start "$RUN" ask_own >/dev/null
  sc reply "$RUN" ask_own "2"
  [ "$status" -eq 3 ]
  sc reply "$RUN" ask_own "2 :   maybe later"
  [ "$status" -eq 0 ]
  [ "$output" = '{"index":2,"option":"Other, please say","free_text":true,"text":"maybe later","answer":"maybe later"}' ]
}

@test "text after a number that is not the free-text option is rejected" {
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  sc reply "$RUN" ask "1: because"
  [ "$status" -eq 3 ]
  [[ "$output" == "Invalid reply: option 1 does not take text"* ]]
}

# ---------------------------------------------------------------------------
# status and persistence across processes
# ---------------------------------------------------------------------------

@test "status prints the gate JSON, and exits 1 when none is pending" {
  sc status "$RUN"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  bash "$SCRIPT" start "$RUN" ask >/dev/null
  sc status "$RUN"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.step_id == "ask" and .gate.options[2] == "Other (describe below)" and (.created_at | type) == "string"' >/dev/null
  bash "$SCRIPT" reply "$RUN" ask 1 >/dev/null
  sc status "$RUN"
  [ "$status" -eq 1 ]
  sc status nosuchrun
  [ "$status" -eq 4 ]
}

@test "the pending gate is read back correctly by a separate process after the starting process has exited" {
  bash -c 'bash "$1" start "$2" ask >/dev/null' _ "$SCRIPT" "$RUN"
  # a second, independent shell process: status, a repeated start, then the reply
  run --separate-stderr bash -c 'bash "$1" status "$2"' _ "$SCRIPT" "$RUN"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.gate.rendered == "Save E80?\n\n1. Save\n2. Skip\n3. Other (describe below)"' >/dev/null
  run --separate-stderr bash -c 'bash "$1" start "$2" ask' _ "$SCRIPT" "$RUN"
  [ "$status" -eq 0 ]
  [ "$output" = $'Save E80?\n\n1. Save\n2. Skip\n3. Other (describe below)' ]
  run --separate-stderr bash -c 'bash "$1" reply "$2" ask "2"' _ "$SCRIPT" "$RUN"
  [ "$status" -eq 0 ]
  [ "$output" = '{"index":2,"option":"Skip","free_text":false,"text":null,"answer":"Skip"}' ]
  run --separate-stderr bash -c 'bash "$1" get-output "$2" ask answer' _ "$STEP_STATE" "$RUN"
  [ "$output" = "Skip" ]
}
