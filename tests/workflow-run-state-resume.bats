#!/usr/bin/env bats
#
# E80_S02_T07: scripts/workflow/run-state.sh resume (next-step rule, legal starting states, interrupted and failed
# step recovery, the definition-change guard and the new-process case).
#
# Every test builds its own throwaway working-file tree under $BATS_TEST_TMPDIR, selects it with JENGA_PROJECT_ROOT
# and writes fixture definitions into <tree>/.workflows/, so the test depends on no builtin workflow and never
# reads or writes this repository's own runs directory. The real loader and validator run against the
# repository's schema and type registry (they are only read).
#
# Mirror safety: depends only on scripts/workflow/*.sh, scripts/resolve-root.sh, scripts/with-lock.sh,
# templates/workflow-schema.json, templates/playbook-types.json and fixtures it builds. The working-file tree
# names in the fixtures are registry-layout directory names, written into scratch trees only.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/run-state.sh"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS JENGA_WORKFLOWS_TEST_ROOT
  mkdir -p "$BATS_TEST_TMPDIR/anchor/project/configs" "$BATS_TEST_TMPDIR/anchor/project/.workflows"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/anchor/project/configs/workflow.json"
  ANCHOR="$(cd "$BATS_TEST_TMPDIR/anchor" && pwd)"
  RUNS="$ANCHOR/project/data/workflow-runs"
  WFDIR="$ANCHOR/project/.workflows"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  cd "$BATS_TEST_TMPDIR" || return 1
}

# demo_def: a four-step fixture (s1 is a checkpoint step).
demo_def() {
  cat <<'JSON'
{
  "id": "demo",
  "name": "Demo flow",
  "description": "Fixture.",
  "steps": [
    {"id": "s1", "type": "skill", "skill": "j.status", "checkpoint": true},
    {"id": "s2", "type": "compute", "command": "echo two"},
    {"id": "s3", "type": "confirm", "prompt": "Continue?", "options": ["yes", "no"]},
    {"id": "s4", "type": "compute", "command": "echo four"}
  ]
}
JSON
}

put_demo() { demo_def > "$WFDIR/demo.json"; }

# write_run <id> <run status> <last_checkpoint or "null"> <s1> <s2> <s3> <s4>: a valid state for the demo
# definition, carrying the definition's real hash, with the given step statuses and a one-entry history.
write_run() {
  local id="$1" st="$2" cp="$3" hash
  shift 3
  put_demo
  hash=$(bash -c '. "$1"; definition_hash "$2"' _ "$SCRIPT" "$WFDIR/demo.json")
  mkdir -p "$RUNS"
  jq -n --arg id "$id" --arg st "$st" --arg cp "$cp" --arg h "$hash" --args '
    ["s1","s2","s3","s4"] as $ids | ["skill","compute","confirm","compute"] as $types | $ARGS.positional as $sts
    | { schema_version: 1, run_id: $id, workflow_id: "demo", definition_hash: $h, inputs: {}, status: $st,
        created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z",
        last_checkpoint: (if $cp == "null" then null else $cp end), definition_change_ack: null,
        steps: [range(0; 4) as $i | { id: $ids[$i], type: $types[$i], checkpoint: ($i == 0), status: $sts[$i],
                                      started_at: (if $sts[$i] == "pending" then null else "2026-01-01T00:00:00Z" end),
                                      finished_at: (if $sts[$i] == "completed" or $sts[$i] == "failed" then "2026-01-01T00:00:01Z" else null end),
                                      outputs: {} }],
        history: [{at: "2026-01-01T00:00:00Z", from: null, to: "running", note: "started"}] }' "$@" > "$RUNS/$id.json"
}

resume() {
  local rid="$1"
  shift
  run --separate-stderr bash "$SCRIPT" resume "$rid" "$@"
}

jqf() { jq -r "$2" "$RUNS/$1.json"; }

# snapshot <id>: copies the state file aside; same_as_snapshot <id> checks it is byte-identical afterwards.
snapshot() { cp "$RUNS/$1.json" "$BATS_TEST_TMPDIR/$1.snap"; }
same_as_snapshot() { cmp -s "$RUNS/$1.json" "$BATS_TEST_TMPDIR/$1.snap"; }

# paused_real_run: start, run s1 to completion and pause, through the real commands. Sets RID.
paused_real_run() {
  put_demo
  RID=$(bash "$SCRIPT" start demo)
  bash "$SCRIPT" step "$RID" s1 in_progress >/dev/null
  bash "$SCRIPT" step "$RID" s1 completed >/dev/null
  bash "$SCRIPT" pause "$RID" >/dev/null
}

# ---------------------------------------------------------------------------
# the next-step rule
# ---------------------------------------------------------------------------

@test "paused run, checkpoint s2, s1 and s2 completed, s3 pending: next step is s3 and the run is running" {
  write_run r1 paused s2 completed completed pending pending
  resume r1
  [ "$status" -eq 0 ]
  jq -e '. == {run_id: "r1", status: "running", resumed_from_checkpoint: "s2", next_step: {id: "s3", type: "confirm"}, definition_changed: false}' \
    <<<"$output" >/dev/null
  [ "$(jqf r1 .status)" = "running" ]
  jq -e '.history | length == 2 and .[1].from == "paused" and .[1].to == "running" and (.[1].note | startswith("resumed"))' \
    "$RUNS/r1.json" >/dev/null
  [ "$(jqf r1 .updated_at)" != "2026-01-01T00:00:00Z" ]
}

@test "stdout is exactly one JSON object on one line" {
  write_run r1 paused s2 completed completed pending pending
  resume r1
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  jq -e 'type == "object" and (keys | sort) == ["definition_changed","next_step","resumed_from_checkpoint","run_id","status"]' \
    <<<"$output" >/dev/null
}

@test "a completed step after the checkpoint is never reported as next: s3 completed, s4 pending gives s4" {
  write_run r1 paused s2 completed completed completed pending
  resume r1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.next_step.id' <<<"$output")" = "s4" ]
  [ "$(jq -r '.next_step.type' <<<"$output")" = "compute" ]
}

@test "last_checkpoint null: s1 completed, s2 pending gives s2 (a completed step before any checkpoint is not re-run)" {
  write_run r1 paused null completed pending pending pending
  resume r1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.next_step.id' <<<"$output")" = "s2" ]
  [ "$(jq -r '.resumed_from_checkpoint' <<<"$output")" = "null" ]
}

@test "last_checkpoint null and nothing completed: next step is the first step" {
  write_run r1 paused null pending pending pending pending
  resume r1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.next_step.id' <<<"$output")" = "s1" ]
}

@test "a skipped step is not reported as next either" {
  write_run r1 paused s1 completed skipped pending pending
  resume r1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.next_step.id' <<<"$output")" = "s3" ]
}

@test "every step completed or skipped: the run moves to completed and next_step is null" {
  write_run r1 paused s1 completed skipped completed skipped
  resume r1
  [ "$status" -eq 0 ]
  jq -e '.status == "completed" and .next_step == null and .definition_changed == false' <<<"$output" >/dev/null
  [ "$(jqf r1 .status)" = "completed" ]
  # paused has no direct edge to completed: two history entries, each move checked against the table
  jq -e '.history as $h | ($h | length == 3) and $h[1].from == "paused" and $h[1].to == "running" and $h[2].from == "running" and $h[2].to == "completed"' \
    "$RUNS/r1.json" >/dev/null
  # and a completed run cannot be resumed again
  resume r1
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# legal and illegal starting states
# ---------------------------------------------------------------------------

@test "awaiting_confirmation resumes to running" {
  write_run r1 awaiting_confirmation s1 completed pending pending pending
  resume r1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = "running" ]
  [ "$(jqf r1 .status)" = "running" ]
  jq -e '.history[-1] | .from == "awaiting_confirmation" and .to == "running"' "$RUNS/r1.json" >/dev/null
}

@test "a completed run is refused with exit 1, the status in the message and the state byte-identical" {
  write_run r1 completed s1 completed completed completed completed
  snapshot r1
  resume r1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *completed* ]]
  same_as_snapshot r1
}

@test "a cancelled run is refused with exit 1, the status in the message and the state byte-identical" {
  write_run r1 cancelled s1 completed pending pending pending
  snapshot r1
  resume r1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *cancelled* ]]
  same_as_snapshot r1
}

@test "a running run with no in_progress step is refused as already running, state byte-identical" {
  write_run r1 running s1 completed pending pending pending
  snapshot r1
  resume r1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"already running"* ]]
  same_as_snapshot r1
}

@test "a running run with an in_progress step: the step is reset to pending, the recovery is in history, and it is next" {
  write_run r1 running s1 completed in_progress pending pending
  resume r1
  [ "$status" -eq 0 ]
  jq -e '.status == "running" and .next_step == {id: "s2", type: "compute"}' <<<"$output" >/dev/null
  jq -e '.steps[1] | .status == "pending" and .started_at == null and .finished_at == null' "$RUNS/r1.json" >/dev/null
  jq -e '.steps[0].status == "completed" and (.steps[2:] | all(.status == "pending"))' "$RUNS/r1.json" >/dev/null
  jq -e '.history[-1] | .from == "running" and .to == "running" and (.note | test("s2")) and (.note | test("in_progress")) and (.note | test("reset to pending"))' \
    "$RUNS/r1.json" >/dev/null
  [ "$(jqf r1 .status)" = "running" ]
  [[ "$stderr" == *"interrupted"* ]]
}

@test "a failed run resumes to running with its failed step reset to pending and the retry noted in history" {
  write_run r1 failed s1 completed failed pending pending
  resume r1
  [ "$status" -eq 0 ]
  jq -e '.status == "running" and .next_step == {id: "s2", type: "compute"}' <<<"$output" >/dev/null
  jq -e '.steps[1] | .status == "pending" and .started_at == null and .finished_at == null' "$RUNS/r1.json" >/dev/null
  jq -e '.history[-1] | .from == "failed" and .to == "running" and (.note | test("retry after failure")) and (.note | test("s2"))' \
    "$RUNS/r1.json" >/dev/null
  # the reset step can be started again through the step command
  run --separate-stderr bash "$SCRIPT" step r1 s2 in_progress
  [ "$status" -eq 0 ]
  [ "$output" = "running" ]
}

@test "a paused run holding an in_progress step also gets it reset, so the executor can start it again" {
  write_run r1 paused s1 completed in_progress pending pending
  resume r1
  [ "$status" -eq 0 ]
  [ "$(jqf r1 '.steps[1].status')" = "pending" ]
  [ "$(jq -r '.next_step.id' <<<"$output")" = "s2" ]
  run --separate-stderr bash "$SCRIPT" step r1 s2 in_progress
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# a new process and session
# ---------------------------------------------------------------------------

@test "start, step and pause in one process, resume in a second env -i process given only the root, the run id and PATH" {
  put_demo
  run --separate-stderr bash -c '
    set -e
    rid=$(bash "$1" start demo)
    bash "$1" step "$rid" s1 in_progress >/dev/null
    bash "$1" step "$rid" s1 completed >/dev/null
    bash "$1" step "$rid" s2 in_progress >/dev/null
    bash "$1" pause "$rid" >/dev/null
    printf "%s\n" "$rid"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  RID="$output"
  [[ "$RID" =~ ^wf-demo- ]]
  run --separate-stderr env -i JENGA_PROJECT_ROOT="$ANCHOR" RID="$RID" PATH="$PATH" bash -c 'bash "$1" resume "$RID"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e --arg id "$RID" '. == {run_id: $id, status: "running", resumed_from_checkpoint: "s1", next_step: {id: "s2", type: "compute"}, definition_changed: false}' \
    <<<"$output" >/dev/null
  [ "$(jqf "$RID" .status)" = "running" ]
  [ "$(jqf "$RID" '.steps[1].status')" = "pending" ]
}

# ---------------------------------------------------------------------------
# the definition-change guard
# ---------------------------------------------------------------------------

# edit_def <jq filter>: rewrites the stored demo definition.
edit_def() {
  jq "$1" "$WFDIR/demo.json" > "$WFDIR/demo.json.new" && mv "$WFDIR/demo.json.new" "$WFDIR/demo.json"
}

@test "an unchanged definition resumes with definition_changed false and no ack" {
  paused_real_run
  resume "$RID"
  [ "$status" -eq 0 ]
  jq -e '.definition_changed == false and .next_step.id == "s2"' <<<"$output" >/dev/null
  [ "$(jqf "$RID" .definition_change_ack)" = "null" ]
}

@test "a definition edited after start makes resume exit 6 with both shortened hashes and the state byte-identical" {
  paused_real_run
  stored=$(jqf "$RID" .definition_hash)
  edit_def '.steps[1].command = "echo changed"'
  current=$(bash -c '. "$1"; definition_hash "$2"' _ "$SCRIPT" "$WFDIR/demo.json")
  [ "$stored" != "$current" ]
  snapshot "$RID"
  resume "$RID"
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  [[ "$stderr" == *"${stored:0:12}"* ]]
  [[ "$stderr" == *"${current:0:12}"* ]]
  [[ "$stderr" != *"${stored:0:13}"* ]]
  [[ "$stderr" == *"changed since the run started"* ]]
  [[ "$stderr" == *"--allow-definition-change"* ]]
  same_as_snapshot "$RID"
}

@test "reformatting the definition without changing it does not trip the guard" {
  paused_real_run
  jq -c -S . "$WFDIR/demo.json" > "$WFDIR/demo.json.new" && mv "$WFDIR/demo.json.new" "$WFDIR/demo.json"
  resume "$RID"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.definition_changed' <<<"$output")" = "false" ]
}

@test "--allow-definition-change resumes, records the ack, keeps the stored hash, and a later resume without it refuses again" {
  paused_real_run
  stored=$(jqf "$RID" .definition_hash)
  edit_def '.steps[1].command = "echo changed"'
  current=$(bash -c '. "$1"; definition_hash "$2"' _ "$SCRIPT" "$WFDIR/demo.json")
  resume "$RID" --allow-definition-change
  [ "$status" -eq 0 ]
  jq -e '.definition_changed == true and .status == "running" and .next_step.id == "s2"' <<<"$output" >/dev/null
  jq -e --arg a "$stored" --arg b "$current" '
    .definition_change_ack | (.from_hash == $a and .to_hash == $b and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")))' \
    "$RUNS/$RID.json" >/dev/null
  [ "$(jqf "$RID" .definition_hash)" = "$stored" ]
  jq -e '.history[-1].note | test("definition change accepted")' "$RUNS/$RID.json" >/dev/null
  # pause again: without the flag the change is still seen
  bash "$SCRIPT" pause "$RID" >/dev/null
  snapshot "$RID"
  resume "$RID"
  [ "$status" -eq 6 ]
  same_as_snapshot "$RID"
}

@test "the flag with an unchanged definition changes nothing: definition_changed false and no ack" {
  paused_real_run
  resume "$RID" --allow-definition-change
  [ "$status" -eq 0 ]
  [ "$(jq -r '.definition_changed' <<<"$output")" = "false" ]
  [ "$(jqf "$RID" .definition_change_ack)" = "null" ]
}

@test "the flag may come before the run id" {
  paused_real_run
  edit_def '.steps[1].command = "echo changed"'
  run --separate-stderr bash "$SCRIPT" resume --allow-definition-change "$RID"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.definition_changed' <<<"$output")" = "true" ]
}

@test "removing a step id the state contains refuses even with the flag, naming the ids, state byte-identical" {
  paused_real_run
  edit_def 'del(.steps[] | select(.id == "s3" or .id == "s4"))'
  snapshot "$RID"
  resume "$RID" --allow-definition-change
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  [[ "$stderr" == *s3* ]]
  [[ "$stderr" == *s4* ]]
  same_as_snapshot "$RID"
  [ "$(jqf "$RID" .definition_change_ack)" = "null" ]
}

@test "a deleted definition makes resume exit 6 with a message distinct from the changed-hash one" {
  paused_real_run
  rm "$WFDIR/demo.json"
  snapshot "$RID"
  resume "$RID"
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no longer exists"* ]]
  [[ "$stderr" != *"changed since the run started"* ]]
  same_as_snapshot "$RID"
  resume "$RID" --allow-definition-change
  [ "$status" -eq 6 ]
  same_as_snapshot "$RID"
}

@test "a refusal for the run status comes before the definition guard" {
  write_run r1 completed s1 completed completed completed completed
  rm "$WFDIR/demo.json"
  resume r1
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# argument and file handling
# ---------------------------------------------------------------------------

@test "no run id, two run ids and an unknown option are usage errors (exit 2)" {
  resume ""
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" resume
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" resume r1 r2
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" resume r1 --force
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" resume ../x
  [ "$status" -eq 2 ]
}

@test "an unknown run is exit 3 and a corrupt state file exit 4, neither is modified" {
  resume nosuchrun
  [ "$status" -eq 3 ]
  mkdir -p "$RUNS"
  printf '{ not json' > "$RUNS/bad.json"
  snapshot bad
  resume bad
  [ "$status" -eq 4 ]
  same_as_snapshot bad
}

@test "the usage text and the header document resume" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume <run_id> [--allow-definition-change]"* ]]
  grep -q 'run-state.sh resume <run_id> \[--allow-definition-change\]' "$SCRIPT"
}
