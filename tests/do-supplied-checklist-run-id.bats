#!/usr/bin/env bats
#
# Coverage for E67_S11_T02: /j-do accepts a caller-supplied checklist run id and adopts it only after
# scripts/foreground-preflight.sh verify exits 0.
#
# What is under test.
#   - skills/j-do/assets/sender_template.json  the optional checklist_run_id field
#   - skills/j-do/SKILL.md                     ### 4.1.2, the ### 1.5 bundle gate paragraph, ### 4.4 and the
#                                              ### 4.3 Fallback wording (text assertions)
#   - the DOCUMENTED DECISION PATH, executed for real: read checklist_run_id from the sender object; when
#     non-empty run `foreground-preflight.sh verify --run <id>`; exit 0 adopts it as RUN_ID, anything else mints
#     do-<UTC>-<rand>; then `checklist.sh check pre-task --run "$RUN_ID"`. do_decision below is that path, nothing
#     more. SKILL.md is prose for an agent, so the path cannot be run from it; the text assertions pin that the
#     prose says what this helper does.
#
# What this suite guards. A sub-agent must never self-certify the judgment item dispatch-cost-and-cadence. The
# supplied id is a claim; the cases that matter are the refusals, one per way a claim could be wrong.
#
# Isolation. A temp project root ($PROJ) reached through JENGA_PROJECT_ROOT, with its own workflow.json,
# events.json, registry and tick-state directory (same pattern as tests/foreground-preflight.bats). The real
# project/logs/events.json and the real project/queue/checklist-ticks/ are never read or written, and nothing
# here runs `foreground-preflight.sh gate`. Every script call has an explicit stdin from /dev/null.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FG="$REPO_ROOT/scripts/foreground-preflight.sh"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
GATE="$REPO_ROOT/skills/j-check-in/scripts/checkin-gate.sh"
SKILL="$REPO_ROOT/skills/j-do/SKILL.md"
TEMPLATE="$REPO_ROOT/skills/j-do/assets/sender_template.json"

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
  export CLAUDE_CODE_SESSION_ID="sess-unit"
  unset JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID JENGA_CHECKLIST_MARKER_DIR
  unset JENGA_CHECKLIST_MARKER_TTL_MINUTES JENGA_SCOPE_THRESHOLDS_FILE JENGA_CHECKLIST_NOW
  unset JENGA_PREFLIGHT_HOOK_SCRIPT_DIR JENGA_PREFLIGHT_HOOK_DEBUG JENGA_CHECKLIST_RUN_ID
  unset JENGA_CHECKLIST_ACTOR JENGA_CHECKLIST_RUN_TTL_MINUTES JENGA_CHECKLIST_VERIFY_TIMEOUT

  write_registry
}

# -----------------------------------------------------------------------------
# Fixtures and runners
# -----------------------------------------------------------------------------

# A registry holding the two items, shaped like the real ones: the machine item is verified by the REAL
# check-in gate (which fails here, the fixture events.json holds no checkin event), the judgment item cannot be
# confirmed by the checker. Both are run-scoped confirm items. Unticked, `check pre-task` therefore exits 11.
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

# tick <item> <run> <actor>
tick() {
  bash "$CHECKLIST" tick "$1" --run "$2" --by "$3" < /dev/null > /dev/null
}

# tick_both <run> <actor>
tick_both() {
  tick "$CHECKIN_ID" "$1" "$2"
  tick "$COST_ID" "$1" "$2"
}

# sender_with <run-id-or-@absent>: a sender object as /do receives it. "@absent" omits the field entirely.
sender_with() {
  if [ "$1" = "@absent" ]; then
    jq 'del(.sender.checklist_run_id) | .sender.task_id = "E99_S01_T01"' "$TEMPLATE"
  else
    jq --arg r "$1" '.sender.checklist_run_id = $r | .sender.task_id = "E99_S01_T01"' "$TEMPLATE"
  fi
}

# do_decision <sender-json>: the documented ### 4.1.2 decision path. Sets RUN_ID, ADOPTED (yes or no), then runs
# `check pre-task --run "$RUN_ID"`; the caller reads $status (0: no deferral, 10 or 11: defer) and $output.
do_decision() {
  local supplied
  supplied="$(printf '%s' "$1" | jq -r '.sender.checklist_run_id // ""')"
  ADOPTED=no
  RUN_ID=""
  if [ -n "$supplied" ] && bash "$FG" verify --run "$supplied" < /dev/null > /dev/null 2>&1; then
    RUN_ID="$supplied"
    ADOPTED=yes
  else
    RUN_ID="do-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  run --separate-stderr bash "$CHECKLIST" check pre-task --run "$RUN_ID" < /dev/null
}

# section <start-regex> <stop-regex>: SKILL.md lines from the first line matching start up to (not including)
# the next line matching stop.
section() {
  awk -v s="$1" -v e="$2" '$0 ~ s { f = 1; print; next } f && $0 ~ e { exit } f { print }' "$SKILL"
}

# =============================================================================
# Group 1 - the sender template
# =============================================================================

@test "sender_template.json is valid JSON, carries checklist_run_id as an empty string, and keeps its other fields" {
  run jq -e . "$TEMPLATE"
  [ "$status" -eq 0 ]
  run jq -r '.sender.checklist_run_id | type' "$TEMPLATE"
  [ "$output" = "string" ]
  run jq -r '.sender.checklist_run_id' "$TEMPLATE"
  [ -z "$output" ]
  for k in agent session_id task_id story_id epic_id date paths worktree; do
    run jq -e --arg k "$k" '.sender | has($k)' "$TEMPLATE"
    [ "$status" -eq 0 ]
  done
  # Same shape as before for the other fields: defaults unchanged.
  run jq -r '.sender.agent, (.sender.paths | length)' "$TEMPLATE"
  [ "${lines[0]}" = "orchestrator" ]
  [ "${lines[1]}" = "0" ]
}

@test "the template still populates cleanly the way the sender-object step does (every existing field settable)" {
  run jq -e '.sender
    | .session_id = "s" | .task_id = "E01_S01_T01" | .story_id = "E01_S01" | .epic_id = "E01"
    | .date = "2026-11-11T00:00:00Z" | .paths = ["abc1234"] | .worktree = "/tmp/x"
    | .checklist_run_id = "fg-20261111T000000Z-deadbeef"
    | select(.session_id == "s" and .checklist_run_id == "fg-20261111T000000Z-deadbeef")' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

# =============================================================================
# Group 2 - the documented decision path, executed
# =============================================================================

@test "a supplied run id whose two items were ticked by user:* is adopted and yields no deferral" {
  tick_both "fg-20261111T120000Z-aaaa1111" "user:jenga"
  do_decision "$(sender_with fg-20261111T120000Z-aaaa1111)"
  [ "$ADOPTED" = yes ]
  [ "$RUN_ID" = "fg-20261111T120000Z-aaaa1111" ]
  [ "$status" -eq 0 ]
  # Both items report the tick as already given; neither asks for a decision.
  [ "$(printf '%s' "$output" | jq -r --arg i "$CHECKIN_ID" '.[] | select(.id == $i) | .result')" = "already_ticked" ]
  [ "$(printf '%s' "$output" | jq -r --arg i "$COST_ID" '.[] | select(.id == $i) | .result')" = "already_ticked" ]
}

@test "user:do and user:dooo ticks are adopted too" {
  tick_both "fg-20261111T120000Z-bbbb2222" "user:do"
  do_decision "$(sender_with fg-20261111T120000Z-bbbb2222)"
  [ "$ADOPTED" = yes ]
  [ "$status" -eq 0 ]
  tick_both "fg-20261111T120000Z-cccc3333" "user:dooo"
  do_decision "$(sender_with fg-20261111T120000Z-cccc3333)"
  [ "$ADOPTED" = yes ]
  [ "$status" -eq 0 ]
}

@test "the field absent: a fresh id is minted and both items still defer (exit 11)" {
  tick_both "fg-20261111T120000Z-aaaa1111" "user:jenga"
  do_decision "$(sender_with @absent)"
  [ "$ADOPTED" = no ]
  [[ "$RUN_ID" =~ ^do-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$ ]]
  [ "$status" -eq 11 ]
}

@test "the field empty: a fresh id is minted and both items still defer" {
  tick_both "fg-20261111T120000Z-aaaa1111" "user:jenga"
  do_decision "$(sender_with "")"
  [ "$ADOPTED" = no ]
  [[ "$RUN_ID" =~ ^do-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$ ]]
  [ "$status" -eq 11 ]
}

@test "a supplied id with nothing ticked: not adopted, still defers" {
  do_decision "$(sender_with fg-20261111T120000Z-dddd4444)"
  [ "$ADOPTED" = no ]
  [[ "$RUN_ID" =~ ^do- ]]
  [ "$status" -eq 11 ]
}

@test "a supplied id ticked by an agent actor: not adopted, still defers" {
  tick_both "fg-20261111T120000Z-eeee5555" "agent:developer"
  do_decision "$(sender_with fg-20261111T120000Z-eeee5555)"
  [ "$ADOPTED" = no ]
  [ "$status" -eq 11 ]
}

@test "a supplied id ticked by the default actor (os-user:<login>): not adopted, still defers" {
  bash "$CHECKLIST" tick "$CHECKIN_ID" --run fg-20261111T120000Z-ffff6666 < /dev/null > /dev/null
  bash "$CHECKLIST" tick "$COST_ID" --run fg-20261111T120000Z-ffff6666 < /dev/null > /dev/null
  do_decision "$(sender_with fg-20261111T120000Z-ffff6666)"
  [ "$ADOPTED" = no ]
  [ "$status" -eq 11 ]
}

@test "only one of the two items ticked by a user: not adopted, still defers" {
  tick "$CHECKIN_ID" "fg-20261111T120000Z-abab7777" "user:jenga"
  do_decision "$(sender_with fg-20261111T120000Z-abab7777)"
  [ "$ADOPTED" = no ]
  [ "$status" -eq 11 ]
}

@test "ticks given under a different run id do not carry over to the supplied one" {
  tick_both "fg-20261111T120000Z-aaaa1111" "user:jenga"
  do_decision "$(sender_with fg-20261111T120000Z-9999zzzz)"
  [ "$ADOPTED" = no ]
  [ "$RUN_ID" != "fg-20261111T120000Z-aaaa1111" ]
  [ "$status" -eq 11 ]
}

@test "a malformed supplied id (path separators, dots) is not adopted and defers" {
  tick_both "fg-20261111T120000Z-aaaa1111" "user:jenga"
  do_decision "$(sender_with "../fg-20261111T120000Z-aaaa1111")"
  [ "$ADOPTED" = no ]
  [ "$status" -eq 11 ]
}

@test "the environment variable JENGA_CHECKLIST_RUN_ID is not a way to supply the id" {
  tick_both "fg-20261111T120000Z-aaaa1111" "user:jenga"
  JENGA_CHECKLIST_RUN_ID=fg-20261111T120000Z-aaaa1111 do_decision "$(sender_with @absent)"
  [ "$ADOPTED" = no ]
  [ "$status" -eq 11 ]
}

@test "the decision path never ticks: tick state is unchanged by a refused or adopted supplied id" {
  tick "$CHECKIN_ID" "fg-20261111T120000Z-abab7777" "user:jenga"
  before="$(find "$STATE" -type f | sort | xargs cat | shasum)"
  do_decision "$(sender_with fg-20261111T120000Z-abab7777)"
  [ "$ADOPTED" = no ]
  after="$(find "$STATE" -type f | sort | xargs cat | shasum)"
  [ "$before" = "$after" ]
}

@test "isolation: the decision path wrote nothing under the real project's tick directory or event log" {
  tick_both "fg-20261111T120000Z-aaaa1111" "user:jenga"
  do_decision "$(sender_with fg-20261111T120000Z-aaaa1111)"
  [ -d "$STATE" ]
  case "$STATE" in "$REPO_ROOT"/*) false ;; esac
  [ ! -s "$EVENTS" ]
}

# =============================================================================
# Group 3 - the SKILL.md text
# =============================================================================

@test "### 4.1.2 states the adopt-after-verify rule and cites foreground-preflight.sh verify" {
  s="$(section '^### 4\.1\.2' '^### 4\.1\.5')"
  [ -n "$s" ]
  [[ "$s" == *"checklist_run_id"* ]]
  [[ "$s" == *"scripts/foreground-preflight.sh"* ]]
  [[ "$s" == *'verify --run'* ]]
  [[ "$s" == *"Adopt only after"* ]]
  # Each of the three keep-today's-behaviour cases is readable from the text.
  [[ "$s" == *"Empty or absent"* ]]
  [[ "$s" == *"mint"* ]]
  [[ "$s" == *"Any non-zero exit"* ]]
  [[ "$s" == *"defer exactly as today"* ]]
  [[ "$s" == *"never retry"* ]]
}

@test "### 4.1.2 carries no inline checklist.sh tick call (the tick logic stays in the script)" {
  s="$(section '^### 4\.1\.2' '^### 4\.1\.5')"
  [ -n "$s" ]
  run grep -c -E 'checklist\.sh"? +tick|checklist\.sh[^ ]* +tick|[[:space:]]tick +"?\$?[A-Za-z_-]+"? +--run' <<< "$s"
  [ "$output" = "0" ]
}

@test "the bundle gate paragraph applies the same rule once, with the story as the unit" {
  p="$(grep -n 'Pre-task gate — once per bundle dispatch' "$SKILL" | head -1 | cut -d: -f1)"
  [ -n "$p" ]
  para="$(sed -n "${p}p" "$SKILL")"
  [[ "$para" == *"checklist_run_id"* ]]
  [[ "$para" == *"scripts/foreground-preflight.sh verify --run"* ]]
  [[ "$para" == *"exits \`0\`"* ]]
  [[ "$para" == *"mints"* ]]
  [[ "$para" == *"defers as today"* ]]
  [[ "$para" == *"the story as the unit"* ]]
}

@test "### 4.4 documents checklist_run_id beside session_id: who supplies it, verbatim, proves nothing" {
  s="$(section '^### 4\.4' '^### 5\.')"
  [ -n "$s" ]
  [[ "$s" == *"checklist_run_id"* ]]
  [[ "$s" == *"/jenga"* && "$s" == *"/dooo"* ]]
  [[ "$s" == *"verbatim"* ]]
  [[ "$s" == *"never regenerated"* ]]
  [[ "$s" == *"presence alone proves nothing"* ]]
}

@test "the ### 5 sender-object step leaves checklist_run_id as the caller supplied it" {
  s="$(section '^### 5\.' '^### 5\.1')"
  [[ "$s" == *"checklist_run_id"* ]]
  [[ "$s" == *"verbatim"* ]]
}

@test "the Fallback to Full Task-Scope Pipeline still reuses the unit's RUN_ID and does not re-gate" {
  s="$(section '^#### Fallback to Full Task-Scope Pipeline' '^---')"
  [ -n "$s" ]
  [[ "$s" == *"The pre-task gate does not fire here."* ]]
  [[ "$s" == *"Reuse that gate's \`RUN_ID\`"* ]]
  [[ "$s" == *"do not call \`checklist.sh check pre-task\` again"* ]]
  # The supplied-id case adds no second verification.
  [[ "$s" == *"no second verification"* ]]
}

@test "remind items and the preflight_deferred event shape are unchanged" {
  s="$(section '^### 4\.1\.2' '^### 4\.1\.5')"
  [[ "$s" == *'{"event": "preflight_deferred", "agent": "orchestrator", "session_id": "<orchestrator_session_id>",'* ]]
  [[ "$s" == *'"item_id": "<id>", "phase": "pre-task", "run_id": "<RUN_ID>", "items": ["<checklist item ids>"], "date":'* ]]
  [[ "$s" == *'Items whose `action` is `remind` never halt or defer'* ]]
}

@test "the verify script the text cites exists, is executable, and the dual-path idiom in the text resolves to it" {
  [ -x "$FG" ]
  s="$(section '^### 4\.1\.2' '^### 4\.1\.5')"
  [[ "$s" == *'[ -f scripts/foreground-preflight.sh ] && echo scripts/foreground-preflight.sh || echo node_modules/@jenga-ai/agent/scripts/foreground-preflight.sh'* ]]
  run bash -c 'cd "$1" && echo "$([ -f scripts/foreground-preflight.sh ] && echo scripts/foreground-preflight.sh || echo node_modules/@jenga-ai/agent/scripts/foreground-preflight.sh)"' _ "$REPO_ROOT"
  [ "$output" = "scripts/foreground-preflight.sh" ]
}

@test "scripts/checklist.sh is not modified by this task" {
  # Content compared with the T01 merge commit the branch was cut from; skipped outside a git checkout.
  git -C "$REPO_ROOT" rev-parse --git-dir > /dev/null 2>&1 || skip "not a git checkout"
  base="$(git -C "$REPO_ROOT" log --format=%H --grep='^story(E67_S11): merge T01' -1 2>/dev/null || true)"
  [ -n "$base" ] || skip "T01 merge commit not in history"
  run git -C "$REPO_ROOT" diff --quiet "$base" -- scripts/checklist.sh scripts/checklist-marker.sh skills/j-check-in/scripts/checkin-gate.sh
  [ "$status" -eq 0 ]
}
