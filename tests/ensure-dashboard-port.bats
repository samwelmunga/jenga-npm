#!/usr/bin/env bats
#
# E47_S11_T02: j.init and j.distribute call scripts/dashboard-port.sh ensure (through
# scripts/ensure-dashboard-port.sh); `jenga config` gets/sets dashboard-config.dashboard_port.
# Cases: missing, valid, invalid stored value; consumer-install layout; set accept/reject.
#
# Isolation: every case works in $BATS_TEST_TMPDIR; this repository's own project/ is never written.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
WRAPPER="$REPO_ROOT/scripts/ensure-dashboard-port.sh"
INIT="$REPO_ROOT/skills/j-init/scripts/init.sh"
DIST="$REPO_ROOT/skills/j-distribute/scripts/distribute-changes.sh"
JENGA="$REPO_ROOT/bin/jenga.js"

setup() {
  export GIT_AUTHOR_NAME="Jenga Test" GIT_AUTHOR_EMAIL="test@example.com"
  export GIT_COMMITTER_NAME="Jenga Test" GIT_COMMITTER_EMAIL="test@example.com"
  unset JENGA_PROJECT_ROOT JENGA_CONFIG_DESCRIPTORS_DIR JENGA_DASHBOARD_PORT_CANDIDATE
  T="$BATS_TEST_TMPDIR/target"
  mkdir -p "$T/project/configs"
  cp "$REPO_ROOT/project/configs/workflow.json" "$T/project/configs/"
  FILE="$T/project/configs/dashboard-config.json"
}

# fixture monorepo for distribute: a git repo with package.json, a minimal include list and the scripts it needs
make_monorepo() {
  M="$BATS_TEST_TMPDIR/mono"
  mkdir -p "$M/scripts" "$M/skills/j-distribute/scripts" "$M/project/configs"
  git -C "$M" init -q
  echo '{"version":"1.2.3"}' > "$M/package.json"
  echo '{"distribute":{"include":["scripts"]}}' > "$M/distribute.config.json"
  cp "$REPO_ROOT"/scripts/{ensure-dashboard-port.sh,dashboard-port.sh,resolve-root.sh,with-lock.sh,find-free-port.cjs} "$M/scripts/"
  cp "$DIST" "$M/skills/j-distribute/scripts/"
  echo '{"dashboard_port": 51111}' > "$M/project/configs/dashboard-config.json"
}

# --- wrapper ----------------------------------------------------------------------------------------------------

@test "wrapper: missing file -> generated, stored in the target, in range" {
  run bash "$WRAPPER" "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == "dashboard-port: generated "* ]]
  p="${output##* }"
  [ "$p" -ge 50000 ] && [ "$p" -le 64999 ]
  [ "$(jq -r .dashboard_port "$FILE")" = "$p" ]
}

@test "wrapper: valid stored port -> kept, file byte-identical" {
  printf '{\n  "dashboard_port": 55555\n}\n' > "$FILE"
  cp "$FILE" "$BATS_TEST_TMPDIR/before"
  run bash "$WRAPPER" "$T"
  [ "$status" -eq 0 ]
  [ "$output" = "dashboard-port: kept 55555" ]
  cmp "$FILE" "$BATS_TEST_TMPDIR/before"
}

@test "wrapper: invalid stored values (out of range, non-integer, string) -> repaired" {
  for bad in 80 70000 5.5 '"abc"'; do
    printf '{"dashboard_port": %s}\n' "$bad" > "$FILE"
    run bash "$WRAPPER" "$T"
    [ "$status" -eq 0 ]
    [[ "$output" == "dashboard-port: repaired "* ]]
    p="${output##* }"
    [ "$p" -ge 50000 ] && [ "$p" -le 64999 ]
    [ "$(jq -r .dashboard_port "$FILE")" = "$p" ]
  done
}

@test "wrapper: existing file without the key -> generated, other keys preserved" {
  echo '{"other": 1}' > "$FILE"
  run bash "$WRAPPER" "$T"
  [[ "$output" == "dashboard-port: generated "* ]]
  [ "$(jq -r .other "$FILE")" = "1" ]
}

@test "wrapper: --dry-run reports and writes nothing" {
  run bash "$WRAPPER" --dry-run "$T"
  [ "$status" -eq 0 ]
  [ "$output" = "dashboard-port: would generate" ]
  [ ! -e "$FILE" ]
  echo '{"dashboard_port": 99}' > "$FILE"
  run bash "$WRAPPER" --dry-run "$T"
  [ "$output" = "dashboard-port: would repair" ]
  [ "$(jq -r .dashboard_port "$FILE")" = "99" ]
}

@test "wrapper: a directory that is not a Jenga project is skipped, nothing created" {
  mkdir "$BATS_TEST_TMPDIR/plain"
  run bash "$WRAPPER" "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ]
  [[ "$output" == "dashboard-port: skipped"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/plain/project" ]
}

@test "wrapper: usage errors exit 2" {
  run bash "$WRAPPER"
  [ "$status" -eq 2 ]
  run bash "$WRAPPER" --bogus "$T"
  [ "$status" -eq 2 ]
}

@test "wrapper: works from a consumer install layout (node_modules/@jenga-ai/agent/scripts)" {
  C="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$C/node_modules/@jenga-ai/agent/scripts"
  cp "$REPO_ROOT"/scripts/{ensure-dashboard-port.sh,dashboard-port.sh,resolve-root.sh,with-lock.sh,find-free-port.cjs} "$C/node_modules/@jenga-ai/agent/scripts/"
  mkdir -p "$C/project/configs"
  cp "$REPO_ROOT/project/configs/workflow.json" "$C/project/configs/"
  run bash -c "cd '$C' && bash node_modules/@jenga-ai/agent/scripts/ensure-dashboard-port.sh '$C'"
  [ "$status" -eq 0 ]
  [[ "$output" == "dashboard-port: generated "* ]]
  [ -f "$C/project/configs/dashboard-config.json" ]
}

@test "wrapper: a wrapper copied alone finds the allocator under node_modules of the cwd" {
  C="$BATS_TEST_TMPDIR/consumer2"
  mkdir -p "$C/node_modules/@jenga-ai/agent/scripts" "$C/elsewhere" "$C/project/configs"
  cp "$REPO_ROOT"/scripts/{dashboard-port.sh,resolve-root.sh,with-lock.sh,find-free-port.cjs} "$C/node_modules/@jenga-ai/agent/scripts/"
  cp "$WRAPPER" "$C/elsewhere/"
  cp "$REPO_ROOT/project/configs/workflow.json" "$C/project/configs/"
  run bash -c "cd '$C' && bash elsewhere/ensure-dashboard-port.sh '$C'"
  [[ "$output" == "dashboard-port: generated "* ]]
}

# --- j.init call site -------------------------------------------------------------------------------------------

@test "init: a fresh scaffold generates a port in range and reports it" {
  C="$BATS_TEST_TMPDIR/fresh"; mkdir -p "$C"
  run bash -c "cd '$C' && bash '$INIT' --visibility visible"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dashboard-port: generated "* ]]
  p="$(jq -r .dashboard_port "$C/project/configs/dashboard-config.json")"
  [ "$p" -ge 50000 ] && [ "$p" -le 64999 ]
  # and it is not this repository's value
  [ "$p" != "$(jq -r .dashboard_port "$REPO_ROOT/project/configs/dashboard-config.json")" ] || skip "random port collided with the repo's value (1 in 15000)"
}

@test "init: the scaffold calls the wrapper that decides generated / kept / repaired" {
  # init.sh re-scaffolds unconditionally (SKILL.md hard-stops on already-scaffolded), so the keep/repair
  # decision is exercised through the wrapper init.sh calls; here we pin that init.sh calls exactly that wrapper.
  run grep -n 'ensure-dashboard-port.sh' "$INIT"
  [ "$status" -eq 0 ]
}

# --- j.distribute call site -------------------------------------------------------------------------------------

@test "distribute: target missing the port gets a generated one, not this repository's value" {
  make_monorepo
  run bash "$M/skills/j-distribute/scripts/distribute-changes.sh" "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dashboard-port: generated "* ]]
  p="$(jq -r .dashboard_port "$FILE")"
  [ "$p" -ge 50000 ] && [ "$p" -le 64999 ]
  [ "$p" != "51111" ] || skip "random port collided with the fixture value"
}

@test "distribute: a valid target port is never overwritten" {
  make_monorepo
  echo '{"dashboard_port": 62222}' > "$FILE"
  run bash "$M/skills/j-distribute/scripts/distribute-changes.sh" "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dashboard-port: kept 62222"* ]]
  [ "$(jq -r .dashboard_port "$FILE")" = "62222" ]
}

@test "distribute: an invalid target port is repaired" {
  make_monorepo
  echo '{"dashboard_port": 22}' > "$FILE"
  run bash "$M/skills/j-distribute/scripts/distribute-changes.sh" "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dashboard-port: repaired "* ]]
  p="$(jq -r .dashboard_port "$FILE")"
  [ "$p" -ge 50000 ] && [ "$p" -le 64999 ]
}

@test "distribute: --dry-run writes no port" {
  make_monorepo
  run bash "$M/skills/j-distribute/scripts/distribute-changes.sh" "$T" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dashboard-port: would generate"* ]]
  [ ! -e "$FILE" ]
}

@test "distribute: a target that is not a Jenga project is skipped and still succeeds" {
  make_monorepo
  mkdir "$BATS_TEST_TMPDIR/plain"
  run bash "$M/skills/j-distribute/scripts/distribute-changes.sh" "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dashboard-port: skipped"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/plain/project" ]
}

@test "distribute: project/configs is not in the shipped include list, so no repo value can be copied" {
  run jq -e '.distribute.include | index("project") == null' "$REPO_ROOT/distribute.config.json"
  [ "$status" -eq 0 ]
}

# --- jenga config -----------------------------------------------------------------------------------------------

@test "jenga config lists dashboard-config.dashboard_port" {
  echo '{"dashboard_port": 58150}' > "$FILE"
  # the interactive browse lists files, then the keys of the chosen one (quit with q)
  run bash -c "printf 'dashboard-config\nq\nq\n' | JENGA_PROJECT_ROOT='$T' node '$JENGA' config"
  [[ "$output" == *"dashboard-config"* ]]
  [[ "$output" == *"dashboard_port"* ]]
}

@test "jenga config get/set: accepts in-range integers" {
  echo '{"dashboard_port": 58150}' > "$FILE"
  run env JENGA_PROJECT_ROOT="$T" node "$JENGA" config get dashboard-config.dashboard_port
  [ "$status" -eq 0 ]
  [[ "$output" == *"58150"* ]]
  for v in 50000 64999 61234; do
    run env JENGA_PROJECT_ROOT="$T" node "$JENGA" config set dashboard-config.dashboard_port "$v"
    [ "$status" -eq 0 ]
    [ "$(jq -r .dashboard_port "$FILE")" = "$v" ]
  done
}

@test "jenga config set: rejects out-of-range and non-integer values, file unchanged" {
  echo '{"dashboard_port": 58150}' > "$FILE"
  cp "$FILE" "$BATS_TEST_TMPDIR/before"
  for v in 49999 65000 80 0 -1 5.5 abc ""; do
    run env JENGA_PROJECT_ROOT="$T" node "$JENGA" config set dashboard-config.dashboard_port "$v"
    [ "$status" -ne 0 ]
    cmp "$FILE" "$BATS_TEST_TMPDIR/before"
  done
}
