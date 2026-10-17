#!/usr/bin/env bats
#
# Coverage for the automatic check-in gate (E44_S07_T03).
#
# Contract under test:
#   - skills/j-check-in/scripts/checkin-gate.sh   its own header: exit codes, session keying, the
#                                                 exact-spelling rule, the fail direction
#   - project/configs/checklists.json             the checkin-run-before-dispatch item, and the
#                                                 never-`block` invariant
#   - hooks/on_preflight_check.sh                 the decision table, for the recursion path
#   - project/documentation/preflight-checklists.md  "Automatic j.check-in at the pre-task gate"
#
# Isolation. Everything runs in a temp project root ($PROJ) reached through JENGA_PROJECT_ROOT, with its
# own workflow.json (naming queue, configs and logs), scope-thresholds.json, events.json and registry.
# The real project's events.json, tick store and marker directory are never read or written.
#
# The ONE deliberate exception: "the registered item is not block-enforcement" READS the repository's real
# project/configs/checklists.json, because that is the file whose value the invariant is about. It only
# reads it — nothing in this suite writes it.
#
# What a "session" is here. Nothing in a script can observe which session it runs in, so a session is its
# key. `as_session <key> <command...>` sets CLAUDE_CODE_SESSION_ID, which is the normal production source
# and the same seam tests/checklist-hook.bats uses. Two sessions are two different keys driving the real
# scripts.
#
# Why the cadence cases look the way they do. The item ships `tick_scope: run`, NOT `persistent`. The
# story's acceptance criteria asked for persistent on the stated belief that it meant once-per-session; it
# does not — a persistent tick survives across sessions (preflight-checklists.md section 7) and lives in a
# project-root-scoped persistent.json the pruner never touches, so it would have fired the gate once and
# gone silent for the life of the repository. See the Deviations section on E44_S07_T02. Once-per-session
# is therefore a composite property and is pinned as two separate facts:
#   1. a tick is not re-verified WITHIN its run      (what the AC's "already_ticked -> proceed" wanted)
#   2. the gate itself is session-scoped, so later units of the same session pass and a new session fails
# Both are asserted below against an invocation-recording verify, so "did not re-run" is proven and not
# assumed.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GATE="$REPO_ROOT/skills/j-check-in/scripts/checkin-gate.sh"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
MARKER="$REPO_ROOT/scripts/checklist-marker.sh"
HOOK="$REPO_ROOT/hooks/on_preflight_check.sh"
REAL_REGISTRY="$REPO_ROOT/project/configs/checklists.json"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  F="$T/checklists.json"
  STATE="$T/state"
  EVENTS="$PROJ/project/logs/events.json"
  CALLS="$T/verify-calls.log"

  mkdir -p "$PROJ/project/configs" "$PROJ/project/logs" "$PROJ/project/queue"

  # Pretty-printed on purpose: the hook's pure-bash probe of paths.queue reads one key per line.
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
  printf '[]\n' > "$EVENTS"

  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_CHECKLISTS_FILE="$F"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$T/no-default-checklists.json"
  export JENGA_CHECKLIST_STATE_DIR="$STATE"
  export CLAUDE_CODE_SESSION_ID="sess-main"
  unset JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID JENGA_CHECKLIST_MARKER_DIR
  unset JENGA_CHECKLIST_MARKER_TTL_MINUTES JENGA_SCOPE_THRESHOLDS_FILE JENGA_CHECKLIST_NOW
  unset JENGA_PREFLIGHT_HOOK_SCRIPT_DIR JENGA_PREFLIGHT_HOOK_DEBUG JENGA_CHECKLIST_RUN_ID
  unset JENGA_CHECKLIST_ACTOR JENGA_CHECKLIST_RUN_TTL_MINUTES JENGA_CHECKLIST_VERIFY_TIMEOUT
}

# -----------------------------------------------------------------------------
# Fixture builders
# -----------------------------------------------------------------------------

# add_event <json-object>: append one event to the fixture events.json.
add_event() { printf '%s\n' "$1" >> "$EVENTS"; }

# checkin_event <session-key>: a canonical checkin event for that session key.
checkin_event() {
  printf '{"event": "checkin", "agent": "orchestrator", "session_key": "%s", "date": "2026-10-12T12:00:00Z"}' "$1"
}

# recording_verify: a verify command that records each invocation, then delegates to the REAL gate.
# This is what makes "the verify was not re-run" an assertion rather than an assumption.
recording_verify() {
  local recorder="$T/recording-verify.sh"
  cat > "$recorder" <<EOF
#!/usr/bin/env bash
printf 'call\n' >> "$CALLS"
exec bash "$GATE"
EOF
  printf 'bash %s' "$recorder"
}

# write_gate_registry [verify-command]: a registry whose only item is the real one under test.
# Defaults to the real gate; pass recording_verify's output to count invocations.
write_gate_registry() {
  local verify="${1:-bash $GATE}"
  jq -n --arg verify "$verify" '{
    checklist_version: 1,
    situations: [],
    items: [{
      id: "checkin-run-before-dispatch",
      text: "A pre-dispatch check-in has been run in this session and its findings surfaced. This item must never be set to block enforcement: satisfying it requires running a check-in, which is itself a tool call, so block would refuse the very dispatch that would satisfy it.",
      situations: ["pre-task"],
      kind: "machine",
      verify: $verify,
      enforcement: "confirm",
      tick_scope: "run"
    }]
  }' > "$F"
}

verify_call_count() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || printf '0'; }

# -----------------------------------------------------------------------------
# Runners
# -----------------------------------------------------------------------------

as_session() { local key="$1"; shift; CLAUDE_CODE_SESSION_ID="$key" "$@"; }

run_gate() { run bash "$GATE" "$@"; }

# item_state <run-id>: result and action of our item from `check pre-task`, as "result action".
item_state() {
  bash "$CHECKLIST" check pre-task --run "$1" 2>/dev/null \
    | jq -r '.[] | select(.id == "checkin-run-before-dispatch") | "\(.result) \(.action)"'
}

payload() { jq -nc --arg t "$1" --arg c "${2:-}" '{tool_name: $t, tool_input: {command: $c}}'; }

run_hook() { run --separate-stderr bash "$HOOK" <<<"$(payload "$1" "${2:-}")"; }

# =============================================================================
# Group 1 — gate exit codes
# =============================================================================

@test "gate exits 0 when a checkin event exists for this session" {
  add_event "$(checkin_event sess-main)"
  run_gate
  [ "$status" -eq 0 ]
}

@test "gate exits 1 when no checkin event exists" {
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"no 'checkin' event"* ]]
}

@test "gate does not pass on a checkin event belonging to a different session key" {
  add_event "$(checkin_event sess-someone-else)"
  run_gate
  [ "$status" -eq 1 ]
  # The whole point of session keying: another session's check-in is not mine.
  as_session sess-someone-else run bash "$GATE"
  [ "$status" -eq 0 ]
}

@test "gate does not pass on a differently-spelled event" {
  # The single-canonical-spelling rule is only real if something enforces it.
  # j.check-in's own tree is grepped for these variants; this is the runtime half.
  add_event '{"event": "check_in", "session_key": "sess-main", "date": "2026-10-12T12:00:00Z"}'
  add_event '{"event": "standup", "session_key": "sess-main", "date": "2026-10-12T12:00:00Z"}'
  add_event '{"event": "checkin_run", "session_key": "sess-main", "date": "2026-10-12T12:00:00Z"}'
  add_event '{"event": "checkin_complete", "session_key": "sess-main", "date": "2026-10-12T12:00:00Z"}'
  run_gate
  [ "$status" -eq 1 ]

  # ...and the canonical spelling alone flips it.
  add_event "$(checkin_event sess-main)"
  run_gate
  [ "$status" -eq 0 ]
}

@test "gate matches session_id as a fallback, since the collector derives its own differently" {
  # collect-liveness.sh resolves SESSION_ID / HARNESS_SESSION_ID / hostname-pid, which is NOT the
  # marker's probe order. A check-in recorded without the explicit session_key still counts.
  add_event '{"event": "checkin", "session_id": "sess-main", "date": "2026-10-12T12:00:00Z"}'
  run_gate
  [ "$status" -eq 0 ]
}

@test "gate exits 7 when no session key can be resolved" {
  add_event "$(checkin_event sess-main)"
  run env -u CLAUDE_CODE_SESSION_ID -u JENGA_CHECKLIST_SESSION_ID -u JENGA_SESSION_ID \
    JENGA_PROJECT_ROOT="$PROJ" bash "$GATE"
  # Non-zero, not 0: an unknown session must cost a prompt, never a silent skip.
  [ "$status" -eq 7 ]
}

@test "gate exits 3 when the events file is absent" {
  rm -f "$EVENTS"
  run_gate
  [ "$status" -eq 3 ]
}

@test "gate rejects bad usage with exit 2" {
  run_gate --max-age-minutes not-a-number
  [ "$status" -eq 2 ]
  run_gate --nonsense
  [ "$status" -eq 2 ]
  run_gate --max-age-minutes
  [ "$status" -eq 2 ]
}

@test "gate accepts --max-age-minutes and documents it as reserved" {
  add_event "$(checkin_event sess-main)"
  run_gate --max-age-minutes 30
  [ "$status" -eq 0 ]
  grep -q "reserved for the deferred time-based cadence mode" "$GATE"
}

@test "gate parses a malformed events.json rather than failing permanently open or shut" {
  # The real events.json is an unterminated JSON array with a missing comma. A strict parse would make
  # the gate permanently unsatisfiable, which under `confirm` means prompting on every dispatch forever.
  cat > "$EVENTS" <<EOF
[
  {"event": "session_start", "session_key": "sess-main", "date": "2026-10-12T11:00:00Z"}
  ,
  $(checkin_event sess-main)
EOF
  run_gate
  [ "$status" -eq 0 ]
}

@test "gate writes nothing" {
  add_event "$(checkin_event sess-main)"
  local before after
  before="$(cd "$PROJ" && find . -type f | sort | xargs cksum 2>/dev/null | cksum)"
  run_gate
  [ "$status" -eq 0 ]
  after="$(cd "$PROJ" && find . -type f | sort | xargs cksum 2>/dev/null | cksum)"
  [ "$before" = "$after" ]
}

# =============================================================================
# Group 2 — cadence
# =============================================================================

@test "cadence: the gate fails on the first unit of a session and the item prompts" {
  write_gate_registry
  [ "$(item_state unit-1)" = "failed prompt" ]
  run bash "$CHECKLIST" check pre-task --run unit-1
  [ "$status" -eq 11 ]   # a confirm item needs a decision
}

@test "cadence: a tick is not re-verified within its own run" {
  # This is what the AC's "already_ticked -> proceed, verify not re-run" was reaching for, and it is
  # proven by the invocation recorder rather than inferred.
  write_gate_registry "$(recording_verify)"

  [ "$(item_state unit-1)" = "failed prompt" ]
  [ "$(verify_call_count)" -eq 1 ]

  bash "$CHECKLIST" tick checkin-run-before-dispatch --run unit-1 --by "agent:test" >/dev/null

  [ "$(item_state unit-1)" = "already_ticked proceed" ]
  [ "$(verify_call_count)" -eq 1 ]   # unchanged: the verify did NOT run again
}

@test "cadence: a run-scoped tick does not leak into the next unit of the same session" {
  # Why the item is NOT persistent: a persistent tick would make the next unit, and every later
  # session, see already_ticked and never check again.
  write_gate_registry "$(recording_verify)"

  bash "$CHECKLIST" tick checkin-run-before-dispatch --run unit-1 --by "agent:test" >/dev/null
  [ "$(item_state unit-1)" = "already_ticked proceed" ]

  # A new unit means a new run id, so the tick is gone and the gate is consulted again.
  [ "$(item_state unit-2)" = "failed prompt" ]
}

@test "cadence: once a check-in is recorded, later units of the same session proceed" {
  write_gate_registry "$(recording_verify)"

  [ "$(item_state unit-1)" = "failed prompt" ]

  add_event "$(checkin_event sess-main)"

  [ "$(item_state unit-2)" = "passed proceed" ]
  [ "$(item_state unit-3)" = "passed proceed" ]
  run bash "$CHECKLIST" check pre-task --run unit-4
  [ "$status" -eq 0 ]   # nothing needs a decision any more

  # The verify DID re-run each time (no tick carried over) and passed each time. That is the
  # mechanism: per-unit re-evaluation from tick_scope run, session scoping from the gate itself.
  [ "$(verify_call_count)" -ge 4 ]
}

@test "cadence: a new session fires the gate again — one check-in per session, not one ever" {
  write_gate_registry
  add_event "$(checkin_event sess-main)"

  [ "$(item_state unit-1)" = "passed proceed" ]

  # Same project, same registry, same events file: only the session key differs.
  as_session sess-second-session bash -c "
    bash '$CHECKLIST' check pre-task --run unit-1 2>/dev/null \
      | jq -r '.[] | select(.id == \"checkin-run-before-dispatch\") | \"\(.result) \(.action)\"'
  " > "$T/second.txt"
  [ "$(cat "$T/second.txt")" = "failed prompt" ]
}

# =============================================================================
# Group 3 — recursion, and the never-block invariant
# =============================================================================

@test "recursion: a nested dispatch while the item is unticked is ASKED about, never refused" {
  # THE PATH THIS PINS. Satisfying this item means running a check-in. When a finding is actionable,
  # j.check-in dispatches a scrum-master subagent — a nested Task/Agent call made while the pre-task
  # frame is still open and the item is still unticked.
  #
  # hooks/on_preflight_check.sh maps check exit 10 -> REFUSE and exit 11 -> ask. Our item is `confirm`,
  # so an unsatisfied check is exit 11 and the nested dispatch is asked about, not refused: no wedge.
  #
  # EXPECTED USER-VISIBLE BEHAVIOUR, recorded so it is an examined outcome and not a surprise: you are
  # asked about a checklist item while already in the act of satisfying it. Answer and proceed.
  #
  # DOCUMENTED FALLBACK: a harness that does not implement "ask" degrades to allow, which is the safe
  # direction here (the alternative would be refusing the dispatch that satisfies the item).
  write_gate_registry
  bash "$MARKER" write --situation pre-task --run unit-1 --skill j.do >/dev/null

  run_hook Task

  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "ask" ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" != "deny" ]
  [[ "$output" == *"checkin-run-before-dispatch"* ]]
}

@test "recursion: the same nested dispatch WOULD be refused under block enforcement" {
  # The counterfactual that makes the never-block rule a wedge guard rather than a style preference.
  jq '.items[0].enforcement = "block"' "$F" > "$F.block" 2>/dev/null || true
  write_gate_registry
  jq '.items[0].enforcement = "block"' "$F" > "$T/block.json"
  cp "$T/block.json" "$F"

  bash "$MARKER" write --situation pre-task --run unit-1 --skill j.do >/dev/null
  run_hook Task

  [ "$status" -eq 2 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "the registered item is not block-enforcement" {
  # Reads the repository's REAL registry, because that is the file whose value this invariant is about.
  # Read-only: nothing in this suite writes it.
  [ -f "$REAL_REGISTRY" ] || skip "no project registry in this checkout"

  local enforcement
  enforcement="$(jq -r '.items[] | select(.id == "checkin-run-before-dispatch") | .enforcement' "$REAL_REGISTRY")"
  [ -n "$enforcement" ] || { echo "checkin-run-before-dispatch is not in $REAL_REGISTRY" >&2; return 1; }

  if [ "$enforcement" = "block" ]; then
    echo "checkin-run-before-dispatch is block-enforcement. Satisfying it requires running a" >&2
    echo "check-in, which is itself a tool call, so block refuses the very dispatch that would" >&2
    echo "satisfy it: an unrecoverable wedge. It must be confirm." >&2
    return 1
  fi
  [ "$enforcement" = "confirm" ]
}

@test "the registered item carries the expected shape and wording" {
  [ -f "$REAL_REGISTRY" ] || skip "no project registry in this checkout"

  local item
  item="$(jq -c '.items[] | select(.id == "checkin-run-before-dispatch")' "$REAL_REGISTRY")"
  [ -n "$item" ]

  [ "$(jq -r '.situations | join(",")' <<<"$item")" = "pre-task" ]
  [ "$(jq -r '.kind' <<<"$item")" = "machine" ]
  [ "$(jq -r '.tick_scope' <<<"$item")" = "run" ]
  [[ "$(jq -r '.verify' <<<"$item")" == *"checkin-gate.sh"* ]]

  local text
  text="$(jq -r '.text' <<<"$item")"
  # "has been run and its findings surfaced", never "findings were clear": the tick must stay
  # legitimate in the actionable branch, which is exactly the branch that would otherwise recurse.
  [[ "$text" == *"has been run"* ]]
  [[ "$text" == *"findings surfaced"* ]]
  [[ "$text" != *"were clear"* ]]
  # The never-block rule and its reason travel with the data.
  [[ "$text" == *"never be set to block"* ]]
  [[ "$text" == *"would satisfy it"* ]]
}

@test "the registry the item lives in still validates" {
  # checklist-registries-valid is a block-enforcement pre-commit item, so an invalid registry blocks
  # every commit in the repository. This is the cheap guard against shipping that.
  [ -f "$REAL_REGISTRY" ] || skip "no project registry in this checkout"
  run bash "$REPO_ROOT/scripts/validate-checklists.sh" "$REPO_ROOT/templates/checklists.json" "$REAL_REGISTRY"
  [ "$status" -eq 0 ]
}

@test "this feature registers no hook wiring of its own" {
  # The PreToolUse block registers on_preflight_check.sh generically: it reads the marker and checks
  # whatever phase it finds. Adding a registry item changes no wiring, and the six files that carry
  # that block must not mention this feature.
  local f
  for f in "$REPO_ROOT/settings.json" "$REPO_ROOT"/templates/permission-levels/level-*.json; do
    [ -f "$f" ] || continue
    if grep -q "checkin" "$f"; then
      echo "$f mentions checkin; this feature must add no hook wiring" >&2
      return 1
    fi
  done
}
