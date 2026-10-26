#!/usr/bin/env bats
#
# E85_S01_T04: scripts/audit-record.sh records audit consent and results as events and rapports.
# Every case runs against a throwaway JENGA_PROJECT_ROOT under BATS_TEST_TMPDIR; this repository's
# event log and rapports are never touched.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/audit-record.sh"

setup() {
  export JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$JENGA_PROJECT_ROOT/project/configs"
  cp "$REPO_ROOT/project/configs/workflow.json" "$JENGA_PROJECT_ROOT/project/configs/workflow.json"
  EVENTS="$JENGA_PROJECT_ROOT/project/logs/events.json"
  RAPPORTS="$JENGA_PROJECT_ROOT/project/rapports/problems"
  AUDITED="$BATS_TEST_TMPDIR/svc"
  mkdir -p "$AUDITED"
}

mkresult() { # <status> [extra jq object merged in]
  jq -n --arg s "$1" --arg d "$AUDITED" '{status:$s, threshold:"high", scanned_dir:$d, generated_at:"2026-10-25T01:02:03Z", consent_basis:"session-approval"}' \
    | jq -c ". + ${2:-{\}}" > "$BATS_TEST_TMPDIR/$1.json"
  echo "$BATS_TEST_TMPDIR/$1.json"
}

findings_file() {
  mkresult findings '{counts:{info:0,low:0,moderate:1,high:2,critical:0,total:3},
    findings:[{name:"lodash",severity:"high",fix_available:true,range:"<4.17.21"},
              {name:"minimist",severity:"high",fix_available:false,range:"<1.2.6"},
              {name:"ms",severity:"moderate",fix_available:true,range:"<2.0.0"}]}'
}

@test "consent appends one single-line audit_consent event with the documented fields" {
  run bash "$SCRIPT" consent --dir "$AUDITED" --session-id S1 --agent tester
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$EVENTS" | tr -d ' ')" = 1 ]
  jq -e --arg d "$AUDITED" '
    keys == ["agent","approved_by","date","event","scanned_dir","session_id","tool_type"]
    and .event == "audit_consent" and .tool_type == "vulnerability" and .approved_by == "user"
    and .agent == "tester" and .session_id == "S1" and .scanned_dir == $d
    and (.date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$EVENTS"
}

@test "events file stays valid JSONL across consent and result calls" {
  bash "$SCRIPT" consent --dir "$AUDITED"
  bash "$SCRIPT" result --file "$(mkresult clean)"
  bash "$SCRIPT" result --file "$(findings_file)"
  [ "$(wc -l < "$EVENTS" | tr -d ' ')" = 3 ]
  while IFS= read -r line; do printf '%s' "$line" | jq -c . >/dev/null; done < "$EVENTS"
}

@test "findings result appends one audit_result event and one security_concern rapport naming every finding" {
  run bash "$SCRIPT" result --file "$(findings_file)" --session-id S2
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$EVENTS" | tr -d ' ')" = 1 ]
  jq -e --arg d "$AUDITED" '
    keys == ["agent","consent_basis","counts","date","event","rapport","scanned_dir","session_id","status","threshold"]
    and .event == "audit_result" and .status == "findings" and .threshold == "high"
    and .counts == {low:0,moderate:1,high:2,critical:0,total:3}
    and .scanned_dir == $d and .consent_basis == "session-approval" and .session_id == "S2"
    and (.rapport | type == "string") and (.date | type == "string") and (has("findings") | not)' "$EVENTS"
  rapport="$(jq -r .rapport "$EVENTS")"
  [ -f "$rapport" ]
  [ "$(ls "$RAPPORTS" | wc -l | tr -d ' ')" = 1 ]
  [ "$(dirname "$rapport")" = "$RAPPORTS" ]
  [[ "$(basename "$rapport")" == audit-*-20261025.md ]]
  grep -q '^\*\*Type:\*\* `security_concern`' "$rapport"
  grep -q 'lodash' "$rapport"
  grep -q 'minimist' "$rapport"
  grep -q '| ms |' "$rapport"
  grep -q '<4.17.21' "$rapport"
}

@test "clean, unavailable and disabled results append the event and write no rapport" {
  for s in clean unavailable disabled; do
    run bash "$SCRIPT" result --file "$(mkresult "$s")"
    [ "$status" -eq 0 ]
  done
  [ "$(wc -l < "$EVENTS" | tr -d ' ')" = 3 ]
  [ ! -d "$RAPPORTS" ] || [ -z "$(ls -A "$RAPPORTS")" ]
  [ "$(jq -s -r 'map(.status) | join(",")' "$EVENTS")" = "clean,unavailable,disabled" ]
  [ "$(jq -s '[.[] | select(.rapport != null)] | length' "$EVENTS")" = 0 ]
}

@test "counts always carries all five keys even when the input lacks some" {
  run bash "$SCRIPT" result --file "$(mkresult clean '{counts:{high:2}}')"
  [ "$status" -eq 0 ]
  jq -e '.counts == {low:0,moderate:0,high:2,critical:0,total:2}' "$EVENTS"
  run bash "$SCRIPT" result --file "$(mkresult disabled)"
  jq -s -e '.[1].counts == {low:0,moderate:0,high:0,critical:0,total:0}' "$EVENTS"
}

@test "two findings results for the same directory and date leave one rapport" {
  f="$(findings_file)"
  bash "$SCRIPT" result --file "$f"
  bash "$SCRIPT" result --file "$f"
  [ "$(ls "$RAPPORTS" | wc -l | tr -d ' ')" = 1 ]
  [ "$(wc -l < "$EVENTS" | tr -d ' ')" = 2 ]
}

@test "usage errors and unreadable result files exit 2 and write nothing" {
  run bash "$SCRIPT"; [ "$status" -eq 2 ]
  run bash "$SCRIPT" bogus; [ "$status" -eq 2 ]
  run bash "$SCRIPT" consent; [ "$status" -eq 2 ]
  run bash "$SCRIPT" result; [ "$status" -eq 2 ]
  run bash "$SCRIPT" result --file "$BATS_TEST_TMPDIR/missing.json"; [ "$status" -eq 2 ]
  echo 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  run bash "$SCRIPT" result --file "$BATS_TEST_TMPDIR/bad.json"; [ "$status" -eq 2 ]
  echo '{"status":"weird"}' > "$BATS_TEST_TMPDIR/weird.json"
  run bash "$SCRIPT" result --file "$BATS_TEST_TMPDIR/weird.json"; [ "$status" -eq 2 ]
  [ ! -e "$EVENTS" ]
}

@test "the script hardcodes no working-file path literal" {
  ! grep -q 'project/' "$SCRIPT"
}
