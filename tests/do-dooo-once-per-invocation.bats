#!/usr/bin/env bats
#
# Coverage for E67_S11_T04: standalone /do and /dooo ask the pre-task judgment item once per invocation, not once
# per task.
#
# What is under test.
#   - skills/j-do/SKILL.md      `### 1.4` (the front-loaded foreground ask), its pointers in `### 1.5`, `### 4`,
#                               `### 4.1.2`, `### 4.4` and `### 5` (text assertions)
#   - skills/j-dooo/SKILL.md    step 0 (one ask per invocation) and step 1's threading of the id (text assertions)
#   - skills/j-do/assets/foreground-prompt.md   the one home of the prompt wording (text assertions)
#   - scripts/foreground-preflight.sh, scripts/checklist.sh   executed for real against a fixture: the decision
#                               path of 1.4 followed by N per-task 4.1.2 checks, the Cancel and Other paths, and
#                               the case (b) path with no supplied id
#
# Honest limit. The decision path in both SKILL.md files is prose an agent follows. These tests assert what that
# prose says and execute the scripts it names (through helpers that mirror the documented steps and log every script
# call they make); they cannot prove that an agent follows the prose, and "starts no task" on Cancel is shown as
# "the helper that stands for starting a task is never reached and no tick exists", not by running an agent.
#
# Tightness rule (from T03's Tester remark). For every Cancel, Other and case (b) assertion, the text is checked
# for what it must NOT contain (the `--user-yes` token, a `gate` command, a `tick` command), not only for the
# absence of one particular phrase, so a mutation that keeps a "never" sentence but adds a call still fails.
#
# Isolation. A temp project root ($PROJ) reached through JENGA_PROJECT_ROOT, with its own workflow.json,
# events.json, registry and tick-state directory (same pattern as tests/jenga-phase-08-foreground.bats). The real
# project/logs/events.json and the real project/queue/checklist-ticks/ are never read or written. Every script
# call has an explicit stdin from /dev/null.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FG="$REPO_ROOT/scripts/foreground-preflight.sh"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
GATE="$REPO_ROOT/skills/j-check-in/scripts/checkin-gate.sh"
DO_SKILL="$REPO_ROOT/skills/j-do/SKILL.md"
DOOO_SKILL="$REPO_ROOT/skills/j-dooo/SKILL.md"
JENGA_SKILL="$REPO_ROOT/skills/jenga/SKILL.md"
ASSET="$REPO_ROOT/skills/j-do/assets/foreground-prompt.md"

CHECKIN_ID="checkin-run-before-dispatch"
COST_ID="dispatch-cost-and-cadence"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  F="$T/checklists.json"
  STATE="$T/state"
  EVENTS="$PROJ/project/logs/events.json"
  CALLS="$T/calls.log"

  mkdir -p "$PROJ/project/configs" "$PROJ/project/logs" "$PROJ/project/queue"
  cat > "$PROJ/project/configs/workflow.json" <<'JSON'
{
  "paths": {
    "queue": "project/queue",
    "configs": "project/configs",
    "logs": "project/logs"
  }
}
JSON
  cat > "$PROJ/project/configs/scope-thresholds.json" <<'JSON'
{
  "marker_ttl_minutes": 60
}
JSON
  : > "$EVENTS"
  : > "$CALLS"

  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_CHECKLISTS_FILE="$F"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$T/no-default-checklists.json"
  export JENGA_CHECKLIST_STATE_DIR="$STATE"
  export CLAUDE_CODE_SESSION_ID="sess-main"
  unset JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID JENGA_CHECKLIST_MARKER_DIR
  unset JENGA_CHECKLIST_MARKER_TTL_MINUTES JENGA_SCOPE_THRESHOLDS_FILE JENGA_CHECKLIST_NOW
  unset JENGA_PREFLIGHT_HOOK_SCRIPT_DIR JENGA_PREFLIGHT_HOOK_DEBUG JENGA_CHECKLIST_RUN_ID
  unset JENGA_CHECKLIST_ACTOR JENGA_CHECKLIST_RUN_TTL_MINUTES JENGA_CHECKLIST_VERIFY_TIMEOUT

  write_registry
}

# -----------------------------------------------------------------------------
# Fixtures and helpers
# -----------------------------------------------------------------------------

# The two items under test, shaped like the real ones: the machine item is verified by the REAL check-in gate,
# the judgment item cannot be confirmed by the checker. Both are run-scoped confirm items.
write_registry() {
  jq -n --arg gate "$GATE" '{
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
        tick_scope: "run"
      },
      {
        id: "dispatch-cost-and-cadence",
        text: "The expected cost and cadence were stated to the user and they agreed.",
        situations: ["pre-task"],
        kind: "judgment",
        enforcement: "confirm",
        tick_scope: "run"
      }
    ]
  }' > "$F"
}

# A check-in has run in the host session (the key the fixture session id resolves to).
add_checkin_event() {
  printf '{"event": "checkin", "agent": "orchestrator", "session_key": "sess-main", "date": "2026-10-12T12:00:00Z"}\n' >> "$EVENTS"
}

# tick_state <item> <run>: the last column of `checklist.sh list pre-task --run <run>` for that item.
tick_state() {
  bash "$CHECKLIST" list pre-task --run "$2" < /dev/null | awk -F'\t' -v id="$1" '$1 == id { print $NF }'
}

# fg <args...>: foreground-preflight.sh with every call logged (subcommand only) so a test can count them.
fg() {
  printf '%s\n' "$1" >> "$CALLS"
  bash "$FG" "$@" < /dev/null
}

# calls <subcommand>: how many times the logged helper ran that subcommand.
calls() { grep -c -x -- "$1" "$CALLS" || true; }

# result_of <json> <item>: the "result" of one item in `checklist.sh check` output.
result_of() { printf '%s' "$1" | jq -r --arg id "$2" '.[] | select(.id == $id) | .result'; }

# ask_yes <via>: ### 1.4 steps 3 to 6 (and /dooo step 0) with the user answering Proceed. Sets INV_ID. The mint,
# the check-in event and the single gate call are the whole ask.
ask_yes() {
  INV_ID="$(fg mint)"
  add_checkin_event
  fg gate --run "$INV_ID" --via "$1" --user-yes > /dev/null
}

# per_task_gate <run-id-or-empty>: the documented ### 4.1.2 path for one unit. Sets RUN_ID and ADOPTED, then runs
# `check pre-task --run "$RUN_ID"`; the caller reads $status (0: no deferral, 10 or 11: defer) and $output (JSON).
# Nothing here ever calls gate or tick: that is the whole point of the section.
per_task_gate() {
  local supplied="$1"
  ADOPTED=no
  RUN_ID=""
  if [ -n "$supplied" ] && fg verify --run "$supplied" > /dev/null 2>&1; then
    RUN_ID="$supplied"
    ADOPTED=yes
  else
    RUN_ID="do-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  run --separate-stderr bash "$CHECKLIST" check pre-task --run "$RUN_ID" < /dev/null
}

# started: the stand-in for "a unit started". Only a unit whose per-task gate passed may reach it.
started() { printf '%s\n' "$1" >> "$T/started.log"; }
started_count() { if [ -f "$T/started.log" ]; then wc -l < "$T/started.log" | tr -d ' '; else echo 0; fi; }

# section <file> <start-regex> <stop-regex>: lines from the first match of start up to (not including) the next
# match of stop.
section() {
  awk -v s="$2" -v e="$3" '$0 ~ s { f = 1; print; next } f && $0 ~ e { exit } f { print }' "$1"
}

do_14() { section "$DO_SKILL" '^### 1\.4\. ' '^### 1\.5\. '; }
do_412() { section "$DO_SKILL" '^### 4\.1\.2\. ' '^### 4\.1\.5\. '; }
dooo_0() { section "$DOOO_SKILL" '^### 0\. ' '^### 1\. '; }
dooo_rest() { awk '/^### 1\. /{f=1} f' "$DOOO_SKILL"; }

# bullet <section-fn> <marker>: the single answer bullet starting with "   - **<marker>**".
bullet() { "$1" | grep -F -- "   - **$2**"; }

# =============================================================================
# Group 1 - /do `### 1.4`: placement, case (a) only, once per invocation
# =============================================================================

@test "1.4 is one heading placed after step 1 and before 1.5, and ties the ask to the invocation" {
  l1="$(grep -n '^### 1\. ' "$DO_SKILL" | cut -d: -f1)"
  l14="$(grep -n '^### 1\.4\. ' "$DO_SKILL" | cut -d: -f1)"
  l15="$(grep -n '^### 1\.5\. ' "$DO_SKILL" | cut -d: -f1)"
  [ -n "$l1" ] && [ -n "$l14" ] && [ -n "$l15" ]
  [ "$l1" -lt "$l14" ]
  [ "$l14" -lt "$l15" ]
  [ "$(grep -c '^### 1\.4\. ' "$DO_SKILL")" -eq 1 ]
  s="$(do_14)"
  [[ "$s" == *'once per `/do` invocation'* ]]
  [[ "$s" == *'before the first `### 4.1.2` gate'* ]]
  [[ "$s" == *'never runs this section again'* ]]
}

@test "1.4 runs under case (a) only: a supplied session id (case b) or an unknown channel does nothing" {
  s="$(do_14)"
  [[ "$s" == *'**Case (b) does nothing here.**'* ]]
  [[ "$s" == *'`### 4.4` case (b)'* ]]
  [[ "$s" == *'cannot tell whether a user can answer'* ]]
  b="$(printf '%s\n' "$s" | grep -F '1. **Case (b) does nothing here.**')"
  [[ "$b" == *'never mint, never prompt, never run `gate`, never tick'* ]]
}

@test "1.4 case (b) text carries no gate call, no tick call, no mint call and no --user-yes" {
  b="$(do_14 | grep -F '1. **Case (b) does nothing here.**')"
  [ -n "$b" ]
  [[ "$b" != *'--user-yes'* ]]
  [[ "$b" != *'FG gate'* ]]
  [[ "$b" != *'FG mint'* ]]
  [[ "$b" != *'foreground-preflight.sh gate'* ]]
  [[ "$b" != *'checklist.sh tick'* ]]
  [[ "$b" != *'checklist-marker.sh write'* ]]
}

@test "1.4 is skipped when the sender object carries a checklist_run_id that verify confirms" {
  s="$(do_14)"
  l="$(printf '%s\n' "$s" | grep -F '2. **Case (a), already asked.**')"
  [[ "$l" == *'FG verify --run'* ]]
  [[ "$l" == *'Exit `0`'* ]]
  [[ "$l" == *'ask nothing'* ]]
  [[ "$l" == *'`/dooo`'* ]]
  [[ "$l" == *'Any non-zero exit: treat the field as absent'* ]]
}

@test "1.4 mints, checks in, then shows the prompt from the shared asset, in that order" {
  s="$(do_14)"
  a="$(printf '%s\n' "$s" | grep -n '3\. \*\*Mint\.\*\*' | cut -d: -f1)"
  b="$(printf '%s\n' "$s" | grep -n '4\. \*\*Check in, in the host session\.\*\*' | cut -d: -f1)"
  c="$(printf '%s\n' "$s" | grep -n '5\. \*\*Show the prompt\.\*\*' | cut -d: -f1)"
  d="$(printf '%s\n' "$s" | grep -n '6\. \*\*Branch on the answer\*\*' | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ]
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ]
  [[ "$s" == *'`j.check-in` yourself, in this session, never in a sub-agent'* ]]
  [[ "$(printf '%s\n' "$s" | sed -n "${c}p")" == *'skills/j-do/assets/foreground-prompt.md'* ]]
  [[ "$(printf '%s\n' "$s" | sed -n "${a}p")" == *'FG mint'* ]]
}

@test "1.4: --user-yes appears exactly once, on the Proceed bullet's gate call with --via do" {
  s="$(do_14)"
  [ "$(printf '%s\n' "$s" | grep -o -- '--user-yes' | wc -l | tr -d ' ')" -eq 1 ]
  p="$(bullet do_14 'Proceed')"
  [[ "$p" == *'--user-yes'* ]]
  [[ "$p" == *'FG gate --run'* ]]
  [[ "$p" == *'--via do'* ]]
  [[ "$p" == *'halts the invocation with nothing started'* ]]
  # And exactly one gate command in the whole section.
  [ "$(printf '%s\n' "$s" | grep -o 'FG gate' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "1.4 Cancel bullet: halts with nothing started, cost item unticked, and carries no gate, tick or --user-yes" {
  c="$(bullet do_14 'Cancel')"
  [ -n "$c" ]
  [[ "$c" == *'halt the invocation'* ]]
  [[ "$c" == *'Nothing is started'* ]]
  [[ "$c" == *'`dispatch-cost-and-cadence` stays unticked'* ]]
  [[ "$c" == *'`gate` is never called on this path'* ]]
  [[ "$c" != *'--user-yes'* ]]
  [[ "$c" != *'FG gate'* ]]
  [[ "$c" != *'FG mint'* ]]
  [[ "$c" != *'foreground-preflight.sh'* ]]
  [[ "$c" != *'checklist.sh tick'* ]]
  [[ "$c" != *'tick '* ]]
}

@test "1.4 Other bullet: re-asks, never reads free text as a yes, and carries no gate, tick or --user-yes" {
  o="$(bullet do_14 'Other')"
  [ -n "$o" ]
  [[ "$o" == *'show the prompt again'* ]]
  [[ "$o" == *'never read as a yes'* ]]
  [[ "$o" == *'`gate` is not called on this path'* ]]
  [[ "$o" != *'--user-yes'* ]]
  [[ "$o" != *'FG gate'* ]]
  [[ "$o" != *'foreground-preflight.sh'* ]]
  [[ "$o" != *'checklist.sh tick'* ]]
}

@test "1.4 Proceed, Cancel and Other are the three branches, in that order, Other last (free text last)" {
  s="$(do_14)"
  a="$(printf '%s\n' "$s" | grep -n -F '   - **Proceed**' | cut -d: -f1)"
  b="$(printf '%s\n' "$s" | grep -n -F '   - **Cancel**' | cut -d: -f1)"
  c="$(printf '%s\n' "$s" | grep -n -F '   - **Other**' | cut -d: -f1)"
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]
  [ "$(printf '%s\n' "$s" | grep -c -F '   - **')" -eq 3 ]
}

@test "1.4 threads the id to every unit: 4.1.2 reads and verifies it, 5 copies it, a bundle carries it" {
  s="$(do_14)"
  [[ "$s" == *'**Threading.**'* ]]
  [[ "$s" == *'every unit this invocation runs'* ]]
  [[ "$s" == *'still verifies it before adopting it'* ]]
  [[ "$s" == *'`already_ticked`'* ]]
  [[ "$s" == *'A bundle (`### 1.5`) carries it the same way'* ]]
  # 4.1.2 says the same from its side, and keeps its own per-task check.
  t="$(do_412)"
  [[ "$t" == *'When `### 1.4` obtained an id for this invocation'* ]]
  [[ "$t" == *'both items are `already_ticked`'* ]]
  [[ "$t" == *'checklist.sh check pre-task --run "$RUN_ID"'* ]]
  # 5 and 4.4 name 1.4 as the source of the id.
  [ "$(grep -c 'from `### 1.4`' "$DO_SKILL")" -ge 1 ]
  [[ "$(section "$DO_SKILL" '^\*\*Sender object\*\*' '^\*\*Context payload\*\*')" == *'invocation'* ]]
  [[ "$(grep -F '**`checklist_run_id` (optional, caller-supplied).**' "$DO_SKILL")" == *'`### 1.4`'* ]]
}

@test "1.5 and step 4 point at 1.4 instead of asking themselves, and 4.1.2 does not re-ask the two items" {
  [[ "$(section "$DO_SKILL" '^### 1\.5\. ' '^#### Epic-Level Bundle Lock')" == *'**Foreground ask first (`### 1.4`).**'* ]]
  [[ "$(section "$DO_SKILL" '^### 4\. ' '^### 4\.1\. ')" == *'If `### 1.4` has not yet been decided in this invocation, run it now'* ]]
  t="$(do_412)"
  [[ "$t" == *'are `already_ticked` by then and are not asked again per task'* ]]
}

@test "no path in /do ticks from a sub-agent: no checklist.sh tick anywhere, and gate --user-yes only in 1.4" {
  [ "$(grep -c 'checklist\.sh tick' "$DO_SKILL")" -eq 0 ]
  [ "$(grep -c 'checklist\.sh tick' "$DOOO_SKILL")" -eq 0 ]
  [ "$(grep -c 'checklist-marker\.sh.*--user' "$DO_SKILL")" -eq 0 ]
  # Every line in /do that mentions --user-yes lies inside 1.4.
  total="$(grep -c -- '--user-yes' "$DO_SKILL")"
  inside="$(do_14 | grep -c -- '--user-yes')"
  [ "$total" -eq "$inside" ]
  # The sections a sub-agent runs (4.1.2, 4.3, 4.4, 5, 1.5) never name the gate subcommand.
  for sec in "$(do_412)" \
             "$(section "$DO_SKILL" '^### 4\.3\. ' '^### 4\.4\. ')" \
             "$(section "$DO_SKILL" '^### 4\.4\. ' '^### 5\. ')" \
             "$(section "$DO_SKILL" '^### 5\. ' '^### 5\.1\. ')" \
             "$(section "$DO_SKILL" '^### 1\.5\. ' '^### 2\. ')"; do
    [ -n "$sec" ]
    [[ "$sec" != *'foreground-preflight.sh" gate'* ]]
    [[ "$sec" != *'FG gate'* ]]
    [[ "$sec" != *'--user-yes'* ]]
  done
}

# =============================================================================
# Group 2 - /dooo step 0 and the threading to every inner /do
# =============================================================================

@test "dooo step 0 is one heading before step 1 and is a single ask per invocation" {
  l0="$(grep -n '^### 0\. ' "$DOOO_SKILL" | cut -d: -f1)"
  l1="$(grep -n '^### 1\. ' "$DOOO_SKILL" | cut -d: -f1)"
  [ -n "$l0" ] && [ -n "$l1" ] && [ "$l0" -lt "$l1" ]
  [ "$(grep -c '^### 0\. ' "$DOOO_SKILL")" -eq 1 ]
  s="$(dooo_0)"
  [[ "$s" == *'once for the whole invocation'* ]]
  [[ "$s" == *'so no inner `/do` asks again'* ]]
  [[ "$s" == *'skills/j-do/assets/foreground-prompt.md'* ]]
  [[ "$s" == *'`j.check-in` yourself, in this session, never in a sub-agent'* ]]
}

@test "dooo mints exactly once, in step 0, and never again mid-invocation" {
  [ "$(grep -c 'FG mint' "$DOOO_SKILL")" -eq 1 ]
  [ "$(dooo_0 | grep -c 'FG mint')" -eq 1 ]
  [[ "$(dooo_0)" == *'never mint a second id mid-invocation'* ]]
  r="$(dooo_rest)"
  [[ "$r" != *'FG mint'* ]]
  [[ "$r" != *'foreground-preflight.sh'* ]]
  [[ "$r" != *'--user-yes'* ]]
}

@test "dooo step 1 passes checklist_run_id to the inner /do on every iteration, unchanged" {
  l="$(awk '/^### 1\. /{f=1} f' "$DOOO_SKILL" | grep -F 'Call the `/do` skill')"
  [[ "$l" == *'`checklist_run_id`'* ]]
  [[ "$l" == *'sender object'* ]]
  [[ "$l" == *'on every iteration of this loop'* ]]
  [[ "$l" == *'never re-minted'* ]]
  [[ "$(dooo_0)" == *'**every** inner `/do` call, on **every** iteration of the loop'* ]]
  [[ "$(dooo_0)" == *'does not ask a second time'* ]]
}

@test "dooo --user-yes appears exactly once, on the Proceed bullet with --via dooo" {
  [ "$(grep -o -- '--user-yes' "$DOOO_SKILL" | wc -l | tr -d ' ')" -eq 1 ]
  p="$(bullet dooo_0 'Proceed')"
  [[ "$p" == *'--user-yes'* ]]
  [[ "$p" == *'FG gate --run'* ]]
  [[ "$p" == *'--via dooo'* ]]
  [ "$(grep -o 'FG gate' "$DOOO_SKILL" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "dooo Cancel and Other bullets carry no gate, mint, tick or --user-yes, and Cancel calls no /do" {
  c="$(bullet dooo_0 'Cancel')"
  o="$(bullet dooo_0 'Other')"
  [ -n "$c" ] && [ -n "$o" ]
  for b in "$c" "$o"; do
    [[ "$b" != *'--user-yes'* ]]
    [[ "$b" != *'FG gate'* ]]
    [[ "$b" != *'FG mint'* ]]
    [[ "$b" != *'foreground-preflight.sh'* ]]
    [[ "$b" != *'checklist.sh tick'* ]]
  done
  [[ "$c" == *'No `/do` is called, nothing is started'* ]]
  [[ "$c" == *'`dispatch-cost-and-cadence` stays unticked'* ]]
  [[ "$c" == *'`gate` is never called on this path'* ]]
  [[ "$o" == *'show the prompt again'* ]]
  [[ "$o" == *'never read as a yes'* ]]
  [[ "$o" == *'`gate` is not called on this path'* ]]
}

@test "dooo empty pool: no prompt, no id, and still no second mint" {
  s="$(dooo_0)"
  l="$(printf '%s\n' "$s" | grep -F '1. **Empty pool.**')"
  [[ "$l" == *'show no prompt, mint no id'* ]]
  [[ "$l" == *'never mints a second id'* ]]
  [[ "$l" != *'--user-yes'* ]]
  [[ "$l" != *'FG gate'* ]]
}

# =============================================================================
# Group 3 - the prompt wording has one home
# =============================================================================

@test "the prompt wording lives only in the asset; /do, /dooo and /jenga reference it" {
  [ "$(grep -c 'each capped at about 30 minutes' "$ASSET")" -eq 1 ]
  for f in "$DO_SKILL" "$DOOO_SKILL" "$JENGA_SKILL"; do
    [ "$(grep -c 'each capped at about 30 minutes' "$f")" -eq 0 ]
    [ "$(grep -c 'no rework round without asking again' "$f")" -eq 0 ]
    [ "$(grep -c 'No time or usage forecast is made here' "$f")" -eq 0 ]
    [ "$(grep -c 'skills/j-do/assets/foreground-prompt.md' "$f")" -ge 1 ]
  done
}

# =============================================================================
# Group 4 - executed: one ask for N tasks, nothing re-asked per task
# =============================================================================

@test "executed: a standalone /do over 3 tasks makes one mint and one gate call, and all three per-task checks are already_ticked" {
  ask_yes do
  for task in E99_S01_T01 E99_S01_T02 E99_S01_T03; do
    per_task_gate "$INV_ID"
    [ "$status" -eq 0 ]
    [ "$ADOPTED" = yes ]
    [ "$RUN_ID" = "$INV_ID" ]
    [ "$(result_of "$output" "$CHECKIN_ID")" = already_ticked ]
    [ "$(result_of "$output" "$COST_ID")" = already_ticked ]
    started "$task"
  done
  [ "$(calls mint)" -eq 1 ]
  [ "$(calls gate)" -eq 1 ]
  [ "$(calls verify)" -eq 3 ]
  [ "$(started_count)" -eq 3 ]
  # The judgment item was never put back to the user: no per-task prompt exists, only the one tick.
  [[ "$(tick_state "$COST_ID" "$INV_ID")" == 'ticked(run) by user:do at '* ]]
}

@test "executed: without the front-loaded ask each of the 3 tasks would defer (the behaviour 1.4 removes)" {
  add_checkin_event
  for task in E99_S01_T01 E99_S01_T02 E99_S01_T03; do
    per_task_gate ""
    [ "$ADOPTED" = no ]
    [ "$status" -eq 11 ]
    [ "$(result_of "$output" "$COST_ID")" = requires_confirmation ]
  done
  [ "$(calls gate)" -eq 0 ]
}

@test "executed: verify confirms an inner /do given the id sees both items satisfied, and a different run id does not" {
  ask_yes dooo
  run --separate-stderr bash "$FG" verify --run "$INV_ID" < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$(tick_state "$CHECKIN_ID" "$INV_ID")" == 'ticked(run) by user:dooo at '* ]]
  [[ "$(tick_state "$COST_ID" "$INV_ID")" == 'ticked(run) by user:dooo at '* ]]
  # A run-scoped tick does not leak into another run id.
  other="fg-20261111T130000Z-99999999"
  run --separate-stderr bash "$FG" verify --run "$other" < /dev/null
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  per_task_gate "$other"
  [ "$ADOPTED" = no ]
  [ "$status" -eq 11 ]
}

@test "executed: /dooo loop of 4 inner /do calls uses one id, one mint and one gate call, and none asks again" {
  ask_yes dooo
  for iteration in 1 2 3 4; do
    # Inner /do: 1.4 step 2 verifies the supplied id (skips its ask), then 4.1.2 verifies it again and adopts it.
    run --separate-stderr bash "$FG" verify --run "$INV_ID" < /dev/null
    [ "$status" -eq 0 ]
    per_task_gate "$INV_ID"
    [ "$status" -eq 0 ]
    [ "$RUN_ID" = "$INV_ID" ]
    [ "$(result_of "$output" "$CHECKIN_ID")" = already_ticked ]
    [ "$(result_of "$output" "$COST_ID")" = already_ticked ]
    started "iteration-$iteration"
  done
  [ "$(calls mint)" -eq 1 ]
  [ "$(calls gate)" -eq 1 ]
  [ "$(started_count)" -eq 4 ]
}

@test "executed: the run id is the same across iterations because it is passed, not re-derived (no mint after the ask)" {
  ask_yes dooo
  first="$INV_ID"
  for iteration in 1 2 3; do
    per_task_gate "$first"
    [ "$RUN_ID" = "$first" ]
  done
  [ "$(calls mint)" -eq 1 ]
}

# =============================================================================
# Group 5 - executed: Cancel, Other, and case (b)
# =============================================================================

@test "executed: Cancel leaves dispatch-cost-and-cadence unticked and starts no task" {
  INV_ID="$(fg mint)"
  add_checkin_event
  # The user answers Cancel: 1.4 and dooo step 0 make no further call. Nothing is ticked, so a unit cannot adopt it.
  [ "$(calls gate)" -eq 0 ]
  [[ "$(tick_state "$COST_ID" "$INV_ID")" != ticked* ]]
  [[ "$(tick_state "$CHECKIN_ID" "$INV_ID")" != ticked* ]]
  run --separate-stderr bash "$FG" verify --run "$INV_ID" < /dev/null
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # Even if a unit were handed this id, it would not start: it defers.
  per_task_gate "$INV_ID"
  [ "$ADOPTED" = no ]
  [ "$status" -eq 11 ]
  [ "$(started_count)" -eq 0 ]
}

@test "executed: Other (an unresolved answer) ticks nothing" {
  INV_ID="$(fg mint)"
  add_checkin_event
  # Free text only: the documented path shows the prompt again and calls neither gate nor tick.
  [ "$(calls gate)" -eq 0 ]
  [[ "$(tick_state "$COST_ID" "$INV_ID")" != ticked* ]]
  run --separate-stderr bash "$FG" verify --run "$INV_ID" < /dev/null
  [ "$status" -ne 0 ]
}

@test "executed: a gate without --user-yes (what a mistaken Cancel path would have to do) still leaves the cost item unticked" {
  add_checkin_event
  INV_ID="$(fg mint)"
  run --separate-stderr bash "$FG" gate --run "$INV_ID" --via do < /dev/null
  [ "$status" -eq 11 ]
  [[ "$(tick_state "$COST_ID" "$INV_ID")" != ticked* ]]
  run --separate-stderr bash "$FG" verify --run "$INV_ID" < /dev/null
  [ "$status" -ne 0 ]
}

@test "executed: a check-in that did not register stops Proceed (gate exit 10, nothing ticked), so no task starts" {
  INV_ID="$(fg mint)"
  # No checkin event in the fixture.
  run --separate-stderr bash "$FG" gate --run "$INV_ID" --via do --user-yes < /dev/null
  [ "$status" -eq 10 ]
  [[ "$(tick_state "$CHECKIN_ID" "$INV_ID")" != ticked* ]]
  [[ "$(tick_state "$COST_ID" "$INV_ID")" != ticked* ]]
  per_task_gate "$INV_ID"
  [ "$status" -ne 0 ]
  [ "$(started_count)" -eq 0 ]
}

@test "executed: case (b) with no supplied id still defers on both items, and never reaches gate" {
  add_checkin_event
  per_task_gate ""
  [ "$ADOPTED" = no ]
  [ "$status" -eq 11 ]
  [ "$(result_of "$output" "$CHECKIN_ID")" = already_ticked ] || [ "$(result_of "$output" "$CHECKIN_ID")" = passed ]
  [ "$(result_of "$output" "$COST_ID")" = requires_confirmation ]
  [ "$(calls gate)" -eq 0 ]
  [ "$(calls mint)" -eq 0 ]
  [ "$(started_count)" -eq 0 ]
}

@test "executed: case (b) with an unticked, an agent-ticked or a half-ticked supplied id still defers" {
  add_checkin_event
  # Unticked.
  per_task_gate "fg-20261111T120000Z-aaaa0001"
  [ "$ADOPTED" = no ]
  [ "$status" -eq 11 ]
  # Both items ticked, but by an agent actor.
  id="fg-20261111T120000Z-aaaa0002"
  bash "$CHECKLIST" tick "$CHECKIN_ID" --run "$id" --by agent:developer < /dev/null > /dev/null
  bash "$CHECKLIST" tick "$COST_ID" --run "$id" --by agent:developer < /dev/null > /dev/null
  per_task_gate "$id"
  [ "$ADOPTED" = no ]
  [ "$status" -eq 11 ]
  # Only the check-in item ticked by a user.
  id="fg-20261111T120000Z-aaaa0003"
  bash "$CHECKLIST" tick "$CHECKIN_ID" --run "$id" --by user:do < /dev/null > /dev/null
  per_task_gate "$id"
  [ "$ADOPTED" = no ]
  [ "$status" -eq 11 ]
  [ "$(calls gate)" -eq 0 ]
  [ "$(started_count)" -eq 0 ]
}

# =============================================================================
# Group 6 - unchanged files and isolation
# =============================================================================

# skills/jenga/SKILL.md is deliberately not in the list below: T05 (E67_S11_T05) reconciles its deferral wording after
# T04, so a diff against the T03 merge commit is expected there. The scripts and assets below stay frozen.
@test "scripts/checklist.sh and the files this task must not touch are unchanged" {
  git -C "$REPO_ROOT" rev-parse --git-dir > /dev/null 2>&1 || skip "not a git checkout"
  base="$(git -C "$REPO_ROOT" log --format=%H --grep='^story(E67_S11): merge T03' -1 2>/dev/null || true)"
  [ -n "$base" ] || skip "T03 merge commit not in history"
  run git -C "$REPO_ROOT" diff --quiet "$base" -- scripts/checklist.sh scripts/checklist-marker.sh scripts/foreground-preflight.sh skills/j-check-in skills/j-do/assets/foreground-prompt.md
  [ "$status" -eq 0 ]
}

@test "isolation: these tests wrote nothing under the repository's real tick directory" {
  real="$REPO_ROOT/project/queue/checklist-ticks"
  before="$( [ -d "$real" ] && ls -A "$real" | sort | tr '\n' ' ' || echo none )"
  ask_yes do
  after="$( [ -d "$real" ] && ls -A "$real" | sort | tr '\n' ' ' || echo none )"
  [ "$before" = "$after" ]
  [ -d "$STATE" ]
}
