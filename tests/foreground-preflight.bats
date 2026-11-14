#!/usr/bin/env bats
#
# Coverage for scripts/foreground-preflight.sh (E67_S11_T01): mint, gate, verify.
#
# Contract under test:
#   - scripts/foreground-preflight.sh   its own header: subcommands, exit codes, the honest limit
#   - scripts/checklist.sh              NOT modified by this story; the tests drive it as the tick store and as the
#                                       oracle for "the pre-existing defer behaviour is unchanged"
#   - skills/j-check-in/scripts/checkin-gate.sh   run for real (never stubbed) by `gate`
#
# What this suite is guarding. `verify` is the trust boundary of the story: it decides whether a dispatched
# unit may treat the judgment item dispatch-cost-and-cadence as already answered. A bug that returns 0 for
# anything but "both items ticked by user:<via> for exactly this run id" lets an agent self-certify an item it
# is forbidden to answer. So the cases below are mostly refusals, one per way a pass could be faked.
#
# The honest limit, pinned as a boundary rather than hidden: the `user:` prefix is checked, not proven. A
# test below ticks as `user:forged` with plain `checklist.sh tick` and shows verify ACCEPTS it. That is the
# documented limit (anyone with shell access can type it), and the tests next to it pin what IS refused: the
# default actor (os-user:<login>), an agent actor, a persistent tick, another run's tick and an edited item.
#
# Isolation. Everything runs in a temp project root ($PROJ) reached through JENGA_PROJECT_ROOT, with its own
# workflow.json, events.json, registry and tick-state directory. The real project/logs/events.json and the real
# project/queue/checklist-ticks/ are never read or written. Every invocation of a script under test has an
# explicit stdin from /dev/null (E43 rule).
#
# What a "session" is here. CLAUDE_CODE_SESSION_ID, the normal production source of the session key and the seam
# tests/checkin-gate.bats uses. A check-in "has run" when the fixture events.json holds a `checkin` event with
# that session_key.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FG="$REPO_ROOT/scripts/foreground-preflight.sh"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
GATE="$REPO_ROOT/skills/j-check-in/scripts/checkin-gate.sh"

CHECKIN_ID="checkin-run-before-dispatch"
COST_ID="dispatch-cost-and-cadence"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  F="$T/checklists.json"
  STATE="$T/state"
  EVENTS="$PROJ/project/logs/events.json"

  mkdir -p "$PROJ/project/configs" "$PROJ/project/logs" "$PROJ/project/queue"
  cat > "$PROJ/project/configs/workflow.json" <<'EOF'
{
  "paths": {
    "queue": "project/queue",
    "configs": "project/configs",
    "logs": "project/logs"
  }
}
EOF
  cat > "$PROJ/project/configs/scope-thresholds.json" <<'EOF'
{
  "marker_ttl_minutes": 60
}
EOF
  : > "$EVENTS"

  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_CHECKLISTS_FILE="$F"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$T/no-default-checklists.json"
  export JENGA_CHECKLIST_STATE_DIR="$STATE"
  export CLAUDE_CODE_SESSION_ID="sess-main"
  unset JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID JENGA_CHECKLIST_MARKER_DIR
  unset JENGA_CHECKLIST_MARKER_TTL_MINUTES JENGA_SCOPE_THRESHOLDS_FILE JENGA_CHECKLIST_NOW
  unset JENGA_PREFLIGHT_HOOK_SCRIPT_DIR JENGA_PREFLIGHT_HOOK_DEBUG JENGA_CHECKLIST_RUN_ID
  unset JENGA_CHECKLIST_ACTOR JENGA_CHECKLIST_RUN_TTL_MINUTES JENGA_CHECKLIST_VERIFY_TIMEOUT

  write_registry run
}

# -----------------------------------------------------------------------------
# Fixture builders
# -----------------------------------------------------------------------------

# write_registry <scope> [<cost item text suffix>]: a registry holding the two items under test, shaped like
# the real ones (machine item verified by the REAL check-in gate, judgment item). The scope applies to both.
write_registry() {
  jq -n --arg gate "$GATE" --arg scope "$1" --arg suffix "${2:-}" '{
    checklist_version: 1,
    situations: [],
    items: [
      {
        id: "checkin-run-before-dispatch",
        text: "A pre-dispatch check-in has been run in this session.",
        situations: ["pre-task"],
        kind: "machine",
        verify: ("bash " + $gate),
        enforcement: "confirm",
        tick_scope: $scope
      },
      {
        id: "dispatch-cost-and-cadence",
        text: ("The expected cost and cadence were stated to the user and they agreed." + $suffix),
        situations: ["pre-task"],
        kind: "judgment",
        enforcement: "confirm",
        tick_scope: $scope
      }
    ]
  }' > "$F"
}

# checkin_event <session-key>: a canonical checkin event for that session key.
add_checkin_event() {
  printf '{"event": "checkin", "agent": "orchestrator", "session_key": "%s", "date": "2026-10-12T12:00:00Z"}\n' "$1" >> "$EVENTS"
}

# -----------------------------------------------------------------------------
# Runners (explicit stdin on every call)
# -----------------------------------------------------------------------------

fg() { run --separate-stderr bash "$FG" "$@" < /dev/null; }

ck() { run --separate-stderr bash "$CHECKLIST" "$@" < /dev/null; }

# tick <item> <run> [<actor>]: tick through the real tick command; no actor means the checker's own default.
tick() {
  if [ -n "${3:-}" ]; then
    bash "$CHECKLIST" tick "$1" --run "$2" --by "$3" < /dev/null > /dev/null
  else
    bash "$CHECKLIST" tick "$1" --run "$2" < /dev/null > /dev/null
  fi
}

# state_of <item> <run>: the tick-state column of `list pre-task` for that item.
state_of() {
  bash "$CHECKLIST" list pre-task --run "$2" < /dev/null 2>/dev/null | awk -F'\t' -v id="$1" '$1 == id { print $5 }'
}

# =============================================================================
# Group 1 - script hygiene
# =============================================================================

@test "script passes bash -n and its header states the subcommands, exit codes and the honest limit" {
  run bash -n "$FG"
  [ "$status" -eq 0 ]
  run grep -c -E '^#   (mint|gate|verify)|^# (mint|gate --run|verify --run)' "$FG"
  [ "$status" -eq 0 ]
  grep -q 'HONEST LIMIT' "$FG"
  grep -q 'CHECKED, not PROVEN' "$FG"
  grep -q 'EXIT CODES' "$FG"
  grep -q 'bash 3.2' "$FG"
}

@test "help prints the usage on stdout and exits 0; an unknown subcommand exits 2" {
  fg --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"foreground-preflight.sh mint"* ]]
  fg frobnicate
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$FG" < /dev/null
  [ "$status" -eq 2 ]
}

# =============================================================================
# Group 2 - mint
# =============================================================================

@test "mint prints one fg-<UTC time>-<rand> id that checklist.sh accepts as a run id" {
  fg mint
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^fg-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
  [ -z "$stderr" ]
  # Accepted by the checker under its own run-id rule: a tick under it succeeds.
  local id="$output"
  ck tick "$COST_ID" --run "$id" --by user:do
  [ "$status" -eq 0 ]
}

@test "two mint calls print different ids and mint has no side effects" {
  fg mint
  local a="$output"
  fg mint
  local b="$output"
  [ "$a" != "$b" ]
  [ ! -e "$STATE" ]
}

@test "mint refuses arguments" {
  fg mint extra
  [ "$status" -eq 2 ]
}

# =============================================================================
# Group 3 - verify: every refusal, then the single pass
# =============================================================================

@test "verify with the run id absent exits non-zero, and the pre-existing defer behaviour is unchanged" {
  fg verify
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # JENGA_CHECKLIST_RUN_ID is not a way around naming the run.
  JENGA_CHECKLIST_RUN_ID=anything fg verify
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # And the underlying checker still defers BOTH items (the machine item fails: no check-in; the judgment item
  # needs the user). Exit 11 is "confirm items need a decision"; neither is already_ticked.
  ck check pre-task
  [ "$status" -eq 11 ]
  [ "$(printf '%s' "$output" | jq -r --arg id "$CHECKIN_ID" '.[] | select(.id == $id) | .result')" = "failed" ]
  [ "$(printf '%s' "$output" | jq -r --arg id "$COST_ID" '.[] | select(.id == $id) | .result')" = "requires_confirmation" ]
  [ "$(printf '%s' "$output" | jq -r '[.[] | select(.result == "already_ticked")] | length')" = "0" ]
}

@test "verify with a malformed run id exits non-zero" {
  fg verify --run ""
  [ "$status" -ne 0 ]
  fg verify --run "has space"
  [ "$status" -ne 0 ]
  fg verify --run "-leading-hyphen"
  [ "$status" -ne 0 ]
  fg verify --run "$(printf 'a%.0s' $(seq 1 129))"
  [ "$status" -ne 0 ]
  fg verify --run
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "verify with a run id supplied but both items unticked exits non-zero" {
  fg verify --run run-1
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unticked"* ]]
}

@test "verify refuses an item ticked by an agent actor" {
  tick "$CHECKIN_ID" run-1 agent:developer
  tick "$COST_ID" run-1 agent:developer
  fg verify --run run-1
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not user:*"* ]]
}

@test "verify refuses the default actor, which is what an agent that forgets --by records" {
  tick "$CHECKIN_ID" run-1
  tick "$COST_ID" run-1
  [[ "$(state_of "$COST_ID" run-1)" == "ticked(run) by os-user:"* ]]
  fg verify --run run-1
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not user:*"* ]]
}

@test "verify refuses when the cost item is ticked by an agent although the machine item is ticked by a user" {
  tick "$CHECKIN_ID" run-1 user:do
  tick "$COST_ID" run-1 agent:developer
  fg verify --run run-1
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"$COST_ID"* ]]
}

@test "verify refuses when only the machine item is ticked by a user" {
  tick "$CHECKIN_ID" run-1 user:do
  fg verify --run run-1
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"$COST_ID"* ]]
}

@test "verify refuses when only the judgment item is ticked by a user" {
  tick "$COST_ID" run-1 user:do
  fg verify --run run-1
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"$CHECKIN_ID"* ]]
}

@test "verify refuses a bare 'user:' prefix with nothing after it" {
  # ACTOR rule: the actor must be 1 to 128 chars; "user:" is legal to the checker, so verify must reject it
  # itself rather than count a prefix with no <via>.
  tick "$CHECKIN_ID" run-1 "user:"
  tick "$COST_ID" run-1 "user:"
  fg verify --run run-1
  [ "$status" -ne 0 ]
}

@test "verify refuses an actor that merely contains user: but does not start with it" {
  tick "$CHECKIN_ID" run-1 "agent:user:do"
  tick "$COST_ID" run-1 "xuser:do"
  fg verify --run run-1
  [ "$status" -ne 0 ]
}

@test "verify exits 0, silently, only when both items are ticked by user:<via> for that run id" {
  tick "$CHECKIN_ID" run-1 user:jenga
  tick "$COST_ID" run-1 user:jenga
  fg verify --run run-1
  [ "$status" -eq 0 ]
  # Nothing on stdout that could be mistaken for a pass other than the exit code.
  [ -z "$output" ]
}

@test "verify accepts user:<via> for each of jenga, do and dooo" {
  local via
  for via in jenga do dooo; do
    tick "$CHECKIN_ID" "run-$via" "user:$via"
    tick "$COST_ID" "run-$via" "user:$via"
    fg verify --run "run-$via"
    [ "$status" -eq 0 ]
  done
}

@test "HONEST LIMIT: a user: actor typed by hand is accepted, because the prefix is checked, not proven" {
  # This is the documented boundary, pinned so nobody later claims it was stronger. The forged tick is
  # indistinguishable from a real one: that is what "checked, not proven" means.
  tick "$CHECKIN_ID" run-forged user:forged
  tick "$COST_ID" run-forged user:forged
  fg verify --run run-forged
  [ "$status" -eq 0 ]
}

@test "a tick written for run id A is not visible to verify --run B, and check --run B still defers both" {
  tick "$CHECKIN_ID" run-A user:do
  tick "$COST_ID" run-A user:do
  fg verify --run run-A
  [ "$status" -eq 0 ]
  fg verify --run run-B
  [ "$status" -ne 0 ]
  [ "$(state_of "$CHECKIN_ID" run-B)" = "unticked" ]
  [ "$(state_of "$COST_ID" run-B)" = "unticked" ]
  ck check pre-task --run run-B
  [ "$status" -eq 11 ]
  [ "$(printf '%s' "$output" | jq -r '[.[] | select(.tick_state != "unticked")] | length')" = "0" ]
  [ "$(printf '%s' "$output" | jq -r '[.[] | select(.result == "already_ticked")] | length')" = "0" ]
}

@test "verify refuses persistent-scoped ticks, even by a user actor, for any run id" {
  write_registry persistent
  tick "$CHECKIN_ID" run-1 user:do
  tick "$COST_ID" run-1 user:do
  [[ "$(state_of "$COST_ID" run-1)" == "ticked(persistent) by user:do at "* ]]
  fg verify --run run-1
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"persistent"* ]]
  # A persistent tick is visible to every run id; it must be refused for those too.
  fg verify --run some-other-run
  [ "$status" -ne 0 ]
}

@test "verify refuses a tick that predates an edit of the item (definition hash no longer matches)" {
  tick "$CHECKIN_ID" run-1 user:do
  tick "$COST_ID" run-1 user:do
  fg verify --run run-1
  [ "$status" -eq 0 ]
  write_registry run " It was also stated that rework needs a new yes."
  fg verify --run run-1
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"unticked"* ]]
}

@test "verify fails, not passes, when the tick state cannot be read" {
  tick "$CHECKIN_ID" run-1 user:do
  tick "$COST_ID" run-1 user:do
  # An invalid registry: checklist.sh list exits non-zero, so verify must too.
  printf '{ not json' > "$F"
  fg verify --run run-1
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # A registry that lacks the two items is likewise not a pass.
  jq -n '{checklist_version: 1, situations: [], items: []}' > "$F"
  fg verify --run run-1
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not an item"* ]]
  # And with no registry file at all.
  rm -f "$F"
  fg verify --run run-1
  [ "$status" -ne 0 ]
}

@test "verify fails on a corrupted run file rather than passing" {
  tick "$CHECKIN_ID" run-1 user:do
  tick "$COST_ID" run-1 user:do
  local f
  for f in "$STATE"/run-*.json; do printf 'garbage' > "$f"; done
  fg verify --run run-1
  [ "$status" -ne 0 ]
}

@test "verify only reads: it creates nothing when there is no tick state" {
  fg verify --run run-1
  [ "$status" -ne 0 ]
  [ ! -e "$STATE" ]
}

# =============================================================================
# Group 4 - gate
# =============================================================================

@test "gate without --user-yes ticks the check-in item, never the cost item, and exits non-zero" {
  add_checkin_event sess-main
  fg gate --run run-1 --via jenga
  [ "$status" -eq 11 ]
  [[ "$stderr" == *"$COST_ID is unticked"* ]]
  [[ "$(state_of "$CHECKIN_ID" run-1)" == "ticked(run) by user:jenga at "* ]]
  [ "$(state_of "$COST_ID" run-1)" = "unticked" ]
  fg verify --run run-1
  [ "$status" -ne 0 ]
}

@test "gate with --user-yes and a passing check-in gate ticks both items, and verify then passes" {
  add_checkin_event sess-main
  fg gate --run run-1 --via do --user-yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CHECKIN_ID"* ]]
  [[ "$(state_of "$CHECKIN_ID" run-1)" == "ticked(run) by user:do at "* ]]
  [[ "$(state_of "$COST_ID" run-1)" == "ticked(run) by user:do at "* ]]
  fg verify --run run-1
  [ "$status" -eq 0 ]
  ck check pre-task --run run-1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.[] | select(.result == "already_ticked")] | length')" = "2" ]
}

@test "gate with a failing check-in gate ticks neither item, even with --user-yes" {
  # No checkin event at all.
  fg gate --run run-1 --via jenga --user-yes
  [ "$status" -eq 10 ]
  [[ "$stderr" == *"check-in has not run"* ]]
  [ "$(state_of "$CHECKIN_ID" run-1)" = "unticked" ]
  [ "$(state_of "$COST_ID" run-1)" = "unticked" ]
  # Nothing was written to the tick store.
  [ ! -e "$STATE" ]
  fg verify --run run-1
  [ "$status" -ne 0 ]
}

@test "gate does not accept another session's check-in" {
  add_checkin_event sess-someone-else
  fg gate --run run-1 --via jenga --user-yes
  [ "$status" -eq 10 ]
  [ ! -e "$STATE" ]
  # The same events, seen from the session that did check in, pass.
  CLAUDE_CODE_SESSION_ID=sess-someone-else fg gate --run run-1 --via jenga --user-yes
  [ "$status" -eq 0 ]
}

@test "gate ticks only under the run id it was given" {
  add_checkin_event sess-main
  fg gate --run run-A --via jenga --user-yes
  [ "$status" -eq 0 ]
  fg verify --run run-B
  [ "$status" -ne 0 ]
}

@test "gate refuses bad usage with exit 2 and ticks nothing" {
  add_checkin_event sess-main
  fg gate --via jenga --user-yes
  [ "$status" -eq 2 ]
  fg gate --run run-1 --user-yes
  [ "$status" -eq 2 ]
  fg gate --run run-1 --via sneaky --user-yes
  [ "$status" -eq 2 ]
  fg gate --run "bad id" --via jenga --user-yes
  [ "$status" -eq 2 ]
  fg gate --run run-1 --via jenga --user-yes --surprise
  [ "$status" -eq 2 ]
  [ ! -e "$STATE" ]
}

@test "gate reports exit 12 when the tick cannot be recorded, and not a pass" {
  add_checkin_event sess-main
  # The state directory path is occupied by a regular file, so checklist.sh tick cannot create it.
  : > "$STATE"
  fg gate --run run-1 --via jenga --user-yes
  [ "$status" -eq 12 ]
}

# =============================================================================
# Group 5 - isolation
# =============================================================================

@test "the suite wrote its ticks only into the fixture state directory" {
  add_checkin_event sess-main
  fg gate --run run-1 --via jenga --user-yes
  [ "$status" -eq 0 ]
  [ -d "$STATE" ]
  [[ "$STATE" == "$BATS_TEST_TMPDIR"/* ]]
  # The fixture events.json is the one the gate read; the real one is a different file.
  [ "$EVENTS" != "$REPO_ROOT/project/logs/events.json" ]
  [[ "$JENGA_PROJECT_ROOT" == "$BATS_TEST_TMPDIR"/* ]]
}
