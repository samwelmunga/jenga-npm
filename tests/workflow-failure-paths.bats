#!/usr/bin/env bats
#
# E80_S06_T06: failure paths of a workflow run, end to end, on the all-step-types fixture (E80_S06_T03).
#
#   1. a failing compute step halts the run; earlier steps stay completed; next-step.sh refuses to advance
#   2. after the fix, a resume from a new process continues at the failed step, not at the start
#   3. a changed definition makes resume refuse (exit 6, state file byte-identical); the override flag is recorded
#   4. an output that violates its declared id_list type fails the step with the rule named
#   5. a compute command that escapes the allow-listed roots is rejected before anything runs
#
# Every script call goes through wf_fresh (one `env -i` process, its own session id), against a throwaway tree under
# $BATS_TEST_TMPDIR. The repository is only read. The compute stub appends to $PROJ/wf-count.log, which is how the
# tests prove which steps really ran.
#
# Assertions use the helpers from helpers/assertions (a bare double-bracket test is inert under bats).
# Mirror safety: depends on tests/helpers/workflow-fixture.bash, its fixtures and scripts/workflow/*.sh only; the
# helper skips, naming the file, when one is absent.

bats_require_minimum_version 1.5.0

load helpers/assertions
load helpers/workflow-fixture

setup() { wf_setup; }

# The state file of run $1.
state_file() { printf '%s\n' "$PROJ/project/data/workflow-runs/$1.json"; }

# jq filter $2 over the state file of run $1 (plain output).
st() { jq -r "$2" "$(state_file "$1")"; }

# How many times the compute stub ran with label $1 (0 when the log does not exist).
count_of() {
  if [ -f "$PROJ/wf-count.log" ]; then
    grep -c -x -F "$1" "$PROJ/wf-count.log" || true
  else
    echo 0
  fi
}

# Checksum of a file's bytes.
sum_of() { cksum < "$1"; }

# Every JSON value on stdout of the last `run`, as the signal field.
signal_of() { printf '%s' "$output" | jq -r .signal; }

# Replaces the installed definition with jq filter $1 applied to it.
edit_definition() {
  local def="$PROJ/project/.workflows/all-step-types.json"
  jq "$1" "$def" > "$def.new" && mv "$def.new" "$def"
}

# Writes an executable compute stub $1 under the workflow scripts directory; its body is $2.
make_stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$PROJ/project/.workflows/scripts/$1"
  chmod +x "$PROJ/project/.workflows/scripts/$1"
}

# Starts a run and drives it past prep (auto), ask_skill, gate and run_playbook, leaving the next next-step.sh call
# to execute derive. Sets RUN.
drive_to_derive() {
  RUN="$(wf_start)"
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  [ "$(signal_of)" = "step" ]
  run wf_complete "$RUN" ask_skill passed
  [ "$status" -eq 0 ]
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  [ "$(signal_of)" = "step" ]
  run wf_reply "$RUN" gate 1
  [ "$status" -eq 0 ]
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "run_playbook" ]
  run wf_complete "$RUN" run_playbook passed
  [ "$status" -eq 0 ]
}

@test "1. a failing compute step fails the step and the run, keeps earlier steps, and next-step refuses to advance" {
  : > "$PROJ/wf-fail-derive"
  drive_to_derive

  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  [ "$(signal_of)" = "halted" ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "derive" ]
  assert_output_contains "exited with code 1"

  [ "$(st "$RUN" .status)" = "failed" ]
  [ "$(st "$RUN" '.steps[] | select(.id=="derive") | .status')" = "failed" ]
  # earlier steps keep their status, and prep keeps its output
  for s in prep ask_skill gate run_playbook; do
    [ "$(st "$RUN" ".steps[] | select(.id==\"$s\") | .status")" = "completed" ]
  done
  [ "$(st "$RUN" '.steps[] | select(.id=="prep") | .outputs.ids')" != "null" ]
  [ "$(st "$RUN" '.steps[] | select(.id=="publish") | .status')" = "pending" ]

  # no silent skip-ahead: asking again stays halted, runs nothing and leaves the state alone
  before="$(sum_of "$(state_file "$RUN")")"
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  [ "$(signal_of)" = "halted" ]
  [ "$(sum_of "$(state_file "$RUN")")" = "$before" ]
  [ "$(count_of prep)" = "1" ]
  [ "$(count_of derive)" = "1" ]
  [ "$(st "$RUN" '.steps[] | select(.id=="publish") | .status')" = "pending" ]
}

@test "2. after the fix a resume from a new process continues at the failed step and re-runs nothing completed" {
  : > "$PROJ/wf-fail-derive"
  drive_to_derive
  run wf_next "$RUN"
  [ "$(signal_of)" = "halted" ]
  [ "$(count_of prep)" = "1" ]
  [ "$(count_of derive)" = "1" ]

  rm -f "$PROJ/wf-fail-derive"
  WF_SESSION="sess-b"
  run --separate-stderr wf_fresh sess-b bash "$(wf_script run-state.sh)" resume "$RUN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "running" ]
  [ "$(printf '%s' "$output" | jq -r '.next_step.id')" = "derive" ]

  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  [ "$(signal_of)" = "complete" ]
  [ "$(st "$RUN" .status)" = "completed" ]
  # prep once; derive twice: the failed attempt and the retry
  [ "$(count_of prep)" = "1" ]
  [ "$(count_of derive)" = "2" ]
  [ "$(st "$RUN" '.steps[] | select(.id=="derive") | .status')" = "completed" ]
}

@test "3. a changed definition makes resume refuse with the state untouched; the override flag continues and is recorded" {
  RUN="$(wf_start)"
  run wf_fresh sess-a bash "$(wf_script run-state.sh)" pause "$RUN"
  [ "$status" -eq 0 ]
  [ "$(st "$RUN" .status)" = "paused" ]
  edit_definition '.steps += [{"id":"extra","type":"compute","command":"project/.workflows/scripts/count-run.sh","args":["extra"]}]'

  before="$(sum_of "$(state_file "$RUN")")"
  run --separate-stderr wf_fresh sess-b bash "$(wf_script run-state.sh)" resume "$RUN"
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "definition changed since the run started"
  assert_contains "$stderr" "--allow-definition-change"
  [ "$(sum_of "$(state_file "$RUN")")" = "$before" ]
  [ "$(st "$RUN" .status)" = "paused" ]
  [ "$(st "$RUN" .definition_change_ack)" = "null" ]

  run --separate-stderr wf_fresh sess-b bash "$(wf_script run-state.sh)" resume "$RUN" --allow-definition-change
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .definition_changed)" = "true" ]
  [ "$(st "$RUN" .status)" = "running" ]
  [ "$(st "$RUN" '.definition_change_ack | type')" = "object" ]
  [ "$(st "$RUN" .definition_change_ack.from_hash)" = "$(st "$RUN" .definition_hash)" ]
  [ "$(st "$RUN" .definition_change_ack.to_hash)" != "$(st "$RUN" .definition_hash)" ]
}

@test "4. an output that violates its declared id_list type fails the step, naming the rule, and is not stored" {
  make_stub bad-ids.sh 'echo "this is not an id"; echo "prep-ran" >> "$(dirname "$0")/../../../wf-count.log"'
  edit_definition '(.steps[] | select(.id=="prep") | .command) = "project/.workflows/scripts/bad-ids.sh"'
  RUN="$(wf_start)"

  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  [ "$(signal_of)" = "halted" ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "prep" ]
  assert_output_contains "violates type 'id_list'"

  [ "$(st "$RUN" .status)" = "failed" ]
  [ "$(st "$RUN" '.steps[] | select(.id=="prep") | .status')" = "failed" ]
  [ "$(st "$RUN" '.steps[] | select(.id=="prep") | .outputs | length')" = "0" ]
  # the command did run once (the violation is found in its output), and nothing after it was dispatched
  [ "$(count_of prep-ran)" = "1" ]
  [ "$(st "$RUN" '.steps[] | select(.id=="ask_skill") | .status')" = "pending" ]
  run wf_next "$RUN"
  [ "$(signal_of)" = "halted" ]
}

@test "5. a compute command that escapes the allow-listed roots is rejected and nothing runs" {
  # a real, executable script just outside the allow-listed roots: reachable only by a path that escapes them
  printf '#!/usr/bin/env bash\necho ran > "$(dirname "$0")/escape-marker"\n' > "$PROJ/outside.sh"
  chmod +x "$PROJ/outside.sh"
  local cmd i=0
  for cmd in "project/.workflows/scripts/../../../outside.sh" \
             "project/.workflows/scripts/count-run.sh; touch $PROJ/escape-marker"; do
    i=$((i + 1))
    edit_definition "(.steps[] | select(.id==\"prep\") | .command) = \"$cmd\""
    RUN="$(wf_start)"
    run wf_next "$RUN"
    [ "$status" -eq 0 ]
    [ "$(signal_of)" = "halted" ]
    [ "$(printf '%s' "$output" | jq -r .step_id)" = "prep" ]
    assert_output_contains "command rejected"
    [ "$(st "$RUN" .status)" = "failed" ]
    [ "$(st "$RUN" '.steps[] | select(.id=="prep") | .status')" = "failed" ]
    [ "$(st "$RUN" '.steps[] | select(.id=="ask_skill") | .status')" = "pending" ]
  done
  [ "$i" -eq 2 ]
  # nothing ran: no compute stub log, no marker from either the escaped script or the inline command
  [ ! -e "$PROJ/wf-count.log" ]
  [ ! -e "$PROJ/escape-marker" ]
}
