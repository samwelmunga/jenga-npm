#!/usr/bin/env bats
#
# Regression coverage for E32_S16 — proving a /jenga-style wave of MORE than
# max_concurrent_developers independent dispatches still caps concurrent
# developer slot holders at the configured value, once every dispatch shares
# one orchestrator_session_id (E32_S16_T01's fix).
#
# Why this file exists
# ---------------------
# E32_S15 built scripts/acquire-concurrency-slot.sh / release-concurrency-slot.sh
# and (per that story's own summaries) any coverage of them exercised the
# scripts' own atomicity in isolation — a single caller, sequential exit-code
# checks. That was never where E32_S16's bug lived: the acquire script always
# correctly enforced its cap against ONE counter file. The defect was that
# skills/jenga/SKILL.md's Phase 4 never made concurrent /do dispatches share
# that one counter file in the first place — each spawned /do minted its own
# private orchestrator_session_id, so N independent dispatches got N private,
# uncontended counter files and the cap never contended across the wave at
# all (E32_S16's own Context section: "7 developers observed running
# concurrently against a configured cap of 3").
#
# skills/jenga/SKILL.md and skills/do/SKILL.md are agent instructions, not
# executable code — there is nothing in either file a bats test can invoke
# directly. What IS mechanically testable, and what actually demonstrates
# both sides of the fix, is the shared primitive every dispatch bottlenecks
# through: scripts/acquire-concurrency-slot.sh keyed by session_id. So this
# suite drives that script directly from REAL background (not sequential)
# processes standing in for N concurrent /do dispatches, in two scenarios:
#
#   1. Each dispatch mints its OWN session_id (the pre-fix behavior) -- every
#      one of the N acquires its own private counter file and succeeds, even
#      though N > cap. This reproduces the cap-bypass defect itself.
#   2. Every dispatch shares ONE session_id (the post-E32_S16_T01 behavior)
#      -- only `cap` acquires succeed; the remaining (N - cap) are
#      capacity_blocked (exit 3). This is the fix holding under real
#      concurrent load, not just sequential single-caller checks.
#
# Everything runs against a throwaway fixture project under $BATS_TEST_TMPDIR
# with its own scope-thresholds.json (max_concurrent_developers=2, a value
# deliberately DIFFERENT from this repo's real configured value of 3, and
# read live via jq rather than assumed) and copies of the REAL
# scripts/with-lock.sh + acquire-concurrency-slot.sh + release-concurrency-slot.sh
# -- never against this repository's own project/queue/.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ACQUIRE_SRC="$REPO_ROOT/scripts/acquire-concurrency-slot.sh"
RELEASE_SRC="$REPO_ROOT/scripts/release-concurrency-slot.sh"
LOCK_SRC="$REPO_ROOT/scripts/with-lock.sh"

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$FIXTURE/scripts" "$FIXTURE/project/configs" "$FIXTURE/project/queue"
  cp "$ACQUIRE_SRC" "$FIXTURE/scripts/acquire-concurrency-slot.sh"
  cp "$RELEASE_SRC" "$FIXTURE/scripts/release-concurrency-slot.sh"
  cp "$LOCK_SRC" "$FIXTURE/scripts/with-lock.sh"
  chmod +x "$FIXTURE"/scripts/*.sh

  # max_concurrent_developers deliberately set to 2 here -- NOT this repo's
  # real value (3) -- and read live via jq below, so this suite can never be
  # accused of silently assuming/hardcoding "3".
  cat > "$FIXTURE/project/configs/scope-thresholds.json" <<'JSON'
{
  "threshold_version": 1,
  "inline_max_files": 3,
  "inline_max_lines": 75,
  "story_max_files": 5,
  "bundle_lock_ttl_minutes": 30,
  "max_concurrent_developers": 2,
  "max_concurrent_testers": 2,
  "slot_ttl_minutes": 45
}
JSON

  CAP="$(jq -r '.max_concurrent_developers' "$FIXTURE/project/configs/scope-thresholds.json")"
  N=$((CAP + 3))

  export JENGA_PROJECT_DIR="$FIXTURE"
  export CAP
  export N
}

# Fires $N acquire calls as REAL background processes (not sequential `run`
# calls) so the with-lock.sh critical section is genuinely contended, then
# waits for all of them and records each one's own exit code to a per-holder
# file (bats' `run` can't be used here -- it only captures one foreground
# command at a time).
#
# $1 selects which session-id shape this wave uses:
#   "shared:<session_id>"  -- every one of the N dispatches uses this exact
#                              value (the post-E32_S16_T01 fix shape).
#   "private"               -- each dispatch i mints its own
#                              "private-session-<i>" (the pre-fix shape).
# Passed as a plain argument rather than an exported variable so each
# dispatch's session id is resolved directly in this function's own scope,
# with nothing for a background subshell to read back out.
fire_concurrent_acquires() {
  local mode="$1"
  local results_dir="$2"
  mkdir -p "$results_dir"
  local i sid
  for i in $(seq 1 "$N"); do
    case "$mode" in
      shared:*) sid="${mode#shared:}" ;;
      private) sid="private-session-$i" ;;
      *) return 1 ;;
    esac
    (
      # `set +e` is required here: bats runs test bodies (and every subshell
      # forked from them, including this backgrounded one) under `set -e`.
      # A capacity_blocked acquire deliberately exits 3 -- without disabling
      # errexit for just this subshell, the acquire's own non-zero exit would
      # abort the subshell before the `echo "$?"` line below ever ran,
      # silently dropping that holder's result instead of recording exit 3.
      set +e
      bash "$JENGA_PROJECT_DIR/scripts/acquire-concurrency-slot.sh" developer "holder-$i" "$sid" > "$results_dir/holder-$i.log" 2>&1
      echo "$?" > "$results_dir/holder-$i.exit"
    ) &
  done
  wait
}

count_exit_code() {
  local results_dir="$1"
  local want="$2"
  local count=0
  local f
  for f in "$results_dir"/holder-*.exit; do
    [ -f "$f" ] || continue
    if [ "$(cat "$f")" = "$want" ]; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

@test "N private session ids (pre-fix shape): all N acquires succeed even though N > cap" {
  RESULTS="$BATS_TEST_TMPDIR/results-private"
  fire_concurrent_acquires private "$RESULTS"

  successes="$(count_exit_code "$RESULTS" 0)"
  [ "$successes" -eq "$N" ]

  # Each dispatch got its OWN counter file -- N separate, uncontended files --
  # which is the literal shape of the bug this story fixes: nothing ever
  # contends against a shared cap when nobody shares a session id.
  counter_file_count="$(find "$JENGA_PROJECT_DIR/project/queue" -maxdepth 1 -name 'concurrency-slots-private-session-*.json' | wc -l | tr -d ' ')"
  [ "$counter_file_count" -eq "$N" ]
}

@test "one shared orchestrator_session_id (post-E32_S16_T01 fix): only cap acquires succeed, rest are capacity_blocked" {
  RESULTS="$BATS_TEST_TMPDIR/results-shared"
  SESSION_ID="shared-wave-session-20260917T000000Z"
  fire_concurrent_acquires "shared:$SESSION_ID" "$RESULTS"

  successes="$(count_exit_code "$RESULTS" 0)"
  blocked="$(count_exit_code "$RESULTS" 3)"

  [ "$successes" -eq "$CAP" ]
  [ "$blocked" -eq "$((N - CAP))" ]

  # Exactly one shared counter file exists for the whole wave, and its
  # holders count matches the cap exactly -- never more.
  COUNTER_FILE="$JENGA_PROJECT_DIR/project/queue/concurrency-slots-${SESSION_ID}.json"
  [ -f "$COUNTER_FILE" ]
  holders_count="$(jq '.developer.holders | length' "$COUNTER_FILE")"
  [ "$holders_count" -eq "$CAP" ]

  # A static snapshot from a real run of this exact assertion is committed at
  # tests/fixtures/E32_S16_T04-cap-holds-counter-snapshot.json (captured once
  # during E32_S16_T04's implementation -- see that file's own header comment
  # and this task's closing commit message). This test intentionally does NOT
  # write into the tracked tests/fixtures/ directory on every run: a bats
  # suite that mutates its own source tree as a side effect of merely running
  # would make every CI run diff-dirty and would race under parallel test
  # execution.
}

@test "a released slot from the shared wave can be reacquired (cap is a live ceiling, not a one-shot gate)" {
  RESULTS="$BATS_TEST_TMPDIR/results-release"
  SESSION_ID="shared-wave-session-release-check"
  fire_concurrent_acquires "shared:$SESSION_ID" "$RESULTS"

  successes="$(count_exit_code "$RESULTS" 0)"
  [ "$successes" -eq "$CAP" ]

  # Which holder id actually won the race is nondeterministic across N
  # concurrent dispatches -- pick a real winner from the recorded results
  # rather than assuming "holder-1" specifically got a slot.
  winner=""
  for f in "$RESULTS"/holder-*.exit; do
    if [ "$(cat "$f")" = "0" ]; then
      winner="$(basename "$f" .exit)"
      break
    fi
  done
  [ -n "$winner" ]

  bash "$JENGA_PROJECT_DIR/scripts/release-concurrency-slot.sh" developer "$winner" "$SESSION_ID"

  run bash "$JENGA_PROJECT_DIR/scripts/acquire-concurrency-slot.sh" developer "holder-late" "$SESSION_ID"
  [ "$status" -eq 0 ]

  COUNTER_FILE="$JENGA_PROJECT_DIR/project/queue/concurrency-slots-${SESSION_ID}.json"
  holders_count="$(jq '.developer.holders | length' "$COUNTER_FILE")"
  [ "$holders_count" -eq "$CAP" ]
}
