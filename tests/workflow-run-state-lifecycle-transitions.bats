#!/usr/bin/env bats
#
# E80_S02_T05: the run lifecycle transition table (assert_transition), run_state_transition, and the pause and
# cancel commands of scripts/workflow/run-state.sh.
#
# Every test builds its own throwaway working-file tree under $BATS_TEST_TMPDIR and exports JENGA_PROJECT_ROOT at
# it, so the real runs directory of this repository is never read or written.
#
# Mirror safety: depends only on scripts/workflow/run-state.sh, scripts/resolve-root.sh, scripts/with-lock.sh and
# fixtures it builds.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/run-state.sh"

STATUSES="running awaiting_confirmation paused failed completed cancelled"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS
  mkdir -p "$BATS_TEST_TMPDIR/anchor/project/configs"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/anchor/project/configs/workflow.json"
  ANCHOR="$(cd "$BATS_TEST_TMPDIR/anchor" && pwd)"
  RUNS="$ANCHOR/project/data/workflow-runs"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  cd "$BATS_TEST_TMPDIR" || return 1
}

# write_run <id> <status>: a valid state file with one in_progress and one pending step and an empty history.
write_run() {
  mkdir -p "$RUNS"
  jq -n --arg id "$1" --arg st "$2" '{
    schema_version: 1, run_id: $id, workflow_id: "wf-a", definition_hash: "abc123",
    inputs: {}, status: $st, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z",
    last_checkpoint: null, definition_change_ack: null,
    steps: [{id: "s1", type: "command", checkpoint: false, status: "in_progress",
             started_at: "2026-01-01T00:00:00Z", finished_at: null, outputs: {}},
            {id: "s2", type: "command", checkpoint: false, status: "pending",
             started_at: null, finished_at: null, outputs: {}}],
    history: []
  }' > "$RUNS/$1.json"
}

# legal <from> <to>: the table, written out independently of the script, as the oracle for the enumeration.
legal() {
  case "$1:$2" in
    running:paused|running:awaiting_confirmation|running:failed|running:completed|running:cancelled) return 0 ;;
    awaiting_confirmation:running|awaiting_confirmation:paused|awaiting_confirmation:failed|awaiting_confirmation:cancelled) return 0 ;;
    paused:running|paused:cancelled) return 0 ;;
    failed:running|failed:cancelled) return 0 ;;
  esac
  return 1
}

call_fn() {
  run --separate-stderr bash -c 'set -u; . "$1"; shift; "$@"' _ "$SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# assert_transition: the 6 x 6 table
# ---------------------------------------------------------------------------

@test "assert_transition accepts or refuses each of the 36 from/to pairs exactly as the table says" {
  local from to checked=0
  for from in $STATUSES; do
    for to in $STATUSES; do
      call_fn assert_transition "$from" "$to" r1
      if legal "$from" "$to"; then
        [ "$status" -eq 0 ] || { echo "expected legal: $from -> $to (rc $status)"; return 1; }
        [ -z "$stderr" ] || { echo "legal move printed: $stderr"; return 1; }
      else
        [ "$status" -eq 1 ] || { echo "expected refused: $from -> $to (rc $status)"; return 1; }
        [[ "$stderr" == "run r1 is $from; cannot move to $to (legal from $from: "* ]] || { echo "bad message: $stderr"; return 1; }
      fi
      checked=$((checked + 1))
    done
  done
  [ "$checked" -eq 36 ]
}

@test "assert_transition refuses x -> x for every status" {
  local s
  for s in $STATUSES; do
    call_fn assert_transition "$s" "$s" r1
    [ "$status" -eq 1 ] || { echo "$s -> $s was accepted"; return 1; }
  done
}

@test "assert_transition message lists the legal moves, or 'none, terminal' for a terminal status" {
  call_fn assert_transition paused paused run-9
  [ "$status" -eq 1 ]
  [ "$stderr" = "run run-9 is paused; cannot move to paused (legal from paused: running, cancelled)" ]
  call_fn assert_transition completed running run-9
  [ "$stderr" = "run run-9 is completed; cannot move to running (legal from completed: none, terminal)" ]
  call_fn assert_transition cancelled paused run-9
  [ "$stderr" = "run run-9 is cancelled; cannot move to paused (legal from cancelled: none, terminal)" ]
  call_fn assert_transition running running run-9
  [ "$stderr" = "run run-9 is running; cannot move to running (legal from running: paused, awaiting_confirmation, failed, completed, cancelled)" ]
}

@test "assert_transition refuses an unknown status name" {
  call_fn assert_transition running bogus r1
  [ "$status" -eq 1 ]
  call_fn assert_transition bogus running r1
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# pause
# ---------------------------------------------------------------------------

@test "pause moves running -> paused, appends a history entry, updates updated_at and prints the new status" {
  write_run r1 running
  run --separate-stderr bash "$SCRIPT" pause r1
  [ "$status" -eq 0 ]
  [ "$output" = "paused" ]
  [ "$(jq -r .status "$RUNS/r1.json")" = "paused" ]
  [ "$(jq '.history | length' "$RUNS/r1.json")" -eq 1 ]
  jq -e '.history[0] | (.from == "running") and (.to == "paused") and (.note | type == "string" and length > 0) and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' "$RUNS/r1.json" >/dev/null
  [ "$(jq -r .updated_at "$RUNS/r1.json")" != "2026-01-01T00:00:00Z" ]
  [ "$(jq -r '.history[0].at' "$RUNS/r1.json")" = "$(jq -r .updated_at "$RUNS/r1.json")" ]
  [ "$(jq -r .created_at "$RUNS/r1.json")" = "2026-01-01T00:00:00Z" ]
}

@test "pause moves awaiting_confirmation -> paused" {
  write_run r1 awaiting_confirmation
  run --separate-stderr bash "$SCRIPT" pause r1
  [ "$status" -eq 0 ]
  [ "$output" = "paused" ]
  jq -e '.status == "paused" and .history[0].from == "awaiting_confirmation" and .history[0].to == "paused"' "$RUNS/r1.json" >/dev/null
}

@test "pause leaves an in_progress step in_progress and does not touch other steps" {
  write_run r1 running
  run bash "$SCRIPT" pause r1
  [ "$status" -eq 0 ]
  jq -e '.steps[0].status == "in_progress" and .steps[1].status == "pending"' "$RUNS/r1.json" >/dev/null
}

@test "pause on paused, failed, completed and cancelled exits 1 with the message and leaves the file byte-identical" {
  local s before
  for s in paused failed completed cancelled; do
    write_run "r-$s" "$s"
    before=$(cksum < "$RUNS/r-$s.json")
    run --separate-stderr bash "$SCRIPT" pause "r-$s"
    [ "$status" -eq 1 ] || { echo "$s: rc $status"; return 1; }
    [ -z "$output" ]
    [[ "$stderr" == "run r-$s is $s; cannot move to paused (legal from $s: "* ]] || { echo "$s: $stderr"; return 1; }
    [ "$(cksum < "$RUNS/r-$s.json")" = "$before" ]
  done
  run --separate-stderr bash "$SCRIPT" pause r-completed
  [ "$stderr" = "run r-completed is completed; cannot move to paused (legal from completed: none, terminal)" ]
  run --separate-stderr bash "$SCRIPT" pause r-failed
  [ "$stderr" = "run r-failed is failed; cannot move to paused (legal from failed: running, cancelled)" ]
}

# ---------------------------------------------------------------------------
# cancel
# ---------------------------------------------------------------------------

@test "cancel works from running, paused, awaiting_confirmation and failed" {
  local s
  for s in running paused awaiting_confirmation failed; do
    write_run "r-$s" "$s"
    run --separate-stderr bash "$SCRIPT" cancel "r-$s"
    [ "$status" -eq 0 ] || { echo "$s: rc $status $stderr"; return 1; }
    [ "$output" = "cancelled" ]
    jq -e --arg s "$s" '.status == "cancelled" and (.history | length) == 1 and .history[0].from == $s and .history[0].to == "cancelled"' "$RUNS/r-$s.json" >/dev/null
    [ "$(jq -r .updated_at "$RUNS/r-$s.json")" != "2026-01-01T00:00:00Z" ]
  done
}

@test "cancel keeps the run file and leaves pending and in_progress steps as they are" {
  write_run r1 running
  run bash "$SCRIPT" cancel r1
  [ "$status" -eq 0 ]
  [ -f "$RUNS/r1.json" ]
  jq -e '.steps[0].status == "in_progress" and .steps[1].status == "pending"' "$RUNS/r1.json" >/dev/null
}

@test "cancel on completed and cancelled exits 1 and leaves the file byte-identical" {
  local s before
  for s in completed cancelled; do
    write_run "r-$s" "$s"
    before=$(cksum < "$RUNS/r-$s.json")
    run --separate-stderr bash "$SCRIPT" cancel "r-$s"
    [ "$status" -eq 1 ]
    [ "$stderr" = "run r-$s is $s; cannot move to cancelled (legal from $s: none, terminal)" ]
    [ "$(cksum < "$RUNS/r-$s.json")" = "$before" ]
  done
}

# ---------------------------------------------------------------------------
# unknown run, corrupt file, usage
# ---------------------------------------------------------------------------

@test "pause and cancel on an unknown run id exit 3 and create nothing" {
  run --separate-stderr bash "$SCRIPT" pause no-such-run
  [ "$status" -eq 3 ]
  run --separate-stderr bash "$SCRIPT" cancel no-such-run
  [ "$status" -eq 3 ]
  [ ! -e "$RUNS" ]
}

@test "pause and cancel on a corrupt file exit 4 with no write" {
  local content before cmd
  mkdir -p "$RUNS"
  for content in 'not json' '' '{"schema_version":1}' '[]'; do
    printf '%s' "$content" > "$RUNS/bad.json"
    before=$(cksum < "$RUNS/bad.json")
    for cmd in pause cancel; do
      run --separate-stderr bash "$SCRIPT" "$cmd" bad
      [ "$status" -eq 4 ] || { echo "$cmd on '$content': rc $status"; return 1; }
      [ "$(cksum < "$RUNS/bad.json")" = "$before" ]
    done
  done
  [ -z "$(ls -A "$RUNS" | grep -v '^bad.json$')" ]
}

@test "pause and cancel reject a bad run id (exit 2) and a missing argument (exit 2)" {
  run --separate-stderr bash "$SCRIPT" pause "../x"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" pause
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" cancel a b
  [ "$status" -eq 2 ]
}

@test "usage text lists pause and cancel" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pause <run_id>"* ]]
  [[ "$output" == *"cancel <run_id>"* ]]
}

# ---------------------------------------------------------------------------
# run_state_transition (the reusable function)
# ---------------------------------------------------------------------------

@test "run_state_transition applies a legal move with the given note and refuses an illegal one" {
  write_run r1 failed
  call_fn run_state_transition r1 running "retry"
  [ "$status" -eq 0 ]
  jq -e '.status == "running" and .history[0].note == "retry" and .history[0].from == "failed"' "$RUNS/r1.json" >/dev/null
  write_run r2 completed
  call_fn run_state_transition r2 running "retry"
  [ "$status" -eq 1 ]
  [ "$(jq -r .status "$RUNS/r2.json")" = "completed" ]
}

# ---------------------------------------------------------------------------
# race
# ---------------------------------------------------------------------------

@test "concurrent pause and cancel on one running run leave valid JSON and a consistent history" {
  local i pf cf
  for i in 1 2 3 4 5 6; do
    write_run "race$i" running
    bash "$SCRIPT" pause "race$i" >"$BATS_TEST_TMPDIR/p$i.out" 2>"$BATS_TEST_TMPDIR/p$i.err" &
    pf=$!
    bash "$SCRIPT" cancel "race$i" >"$BATS_TEST_TMPDIR/c$i.out" 2>"$BATS_TEST_TMPDIR/c$i.err" &
    cf=$!
    local prc=0 crc=0
    wait "$pf" || prc=$?
    wait "$cf" || crc=$?
    jq -e . "$RUNS/race$i.json" >/dev/null
    # cancel is legal from both running and paused, so it always succeeds and the run always ends cancelled;
    # pause either went first (exit 0, two history entries) or lost to cancel (exit 1, one entry).
    [ "$crc" -eq 0 ] || { echo "run $i: cancel rc $crc"; return 1; }
    [ "$(jq -r .status "$RUNS/race$i.json")" = "cancelled" ]
    case "$prc" in
      0) [ "$(jq '.history | length' "$RUNS/race$i.json")" -eq 2 ] ;;
      1) [ "$(jq '.history | length' "$RUNS/race$i.json")" -eq 1 ] ;;
      *) echo "run $i: pause rc $prc"; return 1 ;;
    esac
    # chain consistency: the first entry starts at the run's initial status, then each from equals the previous to
    jq -e '.history as $h
      | ($h[0].from == "running")
        and ([range(1; $h | length)] | all(. as $k | $h[$k].from == $h[$k - 1].to))
        and ($h[-1].to == .status)' "$RUNS/race$i.json" >/dev/null
  done
  [ -z "$(ls -A "$RUNS" | grep -v '^race[0-9]*.json$')" ]
}

@test "two concurrent cancels on one run: exactly one wins, the other is refused, history has one entry" {
  local a b arc=0 brc=0
  write_run r1 running
  bash "$SCRIPT" cancel r1 >/dev/null 2>&1 &
  a=$!
  bash "$SCRIPT" cancel r1 >/dev/null 2>&1 &
  b=$!
  wait "$a" || arc=$?
  wait "$b" || brc=$?
  [ $((arc + brc)) -eq 1 ]
  [ "$(jq '.history | length' "$RUNS/r1.json")" -eq 1 ]
}
