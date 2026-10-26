#!/usr/bin/env bats
#
# E80_S04_T04: scripts/workflow/artifacts.sh register records a workflow output in the per-run registry.
# E80_S04_T05: its read side (list, get, latest) with run-status filtering, at the end of this file.
#
# Every case builds its own throwaway tree under $BATS_TEST_TMPDIR and anchors it with JENGA_PROJECT_ROOT, so
# nothing here reads or writes this repository's data. The expected locations are always asked of
# scripts/resolve-root.sh (get workflow_artifacts); no working-file path is typed into an assertion.
#
# Mirror safety: this file ships to the public mirror. It depends only on scripts/workflow/artifacts.sh,
# scripts/resolve-root.sh, scripts/with-lock.sh and fixtures it builds. The "project" / ".project" strings below
# are registry-layout directory names written into scratch trees only.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/artifacts.sh"
RESOLVE="$REPO_ROOT/scripts/resolve-root.sh"

# The script is bash 3.2 compatible; run it under the system bash (3.2 on macOS) when there is one.
BASH_BIN="bash"
if [ -x /bin/bash ]; then BASH_BIN="/bin/bash"; fi

setup() {
  unset JENGA_PROJECT_ROOT JENGA_WORKFLOWS_TEST_ROOT WITH_LOCK_TIMEOUT_SECONDS
  ROOT="$BATS_TEST_TMPDIR/root"
  SRC="$BATS_TEST_TMPDIR/src"
  mkdir -p "$SRC"
  make_tree "$ROOT" project
  printf 'first body\n' > "$SRC/a.txt"
  printf 'second body\n' > "$SRC/b.txt"
  AROOT="$(artifacts_root "$ROOT")"
}

# Builds fixture tree $1/$2 with a registry whose paths map is $3 (default empty).
make_tree() {
  local paths="${3:-}"
  [ -n "$paths" ] || paths='{}'
  mkdir -p "$1/$2/configs"
  printf '{"paths":%s}\n' "$paths" > "$1/$2/configs/workflow.json"
}

# Asks the real resolver where the artifacts root of tree anchored at $1 is.
artifacts_root() {
  JENGA_PROJECT_ROOT="$1" bash "$RESOLVE" get workflow_artifacts
}

# register <args...>: runs the script anchored at $ROOT with stdout in $output and stderr in $stderr.
reg() {
  run --separate-stderr env JENGA_PROJECT_ROOT="$ROOT" "$BASH_BIN" "$SCRIPT" register "$@"
}

hash_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# Lists every path under $AROOT (empty when it does not exist), for "nothing was written" comparisons.
snapshot() {
  if [ -d "$AROOT" ]; then (cd "$AROOT" && find . | LC_ALL=C sort); fi
}

# ---- the script itself --------------------------------------------------------------------------------------

@test "script exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  bash -n "$SCRIPT"
}

@test "script header documents usage, layout, rules and exit codes; -h and --help print usage" {
  run grep -c -E '^# (USAGE|LAYOUT|RULES|EXIT CODES)' "$SCRIPT"
  [ "$output" -eq 4 ]
  run --separate-stderr "$BASH_BIN" "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"artifacts.sh register"* ]]
  [ -z "$stderr" ]
  run --separate-stderr "$BASH_BIN" "$SCRIPT" -h
  [ "$status" -eq 0 ]
}

@test "script names no project/ working-file literal on a code line" {
  run bash -c "grep -v -E '^[[:space:]]*#' '$SCRIPT' | grep -F 'project/'"
  [ "$status" -ne 0 ]
}

# ---- the happy path -----------------------------------------------------------------------------------------

@test "register copies the file under the run directory and writes one record with exactly 9 fields" {
  reg wf1 run1 step1 sprint.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 0 ] || { echo "stderr=[$stderr]"; false; }
  [ -f "$AROOT/wf1/run1/sprint.md" ]
  cmp -s "$SRC/a.txt" "$AROOT/wf1/run1/sprint.md"
  [ "$(wc -l < "$AROOT/wf1/run1/outputs.jsonl" | tr -d ' ')" -eq 1 ]
  rec="$(cat "$AROOT/wf1/run1/outputs.jsonl")"
  [ "$(printf '%s' "$rec" | jq 'keys | length')" -eq 9 ]
  [ "$(printf '%s' "$rec" | jq -r 'keys | join(",")')" = "created_at,kind,name,path,run_id,sha256,step_id,type,workflow_id" ]
  [ "$(printf '%s' "$rec" | jq -r .workflow_id)" = wf1 ]
  [ "$(printf '%s' "$rec" | jq -r .run_id)" = run1 ]
  [ "$(printf '%s' "$rec" | jq -r .step_id)" = step1 ]
  [ "$(printf '%s' "$rec" | jq -r .name)" = sprint.md ]
  [ "$(printf '%s' "$rec" | jq -r .kind)" = artifact ]
  [ "$(printf '%s' "$rec" | jq -r .type)" = text ]
  # the record is printed on stdout too
  [ "$output" = "$rec" ]
}

@test "the sha256 equals an independent hash and the path is relative to the root" {
  reg wf1 run1 step1 sprint.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 0 ]
  rec="$(cat "$AROOT/wf1/run1/outputs.jsonl")"
  [ "$(printf '%s' "$rec" | jq -r .sha256)" = "$(hash_of "$SRC/a.txt")" ]
  [ "$(printf '%s' "$rec" | jq -r .path)" = "wf1/run1/sprint.md" ]
  [ -f "$AROOT/$(printf '%s' "$rec" | jq -r .path)" ]
}

@test "created_at is UTC ISO 8601" {
  reg wf1 run1 step1 sprint.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 0 ]
  ts="$(jq -r .created_at "$AROOT/wf1/run1/outputs.jsonl")"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "kind data is accepted and recorded as data" {
  reg wf1 run1 step1 count --kind data --type number --file "$SRC/b.txt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .kind "$AROOT/wf1/run1/outputs.jsonl")" = data ]
  [ "$(jq -r .type "$AROOT/wf1/run1/outputs.jsonl")" = number ]
}

@test "two registrations for different names in the same run both persist" {
  reg wf1 run1 step1 one.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 0 ]
  reg wf1 run1 step2 two.md --kind artifact --type text --file "$SRC/b.txt"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$AROOT/wf1/run1/outputs.jsonl" | tr -d ' ')" -eq 2 ]
  [ -f "$AROOT/wf1/run1/one.md" ]
  [ -f "$AROOT/wf1/run1/two.md" ]
  [ "$(jq -r .name "$AROOT/wf1/run1/outputs.jsonl" | tr '\n' ' ')" = "one.md two.md " ]
}

@test "no temporary files are left behind after a successful register" {
  reg wf1 run1 step1 one.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 0 ]
  run bash -c "ls -A '$AROOT/wf1/run1'"
  [ "$(printf '%s\n' "$output" | LC_ALL=C sort | tr '\n' ' ')" = "one.md outputs.jsonl " ]
}

@test "concurrent registrations of different names in one run all persist" {
  for n in 1 2 3 4 5 6; do
    ( JENGA_PROJECT_ROOT="$ROOT" "$BASH_BIN" "$SCRIPT" register wf1 run1 "s$n" "out$n.md" --kind artifact --type text --file "$SRC/a.txt" >/dev/null 2>&1 ) &
  done
  wait
  [ "$(wc -l < "$AROOT/wf1/run1/outputs.jsonl" | tr -d ' ')" -eq 6 ]
  [ "$(jq -r .name "$AROOT/wf1/run1/outputs.jsonl" | sort -u | wc -l | tr -d ' ')" -eq 6 ]
  for n in 1 2 3 4 5 6; do [ -f "$AROOT/wf1/run1/out$n.md" ]; done
}

# ---- duplicates, --replace and run isolation ----------------------------------------------------------------

@test "the same name twice fails without --replace and leaves the first record and file byte-identical" {
  reg wf1 run1 step1 sprint.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 0 ]
  before_idx="$(cksum < "$AROOT/wf1/run1/outputs.jsonl")"
  before_file="$(cksum < "$AROOT/wf1/run1/sprint.md")"
  reg wf1 run1 step9 sprint.md --kind artifact --type text --file "$SRC/b.txt"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"already registered"* ]]
  [ "$(cksum < "$AROOT/wf1/run1/outputs.jsonl")" = "$before_idx" ]
  [ "$(cksum < "$AROOT/wf1/run1/sprint.md")" = "$before_file" ]
  [ "$(wc -l < "$AROOT/wf1/run1/outputs.jsonl" | tr -d ' ')" -eq 1 ]
}

@test "--replace swaps only that run's own record and file for the name" {
  reg wf1 run1 step1 keep.md --kind artifact --type text --file "$SRC/a.txt"
  reg wf1 run1 step1 sprint.md --kind artifact --type text --file "$SRC/a.txt"
  reg wf1 run2 step1 sprint.md --kind artifact --type text --file "$SRC/a.txt"
  other_idx="$(cksum < "$AROOT/wf1/run2/outputs.jsonl")"
  other_file="$(cksum < "$AROOT/wf1/run2/sprint.md")"
  keep_rec="$(jq -c 'select(.name == "keep.md")' "$AROOT/wf1/run1/outputs.jsonl")"
  reg wf1 run1 step2 sprint.md --kind artifact --type markdown --file "$SRC/b.txt" --replace
  [ "$status" -eq 0 ] || { echo "stderr=[$stderr]"; false; }
  [ "$(wc -l < "$AROOT/wf1/run1/outputs.jsonl" | tr -d ' ')" -eq 2 ]
  cmp -s "$SRC/b.txt" "$AROOT/wf1/run1/sprint.md"
  [ "$(jq -r 'select(.name == "sprint.md") | .step_id + " " + .type + " " + .sha256' "$AROOT/wf1/run1/outputs.jsonl")" = "step2 markdown $(hash_of "$SRC/b.txt")" ]
  [ "$(jq -c 'select(.name == "keep.md")' "$AROOT/wf1/run1/outputs.jsonl")" = "$keep_rec" ]
  [ "$(cksum < "$AROOT/wf1/run2/outputs.jsonl")" = "$other_idx" ]
  [ "$(cksum < "$AROOT/wf1/run2/sprint.md")" = "$other_file" ]
}

@test "--replace on a name not yet recorded just registers it" {
  reg wf1 run1 step1 sprint.md --kind artifact --type text --file "$SRC/a.txt" --replace
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$AROOT/wf1/run1/outputs.jsonl" | tr -d ' ')" -eq 1 ]
}

@test "the same name under a different run id succeeds and leaves the first run untouched" {
  reg wf1 run1 step1 sprint.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 0 ]
  before_idx="$(cksum < "$AROOT/wf1/run1/outputs.jsonl")"
  before_file="$(cksum < "$AROOT/wf1/run1/sprint.md")"
  reg wf1 run2 step1 sprint.md --kind artifact --type text --file "$SRC/b.txt"
  [ "$status" -eq 0 ]
  cmp -s "$SRC/b.txt" "$AROOT/wf1/run2/sprint.md"
  [ "$(cksum < "$AROOT/wf1/run1/outputs.jsonl")" = "$before_idx" ]
  [ "$(cksum < "$AROOT/wf1/run1/sprint.md")" = "$before_file" ]
  [ "$(wc -l < "$AROOT/wf1/run2/outputs.jsonl" | tr -d ' ')" -eq 1 ]
}

@test "the same name under a different workflow id is a separate registry" {
  reg wf1 run1 step1 sprint.md --kind artifact --type text --file "$SRC/a.txt"
  reg wf2 run1 step1 sprint.md --kind artifact --type text --file "$SRC/b.txt"
  [ "$status" -eq 0 ]
  cmp -s "$SRC/a.txt" "$AROOT/wf1/run1/sprint.md"
  cmp -s "$SRC/b.txt" "$AROOT/wf2/run1/sprint.md"
}

# ---- rejected input writes nothing -------------------------------------------------------------------------

@test "a name containing /, .. or a leading . is rejected with a message and writes nothing" {
  for bad in "a/b" "../escape" ".hidden" "a..b" "/abs" "x/../y" ".." "-" ""; do
    before="$(snapshot)"
    reg wf1 run1 step1 "$bad" --kind artifact --type text --file "$SRC/a.txt"
    [ "$status" -ne 0 ] || { echo "accepted name [$bad]"; false; }
    [ -z "$output" ]
    [ -n "$stderr" ] || { echo "no message for [$bad]"; false; }
    [ "$(snapshot)" = "$before" ] || { echo "wrote something for [$bad]"; false; }
  done
  [ ! -e "$AROOT" ]
  [ ! -e "$BATS_TEST_TMPDIR/escape" ]
}

@test "a workflow id, run id or step id with /, .. or a leading . is rejected and writes nothing" {
  for bad in "a/b" "../x" ".hid" "a..b" "" "a b"; do
    reg "$bad" run1 step1 n.md --kind artifact --type text --file "$SRC/a.txt"
    [ "$status" -ne 0 ] || { echo "accepted workflow [$bad]"; false; }
    reg wf1 "$bad" step1 n.md --kind artifact --type text --file "$SRC/a.txt"
    [ "$status" -ne 0 ] || { echo "accepted run [$bad]"; false; }
    reg wf1 run1 "$bad" n.md --kind artifact --type text --file "$SRC/a.txt"
    [ "$status" -ne 0 ] || { echo "accepted step [$bad]"; false; }
  done
  [ ! -e "$AROOT" ]
}

@test "a name with a newline in it cannot slip past the token check" {
  reg wf1 run1 step1 $'ok\n/etc/x' --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -ne 0 ]
  [ ! -e "$AROOT" ]
}

@test "the registry's own file name is reserved" {
  for bad in outputs.jsonl outputs.jsonl.lock.d outputs.jsonl.tmp; do
    reg wf1 run1 step1 "$bad" --kind artifact --type text --file "$SRC/a.txt"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"reserved"* ]]
  done
  [ ! -e "$AROOT" ]
}

@test "a bad kind, a bad type or a missing file is rejected and writes nothing" {
  reg wf1 run1 step1 n.md --kind other --type text --file "$SRC/a.txt"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"kind"* ]]
  reg wf1 run1 step1 n.md --kind artifact --type "te/xt" --file "$SRC/a.txt"
  [ "$status" -eq 1 ]
  reg wf1 run1 step1 n.md --kind artifact --type text --file "$SRC/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"regular file"* ]]
  reg wf1 run1 step1 n.md --kind artifact --type text --file "$SRC"
  [ "$status" -eq 1 ]
  [ ! -e "$AROOT" ]
}

@test "missing arguments and unknown options are usage errors with exit 2" {
  reg wf1 run1 step1 n.md --kind artifact --type text
  [ "$status" -eq 2 ]
  reg wf1 run1 step1 --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 2 ]
  reg wf1 run1 step1 n.md --kind artifact --type text --file "$SRC/a.txt" --bogus
  [ "$status" -eq 2 ]
  reg wf1 run1 step1 n.md extra --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 2 ]
  reg wf1 run1 step1 n.md --kind
  [ "$status" -eq 2 ]
  run --separate-stderr "$BASH_BIN" "$SCRIPT"
  [ "$status" -eq 2 ]
  run --separate-stderr "$BASH_BIN" "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
  [ ! -e "$AROOT" ]
}

# ---- the root comes from the resolver ----------------------------------------------------------------------

@test "a conventional tree publishes under the resolver's workflow_artifacts directory" {
  reg wf1 run1 step1 n.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 0 ]
  [ "$AROOT" = "$(cd -P "$ROOT" && pwd -P)/project/data/workflow-artifacts" ] || [ "$AROOT" = "$ROOT/project/data/workflow-artifacts" ]
  [ -f "$AROOT/wf1/run1/n.md" ]
}

@test "a relocated .project tree publishes under its own workflow_artifacts directory" {
  local alt="$BATS_TEST_TMPDIR/alt"
  make_tree "$alt" .project '{"workflow_artifacts":".project/out/wf-artifacts"}'
  expect="$(artifacts_root "$alt")"
  case "$expect" in */.project/out/wf-artifacts) ;; *) echo "resolver said [$expect]"; false ;; esac
  run --separate-stderr env JENGA_PROJECT_ROOT="$alt" "$BASH_BIN" "$SCRIPT" register wfx runx stepx n.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 0 ] || { echo "stderr=[$stderr]"; false; }
  [ -f "$expect/wfx/runx/n.md" ]
  [ -f "$expect/wfx/runx/outputs.jsonl" ]
  # nothing went to the conventional location
  [ ! -e "$alt/project" ]
  [ ! -e "$AROOT" ]
}

@test "a registry override moves the root without touching the script" {
  make_tree "$ROOT" project '{"workflow_artifacts":"project/elsewhere"}'
  reg wf1 run1 step1 n.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 0 ]
  [ -f "$(artifacts_root "$ROOT")/wf1/run1/n.md" ]
  case "$(artifacts_root "$ROOT")" in */project/elsewhere) ;; *) false ;; esac
}

@test "an unresolvable root exits 3 and writes nothing" {
  local bare="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$bare"
  run --separate-stderr env JENGA_PROJECT_ROOT="$bare" "$BASH_BIN" "$SCRIPT" register wf1 run1 step1 n.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
  [ -z "$(ls -A "$bare")" ]
}

# ---- the lock -----------------------------------------------------------------------------------------------

@test "when the lock cannot be acquired register exits non-zero and writes neither file nor record" {
  # with-lock.sh keys its lock directory on <target>.lock.d; a held one makes the acquire time out.
  mkdir -p "$AROOT/wf1/run1/outputs.jsonl.lock.d"
  before="$(snapshot)"
  run --separate-stderr env JENGA_PROJECT_ROOT="$ROOT" WITH_LOCK_TIMEOUT_SECONDS=1 WITH_LOCK_POLL_SECONDS=0.1 "$BASH_BIN" "$SCRIPT" register wf1 run1 step1 n.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"lock"* ]]
  [ ! -e "$AROOT/wf1/run1/n.md" ]
  [ ! -e "$AROOT/wf1/run1/outputs.jsonl" ]
  [ "$(snapshot)" = "$before" ]
}

@test "a lock timeout on a replace leaves the existing record and file untouched" {
  reg wf1 run1 step1 n.md --kind artifact --type text --file "$SRC/a.txt"
  before_idx="$(cksum < "$AROOT/wf1/run1/outputs.jsonl")"
  before_file="$(cksum < "$AROOT/wf1/run1/n.md")"
  mkdir -p "$AROOT/wf1/run1/outputs.jsonl.lock.d"
  run --separate-stderr env JENGA_PROJECT_ROOT="$ROOT" WITH_LOCK_TIMEOUT_SECONDS=1 WITH_LOCK_POLL_SECONDS=0.1 "$BASH_BIN" "$SCRIPT" register wf1 run1 step2 n.md --kind artifact --type text --file "$SRC/b.txt" --replace
  [ "$status" -ne 0 ]
  [ "$(cksum < "$AROOT/wf1/run1/outputs.jsonl")" = "$before_idx" ]
  [ "$(cksum < "$AROOT/wf1/run1/n.md")" = "$before_file" ]
}

@test "the lock is released after a register so the next one is not blocked" {
  reg wf1 run1 step1 one.md --kind artifact --type text --file "$SRC/a.txt"
  [ ! -e "$AROOT/wf1/run1/outputs.jsonl.lock.d" ]
}

# ---- E80_S04_T05: the read side (list, get, latest) ---------------------------------------------------------
#
# The registry is built with the real `register`, then each record's created_at is rewritten so ordering is
# exact and never depends on the clock. Run state is a fixture tree of state files the test writes into the
# runs directory the resolver reports; this repository's own run state is never read.

# rd <args...>: runs the script anchored at $ROOT with stdout in $output and stderr in $stderr.
rd() {
  run --separate-stderr env JENGA_PROJECT_ROOT="$ROOT" "$BASH_BIN" "$SCRIPT" "$@"
}

# state <run_id> <status> [workflow_id]: writes a schema-1 run-state file for the run.
state() {
  local dir
  dir="$(JENGA_PROJECT_ROOT="$ROOT" bash "$RESOLVE" get workflow_runs)"
  mkdir -p "$dir"
  jq -n --arg r "$1" --arg s "$2" --arg w "${3:-sprint}" '{
    schema_version: 1, run_id: $r, workflow_id: $w, definition_hash: "h", inputs: {}, status: $s,
    created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z", last_checkpoint: null,
    definition_change_ack: null, steps: [], history: []}' > "$dir/$1.json"
}

# put <workflow_id> <run_id> <name> <created_at> [body]: registers the output and pins its created_at.
put() {
  local idx
  printf '%s\n' "${5:-body of $2}" > "$SRC/put.tmp"
  JENGA_PROJECT_ROOT="$ROOT" "$BASH_BIN" "$SCRIPT" register "$1" "$2" step1 "$3" --kind artifact --type text \
    --file "$SRC/put.tmp" >/dev/null 2>&1
  idx="$AROOT/$1/$2/outputs.jsonl"
  jq -c --arg c "$4" '.created_at = $c' "$idx" > "$idx.new" && mv "$idx.new" "$idx"
}

# Three completed runs of workflow sprint, r1 oldest.
three_completed() {
  state r1 completed; state r2 completed; state r3 completed
  put sprint r1 sprint.md 2026-02-01T00:00:00Z
  put sprint r2 sprint.md 2026-02-02T00:00:00Z
  put sprint r3 sprint.md 2026-02-03T00:00:00Z
}

@test "read: list on an empty or missing registry prints [] and exits 0" {
  rd list
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '. == []'
  [ -z "$stderr" ]
}

@test "read: list returns every record across workflows, each with run_status, sorted by created_at, run_id, name" {
  state r1 completed; state r2 failed; state r3 running; state r4 completed other
  put sprint r2 b.md 2026-02-02T00:00:00Z
  put sprint r1 z.md 2026-02-01T00:00:00Z
  put sprint r1 a.md 2026-02-01T00:00:00Z
  put sprint r3 a.md 2026-02-02T00:00:00Z
  put other r4 x.md 2026-01-01T00:00:00Z
  rd list
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'length == 5'
  printf '%s' "$output" | jq -e 'all(has("run_status") and (keys | length) == 10)'
  [ "$(printf '%s' "$output" | jq -r 'map(.run_id + ":" + .name) | join(" ")')" = "r4:x.md r1:a.md r1:z.md r2:b.md r3:a.md" ]
  [ "$(printf '%s' "$output" | jq -r 'map(.run_status) | join(" ")')" = "completed completed completed failed running" ]
}

@test "read: list --workflow, --run and both together filter correctly" {
  state r1 completed; state r2 completed; state r4 completed other
  put sprint r1 a.md 2026-02-01T00:00:00Z
  put sprint r2 a.md 2026-02-02T00:00:00Z
  put sprint r2 b.md 2026-02-02T00:00:00Z
  put other r4 a.md 2026-02-04T00:00:00Z
  rd list --workflow sprint
  printf '%s' "$output" | jq -e 'length == 3 and all(.workflow_id == "sprint")'
  rd list --run r2
  printf '%s' "$output" | jq -e 'length == 2 and all(.run_id == "r2")'
  rd list --workflow sprint --run r2
  printf '%s' "$output" | jq -e 'length == 2 and all(.run_id == "r2" and .workflow_id == "sprint")'
  rd list --workflow other --run r2
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '. == []'
  rd list --workflow nosuch
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '. == []'
}

@test "read: list shows a run whose state is gone as unknown" {
  state r1 completed
  put sprint r1 a.md 2026-02-01T00:00:00Z
  put sprint ghost a.md 2026-02-02T00:00:00Z
  rd list --workflow sprint
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.run_id == "ghost") | .run_status')" = unknown ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.run_id == "r1") | .run_status')" = completed ]
}

@test "read: a corrupt run-state file is unknown, not a crash" {
  state r1 completed
  printf 'not json' > "$(JENGA_PROJECT_ROOT="$ROOT" bash "$RESOLVE" get workflow_runs)/r1.json"
  put sprint r1 a.md 2026-02-01T00:00:00Z
  rd list
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].run_status')" = unknown ]
}

@test "read: latest returns the newest completed run among 3 and moves forward when a 4th completes" {
  three_completed
  rd latest sprint sprint.md
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.run_id == "r3" and .run_status == "completed" and .name == "sprint.md"'
  state r4 completed
  put sprint r4 sprint.md 2026-02-04T00:00:00Z
  rd latest sprint sprint.md
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.run_id == "r4"'
}

@test "read: latest breaks a created_at tie by run_id" {
  state ra completed; state rb completed
  put sprint ra sprint.md 2026-02-01T00:00:00Z
  put sprint rb sprint.md 2026-02-01T00:00:00Z
  rd latest sprint sprint.md
  printf '%s' "$output" | jq -e '.run_id == "rb"'
}

@test "read: latest only considers the named output and workflow" {
  three_completed
  state r9 completed other
  put sprint r3 notes.md 2026-02-09T00:00:00Z
  put other r9 sprint.md 2026-02-10T00:00:00Z
  rd latest sprint sprint.md
  printf '%s' "$output" | jq -e '.run_id == "r3" and .workflow_id == "sprint" and .name == "sprint.md"'
}

@test "read: latest skips newer failed and cancelled runs; get --run still returns a failed run's record" {
  state r1 completed; state r2 completed; state r3 failed; state r4 cancelled
  put sprint r1 sprint.md 2026-02-01T00:00:00Z
  put sprint r2 sprint.md 2026-02-02T00:00:00Z
  put sprint r3 sprint.md 2026-02-03T00:00:00Z
  put sprint r4 sprint.md 2026-02-04T00:00:00Z
  rd latest sprint sprint.md
  printf '%s' "$output" | jq -e '.run_id == "r2"'
  rd get sprint sprint.md
  printf '%s' "$output" | jq -e '.run_id == "r2"'
  rd get sprint sprint.md --run r3
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.run_id == "r3" and .run_status == "failed"'
  rd get sprint sprint.md --run r4
  printf '%s' "$output" | jq -e '.run_id == "r4" and .run_status == "cancelled"'
}

@test "read: latest skips running, paused, awaiting_confirmation and unknown runs" {
  state r1 completed; state r2 running; state r3 paused; state r4 awaiting_confirmation
  put sprint r1 sprint.md 2026-02-01T00:00:00Z
  put sprint r2 sprint.md 2026-02-02T00:00:00Z
  put sprint r3 sprint.md 2026-02-03T00:00:00Z
  put sprint r4 sprint.md 2026-02-04T00:00:00Z
  put sprint r5 sprint.md 2026-02-05T00:00:00Z
  rd latest sprint sprint.md
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.run_id == "r1"'
}

@test "read: latest on a name that only exists in non-completed runs exits non-zero, says so and prints no JSON" {
  state r1 failed; state r2 cancelled
  put sprint r1 sprint.md 2026-02-01T00:00:00Z
  put sprint r2 sprint.md 2026-02-02T00:00:00Z
  put sprint r3 sprint.md 2026-02-03T00:00:00Z
  rd latest sprint sprint.md
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"none belongs to a completed run"* ]]
  [[ "$stderr" == *"sprint.md"* ]]
  # the unreadable state of r3 is explained
  [[ "$stderr" == *"r3"* ]]
  [[ "$stderr" == *"not found"* ]]
}

@test "read: unknown workflow and unknown name exit non-zero naming the missing item and print no JSON" {
  three_completed
  rd latest nosuch sprint.md
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"nosuch"* ]]
  rd latest sprint nosuch.md
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"nosuch.md"* ]]
  rd get nosuch sprint.md
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"nosuch"* ]]
  rd get sprint nosuch.md
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"nosuch.md"* ]]
  rd get sprint sprint.md --run nosuchrun
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"nosuchrun"* ]]
}

@test "read: with no registry at all, latest and get exit non-zero and print nothing on stdout" {
  rd latest sprint sprint.md
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  rd get sprint sprint.md --path
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "read: get --path and latest --path print an absolute path of a file that exists, and nothing else" {
  three_completed
  rd latest sprint sprint.md --path
  [ "$status" -eq 0 ]
  [[ "$output" == /* ]]
  [ -f "$output" ]
  [ "$output" = "$AROOT/sprint/r3/sprint.md" ]
  [ "$(cat "$output")" = "body of r3" ]
  rd get sprint sprint.md --run r1 --path
  [ "$status" -eq 0 ]
  [[ "$output" == /* ]]
  [ -f "$output" ]
  [ "$(cat "$output")" = "body of r1" ]
  rd get sprint sprint.md --path
  [ "$(cat "$output")" = "body of r3" ]
}

@test "read: --path reports a record whose file has gone missing instead of printing a dead path" {
  three_completed
  rm -f "$AROOT/sprint/r3/sprint.md"
  rd latest sprint sprint.md --path
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"does not exist"* ]]
}

@test "read: list, get and latest output parses with jq -e" {
  three_completed
  rd list
  printf '%s' "$output" | jq -e 'type == "array"'
  rd get sprint sprint.md
  printf '%s' "$output" | jq -e 'type == "object" and .run_status == "completed"'
  rd latest sprint sprint.md
  printf '%s' "$output" | jq -e 'type == "object" and (.path | startswith("sprint/"))'
}

@test "read: a fresh process with only JENGA_PROJECT_ROOT set returns what an earlier process registered" {
  state r1 completed
  JENGA_PROJECT_ROOT="$ROOT" "$BASH_BIN" "$SCRIPT" register sprint r1 step1 sprint.md --kind artifact --type text \
    --file "$SRC/a.txt" >/dev/null 2>&1
  run --separate-stderr env -i PATH="$PATH" JENGA_PROJECT_ROOT="$ROOT" "$BASH_BIN" "$SCRIPT" latest sprint sprint.md
  [ "$status" -eq 0 ] || { echo "stderr=[$stderr]"; false; }
  printf '%s' "$output" | jq -e '.run_id == "r1" and .run_status == "completed"'
  run --separate-stderr env -i PATH="$PATH" JENGA_PROJECT_ROOT="$ROOT" "$BASH_BIN" "$SCRIPT" list
  printf '%s' "$output" | jq -e 'length == 1'
}

@test "read: usage errors exit 2 and bad ids exit 1" {
  rd get onlyone
  [ "$status" -eq 2 ]
  rd latest sprint
  [ "$status" -eq 2 ]
  rd latest sprint sprint.md --run r1
  [ "$status" -eq 2 ]
  rd list --path
  [ "$status" -eq 2 ]
  rd list extra
  [ "$status" -eq 2 ]
  rd list --workflow
  [ "$status" -eq 2 ]
  rd get ../x sprint.md
  [ "$status" -eq 1 ]
  rd list --run 'a/b'
  [ "$status" -eq 1 ]
}

@test "read: the read commands write nothing under the artifacts root" {
  three_completed
  before="$(snapshot)"
  rd list; rd latest sprint sprint.md; rd get sprint sprint.md --run r1; rd latest sprint sprint.md --path
  [ "$(snapshot)" = "$before" ]
}

@test "read: register no longer prints an unbound-variable error from its exit trap" {
  reg wf1 run1 step1 sprint.md --kind artifact --type text --file "$SRC/a.txt"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"unbound variable"* ]]
  [ -z "$stderr" ]
}
