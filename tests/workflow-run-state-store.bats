#!/usr/bin/env bats
#
# E80_S02_T03: scripts/workflow/run-state.sh core - state file format v1, the locked atomic writer
# (run_state_update), corrupt-file detection, and the read-only commands status and list.
#
# Every test builds its own throwaway working-file tree under $BATS_TEST_TMPDIR and exports JENGA_PROJECT_ROOT at
# it, so the real runs directory of this repository is never read or written.
#
# Mirror safety: depends only on scripts/workflow/run-state.sh, scripts/resolve-root.sh, scripts/with-lock.sh and
# fixtures it builds. The working-file tree names in the fixtures are registry-layout directory names, written
# into scratch trees only.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/run-state.sh"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS
  mkdir -p "$BATS_TEST_TMPDIR/anchor/project/configs"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/anchor/project/configs/workflow.json"
  ANCHOR="$(cd "$BATS_TEST_TMPDIR/anchor" && pwd)"
  RUNS="$ANCHOR/project/data/workflow-runs"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  cd "$BATS_TEST_TMPDIR" || return 1
}

# write_run <runs-dir> <id> <created_at> [workflow_id] [status]: a valid state file.
write_run() {
  mkdir -p "$1"
  jq -n --arg id "$2" --arg c "$3" --arg wf "${4:-wf-a}" --arg st "${5:-running}" '{
    schema_version: 1, run_id: $id, workflow_id: $wf, definition_hash: "abc123",
    inputs: {k: "v"}, status: $st, created_at: $c, updated_at: $c,
    last_checkpoint: null, definition_change_ack: null,
    steps: [{id: "s1", type: "command", checkpoint: false, status: "pending",
             started_at: null, finished_at: null, outputs: {}}],
    history: []
  }' > "$1/$2.json"
}

# call_fn <function> [args...]: runs a sourced function of the script in a fresh bash under set -u.
call_fn() {
  run --separate-stderr bash -c 'set -u; . "$1"; shift; "$@"' _ "$SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# shape: executable, syntax, sourceable, header, no tree literal
# ---------------------------------------------------------------------------

@test "script exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "sourcing prints nothing, exits cleanly and creates nothing, even under set -u" {
  mkdir "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr bash -c 'set -u; cd "$2" && . "$1" && type run_state_path run_state_read run_state_update run_state_dir >/dev/null && echo sourced-ok' _ "$SCRIPT" "$BATS_TEST_TMPDIR/empty"
  [ "$status" -eq 0 ]
  [ "$output" = "sourced-ok" ]
  [ -z "$stderr" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/empty")" ]
  [ ! -e "$RUNS" ]
}

@test "header documents every state-file field, every command and exit codes 0 to 6" {
  local header
  header=$(sed -n '1,/^_RS_SELF=/p' "$SCRIPT")
  local field
  for field in schema_version run_id workflow_id definition_hash inputs status created_at updated_at \
               last_checkpoint definition_change_ack steps history checkpoint started_at finished_at outputs \
               '"at"' '"from"' '"to"' '"note"' running paused awaiting_confirmation failed completed cancelled \
               pending in_progress skipped; do
    printf '%s\n' "$header" | grep -q -- "$field" || { echo "header lacks: $field"; return 1; }
  done
  printf '%s\n' "$header" | grep -Eq '^#   run-state\.sh status <run_id>'
  printf '%s\n' "$header" | grep -Eq '^#   run-state\.sh list'
  printf '%s\n' "$header" | grep -Eq '^#   run-state\.sh -h \| --help'
  local fn
  for fn in run_state_path run_state_read run_state_update run_state_dir; do
    printf '%s\n' "$header" | grep -Eq "^#   $fn" || { echo "header lacks function: $fn"; return 1; }
  done
  local code
  for code in 0 1 2 3 4 5 6; do
    printf '%s\n' "$header" | grep -Eq "^#   $code  " || { echo "header lacks exit code $code"; return 1; }
  done
}

@test "script contains no working-file tree literal" {
  run grep -nE '\.?project/' "$SCRIPT"
  [ "$status" -eq 1 ]
  run grep -n '\.project' "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "the runs location comes from the resolver: a registry override is honoured" {
  printf '{"paths":{"workflow_runs":"elsewhere/runs"}}\n' > "$ANCHOR/project/configs/workflow.json"
  call_fn run_state_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$ANCHOR/elsewhere/runs" ]
}

# ---------------------------------------------------------------------------
# run_state_path / run_state_dir
# ---------------------------------------------------------------------------

@test "run_state_path prints <runs dir>/<id>.json for a valid id and touches no disk" {
  call_fn run_state_path "run-1.a_b"
  [ "$status" -eq 0 ]
  [ "$output" = "$RUNS/run-1.a_b.json" ]
  [ ! -e "$ANCHOR/project/data" ]
}

@test "run_state_path rejects ids with a slash, .., whitespace, or empty, with exit 2, before touching the disk" {
  local bad
  for bad in "a/b" "../x" ".." "a..b" "/abs" "a b" " a" "a " $'a\tb' $'a\nb' "" ".hidden" "a*" 'a$b'; do
    call_fn run_state_path "$bad"
    [ "$status" -eq 2 ] || { echo "id '$bad' gave status $status"; return 1; }
    [ -z "$output" ]
    [[ "$stderr" == *"invalid run id"* ]]
  done
  [ ! -e "$ANCHOR/project/data" ]
}

@test "run_state_path with no argument is a usage error" {
  call_fn run_state_path
  [ "$status" -eq 2 ]
}

@test "run_state_dir creates nothing unless asked, and --create runs mkdir -p" {
  call_fn run_state_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$RUNS" ]
  [ ! -e "$RUNS" ]
  call_fn run_state_dir --create
  [ "$status" -eq 0 ]
  [ "$output" = "$RUNS" ]
  [ -d "$RUNS" ]
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

@test "status prints a valid run as pretty JSON with sorted keys" {
  write_run "$RUNS" r1 2026-01-01T00:00:00Z
  run --separate-stderr bash "$SCRIPT" status r1
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  printf '%s\n' "$output" | jq -e '.run_id == "r1" and .schema_version == 1' >/dev/null
  [ "$output" = "$(jq -S . "$RUNS/r1.json")" ]
}

@test "status exits 3 for an unknown id, prints no state, and names the file" {
  mkdir -p "$RUNS"
  run --separate-stderr bash "$SCRIPT" status nope
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"$RUNS/nope.json"* ]]
  [[ "$stderr" == *"not found"* ]]
}

@test "status exits 3 when the runs directory does not exist, and does not create it" {
  run --separate-stderr bash "$SCRIPT" status nope
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ ! -e "$RUNS" ]
}

# assert_status_corrupt <id> <expected reason fragment>
assert_status_corrupt() {
  run --separate-stderr bash "$SCRIPT" status "$1"
  [ "$status" -eq 4 ] || { echo "status was $status"; return 1; }
  [ -z "$output" ] || { echo "stdout was not empty: $output"; return 1; }
  [[ "$stderr" == *"$RUNS/$1.json"* ]] || { echo "stderr does not name the file: $stderr"; return 1; }
  [[ "$stderr" == *"$2"* ]] || { echo "stderr lacks '$2': $stderr"; return 1; }
}

@test "status exits 4 naming the file for an empty file" {
  mkdir -p "$RUNS"
  : > "$RUNS/empty.json"
  assert_status_corrupt empty "empty"
}

@test "status exits 4 naming the file for truncated JSON" {
  write_run "$RUNS" trunc 2026-01-01T00:00:00Z
  head -c 60 "$RUNS/trunc.json" > "$RUNS/trunc.part" && mv "$RUNS/trunc.part" "$RUNS/trunc.json"
  assert_status_corrupt trunc "not valid JSON"
}

@test "status exits 4 naming the file for valid JSON with a missing required key" {
  write_run "$RUNS" nokey 2026-01-01T00:00:00Z
  jq 'del(.definition_hash)' "$RUNS/nokey.json" > "$RUNS/nokey.tmp" && mv "$RUNS/nokey.tmp" "$RUNS/nokey.json"
  assert_status_corrupt nokey "definition_hash"
}

@test "a null value for a required key counts as present" {
  write_run "$RUNS" nulls 2026-01-01T00:00:00Z
  run --separate-stderr bash "$SCRIPT" status nulls
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.last_checkpoint == null and .definition_change_ack == null' >/dev/null
}

@test "status exits 4 naming the file for a wrong schema_version" {
  write_run "$RUNS" v2 2026-01-01T00:00:00Z
  jq '.schema_version = 2' "$RUNS/v2.json" > "$RUNS/v2.tmp" && mv "$RUNS/v2.tmp" "$RUNS/v2.json"
  assert_status_corrupt v2 "schema_version"
}

@test "status exits 4 for valid JSON that is not an object" {
  mkdir -p "$RUNS"
  printf '[1,2]\n' > "$RUNS/arr.json"
  assert_status_corrupt arr "not a JSON object"
}

@test "status exits 4 for two concatenated JSON documents" {
  write_run "$RUNS" twin 2026-01-01T00:00:00Z
  cat "$RUNS/twin.json" "$RUNS/twin.json" > "$RUNS/twin.cat" && mv "$RUNS/twin.cat" "$RUNS/twin.json"
  assert_status_corrupt twin "single JSON document"
}

@test "status with an invalid id exits 2" {
  run --separate-stderr bash "$SCRIPT" status "../etc"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

@test "list prints sorted rows (created_at, then id) for three hand-written runs" {
  write_run "$RUNS" zeta  2026-01-01T00:00:00Z wf-z running
  write_run "$RUNS" beta  2026-01-02T00:00:00Z wf-b paused
  write_run "$RUNS" alpha 2026-01-02T00:00:00Z wf-a completed
  run --separate-stderr bash "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  local expected
  expected="zeta"$'\t'"wf-z"$'\t'"running"$'\t'"2026-01-01T00:00:00Z"$'\n'
  expected="$expected""alpha"$'\t'"wf-a"$'\t'"completed"$'\t'"2026-01-02T00:00:00Z"$'\n'
  expected="$expected""beta"$'\t'"wf-b"$'\t'"paused"$'\t'"2026-01-02T00:00:00Z"
  [ "$output" = "$expected" ]
}

@test "list prints nothing and exits 0 when the directory is absent, and creates nothing" {
  run --separate-stderr bash "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ ! -e "$RUNS" ]
}

@test "list prints nothing and exits 0 for an empty directory" {
  mkdir -p "$RUNS"
  run --separate-stderr bash "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list with one corrupt file lists the good runs, warns on stderr naming the file and exits 4" {
  write_run "$RUNS" good1 2026-01-01T00:00:00Z
  write_run "$RUNS" good2 2026-01-02T00:00:00Z
  printf '{"schema_version": 1,' > "$RUNS/broken.json"
  run --separate-stderr bash "$SCRIPT" list
  [ "$status" -eq 4 ]
  [[ "$output" == "good1"* ]]
  [[ "$output" == *$'\n'"good2"* ]]
  [[ "$output" != *broken* ]]
  [[ "$stderr" == *"warning"* ]]
  [[ "$stderr" == *"$RUNS/broken.json"* ]]
}

@test "list with only corrupt files is never an empty success" {
  mkdir -p "$RUNS"
  : > "$RUNS/empty.json"
  run --separate-stderr bash "$SCRIPT" list
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [[ "$stderr" == *"$RUNS/empty.json"* ]]
}

@test "list ignores lock directories and temporary files" {
  write_run "$RUNS" only 2026-01-01T00:00:00Z
  mkdir "$RUNS/only.json.lock.d"
  printf 'x' > "$RUNS/.tmp-only.123"
  run --separate-stderr bash "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
}

@test "list rejects extra arguments with exit 2" {
  run --separate-stderr bash "$SCRIPT" list extra
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# run_state_update
# ---------------------------------------------------------------------------

@test "run_state_update writes the new content, sets updated_at and leaves no temp file" {
  write_run "$RUNS" u1 2026-01-01T00:00:00Z
  call_fn run_state_update u1 '.status = "paused" | .history += [{at: $t, from: "running", to: "paused", note: "n"}]' --arg t 2026-02-02T00:00:00Z
  [ "$status" -eq 0 ]
  jq -e '.status == "paused" and (.history | length) == 1 and .history[0].at == "2026-02-02T00:00:00Z"' "$RUNS/u1.json" >/dev/null
  jq -e '.updated_at != "2026-01-01T00:00:00Z" and (.updated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' "$RUNS/u1.json" >/dev/null
  jq -e '.created_at == "2026-01-01T00:00:00Z"' "$RUNS/u1.json" >/dev/null
  [ -z "$(find "$RUNS" -name '.tmp-*')" ]
  [ ! -e "$RUNS/u1.json.lock.d" ]
  run bash "$SCRIPT" status u1
  [ "$status" -eq 0 ]
}

@test "run_state_update cannot be told to set updated_at: the store owns it" {
  write_run "$RUNS" u2 2026-01-01T00:00:00Z
  call_fn run_state_update u2 '.updated_at = "1999-01-01T00:00:00Z"'
  [ "$status" -eq 0 ]
  jq -e '.updated_at != "1999-01-01T00:00:00Z"' "$RUNS/u2.json" >/dev/null
}

@test "run_state_update with the lock held by another process and a 1s timeout exits 5, file byte-identical" {
  write_run "$RUNS" locked 2026-01-01T00:00:00Z
  local before; before=$(cksum < "$RUNS/locked.json")
  bash "$REPO_ROOT/scripts/with-lock.sh" "$RUNS/locked.json" -- sleep 8 &
  local holder=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -d "$RUNS/locked.json.lock.d" ] && break
    sleep 0.2
  done
  [ -d "$RUNS/locked.json.lock.d" ]
  WITH_LOCK_TIMEOUT_SECONDS=1 call_fn run_state_update locked '.status = "failed"'
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"lock"* ]]
  [ "$(cksum < "$RUNS/locked.json")" = "$before" ]
  [ -z "$(find "$RUNS" -name '.tmp-*')" ]
}

@test "run_state_update with a failing jq filter exits 2, file byte-identical, no temp file" {
  write_run "$RUNS" f1 2026-01-01T00:00:00Z
  local before; before=$(cksum < "$RUNS/f1.json")
  call_fn run_state_update f1 '.status = |'
  [ "$status" -eq 2 ]
  [ "$(cksum < "$RUNS/f1.json")" = "$before" ]
  [ -z "$(find "$RUNS" -name '.tmp-*')" ]
  call_fn run_state_update f1 'error("boom")'
  [ "$status" -eq 2 ]
  [ "$(cksum < "$RUNS/f1.json")" = "$before" ]
  [ -z "$(find "$RUNS" -name '.tmp-*')" ]
  [ ! -e "$RUNS/f1.json.lock.d" ]
}

@test "run_state_update refuses a result that is not a valid state, leaving the file byte-identical" {
  write_run "$RUNS" f2 2026-01-01T00:00:00Z
  local before; before=$(cksum < "$RUNS/f2.json")
  local filter
  for filter in 'del(.run_id)' '.schema_version = 2' 'null' 'empty' '[.]'; do
    call_fn run_state_update f2 "$filter"
    [ "$status" -eq 2 ] || { echo "filter '$filter' gave status $status"; return 1; }
    [ "$(cksum < "$RUNS/f2.json")" = "$before" ]
    [ -z "$(find "$RUNS" -name '.tmp-*')" ]
  done
}

@test "run_state_update on a missing run exits 3 and creates nothing" {
  call_fn run_state_update ghost '.status = "paused"'
  [ "$status" -eq 3 ]
  [ ! -e "$RUNS" ]
}

@test "run_state_update on a corrupt file exits 4 and leaves it untouched" {
  mkdir -p "$RUNS"
  printf '{"schema_version": 1' > "$RUNS/bad.json"
  local before; before=$(cksum < "$RUNS/bad.json")
  call_fn run_state_update bad '.status = "paused"'
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"$RUNS/bad.json"* ]]
  [ "$(cksum < "$RUNS/bad.json")" = "$before" ]
  [ -z "$(find "$RUNS" -name '.tmp-*')" ]
}

@test "run_state_update with an invalid id exits 2 before touching the disk" {
  call_fn run_state_update "../x" '.'
  [ "$status" -eq 2 ]
  [ ! -e "$ANCHOR/project/data" ]
}

@test "run_state_update with too few arguments is a usage error" {
  call_fn run_state_update only-an-id
  [ "$status" -eq 2 ]
}

@test "concurrent updates are serialised by the lock: no update is lost" {
  write_run "$RUNS" par 2026-01-01T00:00:00Z
  local n pids=""
  for n in 1 2 3 4 5 6; do
    bash -c '. "$1"; run_state_update par ".history += [{at: \$n, from: \"a\", to: \"b\", note: \"\"}]" --arg n "$2"' _ "$SCRIPT" "$n" &
    pids="$pids $!"
  done
  local p
  for p in $pids; do
    wait "$p"
  done
  [ "$(jq '.history | length' "$RUNS/par.json")" = "6" ]
  [ "$(jq -r '[.history[].at] | sort | join(",")' "$RUNS/par.json")" = "1,2,3,4,5,6" ]
  [ -z "$(find "$RUNS" -name '.tmp-*')" ]
}

# ---------------------------------------------------------------------------
# relocated tree
# ---------------------------------------------------------------------------

@test "relocated tree: list and status read the dot-prefixed tree and the conventional tree is never touched" {
  local anchor2="$BATS_TEST_TMPDIR/relocated"
  mkdir -p "$anchor2/.project/configs"
  printf '{"paths":{}}\n' > "$anchor2/.project/configs/workflow.json"
  write_run "$anchor2/.project/data/workflow-runs" rel1 2026-03-01T00:00:00Z wf-rel running
  # A decoy conventional tree in the working directory must be ignored: JENGA_PROJECT_ROOT wins.
  mkdir -p "$BATS_TEST_TMPDIR/decoy/project/configs"
  printf '{"paths":{}}\n' > "$BATS_TEST_TMPDIR/decoy/project/configs/workflow.json"
  write_run "$BATS_TEST_TMPDIR/decoy/project/data/workflow-runs" decoy 2026-03-01T00:00:00Z wf-decoy running
  cd "$BATS_TEST_TMPDIR/decoy"
  export JENGA_PROJECT_ROOT="$anchor2"

  run --separate-stderr bash "$SCRIPT" list
  [ "$status" -eq 0 ]
  [[ "$output" == "rel1"$'\t'"wf-rel"* ]]
  [[ "$output" != *decoy* ]]

  run --separate-stderr bash "$SCRIPT" status rel1
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.run_id == "rel1"' >/dev/null

  run --separate-stderr bash "$SCRIPT" status decoy
  [ "$status" -eq 3 ]

  call_fn run_state_update rel1 '.status = "paused"'
  [ "$status" -eq 0 ]
  jq -e '.status == "paused"' "$anchor2/.project/data/workflow-runs/rel1.json" >/dev/null
  [ ! -e "$anchor2/project" ]
  [ ! -e "$ANCHOR/project/data" ]
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------

@test "no arguments prints usage on stderr and exits 2" {
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Usage"* ]]
}

@test "an unknown command exits 2" {
  run --separate-stderr bash "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"frobnicate"* ]]
}

@test "status without an id, or with two, exits 2" {
  run --separate-stderr bash "$SCRIPT" status
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" status a b
  [ "$status" -eq 2 ]
}

@test "--help and -h print usage on stdout and exit 0" {
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: run-state.sh start <workflow_id>"* ]]
  [[ "$output" == *"run-state.sh status <run_id>"* ]]
  [[ "$output" == *"Exit codes"* ]]
  [ -z "$stderr" ]
  run --separate-stderr bash "$SCRIPT" -h
  [ "$status" -eq 0 ]
}

@test "an unresolvable working-file root exits 2, not 3" {
  JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/no-registry-here" run --separate-stderr bash "$SCRIPT" list
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "list also works under the system bash (3.2 on macOS) when it is a different interpreter" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  write_run "$RUNS" sys1 2026-01-01T00:00:00Z
  run --separate-stderr /bin/bash "$SCRIPT" list
  [ "$status" -eq 0 ]
  [[ "$output" == "sys1"* ]]
  run --separate-stderr /bin/bash -c '. "$1"; run_state_update sys1 ".status = \"paused\""' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.status == "paused"' "$RUNS/sys1.json" >/dev/null
}
