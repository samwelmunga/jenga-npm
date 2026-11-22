#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# The foreground pre-flight gate in a consumer install, against the SHIPPED registry only (E99_S04_T04).
#
# Why this file exists. tests/foreground-preflight.bats points JENGA_CHECKLISTS_FILE at its own fixture registry
# and JENGA_CHECKLISTS_DEFAULT_FILE at a missing file, so it never reads templates/checklists.json; every other
# run in this repository reads project/configs/checklists.json. Neither sees what an npm consumer sees, which is
# how 5.1.0 shipped a gate that failed with exit 12 ("unknown checklist item id checkin-run-before-dispatch")
# for every /jenga, j.do and j.dooo run in a consumer (E99_S04; fixed by E99_S04_T01).
#
# The consumer here is the real thing, built by helpers/consumer-testbed.bash: the working tree packed with
# npm pack, extracted into node_modules/@jenga-ai/agent and the real postinstall run. It has no root scripts/
# or skills/, no project/configs/checklists.json, and no JENGA_CHECKLISTS_* override, so checklist.sh falls back
# to node_modules/@jenga-ai/agent/templates/checklists.json. The gate runs by the path a skill prescribes in a
# consumer, from the consumer's root.
#
# The check-in is seeded first (a `checkin` event for the session key the fixture's own checklist-marker.sh
# derives), as tests/foreground-preflight.bats does. Without it the gate stops at exit 10 before any tick, and
# a "never 12" assertion would pass for the wrong reason; the first case pins that exit 10 as the control.
#
# Cost and isolation. The pack (about 4 s) and one pristine consumer (about 5 s) are built once in setup_file,
# inside the bats-managed $BATS_FILE_TMPDIR. Each test copies that consumer into $BATS_TEST_TMPDIR and writes
# only there (TMPDIR included). Every script call has stdin from /dev/null (E43 rule).

load helpers/consumer-testbed

bats_require_minimum_version 1.5.0

PKG_REL="node_modules/@jenga-ai/agent"
FG_REL="$PKG_REL/scripts/foreground-preflight.sh"
CHECKLIST_REL="$PKG_REL/scripts/checklist.sh"
MARKER_REL="$PKG_REL/scripts/checklist-marker.sh"
SHIPPED_REL="$PKG_REL/templates/checklists.json"

CHECKIN_ID="checkin-run-before-dispatch"
COST_ID="dispatch-cost-and-cadence"

setup_file() {
  export TMPDIR="$BATS_FILE_TMPDIR/tmp"
  export npm_config_cache="$BATS_FILE_TMPDIR/npm-cache"
  mkdir -p "$TMPDIR"
  testbed_pack
  PRISTINE="$BATS_FILE_TMPDIR/pristine-consumer"
  testbed_consumer "$PRISTINE" clean >/dev/null
  export PRISTINE
}

setup() {
  C="$BATS_TEST_TMPDIR/consumer"
  cp -R "$PRISTINE" "$C"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  cd "$C"

  # Nothing may redirect the registry, the project root, the tick store, the marker or the session key away from
  # this consumer. CLAUDE_PROJECT_DIR matters most: run inside a Claude Code session it names this monorepo.
  unset JENGA_CHECKLISTS_FILE JENGA_CHECKLISTS_DEFAULT_FILE JENGA_PROJECT_ROOT JENGA_PROJECT_DIR CLAUDE_PROJECT_DIR
  unset JENGA_CHECKLIST_STATE_DIR JENGA_CHECKLIST_MARKER_DIR JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID
  unset JENGA_CHECKLIST_RUN_ID JENGA_CHECKLIST_ACTOR JENGA_CHECKLIST_NOW JENGA_CHECKLIST_RUN_TTL_MINUTES
  unset JENGA_CHECKLIST_MARKER_TTL_MINUTES JENGA_CHECKLIST_VERIFY_TIMEOUT JENGA_SCOPE_THRESHOLDS_FILE
  unset JENGA_CHECKLIST_RAPPORTS_DIR JENGA_RESOLVE_STRICT
  export CLAUDE_CODE_SESSION_ID="sess-consumer-e99s04t04"
}

# The consumer state this file is about, asserted rather than assumed.
assert_consumer_shape() {
  [ -z "${JENGA_CHECKLISTS_FILE+set}" ]
  [ -z "${JENGA_CHECKLISTS_DEFAULT_FILE+set}" ]
  [ ! -e "$C/project/configs/checklists.json" ]
  [ ! -e "$C/scripts" ]
  [ ! -e "$C/skills" ]
  [ -f "$C/$SHIPPED_REL" ]
}

# seed_checkin: a canonical checkin event for the session key the consumer's own marker script derives.
seed_checkin() {
  local key
  key="$(bash "$MARKER_REL" session-key < /dev/null)"
  [ -n "$key" ]
  printf '{"event": "checkin", "agent": "orchestrator", "session_key": "%s", "date": "2026-11-20T22:00:00Z"}\n' \
    "$key" >> "$C/project/logs/events.json"
}

mint() { bash "$FG_REL" mint < /dev/null; }

# drop_item <id>: remove one item from the consumer's copy of the shipped registry (never the repository's).
drop_item() {
  jq --arg id "$1" '.items |= map(select(.id != $id))' "$C/$SHIPPED_REL" > "$TMPDIR/registry.json"
  mv "$TMPDIR/registry.json" "$C/$SHIPPED_REL"
  [ "$(jq --arg id "$1" '[.items[] | select(.id == $id)] | length' "$C/$SHIPPED_REL")" -eq 0 ]
}

@test "consumer fixture: no project instance, no JENGA_CHECKLISTS_* override, shipped default carries both items" {
  assert_consumer_shape
  [ "$(jq --arg a "$CHECKIN_ID" --arg b "$COST_ID" '[.items[] | select(.id == $a or .id == $b)] | length' \
        "$C/$SHIPPED_REL")" -eq 2 ]
}

@test "control: without a check-in the gate stops at exit 10 and ticks nothing" {
  assert_consumer_shape
  local run_id
  run_id="$(mint)"
  run --separate-stderr bash "$FG_REL" gate --run "$run_id" --via do < /dev/null
  [ "$status" -eq 10 ]
  [ ! -d "$C/project/queue/checklist-ticks" ]
}

@test "gate without --user-yes exits 11 (past the check-in, never 12) against the shipped registry" {
  assert_consumer_shape
  seed_checkin
  local run_id
  run_id="$(mint)"
  run --separate-stderr bash "$FG_REL" gate --run "$run_id" --via do < /dev/null
  echo "status=$status stderr=$stderr"
  [ "$status" -eq 11 ]
  [[ "$stderr" != *"unknown checklist item id"* ]]
  [[ "$stderr" == *"$CHECKIN_ID was ticked"* ]]
  # The tick landed in this consumer's own tick store, not in any other project's.
  [ -n "$(ls "$C/project/queue/checklist-ticks"/run-*.json 2>/dev/null)" ]
}

@test "gate with --user-yes exits 0 and verify accepts the run" {
  assert_consumer_shape
  seed_checkin
  local run_id
  run_id="$(mint)"
  run --separate-stderr bash "$FG_REL" gate --run "$run_id" --via do --user-yes < /dev/null
  echo "status=$status stdout=$output stderr=$stderr"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"unknown checklist item id"* ]]
  run --separate-stderr bash "$FG_REL" verify --run "$run_id" < /dev/null
  echo "verify status=$status stderr=$stderr"
  [ "$status" -eq 0 ]
}

@test "the shipped checkin-run-before-dispatch verify resolves checkin-gate.sh in the consumer layout" {
  assert_consumer_shape
  seed_checkin
  run --separate-stderr bash "$CHECKLIST_REL" check pre-task --run fx-e99s04t04 < /dev/null
  echo "status=$status stdout=$output stderr=$stderr"
  local item
  item="$(printf '%s' "$output" | jq -c --arg id "$CHECKIN_ID" '.[] | select(.id == $id)')"
  [ -n "$item" ]
  [ "$(printf '%s' "$item" | jq -r '.result')" = "passed" ]
  [ "$(printf '%s' "$item" | jq -r '.exit_status')" = "0" ]
  [ "$(printf '%s' "$item" | jq -r '.cause')" != "not_found" ]
  # Which copy the shipped verify ran: the installed package's, since this consumer has no root skills/.
  local verify
  verify="$(jq -r --arg id "$CHECKIN_ID" '.items[] | select(.id == $id) | .verify' "$C/$SHIPPED_REL")"
  run bash -xc "$verify" < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exec bash node_modules/@jenga-ai/agent/skills/j-check-in/scripts/checkin-gate.sh"* ]]
}

@test "the case is real: with checkin-run-before-dispatch removed from the shipped registry the gate exits 12" {
  assert_consumer_shape
  seed_checkin
  drop_item "$CHECKIN_ID"
  local run_id
  run_id="$(mint)"
  run --separate-stderr bash "$FG_REL" gate --run "$run_id" --via do --user-yes < /dev/null
  echo "status=$status stderr=$stderr"
  [ "$status" -eq 12 ]
  [[ "$stderr" == *"unknown checklist item id \"$CHECKIN_ID\""* ]]
}

@test "the case is real: with dispatch-cost-and-cadence removed from the shipped registry the gate exits 12" {
  assert_consumer_shape
  seed_checkin
  drop_item "$COST_ID"
  local run_id
  run_id="$(mint)"
  run --separate-stderr bash "$FG_REL" gate --run "$run_id" --via do --user-yes < /dev/null
  echo "status=$status stderr=$stderr"
  [ "$status" -eq 12 ]
  [[ "$stderr" == *"unknown checklist item id \"$COST_ID\""* ]]
}
