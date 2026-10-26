#!/usr/bin/env bats
#
# E80_S02_T04: scripts/workflow/run-state.sh start, definition_hash, and the internal __create writer.
#
# Every test builds its own throwaway working-file tree under $BATS_TEST_TMPDIR, selects it with
# JENGA_PROJECT_ROOT and writes fixture definitions into <tree>/.workflows/, so the test depends on no builtin
# workflow and never reads or writes this repository's own runs directory. The real loader and validator run
# against the repository's schema and type registry (they are only read).
#
# Mirror safety: depends only on scripts/workflow/*.sh, scripts/resolve-root.sh, scripts/with-lock.sh,
# templates/workflow-schema.json, templates/playbook-types.json and fixtures it builds. The working-file tree
# names in the fixtures are registry-layout directory names, written into scratch trees only.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/run-state.sh"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS JENGA_WORKFLOWS_TEST_ROOT
  mkdir -p "$BATS_TEST_TMPDIR/anchor/project/configs" "$BATS_TEST_TMPDIR/anchor/project/.workflows"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/anchor/project/configs/workflow.json"
  ANCHOR="$(cd "$BATS_TEST_TMPDIR/anchor" && pwd)"
  RUNS="$ANCHOR/project/data/workflow-runs"
  WFDIR="$ANCHOR/project/.workflows"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  cd "$BATS_TEST_TMPDIR" || return 1
}

# demo_def: the main fixture, with two required inputs, one defaulted input and one checkpoint step.
demo_def() {
  cat <<'JSON'
{
  "id": "demo",
  "name": "Demo flow",
  "description": "Fixture.",
  "inputs": [
    {"name": "a", "description": "first"},
    {"name": "b"},
    {"name": "c", "default": "dd"}
  ],
  "steps": [
    {"id": "first", "type": "skill", "skill": "j.status", "checkpoint": true},
    {"id": "second", "type": "compute", "command": "echo hi"},
    {"id": "third", "type": "confirm", "prompt": "Continue?", "options": ["yes", "no"]}
  ]
}
JSON
}

# put_demo: writes the demo fixture into the project workflow directory.
put_demo() {
  demo_def > "$WFDIR/demo.json"
}

# start_run <args...>: runs start keeping stdout ($output) and stderr ($stderr) apart.
start_run() {
  run --separate-stderr bash "$SCRIPT" start "$@"
}

# assert_runs_untouched: the runs directory has no entry at all (or does not exist).
assert_runs_untouched() {
  [ ! -d "$RUNS" ] || [ -z "$(ls -A "$RUNS")" ]
}

# call_fn <function> [args...]: runs a sourced function of the script in a fresh bash under set -u.
call_fn() {
  run --separate-stderr bash -c 'set -u; . "$1"; shift; "$@"' _ "$SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# the happy path
# ---------------------------------------------------------------------------

@test "start prints exactly one line, the run id, and writes a running state with every step pending" {
  put_demo
  start_run demo --input a=1 --input b=x=y
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  [ -z "$stderr" ]
  run_id="$output"
  [[ "$run_id" =~ ^wf-demo-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$ ]]

  f="$RUNS/$run_id.json"
  [ -f "$f" ]
  jq -e --arg id "$run_id" '
    .schema_version == 1 and .run_id == $id and .workflow_id == "demo" and .status == "running"
    and .inputs.a == "1" and .inputs.b == "x=y"
    and .last_checkpoint == null and .definition_change_ack == null
    and .created_at == .updated_at and (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
    and (.steps | length) == 3
    and ([.steps[].status] | unique) == ["pending"]
    and ([.steps[].outputs] | unique) == [{}]
    and ([.steps[] | .started_at, .finished_at] | unique) == [null]
    and (.definition_hash | test("^[0-9a-f]{64}$"))
    and (.history | length) == 1
    and .history[0].from == null and .history[0].to == "running" and .history[0].note == "started"
    and .history[0].at == .created_at' "$f" >/dev/null
}

@test "step type and checkpoint flags are copied from the definition (checkpoint defaults to false)" {
  put_demo
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  jq -e '[.steps[] | [.id, .type, .checkpoint]] ==
    [["first","skill",true],["second","compute",false],["third","confirm",false]]' \
    "$RUNS/$output.json" >/dev/null
}

@test "an omitted input with a declared default gets the default; a supplied value wins" {
  put_demo
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  jq -e '.inputs == {"a":"1","b":"2","c":"dd"}' "$RUNS/$output.json" >/dev/null

  start_run demo --input a=1 --input b=2 --input c=mine
  [ "$status" -eq 0 ]
  jq -e '.inputs.c == "mine"' "$RUNS/$output.json" >/dev/null
}

@test "a definition with no inputs starts with no --input and stores an empty inputs object" {
  jq -n '{id: "plain", name: "Plain", description: "No inputs.", steps: [{id: "one", type: "skill", skill: "j.status"}]}' \
    > "$WFDIR/plain.json"
  start_run plain
  [ "$status" -eq 0 ]
  jq -e '.inputs == {} and .workflow_id == "plain"' "$RUNS/$output.json" >/dev/null
}

@test "start is the command that creates the runs directory, and only on success" {
  put_demo
  [ ! -e "$RUNS" ]
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  [ -d "$RUNS" ]
}

@test "no temporary or lock entries are left in the runs directory after a successful start" {
  put_demo
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  [ "$(ls -A "$RUNS")" = "$output.json" ]
}

# ---------------------------------------------------------------------------
# definition_hash
# ---------------------------------------------------------------------------

@test "definition_hash is a 64-hex SHA-256 and is stable for the same file" {
  put_demo
  call_fn definition_hash "$WFDIR/demo.json"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
  h1="$output"
  call_fn definition_hash "$WFDIR/demo.json"
  [ "$output" = "$h1" ]
}

@test "definition_hash ignores key order and whitespace" {
  printf '%s\n' '{"id":"x","name":"X","description":"d","steps":[{"id":"s","type":"skill","skill":"j.status","checkpoint":true}]}' > "$BATS_TEST_TMPDIR/a.json"
  cat > "$BATS_TEST_TMPDIR/b.json" <<'JSON'
{
    "steps": [
        {
            "checkpoint": true,
            "skill": "j.status",
            "type": "skill",
            "id": "s"
        }
    ],

    "description": "d",
    "name": "X",
    "id": "x"
}
JSON
  call_fn definition_hash "$BATS_TEST_TMPDIR/a.json"
  [ "$status" -eq 0 ]
  ha="$output"
  call_fn definition_hash "$BATS_TEST_TMPDIR/b.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$ha" ]
}

@test "definition_hash differs when any step field changes" {
  demo_def > "$BATS_TEST_TMPDIR/base.json"
  call_fn definition_hash "$BATS_TEST_TMPDIR/base.json"
  base="$output"

  jq '.steps[1].command = "echo changed"' "$BATS_TEST_TMPDIR/base.json" > "$BATS_TEST_TMPDIR/m1.json"
  jq '.steps[0].checkpoint = false' "$BATS_TEST_TMPDIR/base.json" > "$BATS_TEST_TMPDIR/m2.json"
  jq '.steps[2].prompt = "Go on?"' "$BATS_TEST_TMPDIR/base.json" > "$BATS_TEST_TMPDIR/m3.json"
  jq '.steps |= reverse' "$BATS_TEST_TMPDIR/base.json" > "$BATS_TEST_TMPDIR/m4.json"
  for m in m1 m2 m3 m4; do
    call_fn definition_hash "$BATS_TEST_TMPDIR/$m.json"
    [ "$status" -eq 0 ]
    [ "$output" != "$base" ]
  done
}

@test "definition_hash reads stdin when given no argument or -" {
  demo_def > "$BATS_TEST_TMPDIR/base.json"
  call_fn definition_hash "$BATS_TEST_TMPDIR/base.json"
  from_file="$output"
  run --separate-stderr bash -c '. "$1"; definition_hash < "$2"' _ "$SCRIPT" "$BATS_TEST_TMPDIR/base.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$from_file" ]
  run --separate-stderr bash -c '. "$1"; definition_hash - < "$2"' _ "$SCRIPT" "$BATS_TEST_TMPDIR/base.json"
  [ "$output" = "$from_file" ]
}

@test "definition_hash fails with exit 2 on a missing file and on invalid JSON" {
  call_fn definition_hash "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  printf 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  call_fn definition_hash "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "the hash stored in the state equals definition_hash of the definition file" {
  put_demo
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  stored=$(jq -r '.definition_hash' "$RUNS/$output.json")
  call_fn definition_hash "$WFDIR/demo.json"
  [ "$output" = "$stored" ]
}

@test "two definitions that differ only in layout store the same hash in their runs" {
  put_demo
  start_run demo --input a=1 --input b=2
  h1=$(jq -r '.definition_hash' "$RUNS/$output.json")
  jq -S -c . "$WFDIR/demo.json" > "$WFDIR/demo.tmp" && mv "$WFDIR/demo.tmp" "$WFDIR/demo.json"
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  [ "$(jq -r '.definition_hash' "$RUNS/$output.json")" = "$h1" ]
}

# ---------------------------------------------------------------------------
# refusals: nothing is written
# ---------------------------------------------------------------------------

@test "an unknown workflow id exits non-zero, names the id and creates nothing" {
  put_demo
  start_run no-such-flow
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no-such-flow"* ]]
  assert_runs_untouched
}

@test "a definition that fails validation exits non-zero with the validator's message and creates nothing" {
  jq -n '{id: "broken", name: "Broken", description: "Bad step.", steps: [{id: "s", type: "teleport"}]}' > "$WFDIR/broken.json"
  start_run broken
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"broken"* ]]
  [[ "$stderr" == *"steps[0].type"* ]]
  assert_runs_untouched
}

@test "a missing input exits 2, names the key and creates nothing" {
  put_demo
  start_run demo --input a=1
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"missing input(s): b" ]]
  assert_runs_untouched
}

@test "an input with a default is not reported missing" {
  put_demo
  start_run demo --input a=1
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"missing input(s): b" ]]
}

@test "an unknown input exits 2, names the key and creates nothing" {
  put_demo
  start_run demo --input a=1 --input b=2 --input zeta=9
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unknown input"* ]]
  [[ "$stderr" == *"zeta"* ]]
  assert_runs_untouched
}

@test "missing and unknown inputs are reported together in one message" {
  put_demo
  start_run demo --input zeta=9
  [ "$status" -eq 2 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = "1" ]
  [[ "$stderr" == *"a, b"* ]]
  [[ "$stderr" == *"zeta"* ]]
  assert_runs_untouched
}

@test "a duplicate --input key exits 2, names the key and creates nothing" {
  put_demo
  start_run demo --input a=1 --input a=2 --input b=3
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"duplicate"* ]]
  [[ "$stderr" == *"'a'"* ]]
  assert_runs_untouched
}

@test "refusals leave an existing runs directory exactly as it was (no new file, no leftover .tmp)" {
  put_demo
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  before=$(ls -A "$RUNS")
  start_run demo --input a=1
  [ "$status" -eq 2 ]
  start_run demo --input a=1 --input a=1 --input b=2
  [ "$status" -eq 2 ]
  start_run missing-flow
  [ "$status" -ne 0 ]
  [ "$(ls -A "$RUNS")" = "$before" ]
}

@test "usage errors: no workflow id, two ids, a malformed --input, an unknown option, an invalid id" {
  put_demo
  start_run
  [ "$status" -eq 2 ]
  start_run demo other
  [ "$status" -eq 2 ]
  start_run demo --input
  [ "$status" -eq 2 ]
  start_run demo --input novalue
  [ "$status" -eq 2 ]
  start_run demo --input =v
  [ "$status" -eq 2 ]
  start_run demo --bogus
  [ "$status" -eq 2 ]
  start_run "../etc/passwd"
  [ "$status" -eq 2 ]
  start_run "Demo"
  [ "$status" -eq 2 ]
  assert_runs_untouched
}

@test "--help lists the start command" {
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"start <workflow_id> [--input k=v ...]"* ]]
}

# ---------------------------------------------------------------------------
# unique ids
# ---------------------------------------------------------------------------

# Shims for `date` (fixed second) and `od` (scripted hex), placed first on PATH. Only the exact calls start makes
# are intercepted; everything else goes to the real tool.
make_shims() {
  mkdir -p "$BATS_TEST_TMPDIR/shims"
  REAL_DATE="$(command -v date)"
  REAL_OD="$(command -v od)"
  export REAL_DATE REAL_OD
  cat > "$BATS_TEST_TMPDIR/shims/date" <<'SH'
#!/bin/bash
if [ "$*" = "-u +%Y%m%dT%H%M%SZ" ]; then
  echo 20260101T000000Z
  exit 0
fi
exec "$REAL_DATE" "$@"
SH
  cat > "$BATS_TEST_TMPDIR/shims/od" <<'SH'
#!/bin/bash
case "$*" in
  *-N3*)
    if [ -s "$OD_HEX_FILE" ]; then
      line=$(head -n 1 "$OD_HEX_FILE")
      tail -n +2 "$OD_HEX_FILE" > "$OD_HEX_FILE.next"
      mv "$OD_HEX_FILE.next" "$OD_HEX_FILE"
      echo " ${line:0:2} ${line:2:2} ${line:4:2}"
      exit 0
    fi
    ;;
esac
exec "$REAL_OD" "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/shims/date" "$BATS_TEST_TMPDIR/shims/od"
  export OD_HEX_FILE="$BATS_TEST_TMPDIR/od-hex"
  export PATH="$BATS_TEST_TMPDIR/shims:$PATH"
}

@test "two starts in the same second print different run ids and create two files" {
  put_demo
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  id1="$output"
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  id2="$output"
  [ "$id1" != "$id2" ]
  [ "$(ls "$RUNS" | wc -l | tr -d ' ')" = "2" ]
}

@test "with the clock frozen to one second, two starts still get distinct ids" {
  put_demo
  make_shims
  : > "$OD_HEX_FILE"
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  id1="$output"
  [[ "$id1" == wf-demo-20260101T000000Z-* ]]
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  [[ "$output" == wf-demo-20260101T000000Z-* ]]
  [ "$output" != "$id1" ]
  [ "$(ls "$RUNS" | wc -l | tr -d ' ')" = "2" ]
}

@test "a colliding id is never overwritten: a fresh id is generated and both files survive" {
  put_demo
  make_shims
  printf 'aaaaaa\n' > "$OD_HEX_FILE"
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  [ "$output" = "wf-demo-20260101T000000Z-aaaaaa" ]
  first_bytes=$(cat "$RUNS/$output.json")

  printf 'aaaaaa\nbbbbbb\n' > "$OD_HEX_FILE"
  start_run demo --input a=9 --input b=9
  [ "$status" -eq 0 ]
  [ "$output" = "wf-demo-20260101T000000Z-bbbbbb" ]
  [ "$(cat "$RUNS/wf-demo-20260101T000000Z-aaaaaa.json")" = "$first_bytes" ]
  [ "$(ls "$RUNS" | wc -l | tr -d ' ')" = "2" ]
}

@test "after 5 colliding attempts start exits 1, writes nothing new and leaves the original file untouched" {
  put_demo
  make_shims
  printf 'aaaaaa\n' > "$OD_HEX_FILE"
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  original=$(cat "$RUNS/$output.json")

  printf 'aaaaaa\naaaaaa\naaaaaa\naaaaaa\naaaaaa\naaaaaa\n' > "$OD_HEX_FILE"
  start_run demo --input a=9 --input b=9
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unused run id"* ]]
  [ "$(ls -A "$RUNS" | wc -l | tr -d ' ')" = "1" ]
  [ "$(cat "$RUNS/wf-demo-20260101T000000Z-aaaaaa.json")" = "$original" ]
}

# ---------------------------------------------------------------------------
# the id is a valid run id; the state reads back
# ---------------------------------------------------------------------------

@test "the run id has no slash and passes run_state_path, which resolves to the created file" {
  put_demo
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  id="$output"
  [[ "$id" != */* ]]
  call_fn run_state_path "$id"
  [ "$status" -eq 0 ]
  [ "$output" = "$RUNS/$id.json" ]
  [ -f "$output" ]
}

@test "the state passes run_state_read and status prints it" {
  put_demo
  start_run demo --input a=1 --input b=x=y
  [ "$status" -eq 0 ]
  id="$output"
  call_fn run_state_read "$id"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e --arg id "$id" '.run_id == $id and .status == "running"' >/dev/null

  run --separate-stderr bash "$SCRIPT" status "$id"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.inputs.b == "x=y" and .workflow_id == "demo"' >/dev/null

  run --separate-stderr bash "$SCRIPT" list
  [ "$status" -eq 0 ]
  [[ "$output" == "$id"$'\t'"demo"$'\t'"running"$'\t'* ]]
}

@test "a started run can be changed by run_state_update afterwards" {
  put_demo
  start_run demo --input a=1 --input b=2
  id="$output"
  call_fn run_state_update "$id" '.status = "paused"'
  [ "$status" -eq 0 ]
  jq -e '.status == "paused"' "$RUNS/$id.json" >/dev/null
}

# ---------------------------------------------------------------------------
# relocated tree and registry override
# ---------------------------------------------------------------------------

@test "relocated tree: the definition is read from and the run lands under <anchor>/.project/data/workflow-runs" {
  anchor2="$BATS_TEST_TMPDIR/relocated"
  mkdir -p "$anchor2/.project/configs" "$anchor2/.project/.workflows"
  printf '{"paths":{}}\n' > "$anchor2/.project/configs/workflow.json"
  demo_def > "$anchor2/.project/.workflows/demo.json"
  # A decoy conventional tree must be ignored.
  mkdir -p "$BATS_TEST_TMPDIR/decoy/project/configs"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/decoy/project/configs/workflow.json"
  cd "$BATS_TEST_TMPDIR/decoy"
  export JENGA_PROJECT_ROOT="$anchor2"

  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  [ -f "$anchor2/.project/data/workflow-runs/$output.json" ]
  [ ! -e "$anchor2/project" ]
  [ ! -e "$ANCHOR/project/data" ]
  [ ! -e "$BATS_TEST_TMPDIR/decoy/project/data" ]
}

@test "a workflow_runs registry override is honoured by start" {
  put_demo
  printf '{"paths":{"workflow_runs":"elsewhere/runs"}}\n' > "$ANCHOR/project/configs/workflow.json"
  start_run demo --input a=1 --input b=2
  [ "$status" -eq 0 ]
  [ -f "$ANCHOR/elsewhere/runs/$output.json" ]
  [ ! -e "$RUNS" ]
}

# ---------------------------------------------------------------------------
# internals
# ---------------------------------------------------------------------------

@test "__create refuses to overwrite an existing state file (exit 9) and leaves it byte-identical" {
  put_demo
  start_run demo --input a=1 --input b=2
  id="$output"
  before=$(cat "$RUNS/$id.json")
  run --separate-stderr bash "$SCRIPT" __create "$id" "$before"
  [ "$status" -eq 9 ]
  [ "$(cat "$RUNS/$id.json")" = "$before" ]
  [ "$(ls -A "$RUNS")" = "$id.json" ]
}

@test "__create rejects a document that is not a valid state and leaves nothing behind" {
  mkdir -p "$RUNS"
  run --separate-stderr bash "$SCRIPT" __create wf-x-1 '{"not":"a state"}'
  [ "$status" -eq 12 ]
  [ -z "$(ls -A "$RUNS")" ]
}

@test "script header documents start, definition_hash and the E80_S01 interface adaptation" {
  grep -q 'run-state.sh start <workflow_id> \[--input k=v ...\]' "$SCRIPT"
  grep -q 'definition_hash \[<file>|-\]' "$SCRIPT"
  grep -q 'takes no arguments and prints the whole' "$SCRIPT"
}

@test "the script still names no working-file tree literal" {
  run grep -nE '\.?project/' "$SCRIPT"
  [ "$status" -eq 1 ]
  run grep -n '\.project' "$SCRIPT"
  [ "$status" -eq 1 ]
}
