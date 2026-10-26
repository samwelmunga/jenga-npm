#!/usr/bin/env bats
#
# E85_S04_T02: scripts/audit-notice.sh prints a one-time opt-in notice for dependency audits.
# Every case runs against a throwaway JENGA_PROJECT_ROOT under BATS_TEST_TMPDIR; this repository's
# configs and data directory are never touched.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/audit-notice.sh"

setup() {
  export JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$JENGA_PROJECT_ROOT/project/configs" "$JENGA_PROJECT_ROOT/project/data"
  cp "$REPO_ROOT/project/configs/workflow.json" "$JENGA_PROJECT_ROOT/project/configs/workflow.json"
  CONFIG="$JENGA_PROJECT_ROOT/project/configs/audit-config.json"
  DATA="$JENGA_PROJECT_ROOT/project/data"
  MARKER="$DATA/audit-notice-shown"
}

teardown() {
  chmod u+w "$DATA" 2>/dev/null || true
}

set_mode() { printf '{"config_version":2,"mode":"%s"}\n' "$1" > "$CONFIG"; }

@test "ask: first call prints the notice and creates the marker, second call prints nothing" {
  set_mode ask
  run bash "$SCRIPT" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"not running yet"* ]]
  [ -f "$MARKER" ]
  [[ "$(cat "$MARKER")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
  run bash "$SCRIPT" show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$SCRIPT" show --context publish
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the notice is at most 6 lines, names the command, the in-session approval and the CI alternative" {
  set_mode ask
  run bash "$SCRIPT" show --context init
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -le 6 ]
  [[ "$output" == *"jenga config set audit-config.mode on"* ]]
  [[ "$output" == *"opt-in"* ]]
  [[ "$output" == *"in-session approval prompt"* ]]
  [[ "$output" == *"CI workflow"* ]]
  [[ "$output" != *"vulnerable"* ]]
}

@test "on: never prints and never creates the marker, with the marker absent or present" {
  set_mode on
  run bash "$SCRIPT" show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$MARKER" ]
  printf '2026-01-01\n' > "$MARKER"
  run bash "$SCRIPT" show --context publish
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$MARKER")" = "2026-01-01" ]
}

@test "off: silent and writes no marker" {
  set_mode off
  run bash "$SCRIPT" show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$MARKER" ]
}

@test "missing config behaves as ask" {
  [ ! -e "$CONFIG" ]
  run bash "$SCRIPT" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"jenga config set audit-config.mode on"* ]]
  [ -f "$MARKER" ]
  run bash "$SCRIPT" show
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a config without a mode key behaves as ask" {
  printf '{"config_version":2}\n' > "$CONFIG"
  run bash "$SCRIPT" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"not running yet"* ]]
}

@test "malformed config exits 2 with one stderr line, no stdout and no marker" {
  printf '{ not json' > "$CONFIG"
  run --separate-stderr bash "$SCRIPT" show
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  [ ! -e "$MARKER" ]
}

@test "a non-object config and an unknown mode both exit 2 with no marker" {
  printf '[1,2]\n' > "$CONFIG"
  run bash "$SCRIPT" show
  [ "$status" -eq 2 ]
  [ ! -e "$MARKER" ]
  set_mode sometimes
  run --separate-stderr bash "$SCRIPT" show
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
  [ ! -e "$MARKER" ]
  printf '{"mode":true}\n' > "$CONFIG"
  run bash "$SCRIPT" show
  [ "$status" -eq 2 ]
  [ ! -e "$MARKER" ]
}

@test "status reports not-shown before and shown after the notice" {
  set_mode ask
  run bash "$SCRIPT" status
  [ "$status" -eq 0 ]
  [ "$output" = "not-shown" ]
  bash "$SCRIPT" show >/dev/null
  run bash "$SCRIPT" status
  [ "$status" -eq 0 ]
  [ "$output" = "shown" ]
}

@test "status stays not-shown after a call in mode on" {
  set_mode on
  bash "$SCRIPT" show >/dev/null
  run bash "$SCRIPT" status
  [ "$output" = "not-shown" ]
}

@test "a missing data directory is created for the marker" {
  rm -rf "$DATA"
  set_mode ask
  run bash "$SCRIPT" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"not running yet"* ]]
  [ -f "$MARKER" ]
}

@test "a read-only data directory still prints the notice and exits 0, with a stderr warning" {
  set_mode ask
  chmod a-w "$DATA"
  if [ -w "$DATA" ]; then skip "data directory stays writable here (running as root)"; fi
  run --separate-stderr bash "$SCRIPT" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"jenga config set audit-config.mode on"* ]]
  [[ "$stderr" == *"warning"* ]]
  [ ! -e "$MARKER" ]
}

@test "concurrent callers print the notice exactly once" {
  set_mode ask
  for i in 1 2 3 4 5; do
    bash "$SCRIPT" show > "$BATS_TEST_TMPDIR/out.$i" 2>&1 &
  done
  wait
  total=0
  for i in 1 2 3 4 5; do
    if grep -q "not running yet" "$BATS_TEST_TMPDIR/out.$i"; then total=$((total + 1)); fi
  done
  [ "$total" -eq 1 ]
  [ -f "$MARKER" ]
  [ ! -e "$MARKER.lock.d" ]
}

@test "usage errors exit 2 and --help exits 0" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" bogus
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" show --context nowhere
  [ "$status" -eq 2 ]
  [ ! -e "$MARKER" ]
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "the marker name is git-ignored in this repository" {
  run git -C "$REPO_ROOT" check-ignore -q project/data/audit-notice-shown
  [ "$status" -eq 0 ]
}
