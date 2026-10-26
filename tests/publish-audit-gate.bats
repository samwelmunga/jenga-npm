#!/usr/bin/env bats
#
# E85_S01_T07: the dependency audit is a pre-phase gate of skills/j-publish/scripts/run_gates.sh for npm and
# npm-ci targets. Every case runs against a throwaway project under BATS_TEST_TMPDIR with a stubbed npm on
# PATH: nothing is published, staged, tagged or sent to a registry, and this repository's event log and
# rapports are never touched (JENGA_PROJECT_ROOT points at the throwaway project).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # CI consent is read from the environment (E85_S01_T14), so the suite must behave the same inside CI.
  unset CI GITHUB_ACTIONS
  P="$BATS_TEST_TMPDIR/proj"
  export JENGA_PROJECT_ROOT="$P"
  mkdir -p "$P/skills/j-publish/scripts" "$P/scripts" "$P/project/configs" "$P/bin"
  cp "$REPO_ROOT/skills/j-publish/scripts/run_gates.sh" "$P/skills/j-publish/scripts/"
  local s
  for s in audit-deps.sh audit-record.sh events-append.sh resolve-root.sh with-lock.sh; do
    if [ -f "$REPO_ROOT/scripts/$s" ]; then cp "$REPO_ROOT/scripts/$s" "$P/scripts/"; fi
  done
  cp "$REPO_ROOT/project/configs/workflow.json" "$P/project/configs/workflow.json"
  printf '{"name":"fixture","version":"1.0.0","scripts":{"test":"true","build":"true","lint":"true"}}\n' > "$P/package.json"
  printf '{"name":"fixture","lockfileVersion":3}\n' > "$P/package-lock.json"
  jq -n '{targets:[
    {name:"n",type:"npm"},{name:"c",type:"npm-ci"},{name:"d",type:"droplet"},{name:"i",type:"mobile-ios"}]}' > "$P/publish.json"
  GATES="$P/skills/j-publish/scripts/run_gates.sh"
  EVENTS="$P/project/logs/events.json"
  HISTORY="$P/project/logs/publish-history.json"
  audit_config on
  npm_audit_json '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}}}'
  export PATH="$P/bin:$PATH"
}

audit_config() { # <mode> [offline_behavior]
  jq -n --arg m "$1" --arg o "${2:-warn}" '{config_version:1,mode:$m,severity_threshold:"high",offline_behavior:$o,production_only:false}' \
    > "$P/project/configs/audit-config.json"
}

# Stub npm: `npm audit ...` prints $P/audit.out; every other command (npm test, npm run build) succeeds.
npm_audit_json() {
  printf '%s\n' "$1" > "$P/audit.out"
  printf '#!/bin/sh\nif [ "$1" = audit ]; then cat "%s/audit.out"; exit 1; fi\nexit 0\n' "$P" > "$P/bin/npm"
  chmod +x "$P/bin/npm"
}

findings_json='{"vulnerabilities":{"lodash":{"name":"lodash","severity":"high","fixAvailable":true,"range":"<4.17.21","via":[]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":1,"critical":0,"total":1}}}'
unavailable_json='{"error":{"code":"ENOTFOUND","summary":"registry unreachable"}}'

@test "npm target with a clean audit reports the audit gate as passed and exits 0" {
  run bash "$GATES" pre n "$P/publish.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:passed"* ]]
}

@test "npm-ci target runs the audit gate too" {
  run bash "$GATES" pre c "$P/publish.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:passed"* ]]
}

@test "the audit result is recorded as an audit_result event in the project's event log" {
  run bash "$GATES" pre n "$P/publish.json"
  [ "$status" -eq 0 ]
  jq -e 'select(.event == "audit_result" and .status == "clean")' "$EVENTS" >/dev/null
}

@test "findings at or above the threshold exit 2 naming the audit gate with --non-interactive" {
  npm_audit_json "$findings_json"
  run bash "$GATES" pre n "$P/publish.json" --non-interactive
  [ "$status" -eq 2 ]
  [[ "$output" == *"Gate: audit"* ]]
  [[ "$output" == *"lodash"* ]]
  [[ "$output" != *"audit:passed"* ]]
  jq -e '.[] | select(.event == "gate_failure" and .gate == "audit")' "$HISTORY" >/dev/null
  jq -e 'select(.event == "audit_result" and .status == "findings")' "$EVENTS" >/dev/null
}

@test "findings also exit 2 without a tty (implicit non-interactive)" {
  npm_audit_json "$findings_json"
  run bash "$GATES" pre n "$P/publish.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Gate: audit"* ]]
}

# The interactive path needs a tty (run_gates.sh reads its prompts from /dev/tty), so these cases run it under
# script(1) with the answer piped in; they skip where script(1) does not accept the BSD syntax.
interactive() { # <answer> -> sets status/output
  if ! script -q /dev/null true >/dev/null 2>&1; then
    skip "script(1) with BSD syntax is unavailable"
  fi
  run bash -c '(printf "%s\n" "$1"; sleep 2) | script -q /dev/null bash "$2" pre n "$3"' _ "$1" "$GATES" "$P/publish.json"
}

@test "interactive findings prompt 'proceed anyway / stop': stop exits 2" {
  npm_audit_json "$findings_json"
  interactive s
  [[ "$output" == *"Proceed anyway"* ]]
  [ "$status" -eq 2 ]
}

@test "interactive findings prompt: proceed anyway continues and is not reported as passed" {
  npm_audit_json "$findings_json"
  interactive p
  [[ "$output" == *"Proceed anyway"* ]]
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:failed (proceeded anyway)"* ]]
  [[ "$output" != *"audit:passed"* ]]
}

@test "mode ask without consent skips the audit with reason 'no consent', exit unaffected" {
  audit_config ask
  run bash "$GATES" pre n "$P/publish.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:skipped (no consent)"* ]]
  [[ "$output" != *"audit:passed"* ]]
}

@test "mode ask with --non-interactive (the deploy --yes mapping) is not CI consent: audit skipped, exit unaffected" {
  audit_config ask
  run bash "$GATES" pre n "$P/publish.json" --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:skipped (no consent)"* ]]
  [[ "$output" != *"audit:passed"* ]]
}

@test "the no-consent skip under --non-interactive records no audit_result and no ci-workflow consent" {
  audit_config ask
  run bash "$GATES" pre n "$P/publish.json" --non-interactive
  [ "$status" -eq 0 ]
  if [ -f "$EVENTS" ]; then
    run jq -e 'select(.event == "audit_result" or .event == "audit_consent" or .consent_basis == "ci-workflow")' "$EVENTS"
    [ "$status" -ne 0 ]
  fi
}

@test "the no-consent notice tells the user how to opt in" {
  audit_config ask
  run bash "$GATES" pre n "$P/publish.json" --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode"* && "$output" == *"project/configs/audit-config.json"* ]]
  [[ "$output" == *"run the audit explicitly"* ]]
}

@test "the audit never runs for the --non-interactive no-consent case: npm audit is not invoked" {
  audit_config ask
  printf '#!/bin/sh\nif [ "$1" = audit ]; then echo called > "%s/audit.called"; fi\nexit 0\n' "$P" > "$P/bin/npm"
  chmod +x "$P/bin/npm"
  run bash "$GATES" pre n "$P/publish.json" --non-interactive
  [ "$status" -eq 0 ]
  [ ! -e "$P/audit.called" ]
}

@test "mode ask with the explicit --ci argument runs the audit with consent_basis ci-workflow" {
  audit_config ask
  run bash "$GATES" pre n "$P/publish.json" --non-interactive --ci
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:passed"* ]]
  jq -e 'select(.event == "audit_result" and .consent_basis == "ci-workflow")' "$EVENTS" >/dev/null
}

@test "mode ask with --ci alone (no --non-interactive) also runs the audit as ci-workflow" {
  audit_config ask
  run bash "$GATES" pre n "$P/publish.json" --ci
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:passed"* ]]
  jq -e 'select(.event == "audit_result" and .consent_basis == "ci-workflow")' "$EVENTS" >/dev/null
}

@test "mode ask with CI=true in the environment runs the audit as ci-workflow" {
  audit_config ask
  CI=true run bash "$GATES" pre n "$P/publish.json" --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:passed"* ]]
  jq -e 'select(.event == "audit_result" and .consent_basis == "ci-workflow")' "$EVENTS" >/dev/null
}

@test "mode ask with GITHUB_ACTIONS=true in the environment runs the audit as ci-workflow" {
  audit_config ask
  GITHUB_ACTIONS=true run bash "$GATES" pre n "$P/publish.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:passed"* ]]
  jq -e 'select(.event == "audit_result" and .consent_basis == "ci-workflow")' "$EVENTS" >/dev/null
}

@test "CI set to something other than true is not a CI signal" {
  audit_config ask
  CI=1 GITHUB_ACTIONS=false run bash "$GATES" pre n "$P/publish.json" --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:skipped (no consent)"* ]]
}

@test "mode off stays a skip even with a CI signal" {
  audit_config off
  CI=true run bash "$GATES" pre n "$P/publish.json" --ci
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:skipped (no consent)"* ]]
}

@test "an unknown fourth or fifth argument is a usage error" {
  run bash "$GATES" pre n "$P/publish.json" --yes
  [ "$status" -eq 1 ]
}

@test "mode off is a skip with a no consent notice, never a pass, even with --non-interactive" {
  audit_config off
  run bash "$GATES" pre n "$P/publish.json" --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:skipped (no consent)"* ]]
  [[ "$output" != *"audit:passed"* ]]
}

@test "no audit_result event is recorded for a run refused for lack of consent" {
  audit_config ask
  run bash "$GATES" pre n "$P/publish.json"
  [ "$status" -eq 0 ]
  if [ -f "$EVENTS" ]; then
    run jq -e 'select(.event == "audit_result")' "$EVENTS"
    [ "$status" -ne 0 ]
  fi
}

@test "droplet and mobile-ios targets report the audit gate as skipped (not an npm target)" {
  run bash "$GATES" pre d "$P/publish.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:skipped (not an npm target)"* ]]
  run bash "$GATES" pre i "$P/publish.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:skipped (not an npm target)"* ]]
}

@test "non-npm targets never invoke npm audit" {
  printf '#!/bin/sh\necho "$@" >> "%s/npm.calls"\nexit 0\n' "$P" > "$P/bin/npm"
  chmod +x "$P/bin/npm"
  run bash "$GATES" pre d "$P/publish.json"
  [ "$status" -eq 0 ]
  run grep -q '^audit' "$P/npm.calls"
  [ "$status" -ne 0 ]
}

@test "audit unavailable under offline_behavior warn is a pass with a visible warning" {
  npm_audit_json "$unavailable_json"
  run bash "$GATES" pre n "$P/publish.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:passed (unavailable, warning)"* ]]
  [[ "$output" == *"Dependency audit unavailable"* ]]
  jq -e 'select(.event == "audit_result" and .status == "unavailable")' "$EVENTS" >/dev/null
}

@test "audit unavailable under offline_behavior fail is a failed gate" {
  audit_config on fail
  npm_audit_json "$unavailable_json"
  run bash "$GATES" pre n "$P/publish.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Gate: audit"* ]]
}

@test "an invalid audit config fails the gate (exit 2 from the audit script)" {
  printf '{"mode":"sometimes"}\n' > "$P/project/configs/audit-config.json"
  run bash "$GATES" pre n "$P/publish.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Gate: audit"* ]]
}

@test "a configured 'audit' entry in checks.pre is not run twice" {
  jq '.targets[0].checks = {pre: ["audit"]}' "$P/publish.json" > "$P/p2.json"
  run bash "$GATES" pre n "$P/p2.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'audit:passed')" -eq 1 ]
}

@test "the post phase does not run the audit gate" {
  run bash "$GATES" post n "$P/publish.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *"audit:"* ]]
}

@test "audit scripts are found under node_modules/@jenga-ai/agent/scripts when scripts/ is absent" {
  mkdir -p "$P/node_modules/@jenga-ai/agent"
  mv "$P/scripts" "$P/node_modules/@jenga-ai/agent/scripts"
  run bash "$GATES" pre n "$P/publish.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit:passed"* ]]
}

# validate (deploy --dry-run), stage and deploy all reach the gate through run_gates.sh pre.
@test "publish_deploy.sh runs run_gates.sh pre before the dry-run check (covers deploy and validate)" {
  local f="$REPO_ROOT/skills/j-publish/scripts/publish_deploy.sh"
  grep -q 'RUN_GATES_SCRIPT="\$SCRIPT_DIR/run_gates.sh"' "$f"
  grep -q 'cmd=(bash "\$RUN_GATES_SCRIPT" pre "\$TARGET_NAME" "\$CONFIG_PATH")' "$f"
  grep -q '^  run_pre_gates$' "$f"
}

@test "npm_stage_pipeline.sh runs run_gates.sh pre (covers stage)" {
  local f="$REPO_ROOT/skills/j-publish/scripts/npm_stage_pipeline.sh"
  grep -q 'RUN_GATES_SCRIPT="\${SCRIPT_DIR}/run_gates.sh"' "$f"
  grep -q 'GATES_CMD=(bash "\${RUN_GATES_SCRIPT}" pre ' "$f"
}
