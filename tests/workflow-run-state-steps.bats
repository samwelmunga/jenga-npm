#!/usr/bin/env bats
#
# E80_S02_T06: the step and await-confirmation commands of scripts/workflow/run-state.sh - per-step status,
# started_at / finished_at, --output and --note, checkpoints, and the run status that follows.
#
# Every test builds its own throwaway working-file tree under $BATS_TEST_TMPDIR and exports JENGA_PROJECT_ROOT at
# it, so the real runs directory of this repository is never read or written. State files are written directly
# by write_run (three steps s1, s2, s3; s2 is a checkpoint step unless CP says otherwise); one test goes through
# the real start command and a fixture definition instead.
#
# Mirror safety: depends only on scripts/workflow/*.sh, scripts/resolve-root.sh, scripts/with-lock.sh,
# templates/workflow-schema.json, templates/playbook-types.json and fixtures it builds.

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

# write_run <id> <run_status> [<s1_status> <s2_status> <s3_status>]: a valid state file with steps s1, s2, s3
# (statuses default to pending). s2 has checkpoint true; set CP=none to make no step a checkpoint, CP=s1s2 to make
# s1 and s2 checkpoints. A step that is not pending gets started_at; completed, failed and skipped also finished_at.
write_run() {
  local id="$1" rs="$2" a="${3:-pending}" b="${4:-pending}" c="${5:-pending}" cp="${CP:-s2}"
  mkdir -p "$RUNS"
  jq -n --arg id "$id" --arg rs "$rs" --arg a "$a" --arg b "$b" --arg c "$c" --arg cp "$cp" '
    def st($i; $s; $cpids): {id: $i, type: "skill", checkpoint: ($cpids | index($i) != null), status: $s,
      started_at: (if $s == "pending" then null else "2026-01-01T00:00:00Z" end),
      finished_at: (if ($s == "completed" or $s == "failed" or $s == "skipped") then "2026-01-01T00:00:01Z" else null end),
      outputs: {}};
    (if $cp == "none" then [] elif $cp == "s1s2" then ["s1", "s2"] else ["s2"] end) as $cps
    | { schema_version: 1, run_id: $id, workflow_id: "wf-a", definition_hash: "abc123", inputs: {},
        status: $rs, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z",
        last_checkpoint: null, definition_change_ack: null,
        steps: [st("s1"; $a; $cps), st("s2"; $b; $cps), st("s3"; $c; $cps)],
        history: [] }' > "$RUNS/$id.json"
}

# step <args...>: runs the step command keeping stdout ($output) and stderr ($stderr) apart.
step() {
  run --separate-stderr bash "$SCRIPT" step "$@"
}

fsum() { cksum < "$RUNS/$1.json"; }
jqf() { jq -r "$2" "$RUNS/$1.json"; }

# refused <run> <exit> <args...>: step <run> <args...> exits with <exit>, writes nothing, prints nothing on stdout.
refused() {
  local id="$1" want="$2" before
  shift 2
  before=$(fsum "$id")
  step "$id" "$@"
  [ "$status" -eq "$want" ] || { echo "step $id $*: expected exit $want, got $status ($stderr)"; return 1; }
  [ -z "$output" ] || { echo "step $id $*: stdout was '$output'"; return 1; }
  [ -n "$stderr" ] || { echo "step $id $*: no message on stderr"; return 1; }
  [ "$(fsum "$id")" = "$before" ] || { echo "step $id $*: state file changed"; return 1; }
}

# ---------------------------------------------------------------------------
# walking a run
# ---------------------------------------------------------------------------

@test "walking 3 steps through in_progress then completed ends with the run completed and both timestamps set" {
  write_run r1 running
  local s
  for s in s1 s2 s3; do
    step r1 $s in_progress
    [ "$status" -eq 0 ]
    [ "$output" = "running" ]
    step r1 $s completed
    [ "$status" -eq 0 ]
  done
  [ "$output" = "completed" ]
  [ "$(jqf r1 .status)" = "completed" ]
  jq -e '.steps | all(.status == "completed" and (.started_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
                       and (.finished_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and (.finished_at >= .started_at))' \
    "$RUNS/r1.json" >/dev/null
  # the run moved once, with a history entry that chains from running
  jq -e '.history | length == 1 and .[0].from == "running" and .[0].to == "completed"' "$RUNS/r1.json" >/dev/null
}

@test "step prints exactly one line, the run status after the write, and nothing on stderr" {
  write_run r1 running
  step r1 s1 in_progress
  [ "$status" -eq 0 ]
  [ "$output" = "running" ]
  [ -z "$stderr" ]
  step r1 s1 completed
  [ "$output" = "running" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  step r1 s2 skipped
  [ "$output" = "running" ]
}

@test "started_at is set on the first in_progress, finished_at on completion, and updated_at changes" {
  write_run r1 running
  step r1 s1 in_progress
  [ "$status" -eq 0 ]
  jq -e '.steps[0] | .status == "in_progress" and (.started_at | type == "string") and .finished_at == null' "$RUNS/r1.json" >/dev/null
  [ "$(jqf r1 .updated_at)" != "2026-01-01T00:00:00Z" ]
  step r1 s1 completed
  jq -e '.steps[0] | .status == "completed" and (.finished_at | type == "string")' "$RUNS/r1.json" >/dev/null
  # the other steps are untouched
  jq -e '.steps[1:] | all(.status == "pending" and .started_at == null and .finished_at == null)' "$RUNS/r1.json" >/dev/null
}

@test "a skipped step gets finished_at but no started_at, and skipping the rest completes the run" {
  write_run r1 running completed pending pending
  step r1 s2 skipped
  [ "$status" -eq 0 ]
  [ "$output" = "running" ]
  jq -e '.steps[1] | .status == "skipped" and .started_at == null and (.finished_at | type == "string")' "$RUNS/r1.json" >/dev/null
  step r1 s3 skipped
  [ "$status" -eq 0 ]
  [ "$output" = "completed" ]
  [ "$(jqf r1 .status)" = "completed" ]
}

@test "skipping the last remaining step completes the run, also from awaiting_confirmation (via running)" {
  write_run r1 running completed completed pending
  step r1 s3 skipped
  [ "$status" -eq 0 ]
  [ "$output" = "completed" ]
  jq -e '.history | length == 1 and .[0].from == "running" and .[0].to == "completed"' "$RUNS/r1.json" >/dev/null
  write_run r2 awaiting_confirmation completed completed pending
  step r2 s3 skipped
  [ "$status" -eq 0 ]
  [ "$output" = "completed" ]
  jq -e '.history as $h | ($h | length == 2) and $h[0].to == "running" and $h[1].from == "running" and $h[1].to == "completed"' \
    "$RUNS/r2.json" >/dev/null
}

@test "skipping a step while others remain does not move an awaiting_confirmation run" {
  write_run r1 awaiting_confirmation completed pending pending
  step r1 s2 skipped
  [ "$status" -eq 0 ]
  [ "$output" = "awaiting_confirmation" ]
}

@test "the run does not complete while a step is still pending or in_progress" {
  write_run r1 running completed in_progress pending
  step r1 s2 completed
  [ "$output" = "running" ]
  [ "$(jqf r1 .status)" = "running" ]
  [ "$(jq '.history | length' "$RUNS/r1.json")" -eq 0 ]
}

# ---------------------------------------------------------------------------
# checkpoints
# ---------------------------------------------------------------------------

@test "completing a checkpoint step sets last_checkpoint in the same write; steps 1 and 3 leave it alone" {
  write_run r1 running
  step r1 s1 in_progress; [ "$status" -eq 0 ]
  step r1 s1 completed;   [ "$status" -eq 0 ]
  [ "$(jqf r1 .last_checkpoint)" = "null" ]
  step r1 s2 in_progress; [ "$status" -eq 0 ]
  [ "$(jqf r1 .last_checkpoint)" = "null" ]
  step r1 s2 completed;   [ "$status" -eq 0 ]
  # one call changed both the step and the checkpoint
  jq -e '.last_checkpoint == "s2" and .steps[1].status == "completed"' "$RUNS/r1.json" >/dev/null
  step r1 s3 in_progress; [ "$status" -eq 0 ]
  step r1 s3 completed;   [ "$status" -eq 0 ]
  [ "$(jqf r1 .last_checkpoint)" = "s2" ]
  [ "$(jqf r1 .status)" = "completed" ]
}

@test "a skipped checkpoint step does not set last_checkpoint" {
  write_run r1 running completed pending pending
  step r1 s2 skipped
  [ "$status" -eq 0 ]
  [ "$(jqf r1 .last_checkpoint)" = "null" ]
  [ "$(jqf r1 '.steps[1].status')" = "skipped" ]
}

@test "a checkpoint step that is only in_progress or failed does not set last_checkpoint" {
  write_run r1 running completed pending pending
  step r1 s2 in_progress
  [ "$(jqf r1 .last_checkpoint)" = "null" ]
  step r1 s2 failed
  [ "$(jqf r1 .last_checkpoint)" = "null" ]
}

@test "completing a later checkpoint replaces an earlier last_checkpoint" {
  CP=s1s2 write_run r1 running
  step r1 s1 in_progress; step r1 s1 completed
  [ "$(jqf r1 .last_checkpoint)" = "s1" ]
  step r1 s2 in_progress; step r1 s2 completed
  [ "$(jqf r1 .last_checkpoint)" = "s2" ]
}

@test "with no checkpoint step in the definition last_checkpoint stays null for the whole run" {
  CP=none write_run r1 running
  local s
  for s in s1 s2 s3; do step r1 $s in_progress; step r1 $s completed; done
  [ "$(jqf r1 .status)" = "completed" ]
  [ "$(jqf r1 .last_checkpoint)" = "null" ]
}

# ---------------------------------------------------------------------------
# per-step table and linear order
# ---------------------------------------------------------------------------

@test "a step cannot start while an earlier step is pending" {
  write_run r1 running
  refused r1 1 s2 in_progress
  refused r1 1 s3 in_progress
  [[ "$stderr" == *"s1 (pending)"* ]]
}

@test "a step cannot start while an earlier step is failed or still in_progress" {
  write_run r1 running failed pending pending
  refused r1 1 s2 in_progress
  [[ "$stderr" == *"s1 (failed)"* ]]
  write_run r2 running in_progress pending pending
  refused r2 1 s2 in_progress
}

@test "a step can start when every earlier step is completed or skipped" {
  write_run r1 running skipped completed pending
  step r1 s3 in_progress
  [ "$status" -eq 0 ]
  [ "$output" = "running" ]
}

@test "completed -> in_progress, completed -> failed, completed -> skipped and completed -> completed are refused" {
  write_run r1 running completed pending pending
  refused r1 1 s1 in_progress
  refused r1 1 s1 failed
  refused r1 1 s1 skipped
  refused r1 1 s1 completed
  [[ "$stderr" == *"none, final for this run"* ]]
}

@test "skipped -> in_progress, skipped -> completed and skipped -> failed are refused" {
  write_run r1 running skipped pending pending
  refused r1 1 s1 in_progress
  refused r1 1 s1 completed
  refused r1 1 s1 failed
  refused r1 1 s1 skipped
}

@test "pending -> completed, pending -> failed, in_progress -> skipped and in_progress -> in_progress are refused" {
  write_run r1 running pending pending pending
  refused r1 1 s1 completed
  refused r1 1 s1 failed
  write_run r2 running in_progress pending pending
  refused r2 1 s1 skipped
  refused r2 1 s1 in_progress
}

@test "failed -> in_progress is a retry: started_at is kept, finished_at is cleared, outputs stay empty" {
  write_run r1 running failed pending pending
  step r1 s1 in_progress
  [ "$status" -eq 0 ]
  jq -e '.steps[0] | .status == "in_progress" and .started_at == "2026-01-01T00:00:00Z" and .finished_at == null and .outputs == {}' \
    "$RUNS/r1.json" >/dev/null
  step r1 s1 completed
  [ "$status" -eq 0 ]
  jq -e '.steps[0] | .status == "completed" and (.finished_at > "2026-01-01T00:00:01Z")' "$RUNS/r1.json" >/dev/null
}

@test "failed -> completed and failed -> skipped are refused" {
  write_run r1 running failed pending pending
  refused r1 1 s1 completed
  refused r1 1 s1 skipped
}

# ---------------------------------------------------------------------------
# failure and the run status
# ---------------------------------------------------------------------------

@test "step failed moves the run running -> failed and appends a history entry" {
  write_run r1 running in_progress pending pending
  step r1 s1 failed
  [ "$status" -eq 0 ]
  [ "$output" = "failed" ]
  [ "$(jqf r1 .status)" = "failed" ]
  jq -e '.steps[0] | .status == "failed" and (.finished_at | type == "string")' "$RUNS/r1.json" >/dev/null
  jq -e '.history | length == 1 and .[0].from == "running" and .[0].to == "failed" and (.[0].note | contains("s1"))' "$RUNS/r1.json" >/dev/null
}

@test "after a step failed a later step call on another step is refused with exit 1" {
  write_run r1 running in_progress pending pending
  step r1 s1 failed
  [ "$status" -eq 0 ]
  refused r1 1 s2 in_progress
  refused r1 1 s2 skipped
  refused r1 1 s1 in_progress
  [ "$(jqf r1 .status)" = "failed" ]
}

@test "step failed on an awaiting_confirmation run moves it to failed" {
  write_run r1 awaiting_confirmation completed in_progress pending
  step r1 s2 failed
  [ "$status" -eq 0 ]
  [ "$output" = "failed" ]
}

# ---------------------------------------------------------------------------
# the run must be accepting step reports
# ---------------------------------------------------------------------------

@test "step on a cancelled, completed or failed run is refused with the state byte-identical" {
  local rs
  for rs in cancelled completed failed; do
    write_run "r-$rs" "$rs" completed in_progress pending
    refused "r-$rs" 1 s2 completed
    refused "r-$rs" 1 s2 failed
    refused "r-$rs" 1 s3 in_progress
    [[ "$stderr" == *"is $rs"* ]]
  done
}

@test "step on a paused run is refused except the result of the in_progress step" {
  write_run r1 paused completed in_progress pending
  refused r1 1 s3 in_progress
  refused r1 1 s3 skipped
  refused r1 1 s2 in_progress
  refused r1 1 s2 skipped
  [[ "$stderr" == *"paused"* ]]
}

@test "completing the in_progress step of a paused run is accepted and leaves the run paused" {
  write_run r1 paused completed in_progress pending
  step r1 s2 completed
  [ "$status" -eq 0 ]
  [ "$output" = "paused" ]
  [ "$(jqf r1 .status)" = "paused" ]
  jq -e '.steps[1] | .status == "completed" and (.finished_at > "2026-01-01T00:00:01Z")' "$RUNS/r1.json" >/dev/null
  # the checkpoint of that step is recorded too, and the run history gets no new entry
  [ "$(jqf r1 .last_checkpoint)" = "s2" ]
  [ "$(jq '.history | length' "$RUNS/r1.json")" -eq 0 ]
}

@test "the result of a paused run's in_progress step may also be failed; the run stays paused" {
  write_run r1 paused completed in_progress pending
  step r1 s2 failed
  [ "$status" -eq 0 ]
  [ "$output" = "paused" ]
  [ "$(jqf r1 '.steps[1].status')" = "failed" ]
}

@test "completing the last step of a paused run records it and leaves the run paused" {
  write_run r1 paused completed completed in_progress
  step r1 s3 completed
  [ "$status" -eq 0 ]
  [ "$output" = "paused" ]
  [ "$(jqf r1 '.steps[2].status')" = "completed" ]
}

# ---------------------------------------------------------------------------
# --output and --note
# ---------------------------------------------------------------------------

@test "--output name=value appears under the step's outputs as a string" {
  write_run r1 running in_progress pending pending
  step r1 s1 completed --output report=out/report.md
  [ "$status" -eq 0 ]
  [ "$(jqf r1 '.steps[0].outputs')" = "$(printf '{\n  "report": "out/report.md"\n}')" ]
  jq -e '.steps[0].outputs.report == "out/report.md" and (.steps[1].outputs == {})' "$RUNS/r1.json" >/dev/null
}

@test "--output is repeatable, splits on the first = and keeps the value as a string" {
  write_run r1 running in_progress pending pending
  step r1 s1 completed --output a=1 --output b=x=y --output c=
  [ "$status" -eq 0 ]
  jq -e '.steps[0].outputs == {a: "1", b: "x=y", c: ""}' "$RUNS/r1.json" >/dev/null
}

@test "--output with a status other than completed exits 2 and writes nothing" {
  write_run r1 running in_progress pending pending
  refused r1 2 s1 failed --output a=1
  refused r1 2 s1 in_progress --output a=1
  refused r1 2 s1 skipped --output a=1
  [[ "$stderr" == *"--output"* ]]
  write_run r2 running
  refused r2 2 s1 in_progress --output a=1
}

@test "a malformed, empty-named or repeated --output exits 2 and writes nothing" {
  write_run r1 running in_progress pending pending
  refused r1 2 s1 completed --output noequals
  refused r1 2 s1 completed --output =v
  refused r1 2 s1 completed --output a=1 --output a=2
  refused r1 2 s1 completed --output
}

@test "--note is kept on the step and appended to the history note of a run move" {
  write_run r1 running in_progress pending pending
  step r1 s1 failed --note "disk full"
  [ "$status" -eq 0 ]
  [ "$(jqf r1 '.steps[0].note')" = "disk full" ]
  [ "$(jqf r1 '.history[0].note')" = "step s1 failed: disk full" ]
}

@test "--note with no argument or given twice exits 2" {
  write_run r1 running in_progress pending pending
  refused r1 2 s1 completed --note
  refused r1 2 s1 completed --note a --note b
}

# ---------------------------------------------------------------------------
# await-confirmation
# ---------------------------------------------------------------------------

@test "await-confirmation moves the run running -> awaiting_confirmation and records the step id in the history note" {
  write_run r1 running completed in_progress pending
  run --separate-stderr bash "$SCRIPT" await-confirmation r1 s2
  [ "$status" -eq 0 ]
  [ "$output" = "awaiting_confirmation" ]
  [ "$(jqf r1 .status)" = "awaiting_confirmation" ]
  jq -e '.history | length == 1 and .[0].from == "running" and .[0].to == "awaiting_confirmation" and (.[0].note | contains("s2"))' \
    "$RUNS/r1.json" >/dev/null
  # the step itself is unchanged
  [ "$(jqf r1 '.steps[1].status')" = "in_progress" ]
}

@test "after await-confirmation, step completed returns the run to running" {
  write_run r1 running completed in_progress pending
  bash "$SCRIPT" await-confirmation r1 s2
  step r1 s2 completed
  [ "$status" -eq 0 ]
  [ "$output" = "running" ]
  [ "$(jqf r1 .status)" = "running" ]
  jq -e '.history | length == 2 and .[1].from == "awaiting_confirmation" and .[1].to == "running"' "$RUNS/r1.json" >/dev/null
  [ "$(jqf r1 .last_checkpoint)" = "s2" ]
}

@test "after await-confirmation, step failed moves the run to failed" {
  write_run r1 running completed in_progress pending
  bash "$SCRIPT" await-confirmation r1 s2
  step r1 s2 failed
  [ "$status" -eq 0 ]
  [ "$output" = "failed" ]
  [ "$(jqf r1 .status)" = "failed" ]
  jq -e '.history | length == 2 and .[1].from == "awaiting_confirmation" and .[1].to == "failed"' "$RUNS/r1.json" >/dev/null
}

@test "confirming the last step goes awaiting_confirmation -> running -> completed in one call, two history entries" {
  write_run r1 running completed completed in_progress
  bash "$SCRIPT" await-confirmation r1 s3
  step r1 s3 completed
  [ "$status" -eq 0 ]
  [ "$output" = "completed" ]
  [ "$(jqf r1 .status)" = "completed" ]
  jq -e '.history as $h | ($h | length == 3)
         and ($h[1].from == "awaiting_confirmation") and ($h[1].to == "running")
         and ($h[2].from == "running") and ($h[2].to == "completed")
         and ([range(1; $h | length)] | all(. as $k | $h[$k].from == $h[$k - 1].to))' "$RUNS/r1.json" >/dev/null
}

@test "await-confirmation on a step that is not in_progress exits 1 and writes nothing" {
  local st
  for st in pending completed failed skipped; do
    write_run "r-$st" running "$st" pending pending
    before=$(fsum "r-$st")
    run --separate-stderr bash "$SCRIPT" await-confirmation "r-$st" s1
    [ "$status" -eq 1 ] || { echo "$st: rc $status"; return 1; }
    [ -z "$output" ]
    [[ "$stderr" == *"in_progress"* ]]
    [ "$(fsum "r-$st")" = "$before" ]
  done
}

@test "await-confirmation on a run that is paused, failed or already awaiting exits 1 and writes nothing" {
  local rs before
  for rs in paused failed awaiting_confirmation completed cancelled; do
    write_run "r-$rs" "$rs" completed in_progress pending
    before=$(fsum "r-$rs")
    run --separate-stderr bash "$SCRIPT" await-confirmation "r-$rs" s2
    [ "$status" -eq 1 ] || { echo "$rs: rc $status"; return 1; }
    [ -z "$output" ]
    [[ "$stderr" == *"cannot move to awaiting_confirmation"* ]]
    [ "$(fsum "r-$rs")" = "$before" ]
  done
}

@test "await-confirmation: unknown step exits 2 listing the ids, unknown run exits 3, bad usage exits 2" {
  write_run r1 running completed in_progress pending
  run --separate-stderr bash "$SCRIPT" await-confirmation r1 nope
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"s1, s2, s3"* ]]
  run --separate-stderr bash "$SCRIPT" await-confirmation missing s1
  [ "$status" -eq 3 ]
  run --separate-stderr bash "$SCRIPT" await-confirmation r1
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" await-confirmation r1 s2 extra
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" await-confirmation ../x s2
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# unknown step, unknown run, corrupt file, usage
# ---------------------------------------------------------------------------

@test "an unknown step id exits 2 and the message lists the valid step ids" {
  write_run r1 running
  refused r1 2 nope in_progress
  [[ "$stderr" == *"nope"* ]]
  [[ "$stderr" == *"s1, s2, s3"* ]]
}

@test "an unknown run id exits 3 and creates nothing" {
  write_run r1 running
  step missing s1 in_progress
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"run not found"* ]]
  [ "$(ls -A "$RUNS")" = "r1.json" ]
}

@test "a missing runs directory is reported as an unknown run, not created" {
  step r1 s1 in_progress
  [ "$status" -eq 3 ]
  [ ! -e "$RUNS" ]
}

@test "a corrupt state file exits 4 and is not modified" {
  mkdir -p "$RUNS"
  printf '{ not json' > "$RUNS/bad.json"
  local before; before=$(fsum bad)
  step bad s1 in_progress
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [ "$(fsum bad)" = "$before" ]
  run --separate-stderr bash "$SCRIPT" await-confirmation bad s1
  [ "$status" -eq 4 ]
  [ "$(fsum bad)" = "$before" ]
}

@test "an invalid status word, a missing argument and an extra argument exit 2" {
  write_run r1 running
  refused r1 2 s1 pending
  refused r1 2 s1 running
  refused r1 2 s1 done
  step r1 s1
  [ "$status" -eq 2 ]
  step r1
  [ "$status" -eq 2 ]
  step
  [ "$status" -eq 2 ]
  step r1 s1 in_progress extra
  [ "$status" -eq 2 ]
  step r1 s1 in_progress --bogus
  [ "$status" -eq 2 ]
}

@test "an invalid run id exits 2 before the disk is touched" {
  step '../x' s1 in_progress
  [ "$status" -eq 2 ]
  step '' s1 in_progress
  [ "$status" -eq 2 ]
  [ ! -e "$RUNS" ]
}

@test "usage text lists step and await-confirmation, and -h exits 0" {
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"step <run_id> <step_id>"* ]]
  [[ "$output" == *"--output name=value"* ]]
  [[ "$output" == *"await-confirmation <run_id> <step_id>"* ]]
}

@test "the script header documents step and await-confirmation" {
  grep -q '^#   run-state.sh step <run_id> <step_id>' "$SCRIPT"
  grep -q '^#   run-state.sh await-confirmation <run_id> <step_id>' "$SCRIPT"
  grep -q 'run_state_step' "$SCRIPT"
}

# ---------------------------------------------------------------------------
# locking, races, leftovers
# ---------------------------------------------------------------------------

@test "a held lock makes step exit 5 after the timeout and write nothing" {
  write_run r1 running
  local before; before=$(fsum r1)
  mkdir "$RUNS/r1.json.lock.d"
  export WITH_LOCK_TIMEOUT_SECONDS=1
  step r1 s1 in_progress
  unset WITH_LOCK_TIMEOUT_SECONDS
  [ "$status" -eq 5 ]
  [ "$(fsum r1)" = "$before" ]
  rmdir "$RUNS/r1.json.lock.d"
}

@test "no temporary or lock entries are left behind by successful or refused step calls" {
  write_run r1 running
  step r1 s1 in_progress
  step r1 s2 in_progress   # refused (out of order)
  step r1 s1 completed
  run --separate-stderr bash "$SCRIPT" await-confirmation r1 s1   # refused (not in_progress)
  [ "$(ls -A "$RUNS")" = "r1.json" ]
}

@test "two concurrent completions of one step: exactly one wins and the history is consistent" {
  local i a b arc brc
  for i in 1 2 3 4 5; do
    write_run "race$i" running in_progress pending pending
    arc=0; brc=0
    bash "$SCRIPT" step "race$i" s1 completed >/dev/null 2>&1 &
    a=$!
    bash "$SCRIPT" step "race$i" s1 completed >/dev/null 2>&1 &
    b=$!
    wait "$a" || arc=$?
    wait "$b" || brc=$?
    [ $((arc + brc)) -eq 1 ] || { echo "run $i: rcs $arc $brc"; return 1; }
    jq -e . "$RUNS/race$i.json" >/dev/null
    [ "$(jqf "race$i" '.steps[0].status')" = "completed" ]
  done
}

@test "concurrent step results for two different in_progress-ready steps never corrupt the file" {
  write_run r1 running completed pending pending
  bash "$SCRIPT" step r1 s2 in_progress >/dev/null 2>&1 &
  local a=$!
  bash "$SCRIPT" step r1 s3 in_progress >/dev/null 2>&1 &
  local b=$! arc=0 brc=0
  wait "$a" || arc=$?
  wait "$b" || brc=$?
  jq -e . "$RUNS/r1.json" >/dev/null
  # s3 may start only after s2 is completed or skipped, so s3 always loses; s2 always wins
  [ "$arc" -eq 0 ]
  [ "$brc" -eq 1 ]
  [ "$(jqf r1 '.steps[2].status')" = "pending" ]
}

# ---------------------------------------------------------------------------
# as a sourced function, and end to end with start
# ---------------------------------------------------------------------------

@test "run_state_step and run_state_await_confirmation are available when the script is sourced" {
  write_run r1 running
  run --separate-stderr bash -c 'set -u; . "$1"; run_state_step r1 s1 in_progress && run_state_await_confirmation r1 s1' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'running\nawaiting_confirmation')" ]
}

@test "end to end: start a run from a real definition and walk it to completion with a checkpoint" {
  cat > "$WFDIR/demo.json" <<'JSON'
{
  "id": "demo",
  "name": "Demo flow",
  "description": "Fixture.",
  "steps": [
    {"id": "first", "type": "skill", "skill": "j.status"},
    {"id": "second", "type": "skill", "skill": "j.status", "checkpoint": true},
    {"id": "third", "type": "confirm", "prompt": "Continue?", "options": ["yes", "no"]}
  ]
}
JSON
  run --separate-stderr bash "$SCRIPT" start demo
  [ "$status" -eq 0 ]
  local rid="$output"
  step "$rid" first in_progress;  [ "$status" -eq 0 ]
  step "$rid" first completed --output note=hello;  [ "$status" -eq 0 ]
  step "$rid" second in_progress; [ "$status" -eq 0 ]
  step "$rid" second completed;   [ "$status" -eq 0 ]
  [ "$(jq -r .last_checkpoint "$RUNS/$rid.json")" = "second" ]
  step "$rid" third in_progress;  [ "$status" -eq 0 ]
  run --separate-stderr bash "$SCRIPT" await-confirmation "$rid" third
  [ "$status" -eq 0 ]
  [ "$output" = "awaiting_confirmation" ]
  step "$rid" third completed
  [ "$status" -eq 0 ]
  [ "$output" = "completed" ]
  jq -e '.status == "completed" and .steps[0].outputs.note == "hello" and (.steps | all(.status == "completed"))' \
    "$RUNS/$rid.json" >/dev/null
}
