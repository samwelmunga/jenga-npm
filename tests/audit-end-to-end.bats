#!/usr/bin/env bats
#
# End-to-end proof that dependency audits never run silently (E85_S01_T13, the story's Definition of Done).
#
# The unit files cover each script alone (audit-deps.bats, audit-record.bats, audit-status.bats,
# preflight-audit-items.bats). This file drives the whole chain in one temp project root and asserts the
# cross-script contract:
#
#   refused run      mode ask with no consent flag: audit-deps.sh exits 4, prints nothing on stdout, makes no npm
#                    call, and writes no event and no rapport.
#   approved run     audit-record.sh consent -> audit-deps.sh --approved --json -> audit-record.sh result leaves an
#                    audit_consent event followed by an audit_result event, in that order, and (findings only) a
#                    security_concern rapport. audit-status.sh then reports that very result.
#   checklist        `checklist.sh check pre-release` reports the dependency-audit-before-release item consistently
#                    with the same configured state (mode ask -> unsatisfied exit 4; mode on -> follows the audit).
#   --ci             works under mode ask. audit-deps.sh takes --ci as a plain flag; deriving it from a real CI
#                    signal (CI=true, GITHUB_ACTIONS=true) is skills/j-publish/scripts/run_gates.sh's job (E85_S01_T14)
#                    and is covered by tests/publish-audit-gate.bats, so a CI environment variable alone must NOT
#                    grant consent to audit-deps.sh itself (asserted below).
#
# Isolation. Everything runs under JENGA_PROJECT_ROOT=$PROJ in BATS_TEST_TMPDIR with a stub npm first on PATH that
# prints a canned `npm audit --json` document and records every call. No network, and this repository's own
# audit-config.json, event log, rapports and checklist tick store are never read or written (the real checklist
# registry is only read, by path).

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
AUDIT="$REPO_ROOT/scripts/audit-deps.sh"
RECORD="$REPO_ROOT/scripts/audit-record.sh"
STATUS="$REPO_ROOT/scripts/audit-status.sh"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
INSTANCE="$REPO_ROOT/project/configs/checklists.json"
RELEASE_ID="dependency-audit-before-release"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  PKG="$T/pkg"
  BIN="$T/bin"
  NPM_CALLS="$T/npm-calls.log"
  mkdir -p "$PROJ/project/configs" "$PKG" "$BIN"

  cp "$REPO_ROOT/project/configs/workflow.json" "$PROJ/project/configs/workflow.json"
  cat > "$PROJ/project/configs/scope-thresholds.json" <<'EOF'
{
  "marker_ttl_minutes": 60
}
EOF
  EVENTS="$PROJ/project/logs/events.json"
  RAPPORTS="$PROJ/project/rapports/problems"

  # The audited package: used both as the throwaway package dir ($PKG) and, for the checklist case, the project root.
  printf '{"name":"audit-e2e","version":"1.0.0"}\n' > "$PKG/package.json"
  printf '{"name":"audit-e2e","lockfileVersion":3,"packages":{}}\n' > "$PKG/package-lock.json"
  cp "$PKG/package.json" "$PKG/package-lock.json" "$PROJ/"
  ln -s "$REPO_ROOT/scripts" "$PROJ/scripts"

  cat > "$BIN/npm" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NPM_CALLS"
cat "$T/npm-audit.json"
exit 0
EOF
  chmod +x "$BIN/npm"
  export PATH="$BIN:$PATH"
  clean_audit
  write_config ask

  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$T/no-default-checklists.json"
  export JENGA_CHECKLISTS_FILE="$INSTANCE"
  export JENGA_CHECKLIST_STATE_DIR="$T/state"
  export JENGA_CHECKLIST_VERIFY_TIMEOUT=30
  export CLAUDE_CODE_SESSION_ID="sess-audit-e2e"
  unset JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID JENGA_CHECKLIST_MARKER_DIR JENGA_CHECKLIST_MARKER_TTL_MINUTES
  unset JENGA_SCOPE_THRESHOLDS_FILE JENGA_CHECKLIST_NOW JENGA_PREFLIGHT_HOOK_SCRIPT_DIR JENGA_PREFLIGHT_HOOK_DEBUG
  unset JENGA_CHECKLIST_RUN_ID JENGA_CHECKLIST_ACTOR JENGA_CHECKLIST_RUN_TTL_MINUTES CI GITHUB_ACTIONS
}

write_config() { # <mode>
  printf '{"config_version":1,"mode":"%s","severity_threshold":"high","offline_behavior":"warn","production_only":false}\n' \
    "$1" > "$PROJ/project/configs/audit-config.json"
}

clean_audit() {
  echo '{"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}},"vulnerabilities":{}}' \
    > "$T/npm-audit.json"
}

high_audit() {
  echo '{"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":1,"critical":0,"total":1}},"vulnerabilities":{"leftpad":{"name":"leftpad","severity":"high","fixAvailable":true,"range":"<2.0.0"}}}' \
    > "$T/npm-audit.json"
}

# Run the audit; stdout (JSON) goes to $T/audit.json, stderr to $stderr.
audit() { run --separate-stderr bash -c 'bash "$1" "${@:3}" > "$2"' _ "$AUDIT" "$T/audit.json" "$@"; }

# field <id> <key>: one field of one item in the last `checklist.sh check` report.
field() { printf '%s' "$output" | jq -r --arg id "$1" --arg k "$2" '.[] | select(.id == $id) | .[$k]'; }

# Assert that no audit left any trace: no event log, no rapport directory content, no npm call.
assert_no_trace() {
  [ ! -s "$EVENTS" ] || { echo "event log is not empty: $(cat "$EVENTS")" >&2; return 1; }
  [ -z "$(ls -A "$RAPPORTS" 2>/dev/null)" ] || { echo "rapports written: $(ls "$RAPPORTS")" >&2; return 1; }
  [ ! -e "$NPM_CALLS" ] || { echo "npm was called: $(cat "$NPM_CALLS")" >&2; return 1; }
}

# =============================================================================
# 1. A refused run leaves no trace
# =============================================================================

@test "mode ask with no consent flag: exit 4, empty stdout, no npm call, no event, no rapport" {
  audit --dir "$PKG" --json
  [ "$status" -eq 4 ]
  [ ! -s "$T/audit.json" ]
  case "$stderr" in *"need consent"*) ;; *) echo "stderr: $stderr" >&2; return 1 ;; esac
  assert_no_trace
}

@test "mode off is refused even with --approved and --ci: exit 4, no trace" {
  write_config off
  audit --dir "$PKG" --json --approved --ci
  [ "$status" -eq 4 ]
  [ ! -s "$T/audit.json" ]
  assert_no_trace
}

@test "a CI environment variable alone does not grant consent to audit-deps.sh (only the --ci flag does)" {
  CI=true GITHUB_ACTIONS=true audit --dir "$PKG" --json
  [ "$status" -eq 4 ]
  assert_no_trace
}

# =============================================================================
# 2. consent -> audit -> result leaves ordered events (and a rapport for findings)
# =============================================================================

@test "approved clean run: audit_consent then audit_result in that order, no rapport, and audit-status reports it" {
  run bash "$RECORD" consent --dir "$PKG" --session-id S-e2e --agent tester
  [ "$status" -eq 0 ]
  audit --dir "$PKG" --json --approved
  [ "$status" -eq 0 ]
  run bash "$RECORD" result --file "$T/audit.json" --session-id S-e2e --agent tester
  [ "$status" -eq 0 ]

  [ "$(wc -l < "$EVENTS" | tr -d ' ')" = 2 ]
  [ "$(jq -r '.event' "$EVENTS" | paste -sd, -)" = "audit_consent,audit_result" ]
  jq -e --arg d "$(cd "$PKG" && pwd)" 'select(.event == "audit_result")
    | .status == "clean" and .consent_basis == "session-approval" and .rapport == null and .scanned_dir == $d
      and .counts.total == 0 and .session_id == "S-e2e"' "$EVENTS" | grep -qx true
  [ -z "$(ls -A "$RAPPORTS" 2>/dev/null)" ]
  [ "$(wc -l < "$NPM_CALLS" | tr -d ' ')" = 1 ]

  run bash "$STATUS"
  [ "$status" -eq 0 ]
  case "$output" in *"Dependency audit: $(cd "$PKG" && pwd) - clean (threshold high; total 0"*) ;; *) echo "status: $output" >&2; return 1 ;; esac
}

@test "approved findings run: consent then result events, one security_concern rapport, and audit-status names it" {
  high_audit
  run bash "$RECORD" consent --dir "$PKG" --session-id S-e2e --agent tester
  [ "$status" -eq 0 ]
  audit --dir "$PKG" --json --approved
  [ "$status" -eq 1 ]
  [ "$(jq -r '.status' "$T/audit.json")" = findings ]
  run bash "$RECORD" result --file "$T/audit.json" --session-id S-e2e --agent tester
  [ "$status" -eq 0 ]

  [ "$(jq -r '.event' "$EVENTS" | paste -sd, -)" = "audit_consent,audit_result" ]
  rapport="$(jq -r 'select(.event == "audit_result") | .rapport' "$EVENTS")"
  [ -n "$rapport" ] && [ "$rapport" != null ] && [ -f "$rapport" ]
  [ "$(ls "$RAPPORTS" | wc -l | tr -d ' ')" = 1 ]
  case "$rapport" in "$RAPPORTS"/audit-*.md) ;; *) echo "rapport path: $rapport" >&2; return 1 ;; esac
  grep -q '^\*\*Type:\*\* `security_concern`' "$rapport"
  grep -q 'leftpad' "$rapport"
  [ "$(jq -r 'select(.event == "audit_result") | .status' "$EVENTS")" = findings ]

  run bash "$STATUS"
  [ "$status" -eq 0 ]
  case "$output" in *"findings (threshold high; total 1: low 0, moderate 0, high 1, critical 0)"*) ;; *) echo "status: $output" >&2; return 1 ;; esac
  case "$output" in *"rapport: $rapport"*) ;; *) echo "status: $output" >&2; return 1 ;; esac
}

@test "audit-status with nothing recorded says so and points at opt-in (mode ask)" {
  run bash "$STATUS"
  [ "$status" -eq 0 ]
  case "$output" in *"Dependency audit: no audit recorded"*"opt-in (mode: ask)"*) ;; *) echo "status: $output" >&2; return 1 ;; esac
  assert_no_trace
}

# =============================================================================
# 3. --ci works under mode ask
# =============================================================================

@test "--ci under mode ask runs the audit with consent_basis ci-workflow, and the result records without an audit_consent event" {
  audit --dir "$PKG" --json --ci
  [ "$status" -eq 0 ]
  [ "$(jq -r '.consent_basis' "$T/audit.json")" = ci-workflow ]
  [ "$(wc -l < "$NPM_CALLS" | tr -d ' ')" = 1 ]
  run bash "$RECORD" result --file "$T/audit.json" --agent ci
  [ "$status" -eq 0 ]
  [ "$(jq -r '.event' "$EVENTS" | paste -sd, -)" = "audit_result" ]
  [ "$(jq -r '.consent_basis' "$EVENTS")" = ci-workflow ]
}

@test "--ci under mode ask with findings exits 1 and the recorded result carries the rapport" {
  high_audit
  audit --dir "$PKG" --json --ci
  [ "$status" -eq 1 ]
  run bash "$RECORD" result --file "$T/audit.json" --agent ci
  [ "$status" -eq 0 ]
  [ "$(ls "$RAPPORTS" | wc -l | tr -d ' ')" = 1 ]
}

# =============================================================================
# 4. The pre-release checklist item agrees with the same state
# =============================================================================

@test "pre-release check, mode ask: item unsatisfied (exit 4, no consent), no npm call, no event, no rapport" {
  run --separate-stderr bash "$CHECKLIST" check pre-release --run r-e2e-ask
  [ "$status" -eq 11 ] || { echo "exit $status, stderr: $stderr" >&2; return 1; }
  [ "$(field "$RELEASE_ID" result)" = failed ]
  [ "$(field "$RELEASE_ID" exit_status)" = 4 ]
  case "$(field "$RELEASE_ID" reason)" in *"audit not run: no consent"*) ;; *) echo "reason: $(field "$RELEASE_ID" reason)" >&2; return 1 ;; esac
  assert_no_trace
  # The direct call agrees with the checklist: same state, same refusal.
  audit --dir "$PROJ" --json
  [ "$status" -eq 4 ]
}

@test "pre-release check, mode on: item follows the audit result (clean passes, findings fail with exit 1)" {
  write_config on
  run --separate-stderr bash "$CHECKLIST" check pre-release --run r-e2e-on-clean
  [ "$(field "$RELEASE_ID" result)" = passed ]
  [ "$(field "$RELEASE_ID" action)" = proceed ]
  [ -e "$NPM_CALLS" ]

  high_audit
  run --separate-stderr bash "$CHECKLIST" check pre-release --run r-e2e-on-findings
  [ "$(field "$RELEASE_ID" result)" = failed ]
  [ "$(field "$RELEASE_ID" exit_status)" = 1 ]
  # The direct call on the same state returns the same verdict the item reported.
  audit --dir "$PROJ" --json
  [ "$status" -eq 1 ]
}

@test "pre-release check, mode off: item unsatisfied (exit 4), no trace" {
  write_config off
  run --separate-stderr bash "$CHECKLIST" check pre-release --run r-e2e-off
  [ "$(field "$RELEASE_ID" result)" = failed ]
  [ "$(field "$RELEASE_ID" exit_status)" = 4 ]
  assert_no_trace
}
