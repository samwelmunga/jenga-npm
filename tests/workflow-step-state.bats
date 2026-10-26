#!/usr/bin/env bats
#
# E80_S03_T01: scripts/workflow/step-state.sh - step-level read and write primitives over the E80_S02 run state
# file (get, current-step, set-step, set-output, get-output, set-run-status, set-gate, get-gate, clear-gate,
# checkpoint).
#
# Every test builds its own throwaway working-file tree under $BATS_TEST_TMPDIR and exports JENGA_PROJECT_ROOT at
# it, so the real runs directory of this repository is never read or written.
#
# Mirror safety: depends only on scripts/workflow/step-state.sh, scripts/workflow/run-state.sh,
# scripts/resolve-root.sh, scripts/with-lock.sh and fixtures it builds. The working-file tree names in the
# fixtures are registry-layout directory names, written into scratch trees only.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/step-state.sh"
RUN_STATE="$REPO_ROOT/scripts/workflow/run-state.sh"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS
  mkdir -p "$BATS_TEST_TMPDIR/anchor/project/configs"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/anchor/project/configs/workflow.json"
  ANCHOR="$(cd "$BATS_TEST_TMPDIR/anchor" && pwd)"
  RUNS="$ANCHOR/project/data/workflow-runs"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  cd "$BATS_TEST_TMPDIR" || return 1
}

# write_run <id> [run status]: a valid state file with three pending steps; s1 is a checkpoint step.
write_run() {
  mkdir -p "$RUNS"
  jq -n --arg id "$1" --arg st "${2:-running}" '{
    schema_version: 1, run_id: $id, workflow_id: "wf-a", definition_hash: "abc123",
    inputs: {k: "v"}, status: $st, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z",
    last_checkpoint: null, definition_change_ack: null,
    steps: [
      {id: "s1", type: "skill", checkpoint: true, status: "pending", started_at: null, finished_at: null, outputs: {}},
      {id: "s2", type: "skill", checkpoint: false, status: "pending", started_at: null, finished_at: null, outputs: {}},
      {id: "s3", type: "skill", checkpoint: false, status: "pending", started_at: null, finished_at: null, outputs: {}}
    ],
    history: []
  }' > "$RUNS/$1.json"
}

# mod <id> <jq filter> [jq args]: rewrites a fixture file directly, bypassing the script under test.
mod() {
  local id="$1" filter="$2"
  shift 2
  jq "$@" "$filter" "$RUNS/$id.json" > "$RUNS/$id.json.new" && mv "$RUNS/$id.json.new" "$RUNS/$id.json"
}

# snap <id>: a checksum of the state file, to prove a refused command left it byte-identical.
snap() {
  cksum < "$RUNS/$1.json"
}

# no_tmp: no temporary file is left in the runs directory.
no_tmp() {
  [ -z "$(find "$RUNS" -name '.tmp-*')" ]
}

# ss <args...>: runs the script with stdout and stderr captured separately.
ss() {
  run --separate-stderr bash "$SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# shape: executable, syntax, sourceable, header, no tree literal
# ---------------------------------------------------------------------------

@test "script exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "sourcing prints nothing, exits cleanly and creates nothing, even under set -u" {
  mkdir "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr bash -c 'set -u; cd "$2" && . "$1" && type _ss_main run_state_update run_state_read >/dev/null && echo sourced-ok' _ "$SCRIPT" "$BATS_TEST_TMPDIR/empty"
  [ "$status" -eq 0 ]
  [ "$output" = "sourced-ok" ]
  [ -z "$stderr" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/empty")" ]
  [ ! -e "$RUNS" ]
}

@test "header documents every subcommand, the pending_gate key and exit codes 0 to 5" {
  local header cmd code word
  header=$(sed -n '1,/^_SS_SELF=/p' "$SCRIPT")
  for cmd in get current-step set-step set-output get-output set-run-status set-gate get-gate clear-gate checkpoint; do
    printf '%s\n' "$header" | grep -Eq "^#   step-state\.sh $cmd( |\$)" || { echo "header lacks command: $cmd"; return 1; }
  done
  printf '%s\n' "$header" | grep -Eq '^#   step-state\.sh -h \| --help'
  for code in 0 1 2 3 4 5; do
    printf '%s\n' "$header" | grep -Eq "^#   $code  " || { echo "header lacks exit code $code"; return 1; }
  done
  for word in pending_gate in_progress awaiting_confirmation started_at finished_at last_checkpoint run_state_update with-lock.sh; do
    printf '%s\n' "$header" | grep -q -- "$word" || { echo "header lacks: $word"; return 1; }
  done
}

@test "script contains no working-file tree literal" {
  run grep -nE '\.?project/' "$SCRIPT"
  [ "$status" -eq 1 ]
  run grep -n '\.project' "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "the runs location comes from the resolver: a registry override is honoured" {
  printf '{"paths":{"workflow_runs":"elsewhere/runs"}}\n' > "$ANCHOR/project/configs/workflow.json"
  mkdir -p "$ANCHOR/elsewhere/runs"
  RUNS="$ANCHOR/elsewhere/runs"
  write_run moved
  ss current-step moved
  [ "$status" -eq 0 ]
  [ "$output" = "s1" ]
  ss set-step moved s1 in_progress
  [ "$status" -eq 0 ]
  jq -e '.steps[0].status == "in_progress"' "$ANCHOR/elsewhere/runs/moved.json" >/dev/null
  [ ! -e "$ANCHOR/project/data" ]
}

@test "no arguments and an unknown command are usage errors (exit 2); -h prints usage and exits 0" {
  ss
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: step-state.sh"* ]]
  ss frobnicate r1
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown command"* ]]
  ss --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: step-state.sh"* ]]
  ss -h
  [ "$status" -eq 0 ]
}

@test "a wrong number of arguments is a usage error (exit 2) for every subcommand" {
  write_run r1
  local before; before=$(snap r1)
  local args
  for args in "get" "current-step" "set-step r1 s1" "set-step r1 s1 completed extra" "set-output r1 s1 k" \
              "get-output r1 s1" "set-run-status r1" "set-gate r1 s1" "get-gate" "clear-gate" "checkpoint r1"; do
    # shellcheck disable=SC2086
    ss $args
    [ "$status" -eq 2 ] || { echo "'$args' gave status $status"; return 1; }
  done
  [ "$(snap r1)" = "$before" ]
}

@test "an invalid run id is exit 2 on reads and writes, before the disk is touched" {
  local id
  for id in "../x" "a/b" ".hidden" "a..b"; do
    ss get "$id"
    [ "$status" -eq 2 ] || { echo "get '$id' gave $status"; return 1; }
    ss set-step "$id" s1 completed
    [ "$status" -eq 2 ] || { echo "set-step '$id' gave $status"; return 1; }
  done
  [ ! -e "$RUNS" ]
}

# ---------------------------------------------------------------------------
# get
# ---------------------------------------------------------------------------

@test "get prints the same JSON as run-state.sh status" {
  write_run g1
  ss get g1
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$(bash "$RUN_STATE" status g1)" ]
  printf '%s\n' "$output" | jq -e '.run_id == "g1" and .schema_version == 1' >/dev/null
}

@test "get on an unknown run exits 3 naming the file, prints nothing and creates nothing" {
  ss get nope
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"$RUNS/nope.json"* ]]
  [[ "$stderr" == *"not found"* ]]
  [ ! -e "$RUNS" ]
}

# ---------------------------------------------------------------------------
# current-step
# ---------------------------------------------------------------------------

@test "current-step prints the first step that is not completed or skipped" {
  write_run c1
  ss current-step c1
  [ "$status" -eq 0 ]
  [ "$output" = "s1" ]
  mod c1 '.steps[0].status = "completed"'
  ss current-step c1
  [ "$output" = "s2" ]
  mod c1 '.steps[1].status = "skipped"'
  ss current-step c1
  [ "$output" = "s3" ]
  mod c1 '.steps[2].status = "in_progress"'
  ss current-step c1
  [ "$output" = "s3" ]
}

@test "current-step never moves past a failed step" {
  write_run c2
  mod c2 '.steps[0].status = "completed" | .steps[1].status = "failed"'
  ss current-step c2
  [ "$status" -eq 0 ]
  [ "$output" = "s2" ]
}

@test "current-step uses definition order, not status order, when a later step is already completed" {
  write_run c3
  mod c3 '.steps[2].status = "completed"'
  ss current-step c3
  [ "$output" = "s1" ]
}

@test "current-step prints nothing and exits 0 when every step is completed or skipped" {
  write_run c4
  mod c4 '.steps[0].status = "completed" | .steps[1].status = "skipped" | .steps[2].status = "completed"'
  ss current-step c4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "current-step does not write the state file" {
  write_run c5
  local before; before=$(snap c5)
  ss current-step c5
  [ "$(snap c5)" = "$before" ]
}

# ---------------------------------------------------------------------------
# set-step
# ---------------------------------------------------------------------------

@test "set-step accepts every status and stores it" {
  write_run st1
  local st
  for st in in_progress completed failed skipped pending; do
    ss set-step st1 s2 "$st"
    [ "$status" -eq 0 ] || { echo "status $st gave $status: $stderr"; return 1; }
    [ -z "$output" ]
    jq -e --arg st "$st" '.steps[1].status == $st' "$RUNS/st1.json" >/dev/null
  done
  no_tmp
}

@test "set-step in_progress stamps started_at and clears finished_at" {
  write_run st2
  mod st2 '.steps[0].finished_at = "2020-01-01T00:00:00Z"'
  ss set-step st2 s1 in_progress
  [ "$status" -eq 0 ]
  jq -e '.steps[0].started_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$RUNS/st2.json" >/dev/null
  jq -e '.steps[0].finished_at == null' "$RUNS/st2.json" >/dev/null
}

@test "set-step completed, failed and skipped stamp finished_at and keep started_at" {
  write_run st3
  ss set-step st3 s1 in_progress
  local started; started=$(jq -r '.steps[0].started_at' "$RUNS/st3.json")
  local st
  for st in completed failed skipped; do
    mod st3 '.steps[0].finished_at = null'
    ss set-step st3 s1 "$st"
    [ "$status" -eq 0 ]
    jq -e '.steps[0].finished_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$RUNS/st3.json" >/dev/null
    [ "$(jq -r '.steps[0].started_at' "$RUNS/st3.json")" = "$started" ]
  done
}

@test "set-step skipped on a step that never started leaves started_at null" {
  write_run st4
  ss set-step st4 s3 skipped
  [ "$status" -eq 0 ]
  jq -e '.steps[2].started_at == null and (.steps[2].finished_at | type) == "string"' "$RUNS/st4.json" >/dev/null
}

@test "set-step pending clears both timestamps" {
  write_run st5
  ss set-step st5 s1 in_progress
  ss set-step st5 s1 completed
  ss set-step st5 s1 pending
  [ "$status" -eq 0 ]
  jq -e '.steps[0].started_at == null and .steps[0].finished_at == null and .steps[0].status == "pending"' "$RUNS/st5.json" >/dev/null
}

@test "set-step changes only the named step, bumps updated_at and leaves the run status and history alone" {
  write_run st6
  ss set-step st6 s2 completed
  [ "$status" -eq 0 ]
  jq -e '.steps[0].status == "pending" and .steps[2].status == "pending" and .steps[1].status == "completed"' "$RUNS/st6.json" >/dev/null
  jq -e '.status == "running" and (.history | length) == 0 and .created_at == "2026-01-01T00:00:00Z"' "$RUNS/st6.json" >/dev/null
  jq -e '.updated_at != "2026-01-01T00:00:00Z"' "$RUNS/st6.json" >/dev/null
  # still a state file run-state.sh accepts
  run bash "$RUN_STATE" status st6
  [ "$status" -eq 0 ]
}

@test "set-step with an unknown step is exit 2 naming the step and the known steps; file untouched" {
  write_run st7
  local before; before=$(snap st7)
  ss set-step st7 nope completed
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unknown step 'nope'"* ]]
  [[ "$stderr" == *"s1, s2, s3"* ]]
  [ "$(snap st7)" = "$before" ]
  no_tmp
}

@test "set-step with an illegal status is exit 2 naming the status; file untouched" {
  write_run st8
  local before; before=$(snap st8)
  local bad
  for bad in done Completed running "" "in progress"; do
    ss set-step st8 s1 "$bad"
    [ "$status" -eq 2 ] || { echo "status '$bad' gave $status"; return 1; }
    [[ "$stderr" == *"illegal step status"* ]]
  done
  [ "$(snap st8)" = "$before" ]
}

@test "set-step on an unknown run exits 3 and creates nothing" {
  ss set-step ghost s1 completed
  [ "$status" -eq 3 ]
  [ ! -e "$RUNS" ]
}

# ---------------------------------------------------------------------------
# set-output / get-output
# ---------------------------------------------------------------------------

@test "set-output then get-output round-trips a value, byte for byte on the value line" {
  write_run o1
  ss set-output o1 s1 summary "two words & 'quotes' \"too\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ss get-output o1 s1 summary
  [ "$status" -eq 0 ]
  [ "$output" = "two words & 'quotes' \"too\"" ]
  jq -e '.steps[0].outputs.summary == "two words & '"'"'quotes'"'"' \"too\""' "$RUNS/o1.json" >/dev/null
}

@test "set-output replaces an earlier value of the same name and keeps other outputs and other steps" {
  write_run o2
  ss set-output o2 s1 a one
  ss set-output o2 s1 b two
  ss set-output o2 s1 a three
  ss set-output o2 s2 a other
  jq -e '.steps[0].outputs == {a: "three", b: "two"} and .steps[1].outputs == {a: "other"} and .steps[2].outputs == {}' "$RUNS/o2.json" >/dev/null
}

@test "set-output stores a multi-line value and an empty value; get-output returns them" {
  write_run o3
  ss set-output o3 s1 multi $'line one\nline two'
  [ "$status" -eq 0 ]
  ss set-output o3 s1 empty ""
  [ "$status" -eq 0 ]
  ss get-output o3 s1 multi
  [ "$status" -eq 0 ]
  [ "$output" = $'line one\nline two' ]
  ss get-output o3 s1 empty
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "get-output prints a non-string stored output as compact JSON" {
  write_run o4
  mod o4 '.steps[0].outputs = {n: 3, list: ["a","b"]}'
  ss get-output o4 s1 n
  [ "$output" = "3" ]
  ss get-output o4 s1 list
  [ "$output" = '["a","b"]' ]
}

@test "set-output with an unknown step or an empty name is exit 2; file untouched" {
  write_run o5
  local before; before=$(snap o5)
  ss set-output o5 nope k v
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown step 'nope'"* ]]
  ss set-output o5 s1 "" v
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"empty output name"* ]]
  [ "$(snap o5)" = "$before" ]
}

@test "get-output on a missing output exits 1 naming the missing output; nothing on stdout" {
  write_run o6
  ss get-output o6 s1 absent
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no output named 'absent'"* ]]
  [[ "$stderr" == *"missing output"* ]]
}

@test "get-output on a skipped step exits 1 and names 'skipped'" {
  write_run o7
  ss set-output o7 s1 k v
  ss set-step o7 s1 skipped
  ss get-output o7 s1 k
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"skipped"* ]]
}

@test "get-output on a failed step exits 1 and names 'failed', even when the output was stored earlier" {
  write_run o8
  ss set-output o8 s1 k v
  ss set-step o8 s1 failed
  ss get-output o8 s1 k
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"failed"* ]]
}

@test "get-output on an unknown step is exit 2; on an unknown run exit 3" {
  write_run o9
  ss get-output o9 nope k
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown step 'nope'"* ]]
  ss get-output ghost s1 k
  [ "$status" -eq 3 ]
}

# ---------------------------------------------------------------------------
# set-run-status
# ---------------------------------------------------------------------------

@test "set-run-status allows running -> awaiting_confirmation -> running and records history" {
  write_run r1
  ss set-run-status r1 awaiting_confirmation
  [ "$status" -eq 0 ]
  jq -e '.status == "awaiting_confirmation"' "$RUNS/r1.json" >/dev/null
  ss set-run-status r1 running
  [ "$status" -eq 0 ]
  jq -e '.status == "running" and (.history | length) == 2' "$RUNS/r1.json" >/dev/null
  jq -e '.history[0].from == "running" and .history[0].to == "awaiting_confirmation" and .history[1].from == "awaiting_confirmation" and .history[1].to == "running"' "$RUNS/r1.json" >/dev/null
  jq -e '(.history[0] | keys) == ["at","from","note","to"] and (.history[0].at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and (.history[0].note | length) > 0' "$RUNS/r1.json" >/dev/null
}

@test "set-run-status allows running -> failed and running -> completed" {
  write_run r2
  ss set-run-status r2 failed
  [ "$status" -eq 0 ]
  jq -e '.status == "failed" and (.history | length) == 1 and .history[0].to == "failed"' "$RUNS/r2.json" >/dev/null
  write_run r3
  ss set-run-status r3 completed
  [ "$status" -eq 0 ]
  jq -e '.status == "completed" and (.history | length) == 1 and .history[0].to == "completed"' "$RUNS/r3.json" >/dev/null
}

@test "set-run-status refuses every transition outside the allowed four with exit 1; file untouched" {
  local from to
  for from in running paused awaiting_confirmation failed completed cancelled; do
    for to in running paused awaiting_confirmation failed completed cancelled; do
      case "$from>$to" in
        running\>awaiting_confirmation|awaiting_confirmation\>running|running\>failed|running\>completed) continue ;;
      esac
      write_run rt "$from"
      local before; before=$(snap rt)
      ss set-run-status rt "$to"
      [ "$status" -eq 1 ] || { echo "$from -> $to gave status $status"; return 1; }
      [ -z "$output" ]
      [[ "$stderr" == *"refused transition"* ]] || { echo "$from -> $to stderr: $stderr"; return 1; }
      [ "$(snap rt)" = "$before" ] || { echo "$from -> $to changed the file"; return 1; }
    done
  done
  no_tmp
}

@test "set-run-status with an illegal status is exit 2; file untouched" {
  write_run r4
  local before; before=$(snap r4)
  local bad
  for bad in done RUNNING in_progress ""; do
    ss set-run-status r4 "$bad"
    [ "$status" -eq 2 ] || { echo "status '$bad' gave $status"; return 1; }
    [[ "$stderr" == *"illegal run status"* ]]
  done
  [ "$(snap r4)" = "$before" ]
}

@test "set-run-status on an unknown run exits 3" {
  ss set-run-status ghost failed
  [ "$status" -eq 3 ]
}

# ---------------------------------------------------------------------------
# set-gate / get-gate / clear-gate
# ---------------------------------------------------------------------------

@test "set-gate then get-gate round-trips the record with step id and timestamp" {
  write_run g1
  ss set-gate g1 s2 '{"prompt":"Continue?","options":["Yes","No","Other"]}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ss get-gate g1
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.step_id == "s2" and .gate.prompt == "Continue?" and (.gate.options | length) == 3 and (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' >/dev/null
}

@test "a run with a pending gate is still a valid state file for run-state.sh status and list" {
  write_run g2
  ss set-gate g2 s1 '{"prompt":"p"}'
  [ "$status" -eq 0 ]
  run bash "$RUN_STATE" status g2
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.pending_gate.step_id == "s1"' >/dev/null
  run bash "$RUN_STATE" list
  [ "$status" -eq 0 ]
  [[ "$output" == g2$'\t'* ]]
}

@test "set-gate replaces a gate that is already pending" {
  write_run g3
  ss set-gate g3 s1 '{"prompt":"first"}'
  ss set-gate g3 s2 '{"prompt":"second"}'
  [ "$status" -eq 0 ]
  jq -e '.pending_gate.step_id == "s2" and .pending_gate.gate.prompt == "second"' "$RUNS/g3.json" >/dev/null
}

@test "set-gate accepts any JSON document except null (array, string, number)" {
  write_run g4
  local doc
  for doc in '["a","b"]' '"just text"' '42'; do
    ss set-gate g4 s1 "$doc"
    [ "$status" -eq 0 ] || { echo "'$doc' gave $status"; return 1; }
    [ "$(jq -c '.pending_gate.gate' "$RUNS/g4.json")" = "$doc" ]
  done
}

@test "set-gate with invalid JSON, null, two documents or empty is exit 2; file untouched" {
  write_run g5
  local before; before=$(snap g5)
  local bad
  for bad in '{bad' 'null' '{"a":1} {"b":2}' ''; do
    ss set-gate g5 s1 "$bad"
    [ "$status" -eq 2 ] || { echo "'$bad' gave $status"; return 1; }
    [[ "$stderr" == *"not one valid JSON document"* ]]
  done
  [ "$(snap g5)" = "$before" ]
}

@test "set-gate with an unknown step is exit 2; file untouched" {
  write_run g6
  local before; before=$(snap g6)
  ss set-gate g6 nope '{"prompt":"p"}'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown step 'nope'"* ]]
  [ "$(snap g6)" = "$before" ]
}

@test "get-gate with no pending gate exits 1 with nothing on stdout" {
  write_run g7
  ss get-gate g7
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no pending gate"* ]]
}

@test "clear-gate removes the key entirely and get-gate then exits 1" {
  write_run g8
  ss set-gate g8 s1 '{"prompt":"p"}'
  ss clear-gate g8
  [ "$status" -eq 0 ]
  jq -e 'has("pending_gate") | not' "$RUNS/g8.json" >/dev/null
  ss get-gate g8
  [ "$status" -eq 1 ]
}

@test "clear-gate with no gate pending exits 0 and does not write" {
  write_run g9
  local before; before=$(snap g9)
  ss clear-gate g9
  [ "$status" -eq 0 ]
  [ "$(snap g9)" = "$before" ]
}

@test "a gate survives other writes and is still pending afterwards" {
  write_run g10
  ss set-gate g10 s1 '{"prompt":"p"}'
  ss set-step g10 s1 in_progress
  ss set-run-status g10 awaiting_confirmation
  ss get-gate g10
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.gate.prompt == "p"' >/dev/null
}

# ---------------------------------------------------------------------------
# checkpoint
# ---------------------------------------------------------------------------

@test "checkpoint records last_checkpoint for a completed step whose definition says checkpoint true" {
  write_run k1
  ss set-step k1 s1 completed
  ss checkpoint k1 s1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  jq -e '.last_checkpoint == "s1"' "$RUNS/k1.json" >/dev/null
}

@test "checkpoint on a step that is not completed is exit 1 naming the status; file untouched" {
  write_run k2
  local before; before=$(snap k2)
  local st
  for st in pending in_progress failed skipped; do
    mod k2 '.steps[0].status = $st' --arg st "$st"
    before=$(snap k2)
    ss checkpoint k2 s1
    [ "$status" -eq 1 ] || { echo "$st gave $status"; return 1; }
    [[ "$stderr" == *"'$st'"* ]] || { echo "$st: $stderr"; return 1; }
    [ "$(snap k2)" = "$before" ]
  done
}

@test "checkpoint on a completed step whose definition lacks checkpoint true is exit 1; file untouched" {
  write_run k3
  ss set-step k3 s2 completed
  local before; before=$(snap k3)
  ss checkpoint k3 s2
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"checkpoint: true"* ]]
  [ "$(snap k3)" = "$before" ]
  jq -e '.last_checkpoint == null' "$RUNS/k3.json" >/dev/null
}

@test "checkpoint with an unknown step is exit 2; on an unknown run exit 3" {
  write_run k4
  ss checkpoint k4 nope
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown step 'nope'"* ]]
  ss checkpoint ghost s1
  [ "$status" -eq 3 ]
}

@test "a later checkpoint replaces an earlier one" {
  write_run k5
  mod k5 '.steps[1].checkpoint = true'
  ss set-step k5 s1 completed
  ss set-step k5 s2 completed
  ss checkpoint k5 s1
  ss checkpoint k5 s2
  [ "$status" -eq 0 ]
  jq -e '.last_checkpoint == "s2"' "$RUNS/k5.json" >/dev/null
}

# ---------------------------------------------------------------------------
# a second process, concurrency
# ---------------------------------------------------------------------------

@test "a second process started later, from another directory, reads what the first wrote" {
  write_run p1
  (
    bash "$SCRIPT" set-step p1 s1 completed
    bash "$SCRIPT" set-output p1 s1 result "from-process-one"
    bash "$SCRIPT" set-gate p1 s2 '{"prompt":"go?"}'
    bash "$SCRIPT" set-run-status p1 awaiting_confirmation
  )
  run --separate-stderr bash -c 'cd / && bash "$1" get-output p1 s1 result && bash "$1" current-step p1 && bash "$1" get-gate p1 | jq -r .step_id && bash "$2" status p1 | jq -r .status' _ "$SCRIPT" "$RUN_STATE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "from-process-one" ]
  [ "${lines[1]}" = "s2" ]
  [ "${lines[2]}" = "s2" ]
  [ "${lines[3]}" = "awaiting_confirmation" ]
}

@test "concurrent writers are serialised: every parallel set-output lands and the file stays valid" {
  write_run par
  local i
  for i in 1 2 3 4 5 6; do
    bash "$SCRIPT" set-output par s1 "k$i" "v$i" 3>&- &
  done
  wait
  for i in 1 2 3 4 5 6; do
    jq -e --arg k "k$i" --arg v "v$i" '.steps[0].outputs[$k] == $v' "$RUNS/par.json" >/dev/null || { echo "lost write k$i"; return 1; }
  done
  run bash "$RUN_STATE" status par
  [ "$status" -eq 0 ]
  no_tmp
  [ ! -e "$RUNS/par.json.lock.d" ]
}

# ---------------------------------------------------------------------------
# corrupt and missing files, on every subcommand
# ---------------------------------------------------------------------------

# Every subcommand with arguments that are valid for the fixtures, one per line (run id is filled in).
ALL_COMMANDS=(
  "get"
  "current-step"
  "set-step @ s1 completed"
  "set-output @ s1 k v"
  "get-output @ s1 k"
  "set-run-status @ failed"
  "set-gate @ s1 {}"
  "get-gate @"
  "clear-gate @"
  "checkpoint @ s1"
)

# run_all_on <id> <expected status>: every subcommand on run <id> exits with the expected status, prints nothing on
# stdout and names the state file on stderr.
run_all_on() {
  local id="$1" want="$2" spec cmd rest
  for spec in "${ALL_COMMANDS[@]}"; do
    cmd="${spec%% *}"
    rest="${spec#"$cmd"}"
    rest="${rest# }"
    # "@" stands for the run id. "get" and "current-step" are written without it above, so add it here.
    case "$spec" in
      *@*) rest="${rest/@/$id}" ;;
      *) rest="$id" ;;
    esac
    # shellcheck disable=SC2086
    run --separate-stderr bash "$SCRIPT" "$cmd" $rest
    [ "$status" -eq "$want" ] || { echo "$cmd gave status $status, wanted $want ($stderr)"; return 1; }
    [ -z "$output" ] || { echo "$cmd printed on stdout: $output"; return 1; }
    [[ "$stderr" == *"$RUNS/$id.json"* ]] || { echo "$cmd stderr does not name the file: $stderr"; return 1; }
  done
}

@test "every subcommand exits 4 naming the file on an empty state file, which is left untouched" {
  mkdir -p "$RUNS"
  : > "$RUNS/empty.json"
  run_all_on empty 4
  [ ! -s "$RUNS/empty.json" ]
  no_tmp
}

@test "every subcommand exits 4 naming the file on truncated JSON, which is left byte-identical" {
  write_run trunc
  head -c 60 "$RUNS/trunc.json" > "$RUNS/trunc.part" && mv "$RUNS/trunc.part" "$RUNS/trunc.json"
  local before; before=$(snap trunc)
  run_all_on trunc 4
  [ "$(snap trunc)" = "$before" ]
  no_tmp
}

@test "every subcommand exits 4 on valid JSON that lacks a required key or has the wrong schema_version" {
  write_run nokey
  mod nokey 'del(.definition_hash)'
  local before; before=$(snap nokey)
  run_all_on nokey 4
  [ "$(snap nokey)" = "$before" ]
  write_run badver
  mod badver '.schema_version = 2'
  before=$(snap badver)
  run_all_on badver 4
  [ "$(snap badver)" = "$before" ]
  write_run notobj
  printf '[1,2,3]\n' > "$RUNS/notobj.json"
  before=$(snap notobj)
  run_all_on notobj 4
  [ "$(snap notobj)" = "$before" ]
}

@test "every subcommand exits 3 naming the file for an unknown run and creates nothing" {
  run_all_on ghost 3
  [ ! -e "$RUNS" ]
}

# ---------------------------------------------------------------------------
# lock held: every write aborts, file byte-identical
# ---------------------------------------------------------------------------

@test "with the lock held by another process every write subcommand exits 5 and leaves the file byte-identical" {
  write_run locked
  ss set-step locked s1 completed
  ss set-gate locked s2 '{"prompt":"p"}'
  local before; before=$(snap locked)
  bash "$REPO_ROOT/scripts/with-lock.sh" "$RUNS/locked.json" -- sleep 10 3>&- &
  local holder=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -d "$RUNS/locked.json.lock.d" ] && break
    sleep 0.2
  done
  [ -d "$RUNS/locked.json.lock.d" ]
  local rc=0 failed=""
  export WITH_LOCK_TIMEOUT_SECONDS=1
  local spec
  for spec in "set-step locked s2 completed" "set-output locked s1 k v" "set-run-status locked failed" \
              "set-gate locked s1 {\"prompt\":\"q\"}" "clear-gate locked" "checkpoint locked s1"; do
    run --separate-stderr bash "$SCRIPT" $spec
    if [ "$status" -ne 5 ]; then failed="$failed [$spec -> $status]"; fi
    if [[ "$stderr" != *"lock"* ]]; then failed="$failed [$spec: no lock message]"; fi
    if [ "$(snap locked)" != "$before" ]; then failed="$failed [$spec changed the file]"; fi
  done
  unset WITH_LOCK_TIMEOUT_SECONDS
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null || true
  [ -z "$failed" ] || { echo "problems:$failed"; return 1; }
  no_tmp
}

@test "reads are not blocked by a held lock" {
  write_run lockread
  bash "$REPO_ROOT/scripts/with-lock.sh" "$RUNS/lockread.json" -- sleep 6 3>&- &
  local holder=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -d "$RUNS/lockread.json.lock.d" ] && break
    sleep 0.2
  done
  ss get lockread
  local rc1=$status
  ss current-step lockread
  local rc2=$status
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null || true
  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]
}
