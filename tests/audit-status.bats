#!/usr/bin/env bats
#
# E85_S01_T11: scripts/audit-status.sh prints the latest audit_result per scanned directory.
# Every case runs against a throwaway JENGA_PROJECT_ROOT under BATS_TEST_TMPDIR; this repository's
# event log and rapports are never touched.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/audit-status.sh"

setup() {
  export JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$JENGA_PROJECT_ROOT/project/configs" "$JENGA_PROJECT_ROOT/project/logs" "$JENGA_PROJECT_ROOT/project/rapports/problems"
  cp "$REPO_ROOT/project/configs/workflow.json" "$JENGA_PROJECT_ROOT/project/configs/workflow.json"
  cp "$REPO_ROOT/project/configs/audit-config.json" "$JENGA_PROJECT_ROOT/project/configs/audit-config.json"
  EVENTS="$JENGA_PROJECT_ROOT/project/logs/events.json"
  RAPPORTS="$JENGA_PROJECT_ROOT/project/rapports/problems"
}

ago() { jq -nr --argjson d "$1" 'now - 86400 * $d | floor | todate'; } # ISO timestamp <days> days ago

# ev <dir> <status> <days-ago> [high-count] [rapport]
ev() {
  jq -nc --arg dir "$1" --arg s "$2" --arg date "$(ago "$3")" --argjson high "${4:-0}" --arg rap "${5:-}" '
    {event:"audit_result", agent:"audit-record", status:$s, threshold:"high",
     counts:{low:0, moderate:1, high:$high, critical:0, total:($high + 1)},
     scanned_dir:$dir, consent_basis:"session-approval", rapport:(if $rap == "" then null else $rap end),
     session_id:"S", date:$date}' >> "$EVENTS"
}

@test "no events file prints the no-audit line plus the opt-in hint (mode ask) and exits 0" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Dependency audit: no audit recorded" ]
  [[ "$output" == *"opt-in"* ]]
  [[ "$output" == *"jenga config set audit-config.mode on"* ]]
}

@test "no audit events among other events prints the no-audit line; mode on drops the hint" {
  echo '{"event":"session_start","agent":"developer"}' > "$EVENTS"
  jq '.mode = "on"' "$JENGA_PROJECT_ROOT/project/configs/audit-config.json" > "$BATS_TEST_TMPDIR/c.json"
  mv "$BATS_TEST_TMPDIR/c.json" "$JENGA_PROJECT_ROOT/project/configs/audit-config.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "Dependency audit: no audit recorded" ]
}

@test "two results for one directory report only the newer one" {
  ev /srv/a findings 5 3
  ev /srv/a clean 1
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"/srv/a - clean"* ]]
  [[ "$output" == *"1 day old"* ]]
  [[ "$output" != *"findings"* ]]
}

@test "events for two directories report both" {
  ev /srv/a clean 2
  ev /srv/b unavailable 3
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *"/srv/a - clean"* ]]
  [[ "$output" == *"/srv/b - unavailable"* ]]
}

@test "age is computed in whole days and a result over 14 days is marked stale" {
  ev /srv/old clean 20
  ev /srv/new clean 3
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/srv/old - clean"*"20 days old (stale)"* ]]
  [[ "$output" == *"/srv/new - clean"*"3 days old"* ]]
  [[ "$(printf '%s\n' "$output" | grep '/srv/new')" != *"(stale)"* ]]
}

@test "a findings result prints the per-severity counts and the rapport named by the event" {
  rap="$RAPPORTS/audit-srv-a-20261020.md"
  printf 'x\n' > "$rap"
  ev /srv/a findings 2 2 "$rap"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"findings (threshold high; total 3: low 0, moderate 1, high 2, critical 0)"* ]]
  [[ "$output" == *"rapport: $rap"* ]]
}

@test "a findings result whose recorded rapport is gone falls back to the newest rapport naming the directory" {
  ev /srv/a findings 2 2 "/gone/audit-x.md"
  printf 'The dependency audit of `/srv/a` found 3\n' > "$RAPPORTS/audit-srv-a-20261001.md"
  printf 'The dependency audit of `/srv/other` found 3\n' > "$RAPPORTS/audit-srv-other-20261002.md"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rapport: $RAPPORTS/audit-srv-a-20261001.md"* ]]
}

@test "a findings result with no rapport prints no rapport line" {
  ev /srv/a findings 2 2
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"rapport:"* ]]
}

@test "a torn final line is ignored without an error" {
  ev /srv/a clean 1
  printf '{"event":"audit_result","status":"fin' >> "$EVENTS"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"/srv/a - clean"* ]]
}

@test "the script makes no npm call and writes no file" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "$@" >> "%s/npm.calls"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/npm"
  chmod +x "$BATS_TEST_TMPDIR/bin/npm"
  ev /srv/a findings 1 2
  ev /srv/b clean 1
  before="$(find "$JENGA_PROJECT_ROOT" -type f -exec cksum {} + | sort)"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  after="$(find "$JENGA_PROJECT_ROOT" -type f -exec cksum {} + | sort)"
  [ "$before" = "$after" ]
  [ ! -e "$BATS_TEST_TMPDIR/npm.calls" ]
}

@test "skills/j-status/SKILL.md runs the script under a Dependency audit heading and parses nothing itself" {
  skill="$REPO_ROOT/skills/j-status/SKILL.md"
  grep -q 'audit-status.sh' "$skill"
  grep -q 'Dependency audit' "$skill"
  ! grep -qi 'audit_result' "$skill"
}
