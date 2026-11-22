#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E47_S11_T03: the dashboard prefers the project's assigned port (scripts/dashboard-port.sh get), falls back to
# the verified-free search with a warning when it is busy, missing or invalid, and an explicit port still wins.
# Real sockets are bound. Every test works in a throwaway project under $BATS_TEST_TMPDIR.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/find-free-port.cjs"
START="$REPO_ROOT/project/app/ui/scripts/dashboard-start.cjs"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/board" "$PROJ/project/configs"
  PROJ="$(cd "$PROJ" && pwd -P)"
  cp "$REPO_ROOT/project/configs/workflow.json" "$PROJ/project/configs/"
  PIDS=""
}

teardown() {
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
}

hold_port() {
  node -e 'require("net").createServer().listen(+process.argv[1], () => console.log("held"))' "$1" \
    > "$BATS_TEST_TMPDIR/hold-$1.log" 2>&1 &
  PIDS="$PIDS $!"
  local i
  for i in $(seq 1 50); do
    grep -q held "$BATS_TEST_TMPDIR/hold-$1.log" && return 0
    sleep 0.1
  done
  return 1
}

start_dashboard() {
  local log="$1"; shift
  (cd "$PROJ" && JENGA_PROJECT_ROOT="$PROJ" exec node "$START" --api-only "$@") > "$log" 2>&1 &
  LAST_PID=$!
  PIDS="$PIDS $LAST_PID"
  local i
  for i in $(seq 1 80); do
    grep -q "running at" "$log" && return 0
    kill -0 "$LAST_PID" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

port_in_log() { sed -n 's#.*running at http://localhost:\([0-9]*\).*#\1#p' "$1" | head -1; }

# assign <value>: write dashboard_port (raw JSON value) into the project's dashboard-config.json
assign() { printf '{"dashboard_port": %s}\n' "$1" > "$PROJ/project/configs/dashboard-config.json"; }

@test "assigned port free: binds exactly it, no warning, and records it" {
  command -v jq >/dev/null || skip "jq not installed"
  free="$(node "$HELPER" --start 52000)"
  assign "$free"
  start_dashboard "$BATS_TEST_TMPDIR/a.log"
  [ "$(port_in_log "$BATS_TEST_TMPDIR/a.log")" = "$free" ]
  assert_output_not_contains "Warning"
  run cat "$BATS_TEST_TMPDIR/a.log"
  assert_output_not_contains "Warning"
  run cat "$PROJ/project/queue/dashboard-port.json"
  assert_output_contains "\"port\":$free"
}

@test "assigned port busy: falls back and the warning names both ports" {
  command -v jq >/dev/null || skip "jq not installed"
  busy="$(node "$HELPER" --start 53000)"
  hold_port "$busy"
  assign "$busy"
  start_dashboard "$BATS_TEST_TMPDIR/a.log"
  used="$(port_in_log "$BATS_TEST_TMPDIR/a.log")"
  [ -n "$used" ]
  [ "$used" != "$busy" ]
  run cat "$BATS_TEST_TMPDIR/a.log"
  assert_output_contains "assigned port $busy"
  assert_output_contains "busy"
  assert_output_contains "using $used"
  run curl -s "http://localhost:$used/v1/health"
  assert_output_contains '"status":"ok"'
}

@test "missing value: falls back with a warning suggesting the allocator" {
  start_dashboard "$BATS_TEST_TMPDIR/a.log"
  [ -n "$(port_in_log "$BATS_TEST_TMPDIR/a.log")" ]
  run cat "$BATS_TEST_TMPDIR/a.log"
  assert_output_contains "Warning"
  assert_output_contains "missing"
  assert_output_contains "dashboard-port.sh ensure"
}

@test "invalid value: falls back with a warning and does not crash" {
  command -v jq >/dev/null || skip "jq not installed"
  assign 80
  start_dashboard "$BATS_TEST_TMPDIR/a.log"
  [ -n "$(port_in_log "$BATS_TEST_TMPDIR/a.log")" ]
  run cat "$BATS_TEST_TMPDIR/a.log"
  assert_output_contains "Warning"
  assert_output_contains "invalid"
  assert_output_contains "outside"
  printf 'not json{' > "$PROJ/project/configs/dashboard-config.json"
  start_dashboard "$BATS_TEST_TMPDIR/b.log"
  [ -n "$(port_in_log "$BATS_TEST_TMPDIR/b.log")" ]
}

@test "explicit --port wins over the assigned port" {
  command -v jq >/dev/null || skip "jq not installed"
  assigned="$(node "$HELPER" --start 54000)"
  assign "$assigned"
  explicit="$(node "$HELPER" --start 54500)"
  start_dashboard "$BATS_TEST_TMPDIR/a.log" --port "$explicit"
  [ "$(port_in_log "$BATS_TEST_TMPDIR/a.log")" = "$explicit" ]
  run cat "$BATS_TEST_TMPDIR/a.log"
  assert_output_not_contains "Warning"
}

@test "explicit JENGA_API_PORT wins over the assigned port" {
  command -v jq >/dev/null || skip "jq not installed"
  assigned="$(node "$HELPER" --start 55000)"
  assign "$assigned"
  explicit="$(node "$HELPER" --start 55500)"
  export JENGA_API_PORT="$explicit"
  start_dashboard "$BATS_TEST_TMPDIR/a.log"
  [ "$(port_in_log "$BATS_TEST_TMPDIR/a.log")" = "$explicit" ]
}

@test "explicit busy port still fails loudly even with a free assigned port" {
  command -v jq >/dev/null || skip "jq not installed"
  assigned="$(node "$HELPER" --start 56000)"
  assign "$assigned"
  busy="$(node "$HELPER" --start 56500)"
  hold_port "$busy"
  run bash -c "cd '$PROJ' && JENGA_PROJECT_ROOT='$PROJ' node '$START' --api-only --port $busy"
  [ "$status" -eq 1 ]
  assert_output_contains "port $busy is already in use"
  assert_output_not_contains "running at"
}
