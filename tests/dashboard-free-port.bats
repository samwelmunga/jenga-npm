#!/usr/bin/env bats
#
# E47_S08_T03: the dashboard binds a verified-free port, an explicit busy port fails loudly, and
# `dashboard open` finds the port actually chosen.
#
# Covers scripts/find-free-port.cjs (the dependency-free shared helper), scripts/dashboard-port-state.cjs
# and project/app/ui/scripts/{dashboard-start,dashboard-open}.cjs. Real sockets are bound, nothing is
# faked except the browser launcher (`open` / `xdg-open` on PATH), so no browser opens. Every test
# works in a throwaway project under $BATS_TEST_TMPDIR. Ports under test are always taken from the
# helper itself (never assumed free), except 3001 where the test adapts to whatever the machine has.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/find-free-port.cjs"
START="$REPO_ROOT/project/app/ui/scripts/dashboard-start.cjs"
OPEN="$REPO_ROOT/project/app/ui/scripts/dashboard-open.cjs"

setup() {
  PROJ_A="$BATS_TEST_TMPDIR/proj-a"
  PROJ_B="$BATS_TEST_TMPDIR/proj-b"
  mkdir -p "$PROJ_A/project/board" "$PROJ_B/project/board"
  PROJ_A="$(cd "$PROJ_A" && pwd -P)"
  PROJ_B="$(cd "$PROJ_B" && pwd -P)"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  OPENED="$BATS_TEST_TMPDIR/opened.log"
  mkdir -p "$FAKE_BIN"
  for b in open xdg-open; do
    printf '#!/bin/sh\necho "$@" >> "%s"\n' "$OPENED" > "$FAKE_BIN/$b"
    chmod +x "$FAKE_BIN/$b"
  done
  PIDS=""
}

teardown() {
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
}

# hold_port <port>: occupy a port (wildcard, like a real server) until teardown.
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

# start_dashboard <project-dir> <log> [args...]: run the dashboard API in the background from that project
# and wait (bounded) for it to either listen or exit.
start_dashboard() {
  local proj="$1" log="$2"; shift 2
  (cd "$proj" && exec node "$START" --api-only "$@") > "$log" 2>&1 &
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

busy_3001() { node "$HELPER" --check 3001; [ $? -ne 0 ]; }

@test "helper: a free start port is returned as-is" {
  free="$(node "$HELPER" --start 41000)"
  run node "$HELPER" --start "$free"
  [ "$status" -eq 0 ]
  [ "$output" = "$free" ]
  run node "$HELPER" --check "$free"
  [ "$status" -eq 0 ]
}

@test "helper: a busy start port is skipped, and --check reports it busy" {
  free="$(node "$HELPER" --start 41100)"
  hold_port "$free"
  run node "$HELPER" --check "$free"
  [ "$status" -eq 1 ]
  run node "$HELPER" --start "$free"
  [ "$status" -eq 0 ]
  [ "$output" != "$free" ]
  [ "$output" -gt "$free" ]
  run node "$HELPER" --check "$output"
  [ "$status" -eq 0 ]
}

@test "helper: listenOnFreePort explicit-busy rejects with EADDRINUSE and never substitutes" {
  free="$(node "$HELPER" --start 41200)"
  hold_port "$free"
  run node -e '
    const { listenOnFreePort } = require(process.argv[1]);
    const http = require("http");
    listenOnFreePort(http.createServer(), { explicit: +process.argv[2] })
      .then(r => { console.log("BOUND " + r.port); process.exit(0); })
      .catch(e => { console.log("REJECTED " + e.code); process.exit(0); });
  ' "$HELPER" "$free"
  [ "$status" -eq 0 ]
  assert_output_contains "REJECTED EADDRINUSE"
}

@test "helper: listenOnFreePort without explicit skips a busy start port and binds a free one" {
  free="$(node "$HELPER" --start 41300)"
  hold_port "$free"
  run node -e '
    const { listenOnFreePort } = require(process.argv[1]);
    const http = require("http");
    listenOnFreePort(http.createServer(), { start: +process.argv[2] })
      .then(r => { console.log("BOUND " + r.port); process.exit(0); });
  ' "$HELPER" "$free"
  [ "$status" -eq 0 ]
  assert_output_not_contains "BOUND $free"
  assert_output_contains "BOUND "
}

@test "dashboard start: with 3001 busy it binds another port, prints its URL and records it" {
  busy_3001 || hold_port 3001
  start_dashboard "$PROJ_A" "$BATS_TEST_TMPDIR/a.log"
  port="$(port_in_log "$BATS_TEST_TMPDIR/a.log")"
  [ -n "$port" ]
  [ "$port" != "3001" ]
  run curl -s "http://localhost:$port/v1/health"
  assert_output_contains '"status":"ok"'
  run cat "$PROJ_A/project/queue/dashboard-port.json"
  assert_output_contains "\"port\":$port"
}

@test "dashboard start: with 3001 free it still binds 3001" {
  if busy_3001; then skip "port 3001 is in use on this machine"; fi
  start_dashboard "$PROJ_A" "$BATS_TEST_TMPDIR/a.log"
  [ "$(port_in_log "$BATS_TEST_TMPDIR/a.log")" = "3001" ]
}

@test "dashboard start: an explicit busy --port exits non-zero and does not pick another port" {
  free="$(node "$HELPER" --start 41400)"
  hold_port "$free"
  run bash -c "cd '$PROJ_A' && node '$START' --api-only --port $free"
  [ "$status" -eq 1 ]
  assert_output_contains "port $free is already in use"
  assert_output_not_contains "running at"
  [ ! -e "$PROJ_A/project/queue/dashboard-port.json" ]
}

@test "dashboard start: an explicit busy JENGA_API_PORT also fails loudly" {
  free="$(node "$HELPER" --start 41500)"
  hold_port "$free"
  run bash -c "cd '$PROJ_A' && JENGA_API_PORT=$free node '$START' --api-only"
  [ "$status" -eq 1 ]
  assert_output_contains "already in use"
}

@test "dashboard start: an explicit free --port binds exactly that port" {
  free="$(node "$HELPER" --start 41600)"
  start_dashboard "$PROJ_A" "$BATS_TEST_TMPDIR/a.log" --port "$free"
  [ "$(port_in_log "$BATS_TEST_TMPDIR/a.log")" = "$free" ]
}

@test "dashboard open: finds the running port with no flag, and --port still takes priority" {
  busy_3001 || hold_port 3001
  start_dashboard "$PROJ_A" "$BATS_TEST_TMPDIR/a.log"
  port="$(port_in_log "$BATS_TEST_TMPDIR/a.log")"
  run bash -c "cd '$PROJ_A' && PATH='$FAKE_BIN':\$PATH node '$OPEN'"
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$OPENED")" "http://localhost:$port"
  # --port wins over the recorded port: nothing listens on 3999, so open warns about 3999 (and not about
  # the recorded port) instead of opening it.
  : > "$OPENED"
  run bash -c "cd '$PROJ_A' && PATH='$FAKE_BIN':\$PATH node '$OPEN' --port 3999 2>&1"
  [ "$status" -eq 0 ]
  assert_output_contains "http://localhost:3999"
  assert_output_not_contains "localhost:$port"
}

@test "dashboard start --open on a running project opens that dashboard instead of starting a second" {
  busy_3001 || hold_port 3001
  start_dashboard "$PROJ_A" "$BATS_TEST_TMPDIR/a.log"
  port="$(port_in_log "$BATS_TEST_TMPDIR/a.log")"
  run bash -c "cd '$PROJ_A' && PATH='$FAKE_BIN':\$PATH node '$START' --open"
  [ "$status" -eq 0 ]
  assert_output_contains "already running at http://localhost:$port"
  assert_contains "$(cat "$OPENED")" "http://localhost:$port"
}

@test "dashboard start: two projects started back to back get distinct ports" {
  start_dashboard "$PROJ_A" "$BATS_TEST_TMPDIR/a.log"
  start_dashboard "$PROJ_B" "$BATS_TEST_TMPDIR/b.log"
  pa="$(port_in_log "$BATS_TEST_TMPDIR/a.log")"
  pb="$(port_in_log "$BATS_TEST_TMPDIR/b.log")"
  [ -n "$pa" ]
  [ -n "$pb" ]
  [ "$pa" != "$pb" ]
}

@test "dashboard start: the recorded port is removed on a graceful stop" {
  start_dashboard "$PROJ_A" "$BATS_TEST_TMPDIR/a.log"
  [ -e "$PROJ_A/project/queue/dashboard-port.json" ]
  kill -TERM "$LAST_PID"
  for i in $(seq 1 50); do
    [ -e "$PROJ_A/project/queue/dashboard-port.json" ] || break
    sleep 0.1
  done
  [ ! -e "$PROJ_A/project/queue/dashboard-port.json" ]
}
