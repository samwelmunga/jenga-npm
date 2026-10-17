#!/usr/bin/env bats
#
# Coverage for skills/j-check-in/scripts/collect-liveness.sh (E44_S05_T01).
#
# Contract under test:
# - Exit code always 0 (except internal script error)
# - JSON output with exactly 6 required keys: generated_at, session_id, visibility, findings, residue, counts
# - Visibility object always present with required fields: in_session, cross_session, agents_input, notes
# - Zero file writes (read-only contract)
# - Hardcoded thresholds: 20-min idle warn, 45-min stall
# - Modes: normal (with ListAgents input) and --no-agents (offline)
#
# Isolation: All fixtures generated at test time into $BATS_TEST_TMPDIR.
# The real project/ tree is never touched by these tests.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
COLLECT_LIVENESS="$REPO_ROOT/skills/j-check-in/scripts/collect-liveness.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  FIXTURE_ROOT="$T/fixture"
  mkdir -p "$FIXTURE_ROOT/project/queue"
  mkdir -p "$FIXTURE_ROOT/project/logs"
  mkdir -p "$FIXTURE_ROOT/project/board"
  mkdir -p "$FIXTURE_ROOT/project/rapports/problems"
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees"

  # Create synthetic events.json
  cat > "$FIXTURE_ROOT/project/logs/events.json" <<'EOF'
{"event": "session_start", "agent": "developer", "session_id": "dev-session-123", "date": "2026-10-07T10:00:00Z"}
{"event": "session_start", "agent": "tester", "session_id": "tester-session-456", "date": "2026-10-07T10:05:00Z"}
{"event": "task_completed", "agent": "developer", "session_id": "dev-session-123", "date": "2026-10-07T10:30:00Z"}
EOF
}

# Create a temporary fixture snapshot for behavioral no-writes test
snapshot_fixture() {
  local snapshot_dir="$T/fixture-snapshot"
  rm -rf "$snapshot_dir"
  cp -r "$FIXTURE_ROOT" "$snapshot_dir"
  echo "$snapshot_dir"
}

# Compare two fixture trees byte-by-byte
assert_fixture_unchanged() {
  local before="$1" after="$FIXTURE_ROOT"
  local diff_out
  diff_out=$(diff -r "$before" "$after" 2>&1 || true)
  if [ -n "$diff_out" ]; then
    echo "Fixture tree was modified:" >&2
    echo "$diff_out" >&2
    return 1
  fi
}

# ============================================================================
# Test: Exit code is always 0 when findings are present (or empty)
# ============================================================================

@test "exit code is 0 with mock input and findings" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  # Create a mock ListAgents input
  local agents_input='[
    {"id": "dev-1", "name": "developer", "session_id": "dev-session-123", "status": "running"}
  ]'

  run bash "$COLLECT_LIVENESS" <<< "$agents_input"
  [ "$status" -eq 0 ]

  # "...and findings" has to mean findings. Without this the case passed
  # against a collector that hardcoded an empty findings array, which is
  # exactly how the stubbed collector shipped looking tested.
  [ "$(echo "$output" | jq '.findings | length')" -ge 1 ]
}

@test "exit code is 0 with --no-agents flag" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  run bash "$COLLECT_LIVENESS" --no-agents
  [ "$status" -eq 0 ]
}

@test "exit code is 0 with empty board" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  run bash "$COLLECT_LIVENESS" --no-agents
  [ "$status" -eq 0 ]
}

# ============================================================================
# Test: JSON structure has all 6 required keys
# ============================================================================

@test "output is valid JSON with 6 required top-level keys" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  run bash "$COLLECT_LIVENESS" --no-agents
  [ "$status" -eq 0 ]

  # Verify JSON is valid
  echo "$output" | jq empty

  # Check each required key exists
  echo "$output" | jq -e '.generated_at' > /dev/null
  echo "$output" | jq -e '.session_id' > /dev/null
  echo "$output" | jq -e '.visibility' > /dev/null
  echo "$output" | jq -e '.findings' > /dev/null
  echo "$output" | jq -e '.residue' > /dev/null
  echo "$output" | jq -e '.counts' > /dev/null
}

# ============================================================================
# Test: Static check for no file writes in script
# ============================================================================

@test "script contains no output redirection (>) operators" {
  # Static check: look for shell redirection patterns
  # Look for shell redirection patterns: word> or >word at start of line (with possible indent)
  local redirect_count
  redirect_count=$(grep -E "^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*>" "$COLLECT_LIVENESS" 2>/dev/null | wc -l || echo "0")
  [ "$redirect_count" -eq 0 ]
}

@test "script contains no mv commands" {
  local mv_count
  mv_count=$({ grep -c "^[[:space:]]*mv " "$COLLECT_LIVENESS" 2>/dev/null; } || printf "0")
  mv_count=$(printf "%s" "$mv_count" | tr -d '\n' | xargs)
  [ "$mv_count" -eq 0 ]
}

@test "script contains no tee commands" {
  local tee_count
  tee_count=$({ grep -c "^[[:space:]]*tee " "$COLLECT_LIVENESS" 2>/dev/null; } || printf "0")
  tee_count=$(printf "%s" "$tee_count" | tr -d '\n' | xargs)
  [ "$tee_count" -eq 0 ]
}

# ============================================================================
# Test: Behavioral check for no writes
# ============================================================================

@test "script makes zero modifications to fixture tree" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  # Snapshot fixture before running
  local before
  before=$(snapshot_fixture)

  # Run script with mock input
  local agents_input='[{"id": "dev-1", "name": "developer"}]'
  run bash "$COLLECT_LIVENESS" <<< "$agents_input"

  # Verify fixture is unchanged
  assert_fixture_unchanged "$before"
}

# ============================================================================
# Test: Visibility object structure with ListAgents input
# ============================================================================

@test "visibility object is present with required fields (with ListAgents)" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  local agents_input='[{"id": "dev-1"}]'
  run bash "$COLLECT_LIVENESS" <<< "$agents_input"

  # Check visibility exists
  echo "$output" | jq -e '.visibility' > /dev/null

  # Check all required fields exist
  echo "$output" | jq -e '.visibility.in_session' > /dev/null
  echo "$output" | jq -e '.visibility.cross_session' > /dev/null
  echo "$output" | jq -e '.visibility.agents_input' > /dev/null
  echo "$output" | jq -e '.visibility.notes' > /dev/null

  # Verify notes is an array and not empty
  local notes_len
  notes_len=$(echo "$output" | jq '.visibility.notes | length')
  [ "$notes_len" -gt 0 ]
}

# ============================================================================
# Test: Visibility object structure in --no-agents mode
# ============================================================================

@test "visibility.agents_input is \"absent\" in --no-agents mode" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  run bash "$COLLECT_LIVENESS" --no-agents

  local agents_input_value
  agents_input_value=$(echo "$output" | jq -r '.visibility.agents_input')
  [ "$agents_input_value" = "absent" ]
}

@test "visibility.in_session is false in --no-agents mode" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  run bash "$COLLECT_LIVENESS" --no-agents

  local in_session_value
  in_session_value=$(echo "$output" | jq '.visibility.in_session')
  [ "$in_session_value" = "false" ]
}

@test "visibility.notes mentions harness unavailability in --no-agents mode" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  run bash "$COLLECT_LIVENESS" --no-agents

  local notes
  notes=$(echo "$output" | jq -r '.visibility.notes | join(" ")')

  # Should mention that harness agent list is unavailable
  if ! echo "$notes" | grep -qi "unavailable\|absent\|no-agents"; then
    echo "Notes should mention unavailability: $notes" >&2
    return 1
  fi
}

# ============================================================================
# Test: Empty board scenario
# ============================================================================

@test "empty board produces valid JSON with empty findings array" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  # Ensure no queue items, no rapports, no slot files
  rm -f "$FIXTURE_ROOT/project/queue/scrum_triggers.jsonl"
  rm -f "$FIXTURE_ROOT/project/queue/concurrency-slots-*.json"
  find "$FIXTURE_ROOT/project/rapports" -type f -delete

  run bash "$COLLECT_LIVENESS" --no-agents

  # Verify findings array is empty
  local findings
  findings=$(echo "$output" | jq '.findings')
  [ "$findings" = "[]" ]

  # Visibility should still be populated
  echo "$output" | jq -e '.visibility' > /dev/null
}

# ============================================================================
# Test: Hardcoded thresholds are present in script
# ============================================================================

@test "script contains hardcoded 20-minute warn threshold" {
  grep -q "IDLE_WARN_MINUTES=20" "$COLLECT_LIVENESS"
}

@test "script contains hardcoded 45-minute stall threshold" {
  grep -q "STALL_MINUTES=45" "$COLLECT_LIVENESS"
}

# ============================================================================
# Test: Finding object structure
# ============================================================================

@test "every finding has an escalation object with a boolean break_available (no-agents)" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  # Create a scenario that would produce findings (stale residue)
  echo '{"event": "test", "date": "2026-09-20T10:00:00Z"}' > "$FIXTURE_ROOT/project/queue/scrum_triggers.jsonl"

  run bash "$COLLECT_LIVENESS" --no-agents

  # --no-agents can never report a live dispatcher, so the rung is always off.
  echo "$output" | jq -e '[.findings[] | select(.escalation.break_available != false)] | length == 0' > /dev/null
}

# ============================================================================
# Test: Counts object structure
# ============================================================================

@test "counts object has error, warn, info fields with numeric values" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  run bash "$COLLECT_LIVENESS" --no-agents

  # Check all count fields are present and numeric
  echo "$output" | jq -e '.counts.error | type == "number"' > /dev/null
  echo "$output" | jq -e '.counts.warn | type == "number"' > /dev/null
  echo "$output" | jq -e '.counts.info | type == "number"' > /dev/null
}

# ============================================================================
# Test: Residue object structure
# ============================================================================

@test "residue object contains all required fields" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  run bash "$COLLECT_LIVENESS" --no-agents

  # Check all residue fields exist (oldest_residue_at may be null)
  echo "$output" | jq -e '.residue.undrained_triggers' > /dev/null
  echo "$output" | jq -e '.residue.open_rapports' > /dev/null
  echo "$output" | jq -e '.residue.slot_files_other_sessions' > /dev/null
  echo "$output" | jq -e '.residue.stale_worktrees' > /dev/null
  # oldest_residue_at is allowed to be null
  echo "$output" | jq '.residue | keys' | grep -q "oldest_residue_at"
}

# ============================================================================
# Test: Isolation - no repository tree modifications
# ============================================================================

@test "test never reads from real project directory" {
  # This test verifies that all fixtures use $BATS_TEST_TMPDIR
  # by running with an intentionally invalid JENGA_PROJECT_ROOT

  export JENGA_PROJECT_ROOT="/this/does/not/exist/xyz"

  run bash "$COLLECT_LIVENESS" --no-agents

  # Should still succeed (exit 0) because it uses the nonexistent root gracefully
  [ "$status" -eq 0 ]
}

# ============================================================================
# Test: Generated_at field
# ============================================================================

@test "generated_at is an ISO 8601 timestamp" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  run bash "$COLLECT_LIVENESS" --no-agents

  local generated_at
  generated_at=$(echo "$output" | jq -r '.generated_at')

  # Check format: YYYY-MM-DDTHH:MM:SSZ
  if ! echo "$generated_at" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    echo "Invalid ISO 8601 timestamp: $generated_at" >&2
    return 1
  fi
}

# ============================================================================
# Test: Session_id field
# ============================================================================

@test "session_id is present and non-empty" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"

  run bash "$COLLECT_LIVENESS" --no-agents

  local session_id
  session_id=$(echo "$output" | jq -r '.session_id')

  [ -n "$session_id" ]
  [ "$session_id" != "null" ]
}

@test "session_id respects SESSION_ID environment variable when set" {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"
  export SESSION_ID="test-session-xyz-123"

  run bash "$COLLECT_LIVENESS" --no-agents

  local session_id
  session_id=$(echo "$output" | jq -r '.session_id')
  [ "$session_id" = "test-session-xyz-123" ]
}

# ============================================================================
# FINDING DETECTION — the non-vacuous half of the suite (E44_S05_T02)
#
# Everything above this line asserts the shape of the envelope. None of it
# asserts that a finding is ever produced, so the whole block above stayed
# green against a collector that hardcoded `FINDINGS_ARRAY="[]"` and never
# analysed anything. Two cases above are actively vacuous for that reason:
# "exit code is 0 with mock input and findings" produced none, and "every
# finding has an escalation object" iterated an empty array. The cases below
# exist so that regression cannot reappear silently: each one drives a
# specific finding code out of a fixture built for it.
#
# Time is pinned via JENGA_CHECKIN_NOW_EPOCH so idle and TTL arithmetic is
# deterministic rather than relative to when the suite happens to run.
# 1791374400 == 2026-10-07T12:00:00Z, one hour after the newest event the
# shared setup() fixture writes.
# ============================================================================

FIXED_NOW=1791374400

# Write a stand-in for scripts/check-worktree-liveness.sh with a chosen exit
# code and output, so the exit-4 "cannot determine" path and the exit-1 "live
# processes" path are both reachable without depending on real OS processes or
# on lsof being present.
stub_liveness() {
  local rc="$1"; shift
  local stub="$T/stub-liveness.sh"
  {
    printf '#!/bin/bash\n'
    local line
    for line in "$@"; do
      printf 'echo %q\n' "$line"
    done
    printf 'exit %s\n' "$rc"
  } > "$stub"
  printf '%s' "$stub"
}

# Declare a board item as In Progress. Scope defaults to `task`.
board_item() {
  local id="$1" scope="${2:-task}"
  mkdir -p "$FIXTURE_ROOT/project/board/tasks"
  cat > "$FIXTURE_ROOT/project/board/tasks/${id}_fixture.md" <<EOF
---
id: $id
status: In Progress
execution_scope: $scope
---
EOF
}

# Write a concurrency slot file for a session with one holder acquired at a
# given ISO timestamp. Shape per scripts/acquire-concurrency-slot.sh's header.
slot_file() {
  local session="$1" role="$2" holder="$3" acquired="$4"
  cat > "$FIXTURE_ROOT/project/queue/concurrency-slots-${session}.json" <<EOF
{"$role": {"cap": 3, "holders": {"$holder": "$acquired"}}}
EOF
}

run_collector() {
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT"
  export JENGA_CHECKIN_NOW_EPOCH="$FIXED_NOW"
  run bash "$COLLECT_LIVENESS" "$@"
}

# ---------------------------------------------------------------------------
# F1 — agent running, idle past the stall threshold
# ---------------------------------------------------------------------------

@test "F1: running agent idle past the stall threshold is warn and actionable" {
  # dev-session-123's newest event is 10:30Z; pinned now is 12:00Z => 90 min.
  local agents='[{"name": "E99_S01_T01", "state": "running", "session_id": "dev-session-123"}]'
  run_collector <<< "$agents"
  [ "$status" -eq 0 ]

  local f
  f=$(echo "$output" | jq -c '[.findings[] | select(.code == "F1")]')
  [ "$(echo "$f" | jq 'length')" -eq 1 ]
  [ "$(echo "$f" | jq -r '.[0].severity')" = "warn" ]
  [ "$(echo "$f" | jq -r '.[0].actionable')" = "true" ]
  [ "$(echo "$f" | jq -r '.[0].evidence.idle_minutes')" -eq 90 ]
  [ "$(echo "$f" | jq -r '.[0].escalation.next_rung')" = "taskstop" ]
}

@test "F1: idle between the warn and stall thresholds is info and not actionable" {
  # 11:30Z is 30 minutes before the pinned now: past warn (20), under stall (45).
  cat >> "$FIXTURE_ROOT/project/logs/events.json" <<'EOF'
{"event": "advisory_checkpoint", "session_id": "dev-session-warnonly", "date": "2026-10-07T11:30:00Z"}
EOF
  local agents='[{"name": "E99_S01_T09", "state": "running", "session_id": "dev-session-warnonly"}]'
  run_collector <<< "$agents"
  [ "$status" -eq 0 ]

  local f
  f=$(echo "$output" | jq -c '[.findings[] | select(.code == "F1")]')
  [ "$(echo "$f" | jq 'length')" -eq 1 ]
  [ "$(echo "$f" | jq -r '.[0].severity')" = "info" ]
  [ "$(echo "$f" | jq -r '.[0].actionable')" = "false" ]
  [ "$(echo "$f" | jq -r '.[0].evidence.idle_minutes')" -eq 30 ]
  [ "$(echo "$f" | jq -r '.[0].escalation.next_rung')" = "observe" ]
}

@test "F1: a freshly active running agent produces no finding" {
  cat >> "$FIXTURE_ROOT/project/logs/events.json" <<'EOF'
{"event": "advisory_checkpoint", "session_id": "dev-session-fresh", "date": "2026-10-07T11:55:00Z"}
EOF
  local agents='[{"name": "E99_S01_T10", "state": "running", "session_id": "dev-session-fresh"}]'
  run_collector <<< "$agents"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.code == "F1")] | length')" -eq 0 ]
}

@test "F13: a running agent with no matching dated event is undeterminable, not clear" {
  local agents='[{"name": "E99_S01_T11", "state": "running", "session_id": "no-such-session"}]'
  run_collector <<< "$agents"
  [ "$status" -eq 0 ]

  local f
  f=$(echo "$output" | jq -c '[.findings[] | select(.code == "F13")]')
  [ "$(echo "$f" | jq 'length')" -ge 1 ]
  [ "$(echo "$f" | jq -r '.[0].actionable')" = "false" ]
  [ "$(echo "$f" | jq -r '.[0].severity')" = "warn" ]
}

# ---------------------------------------------------------------------------
# F2 — agent completed, worktree still has live processes
# ---------------------------------------------------------------------------

@test "F2: completed agent with live worktree processes is warn, actionable, with a process count" {
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/E99_S01_T02-slug"
  local stub
  stub=$(stub_liveness 1 "live process rooted in worktree — PID 111: loop" \
                         "live process rooted in worktree — PID 222: loop")
  export JENGA_LIVENESS_SCRIPT="$stub"

  local agents='[{"name": "E99_S01_T02", "state": "completed", "session_id": "dev-session-123"}]'
  run_collector <<< "$agents"
  [ "$status" -eq 0 ]

  local f
  f=$(echo "$output" | jq -c '[.findings[] | select(.code == "F2")]')
  [ "$(echo "$f" | jq 'length')" -eq 1 ]
  [ "$(echo "$f" | jq -r '.[0].severity')" = "warn" ]
  [ "$(echo "$f" | jq -r '.[0].actionable')" = "true" ]
  [ "$(echo "$f" | jq -r '.[0].evidence.worktree_live_processes')" -eq 2 ]
  [ "$(echo "$f" | jq -r '.[0].evidence.worktree')" = "E99_S01_T02-slug" ]
}

@test "F2: completed agent with a clear worktree produces no finding" {
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/E99_S01_T02-slug"
  local stub
  stub=$(stub_liveness 0)
  export JENGA_LIVENESS_SCRIPT="$stub"

  local agents='[{"name": "E99_S01_T02", "state": "completed", "session_id": "dev-session-123"}]'
  run_collector <<< "$agents"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.code == "F2")] | length')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# F3 / F4 — slot holders past TTL
# ---------------------------------------------------------------------------

@test "F3: this session's slot holder past TTL is info and not actionable" {
  slot_file "mysession" "developer" "E99_S01_T05" "2026-10-07T09:00:00Z"
  export SESSION_ID="mysession"
  run_collector --no-agents
  [ "$status" -eq 0 ]

  local f
  f=$(echo "$output" | jq -c '[.findings[] | select(.code == "F3")]')
  [ "$(echo "$f" | jq 'length')" -eq 1 ]
  [ "$(echo "$f" | jq -r '.[0].severity')" = "info" ]
  [ "$(echo "$f" | jq -r '.[0].actionable')" = "false" ]
  [ "$(echo "$f" | jq -r '.[0].evidence.age_minutes')" -eq 180 ]
}

@test "F4: another session's slot holder past TTL always carries actionable: false" {
  slot_file "othersession" "tester" "E98_S01_T01" "2026-10-07T08:00:00Z"
  export SESSION_ID="mysession"
  run_collector --no-agents
  [ "$status" -eq 0 ]

  local f
  f=$(echo "$output" | jq -c '[.findings[] | select(.code == "F4")]')
  [ "$(echo "$f" | jq 'length')" -eq 1 ]
  [ "$(echo "$f" | jq -r '.[0].actionable')" = "false" ]
  # The reason must name why this session may not act, not merely that it won't.
  echo "$f" | jq -e '.[0].evidence.reason | test("never read or write")' > /dev/null
}

@test "F3/F4: a slot holder inside TTL produces no finding" {
  slot_file "mysession" "developer" "E99_S01_T05" "2026-10-07T11:45:00Z"
  export SESSION_ID="mysession"
  run_collector --no-agents
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.code == "F3" or .code == "F4")] | length')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# F5 / F6 — board says In Progress, reality disagrees
# ---------------------------------------------------------------------------

@test "F5: In Progress with a worktree but nothing alive is warn, actionable, owned by j.reconcile" {
  board_item "E99_S01_T05" "task"
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/E99_S01_T05-slug"
  local stub
  stub=$(stub_liveness 0)
  export JENGA_LIVENESS_SCRIPT="$stub"

  run_collector --no-agents
  [ "$status" -eq 0 ]

  local f
  f=$(echo "$output" | jq -c '[.findings[] | select(.code == "F5")]')
  [ "$(echo "$f" | jq 'length')" -eq 1 ]
  [ "$(echo "$f" | jq -r '.[0].severity')" = "warn" ]
  [ "$(echo "$f" | jq -r '.[0].actionable')" = "true" ]
  [ "$(echo "$f" | jq -r '.[0].subject.task_id')" = "E99_S01_T05" ]
  [ "$(echo "$f" | jq -r '.[0].owning_skill')" = "j.reconcile" ]
}

@test "F5: In Progress with a running agent of the same board id produces no finding" {
  board_item "E99_S01_T05" "task"
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/E99_S01_T05-slug"
  local stub
  stub=$(stub_liveness 0)
  export JENGA_LIVENESS_SCRIPT="$stub"

  cat >> "$FIXTURE_ROOT/project/logs/events.json" <<'EOF'
{"event": "advisory_checkpoint", "session_id": "dev-session-fresh", "date": "2026-10-07T11:55:00Z"}
EOF
  local agents='[{"name": "E99_S01_T05", "state": "running", "session_id": "dev-session-fresh"}]'
  run_collector <<< "$agents"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.code == "F5")] | length')" -eq 0 ]
}

@test "F6: In Progress at task scope with no worktree is warn, actionable, owned by j.reconcile" {
  board_item "E99_S01_T06" "task"
  run_collector --no-agents
  [ "$status" -eq 0 ]

  local f
  f=$(echo "$output" | jq -c '[.findings[] | select(.code == "F6")]')
  [ "$(echo "$f" | jq 'length')" -eq 1 ]
  [ "$(echo "$f" | jq -r '.[0].severity')" = "warn" ]
  [ "$(echo "$f" | jq -r '.[0].actionable')" = "true" ]
  [ "$(echo "$f" | jq -r '.[0].subject.task_id')" = "E99_S01_T06" ]
  [ "$(echo "$f" | jq -r '.[0].owning_skill')" = "j.reconcile" ]
}

@test "F6: light and inline scopes are exempt, because j.do never gives them a worktree" {
  board_item "E99_S01_T07" "light"
  board_item "E99_S01_T08" "inline"
  run_collector --no-agents
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.code == "F6")] | length')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# F13 and the exit-4 degradation — a blind run must never read as a clean one
# ---------------------------------------------------------------------------

@test "exit 4 from check-worktree-liveness.sh degrades cross_session to none and emits F13" {
  board_item "E99_S01_T05" "task"
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/E99_S01_T05-slug"
  local stub
  stub=$(stub_liveness 4)
  export JENGA_LIVENESS_SCRIPT="$stub"

  run_collector --no-agents
  [ "$status" -eq 0 ]

  [ "$(echo "$output" | jq -r '.visibility.cross_session')" = "none" ]

  local f
  f=$(echo "$output" | jq -c '[.findings[] | select(.code == "F13")]')
  [ "$(echo "$f" | jq 'length')" -ge 1 ]
  [ "$(echo "$f" | jq -r '.[0].severity')" = "warn" ]
  [ "$(echo "$f" | jq -r '.[0].actionable')" = "false" ]
  # It must say it does not know, and say so in the finding itself.
  echo "$f" | jq -e '.[0].evidence.reason | test("NOT the same as clear")' > /dev/null
}

@test "exit 4 suppresses F5 for the same item, so a blind probe is never reported as dead" {
  board_item "E99_S01_T05" "task"
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/E99_S01_T05-slug"
  local stub
  stub=$(stub_liveness 4)
  export JENGA_LIVENESS_SCRIPT="$stub"

  run_collector --no-agents
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.code == "F5")] | length')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Contract invariants, asserted against findings that actually exist
# ---------------------------------------------------------------------------

@test "every finding carries a boolean break_available and a valid next_rung (non-vacuous)" {
  board_item "E99_S01_T06" "task"
  slot_file "othersession" "tester" "E98_S01_T01" "2026-10-07T08:00:00Z"
  export SESSION_ID="mysession"
  local agents='[{"name": "E99_S01_T01", "state": "running", "session_id": "dev-session-123"}]'
  run_collector <<< "$agents"
  [ "$status" -eq 0 ]

  # Guard against this assertion going vacuous again.
  local count
  count=$(echo "$output" | jq '.findings | length')
  [ "$count" -ge 3 ]

  [ "$(echo "$output" | jq '[.findings[] | select(.escalation.break_available | type != "boolean")] | length')" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.escalation | has("break_issued_at") and has("grace_minutes") | not)] | length')" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.escalation.next_rung != "observe" and .escalation.next_rung != "taskstop")] | length')" -eq 0 ]
  # break_reason is present exactly when break_available is true.
  [ "$(echo "$output" | jq '[.findings[] | select((.escalation.break_available) != (.escalation | has("break_reason")))] | length')" -eq 0 ]
}

@test "every finding carries actionable as a boolean distinct from severity (non-vacuous)" {
  board_item "E99_S01_T06" "task"
  slot_file "othersession" "tester" "E98_S01_T01" "2026-10-07T08:00:00Z"
  export SESSION_ID="mysession"
  local agents='[{"name": "E99_S01_T01", "state": "running", "session_id": "dev-session-123"}]'
  run_collector <<< "$agents"
  [ "$status" -eq 0 ]

  [ "$(echo "$output" | jq '.findings | length')" -ge 3 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.actionable | type != "boolean")] | length')" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.severity != "error" and .severity != "warn" and .severity != "info")] | length')" -eq 0 ]
  # severity and actionable must not be redundant: this fixture has a warn
  # that is actionable and an info that is not.
  [ "$(echo "$output" | jq '[.findings[] | select(.severity == "warn" and .actionable == true)] | length')" -ge 1 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.severity == "info" and .actionable == false)] | length')" -ge 1 ]
}

@test "counts match the findings array it reports" {
  board_item "E99_S01_T06" "task"
  slot_file "othersession" "tester" "E98_S01_T01" "2026-10-07T08:00:00Z"
  export SESSION_ID="mysession"
  local agents='[{"name": "E99_S01_T01", "state": "running", "session_id": "dev-session-123"}]'
  run_collector <<< "$agents"
  [ "$status" -eq 0 ]

  # Guard against 0 == 0 passing for the wrong reason.
  [ "$(echo "$output" | jq '.findings | length')" -ge 3 ]

  echo "$output" | jq -e '
    (.counts.error == ([.findings[] | select(.severity == "error")] | length))
    and (.counts.warn == ([.findings[] | select(.severity == "warn")] | length))
    and (.counts.info == ([.findings[] | select(.severity == "info")] | length))
  ' > /dev/null
}

@test "every one of the seven finding codes is reachable from a fixture" {
  # One run cannot produce all seven, but the suite as a whole must prove each
  # is implemented. This case asserts the union across the fixtures above by
  # re-driving each code and collecting which ones appeared.
  local seen=""

  # F1 + F13 (running, stale session and unknown session)
  cat >> "$FIXTURE_ROOT/project/logs/events.json" <<'EOF'
{"event": "advisory_checkpoint", "session_id": "dev-session-123", "date": "2026-10-07T10:30:00Z"}
EOF
  local agents='[{"name": "E99_S01_T01", "state": "running", "session_id": "dev-session-123"},
                 {"name": "E99_S01_T11", "state": "running", "session_id": "no-such-session"}]'
  run_collector <<< "$agents"
  seen="$seen $(echo "$output" | jq -r '.findings[].code' | sort -u | tr '\n' ' ')"

  # F2
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/E99_S01_T02-slug"
  export JENGA_LIVENESS_SCRIPT="$(stub_liveness 1 'PID 111')"
  run_collector <<< '[{"name": "E99_S01_T02", "state": "completed", "session_id": "dev-session-123"}]'
  seen="$seen $(echo "$output" | jq -r '.findings[].code' | sort -u | tr '\n' ' ')"

  # F3 + F4
  slot_file "mysession" "developer" "E99_S01_T05" "2026-10-07T09:00:00Z"
  slot_file "othersession" "tester" "E98_S01_T01" "2026-10-07T08:00:00Z"
  export SESSION_ID="mysession"
  run_collector --no-agents
  seen="$seen $(echo "$output" | jq -r '.findings[].code' | sort -u | tr '\n' ' ')"

  # F5 + F6
  board_item "E99_S01_T05" "task"
  board_item "E99_S01_T06" "task"
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/E99_S01_T05-slug"
  export JENGA_LIVENESS_SCRIPT="$(stub_liveness 0)"
  run_collector --no-agents
  seen="$seen $(echo "$output" | jq -r '.findings[].code' | sort -u | tr '\n' ' ')"

  local code
  for code in F1 F2 F3 F4 F5 F6 F13; do
    if ! echo " $seen " | grep -q " $code "; then
      echo "finding code $code was never produced by any fixture; seen: $seen" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Zero writes, re-asserted on a run that actually produces findings
# ---------------------------------------------------------------------------

@test "a run that produces findings still writes nothing to the fixture tree" {
  board_item "E99_S01_T06" "task"
  slot_file "othersession" "tester" "E98_S01_T01" "2026-10-07T08:00:00Z"
  export SESSION_ID="mysession"

  local before
  before=$(snapshot_fixture)

  local agents='[{"name": "E99_S01_T01", "state": "running", "session_id": "dev-session-123"}]'
  run_collector <<< "$agents"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.findings | length')" -ge 2 ]

  assert_fixture_unchanged "$before"
}

@test "the real repository's events.json yields derivable idle times, not a silent empty parse" {
  # Regression guard for the defect that made F1 unreachable in practice. The
  # committed project/logs/events.json is an unterminated JSON array with a
  # missing comma, so a strict `jq -s` parse fails on it outright and the old
  # `|| echo "[]"` fallback degraded to "no activity data". Nothing in the
  # envelope tests notices that: the report still renders, still validates,
  # and still reads clean — it just can never derive an idle time for anyone,
  # so every running agent collapses to F13 and no F1 is ever possible.
  #
  # Asserting "the note is absent" is not enough, because the old collector
  # did not emit a note either. So assert the capability directly: feed every
  # session id the real log mentions and require that at least one resolves to
  # a numeric idle time.
  #
  # This case reads the real tree deliberately. The zero-writes guarantee
  # asserted above, statically and behaviourally, is what makes that safe.
  local real_events="$REPO_ROOT/project/logs/events.json"
  [ -f "$real_events" ] || skip "no real events.json in this checkout"

  local agents
  agents=$(grep -o '"session_id": *"[^"]*"' "$real_events" \
    | sed 's/.*"session_id": *"//; s/"$//' \
    | sort -u | head -40 \
    | jq -R -s 'split("\n") | map(select(length > 0))
                | to_entries
                | map({name: ("probe-" + (.key | tostring)), state: "running", session_id: .value})')

  [ "$(echo "$agents" | jq 'length')" -gt 0 ]

  run env JENGA_PROJECT_ROOT="$REPO_ROOT" bash "$COLLECT_LIVENESS" <<< "$agents"
  [ "$status" -eq 0 ]
  echo "$output" | jq empty

  local resolved
  resolved=$(echo "$output" | jq '[.findings[] | select(.code == "F1" and (.evidence.idle_minutes | type == "number"))] | length')
  if [ "$resolved" -lt 1 ]; then
    echo "No session id from the real events.json resolved to an idle time." >&2
    echo "The tolerant parse has regressed to a silent empty result." >&2
    echo "notes: $(echo "$output" | jq -c '.visibility.notes')" >&2
    echo "codes: $(echo "$output" | jq -c '[.findings[].code] | unique')" >&2
    return 1
  fi
}

# ============================================================================
# Story and bundle scoping for F5/F6
#
# Added after a live run against this repository produced 8 F6 findings, all
# 8 of them stories, and all 8 false. A story is "In Progress" because its
# tasks are; it never gets a worktree of its own unless j.do is running it as
# a bundle. Symmetrically, a task INSIDE a bundle has no worktree of its own
# either — the bundle shares the story's. Both directions are regressions
# waiting to happen, so both are pinned here.
# ============================================================================

board_story() {
  local id="$1"
  mkdir -p "$FIXTURE_ROOT/project/board/stories"
  cat > "$FIXTURE_ROOT/project/board/stories/${id}_fixture.md" <<EOF
---
id: $id
status: In Progress
---
EOF
}

@test "F6: an In Progress story with no bundle manifest is not flagged" {
  board_story "E99_S02"
  run_collector --no-agents
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.subject.task_id == "E99_S02")] | length')" -eq 0 ]
}

@test "F6: an In Progress story IS flagged once it is running as a bundle" {
  board_story "E99_S02"
  echo '{"story_id": "E99_S02"}' > "$FIXTURE_ROOT/project/queue/bundle-E99_S02.json"
  run_collector --no-agents
  [ "$status" -eq 0 ]

  local f
  f=$(echo "$output" | jq -c '[.findings[] | select(.code == "F6" and .subject.task_id == "E99_S02")]')
  [ "$(echo "$f" | jq 'length')" -eq 1 ]
  [ "$(echo "$f" | jq -r '.[0].actionable')" = "true" ]
}

@test "F5: a bundled story with its bundle worktree alive is not flagged F6" {
  board_story "E99_S02"
  echo '{"story_id": "E99_S02"}' > "$FIXTURE_ROOT/project/queue/bundle-E99_S02.json"
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/bundle-E99_S02"
  export JENGA_LIVENESS_SCRIPT="$(stub_liveness 1 'PID 111')"

  run_collector --no-agents
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.code == "F6")] | length')" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.code == "F5")] | length')" -eq 0 ]
}

@test "F6: a task inside a bundle resolves to the bundle worktree, not worktree-less" {
  board_item "E99_S02_T01" "task"
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/bundle-E99_S02"
  export JENGA_LIVENESS_SCRIPT="$(stub_liveness 1 'PID 111')"

  run_collector --no-agents
  [ "$status" -eq 0 ]
  # Not F6 (it has a worktree) and not F5 (something is alive in it).
  [ "$(echo "$output" | jq '[.findings[] | select(.subject.task_id == "E99_S02_T01")] | length')" -eq 0 ]
}

@test "F6: a task with neither its own nor a bundle worktree is still flagged" {
  board_item "E99_S03_T01" "task"
  run_collector --no-agents
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.code == "F6" and .subject.task_id == "E99_S03_T01")] | length')" -eq 1 ]
}

# ============================================================================
# E44_S10 — escalation.break_available is computed, not hard-coded
#
# Every case runs in $FIXTURE_ROOT with a stub check-break.sh. The repository's
# real queue, board and events.json are never read or written.
# ============================================================================

# pinned now is 12:00Z. 11:30Z => idle 30 (past warn 20, under stall 45).
# 10:30Z (the setup() default for dev-session-123) => idle 90 (stalled).
brk_setup() {
  mkdir -p "$FIXTURE_ROOT/project/configs" "$FIXTURE_ROOT/project/board/tasks"
  echo '{"bundle_lock_ttl_minutes": 30}' > "$FIXTURE_ROOT/project/configs/scope-thresholds.json"
  cat >> "$FIXTURE_ROOT/project/logs/events.json" <<'EOF'
{"event": "advisory_checkpoint", "session_id": "brk-healthy", "date": "2026-10-07T11:30:00Z"}
EOF
  printf '#!/bin/bash\nexit 0\n' > "$T/break-ok.sh"
  printf '#!/bin/bash\nexit 10\n' > "$T/break-pending.sh"
  printf '#!/bin/bash\nexit 3\n' > "$T/break-broken.sh"
  export JENGA_CHECKIN_BREAK_SCRIPT="$T/break-ok.sh"
  # live bundle (started 11:50Z, ttl 30) with one unfinished task
  echo '{"story_id": "E99_S01", "started_at": "2026-10-07T11:50:00Z", "tasks": ["E99_S01_T01"]}' \
    > "$FIXTURE_ROOT/project/queue/bundle-E99_S01.json"
  printf -- '---\nid: E99_S01_T01\nstatus: In Progress\n---\n' > "$FIXTURE_ROOT/project/board/tasks/E99_S01_T01_x.md"
}

brk_agents_healthy='[{"name": "E99_S01", "state": "running", "session_id": "brk-healthy"}]'

brk_flag() {
  # echo the break_available of the (single) F1 finding
  echo "$output" | jq -r '[.findings[] | select(.code == "F1")][0].escalation.break_available'
}

@test "break_available: eligible healthy bundle agent with queued work -> true with a reason" {
  brk_setup
  run_collector <<< "$brk_agents_healthy"
  [ "$status" -eq 0 ]
  [ "$(brk_flag)" = "true" ]
  [ -n "$(echo "$output" | jq -r '[.findings[] | select(.code == "F1")][0].escalation.break_reason')" ]
  [ "$(echo "$output" | jq -r '[.findings[] | select(.code == "F1")][0].escalation.break_reason')" != "null" ]
}

@test "break_available: eligible via a live epic lock and a live todo.md entry -> true" {
  brk_setup
  rm "$FIXTURE_ROOT/project/queue/bundle-E99_S01.json"
  echo '{"epic_id": "E99", "bundle_story_id": "E99_S01", "started_at": "2026-10-07T11:50:00Z"}' \
    > "$FIXTURE_ROOT/project/queue/epic-lock-E99.json"
  printf -- '---\nid: E99_S02_T01\nstatus: Pending\n---\n' > "$FIXTURE_ROOT/project/board/tasks/E99_S02_T01_x.md"
  printf '# Todo\n\nNext thing: E99_S02_T01\n' > "$FIXTURE_ROOT/project/todo.md"
  run_collector <<< "$brk_agents_healthy"
  [ "$(brk_flag)" = "true" ]
}

@test "break_available: a stalled agent -> false, even with queued work" {
  brk_setup
  local agents='[{"name": "E99_S01", "state": "running", "session_id": "dev-session-123"}]'
  run_collector <<< "$agents"
  [ "$(echo "$output" | jq -r '[.findings[] | select(.code == "F1")][0].severity')" = "warn" ]
  [ "$(brk_flag)" = "false" ]
  [ "$(echo "$output" | jq '[.findings[] | select(.escalation | has("break_reason"))] | length')" -eq 0 ]
}

@test "break_available: no queued work -> false" {
  brk_setup
  printf -- '---\nid: E99_S01_T01\nstatus: Passed\n---\n' > "$FIXTURE_ROOT/project/board/tasks/E99_S01_T01_x.md"
  run_collector <<< "$brk_agents_healthy"
  [ "$(echo "$output" | jq '[.findings[] | select(.code == "F1")] | length')" -eq 1 ]
  [ "$(brk_flag)" = "false" ]
}

@test "break_available: no live manifest or lock -> false" {
  brk_setup
  echo '{"story_id": "E99_S01", "started_at": "2026-10-07T08:00:00Z", "tasks": ["E99_S01_T01"]}' \
    > "$FIXTURE_ROOT/project/queue/bundle-E99_S01.json"
  run_collector <<< "$brk_agents_healthy"
  [ "$(brk_flag)" = "false" ]
}

@test "break_available: a pending break (--peek exit 10) -> false" {
  brk_setup
  export JENGA_CHECKIN_BREAK_SCRIPT="$T/break-pending.sh"
  run_collector <<< "$brk_agents_healthy"
  [ "$(brk_flag)" = "false" ]
}

@test "break_available: check-break.sh absent -> false" {
  brk_setup
  export JENGA_CHECKIN_BREAK_SCRIPT="$T/does-not-exist.sh"
  run_collector <<< "$brk_agents_healthy"
  [ "$(echo "$output" | jq '[.findings[] | select(.code == "F1")] | length')" -eq 1 ]
  [ "$(brk_flag)" = "false" ]
}

@test "break_available: an unreadable input fails closed to false and is disclosed" {
  brk_setup
  rm "$FIXTURE_ROOT/project/configs/scope-thresholds.json"
  run_collector <<< "$brk_agents_healthy"
  [ "$(brk_flag)" = "false" ]
  echo "$output" | jq -e '.visibility.notes | map(select(test("/break"))) | length >= 1' > /dev/null
}

@test "break_available: check-break.sh --peek erroring fails closed to false and is disclosed" {
  brk_setup
  export JENGA_CHECKIN_BREAK_SCRIPT="$T/break-broken.sh"
  run_collector <<< "$brk_agents_healthy"
  [ "$(brk_flag)" = "false" ]
  echo "$output" | jq -e '.visibility.notes | map(select(test("check-break"))) | length >= 1' > /dev/null
}

@test "break_available: --no-agents -> false for every finding" {
  brk_setup
  run_collector --no-agents
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings[] | select(.escalation.break_available != false)] | length')" -eq 0 ]
}

@test "break_available: F2, F3, F5 and F13 findings -> false even when an eligible bundle exists" {
  brk_setup
  board_item "E99_S01_T06" "task"
  slot_file "mysession" "tester" "E98_S01_T01" "2026-10-07T08:00:00Z"
  slot_file "othersession" "tester" "E98_S01_T02" "2026-10-07T08:00:00Z"
  export SESSION_ID="mysession"
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/E99_S01_T06-slug"
  export JENGA_LIVENESS_SCRIPT="$(stub_liveness 1 "1234 sleep")"
  local agents='[{"name": "E99_S01", "state": "running", "session_id": "brk-healthy"},
                 {"name": "E99_S01_T06", "state": "completed", "session_id": "x"},
                 {"name": "E99_S09_T01", "state": "running", "session_id": "no-such-session"}]'
  run_collector <<< "$agents"
  [ "$status" -eq 0 ]
  # the eligible F1 is still true, proving the others are false on their own merits
  [ "$(brk_flag)" = "true" ]
  local code
  for code in F2 F3 F4 F13; do
    [ "$(echo "$output" | jq --arg c "$code" '[.findings[] | select(.code == $c)] | length')" -ge 1 ] || { echo "no $code finding produced" >&2; return 1; }
    [ "$(echo "$output" | jq --arg c "$code" '[.findings[] | select(.code == $c and .escalation.break_available != false)] | length')" -eq 0 ]
  done
}

@test "break_available: F5 and F6 findings -> false" {
  brk_setup
  board_item "E99_S05_T01" "task"
  board_item "E99_S06_T01" "task"
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/E99_S05_T01-slug"
  export JENGA_LIVENESS_SCRIPT="$(stub_liveness 0)"
  run_collector <<< "$brk_agents_healthy"
  for code in F5 F6; do
    [ "$(echo "$output" | jq --arg c "$code" '[.findings[] | select(.code == $c)] | length')" -ge 1 ] || { echo "no $code finding produced" >&2; return 1; }
    [ "$(echo "$output" | jq --arg c "$code" '[.findings[] | select(.code == $c and .escalation.break_available != false)] | length')" -eq 0 ]
  done
}

@test "break_available: eligibility is evaluated read-only (fixture unchanged)" {
  brk_setup
  local before
  before=$(snapshot_fixture)
  run_collector <<< "$brk_agents_healthy"
  assert_fixture_unchanged "$before"
}

@test "anti-vacuity: an always-false collector stub fails the eligible case" {
  brk_setup
  local stub="$T/collector-always-false.sh"
  {
    printf '#!/bin/bash\n'
    printf 'bash %q "$@" | jq -c %q\n' "$COLLECT_LIVENESS" '.findings |= map(.escalation.break_available = false | del(.escalation.break_reason))'
  } > "$stub"
  export JENGA_PROJECT_ROOT="$FIXTURE_ROOT" JENGA_CHECKIN_NOW_EPOCH="$FIXED_NOW"
  run bash "$stub" <<< "$brk_agents_healthy"
  [ "$(echo "$output" | jq -r '[.findings[] | select(.code == "F1")][0].escalation.break_available')" = "false" ]
  # i.e. the eligible-case assertion (== true) would fail against this stub
}

@test "static: the collector never reads the break flag file directly" {
  ! grep -n "break_request" "$COLLECT_LIVENESS"
  grep -q -- "--peek" "$COLLECT_LIVENESS"
}

@test "static: SKILL.md section 6 names all three rungs" {
  local sec
  sec=$(sed -n '/^## 6\. The escalation ladder/,/^## 7\./p' "$REPO_ROOT/skills/j-check-in/SKILL.md")
  echo "$sec" | grep -qi "observe"
  echo "$sec" | grep -q '`/break`'
  echo "$sec" | grep -q '`TaskStop`'
  echo "$sec" | grep -qi "different subjects"
  echo "$sec" | grep -qi "three rungs"
}

@test "static: no sentence in skills/j-check-in presents /break as a way to stop or unwedge an agent" {
  # Any line that mentions /break together with stop/unwedge/kill/terminate of an
  # agent must also negate it (not / cannot / never / does not / nor / no ).
  local offenders
  offenders=$(grep -rniE '/break' "$REPO_ROOT/skills/j-check-in" \
    | grep -iE '\b(unwedge|kill|terminate)\b|stop (this|the|a|that) agent' \
    | grep -viE "\b(not|cannot|never|nor|no|rather than|without)\b|n't" || true)
  [ -z "$offenders" ]
}
