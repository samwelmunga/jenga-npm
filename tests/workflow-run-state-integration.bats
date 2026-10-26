#!/usr/bin/env bats
#
# E80_S02_T08: cross-command integration suite for scripts/workflow/run-state.sh (story E80_S02).
#
# The per-command suites (tests/workflow-run-state-*.bats, tasks T03 to T07) each test one concern in isolation.
# This file covers what only shows up when the commands are combined: a full lifecycle where every command runs in
# its own process, an interrupted session recovered by a fresh process, concurrent writers, a lock timeout, the
# "no path literal" rule, a relocated working-file tree, and the public-mirror classification.
#
# Isolation (same rules as tests/create-task-worktree.bats): every test builds its own fixture tree under
# $BATS_TEST_TMPDIR, selects it with JENGA_PROJECT_ROOT and never reads or writes this repository's own
# runs directory. Fixture definitions are written into the fixture's own workflow directory, so the test depends on
# no builtin workflow. The real loader and validator run against the repository's schema (read only).
#
# Public mirror: everything this suite reads classifies PUBLIC (scripts/check-publicignore-match.sh): run-state.sh,
# the sibling workflow scripts, resolve-root.sh, with-lock.sh, the workflow schema and type registry, and this
# file. A repo file that is absent from the tree makes the test that needs it skip, naming the file in the reason.
#
# Fixture helpers are local: the T03 to T07 suites each define their own variant (different step lists, state
# writers and setup), so there is no duplicated helper to factor out.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/run-state.sh"

setup() {
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS JENGA_WORKFLOWS_TEST_ROOT
  command -v jq >/dev/null 2>&1 || skip "jq is not installed (run-state.sh needs it)"
  [ -f "$SCRIPT" ] || skip "scripts/workflow/run-state.sh is not in this tree (the suite exercises it)"
  make_tree "$BATS_TEST_TMPDIR/anchor" project
  ANCHOR="$(cd "$BATS_TEST_TMPDIR/anchor" && pwd)"
  RUNS="$ANCHOR/project/data/workflow-runs"
  export JENGA_PROJECT_ROOT="$ANCHOR"
  cd "$BATS_TEST_TMPDIR" || return 1
}

# demo_def: a three-step fixture; s2 is the checkpoint step.
demo_def() {
  cat <<'JSON'
{
  "id": "demo",
  "name": "Demo flow",
  "description": "Fixture.",
  "steps": [
    {"id": "s1", "type": "skill", "skill": "j.status"},
    {"id": "s2", "type": "compute", "command": "echo two", "checkpoint": true},
    {"id": "s3", "type": "compute", "command": "echo three"}
  ]
}
JSON
}

# make_tree <anchor> <tree dir name>: a working-file tree holding the registry and the demo definition.
make_tree() {
  mkdir -p "$1/$2/configs" "$1/$2/.workflows"
  printf '{"paths":{}}\n' > "$1/$2/configs/workflow.json"
  demo_def > "$1/$2/.workflows/demo.json"
}

# rs <args...>: one run-state.sh command in its own process with a scrubbed environment, so no shell function or
# variable of the test can leak into it. Only PATH and the tree selector are passed.
rs() {
  env -i PATH="$PATH" JENGA_PROJECT_ROOT="$JENGA_PROJECT_ROOT" bash "$SCRIPT" "$@"
}

# jqf <run id> <jq filter>: reads a field of the state file in the active runs directory (RUNS).
jqf() { jq -r "$2" "$RUNS/$1.json"; }

# bg_rc <file> <command...>: runs the command (output discarded) and writes its exit code to <file>. The command
# may fail without aborting the caller (bats runs with errexit on), so a refused move is recorded, not fatal.
bg_rc() {
  local f="$1" rc=0
  shift
  "$@" >/dev/null 2>&1 || rc=$?
  echo "$rc" > "$f"
}

# chain_ok <run id>: the history starts at from=null/to=running and each entry's "from" equals the previous "to".
chain_ok() {
  jq -e '.history as $h | ($h | length) >= 1 and $h[0].from == null and $h[0].to == "running"
         and ([range(1; $h | length)] | all(. as $i | $h[$i].from == $h[$i - 1].to))' "$RUNS/$1.json" >/dev/null
}

# lifecycle: scenario 1 as a function so scenario 6 can repeat it against another tree. Every command is a separate
# process (rs). Sets RID. Uses RUNS for the file checks.
lifecycle() {
  local out
  RID=$(rs start demo)
  [ -n "$RID" ]
  [ "$(rs step "$RID" s1 in_progress)" = "running" ]
  [ "$(rs step "$RID" s1 completed)" = "running" ]
  [ "$(rs step "$RID" s2 in_progress)" = "running" ]
  [ "$(rs step "$RID" s2 completed)" = "running" ]
  [ "$(rs pause "$RID")" = "paused" ]
  out=$(rs status "$RID")
  [ "$(jq -r .status <<<"$out")" = "paused" ]
  [ "$(jq -r .last_checkpoint <<<"$out")" = "s2" ]
  out=$(rs resume "$RID")
  [ "$(jq -r .status <<<"$out")" = "running" ]
  [ "$(jq -r .next_step.id <<<"$out")" = "s3" ]
  [ "$(jq -r .resumed_from_checkpoint <<<"$out")" = "s2" ]
  [ "$(rs step "$RID" s3 in_progress)" = "running" ]
  [ "$(rs step "$RID" s3 completed)" = "completed" ]
  [ "$(rs status "$RID" | jq -r .status)" = "completed" ]
  rs list | awk -F'\t' -v id="$RID" '$1 == id { print $3 }' | grep -qx completed
}

# ---------------------------------------------------------------------------
# 1. full lifecycle across separate processes
# ---------------------------------------------------------------------------

@test "full lifecycle, one process per command: start, steps, pause, status, resume, steps, completed, list" {
  lifecycle
  [ "$(jqf "$RID" .status)" = "completed" ]
  [ "$(jqf "$RID" '[.steps[].status] | unique | join(",")')" = "completed" ]
  [ "$(jqf "$RID" .last_checkpoint)" = "s2" ]
  chain_ok "$RID"
  # started running, paused, resumed, completed.
  [ "$(jqf "$RID" '[.history[].to] | join(",")')" = "running,paused,running,completed" ]
  # One run file, no scratch or lock entries.
  [ "$(ls -A "$RUNS" | wc -l | tr -d ' ')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 2. interrupted session
# ---------------------------------------------------------------------------

@test "interrupted session: a step left in_progress is recovered by a fresh resume and the run finishes" {
  local out RID
  RID=$(rs start demo)
  [ "$(rs step "$RID" s1 in_progress)" = "running" ]
  # The session ends here: no completed, no pause. A fresh process resumes from the file alone.
  out=$(rs resume "$RID")
  [ "$(jq -r .status <<<"$out")" = "running" ]
  [ "$(jq -r .next_step.id <<<"$out")" = "s1" ]
  [ "$(jqf "$RID" '.steps[0].status')" = "pending" ]
  jq -e '.history[-1] | .from == "running" and .to == "running"' "$RUNS/$RID.json" >/dev/null
  rs step "$RID" s1 in_progress >/dev/null
  rs step "$RID" s1 completed >/dev/null
  rs step "$RID" s2 in_progress >/dev/null
  rs step "$RID" s2 completed >/dev/null
  rs step "$RID" s3 in_progress >/dev/null
  [ "$(rs step "$RID" s3 completed)" = "completed" ]
  [ "$(jqf "$RID" .status)" = "completed" ]
  chain_ok "$RID"
}

# ---------------------------------------------------------------------------
# 3. concurrent writers
# ---------------------------------------------------------------------------

@test "concurrent pause/status/list mixes and 4 cancels against one run leave a valid, chain-consistent file and no leftovers" {
  local RID i pids=() pause_zero=0 cancel_zero=0 f
  RID=$(rs start demo)
  rs step "$RID" s1 in_progress >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/rc"

  # 12 writers and readers at once: 4 pauses, 2 status, 2 list, 4 cancels. Each records its exit code in its own file.
  for i in 1 2 3 4; do
    bg_rc "$BATS_TEST_TMPDIR/rc/pause.$i" rs pause "$RID" 3>&- &
    pids+=("$!")
  done
  for i in 1 2; do
    bg_rc "$BATS_TEST_TMPDIR/rc/status.$i" rs status "$RID" 3>&- &
    pids+=("$!")
    bg_rc "$BATS_TEST_TMPDIR/rc/list.$i" rs list 3>&- &
    pids+=("$!")
  done
  for i in 1 2 3 4; do
    bg_rc "$BATS_TEST_TMPDIR/rc/cancel.$i" rs cancel "$RID" 3>&- &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i"; done

  # Readers never fail; a pause or cancel either took effect (0) or was refused as an illegal move (1), never anything else.
  for f in "$BATS_TEST_TMPDIR"/rc/status.* "$BATS_TEST_TMPDIR"/rc/list.*; do
    [ "$(cat "$f")" = "0" ] || { echo "reader $f exited $(cat "$f")"; return 1; }
  done
  for f in "$BATS_TEST_TMPDIR"/rc/pause.* "$BATS_TEST_TMPDIR"/rc/cancel.*; do
    case "$(cat "$f")" in
      0) case "$f" in */pause.*) pause_zero=$((pause_zero + 1)) ;; *) cancel_zero=$((cancel_zero + 1)) ;; esac ;;
      1) ;;
      *) echo "writer $f exited $(cat "$f")"; return 1 ;;
    esac
  done
  # Exactly one cancel wins (cancelled is terminal); a pause wins at most once.
  [ "$cancel_zero" -eq 1 ]
  [ "$pause_zero" -le 1 ]

  jq -e . "$RUNS/$RID.json" >/dev/null
  [ "$(jqf "$RID" .status)" = "cancelled" ]
  chain_ok "$RID"
  [ "$(jqf "$RID" '.history | length')" -eq $((2 + pause_zero)) ]
  # No temporary file and no lock directory remains.
  [ -z "$(find "$RUNS" -mindepth 1 \( -name '.tmp-*' -o -name '*.lock.d' \))" ]
  [ "$(find "$RUNS" -mindepth 1 | wc -l | tr -d ' ')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 4. lock timeout
# ---------------------------------------------------------------------------

@test "a held lock makes pause exit 5 after the timeout, state byte-identical, and the lock is released afterwards" {
  local RID holder n=0
  [ -f "$REPO_ROOT/scripts/with-lock.sh" ] || skip "scripts/with-lock.sh is not in this tree (the suite holds a lock with it)"
  RID=$(rs start demo)
  cp "$RUNS/$RID.json" "$BATS_TEST_TMPDIR/before.json"

  # Hold the state file's lock from a background process.
  bash "$REPO_ROOT/scripts/with-lock.sh" "$RUNS/$RID.json" -- sleep 60 >/dev/null 2>&1 3>&- &
  holder=$!
  while [ ! -d "$RUNS/$RID.json.lock.d" ] && [ "$n" -lt 100 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  [ -d "$RUNS/$RID.json.lock.d" ] || { kill "$holder" 2>/dev/null; echo "lock was never taken"; return 1; }

  run --separate-stderr env -i PATH="$PATH" JENGA_PROJECT_ROOT="$JENGA_PROJECT_ROOT" WITH_LOCK_TIMEOUT_SECONDS=1 \
    bash "$SCRIPT" pause "$RID"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  cmp -s "$RUNS/$RID.json" "$BATS_TEST_TMPDIR/before.json"

  # Release the lock: TERM is forwarded to the sleep and the lock directory is removed.
  kill -TERM "$holder"
  wait "$holder" 2>/dev/null || true
  n=0
  while [ -d "$RUNS/$RID.json.lock.d" ] && [ "$n" -lt 50 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  [ ! -d "$RUNS/$RID.json.lock.d" ]
  # With the lock free, the same command now succeeds.
  [ "$(rs pause "$RID")" = "paused" ]
}

# ---------------------------------------------------------------------------
# 5. no literal
# ---------------------------------------------------------------------------

@test "run-state.sh carries no project/ path literal outside comments and takes its paths from resolve-root.sh" {
  local hits
  # The DoD rule: no script hardcodes a project/... literal for run state. Comment lines describe the layout and are ignored.
  hits=$(grep -nE '(^|[^A-Za-z_])\.?project/' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  [ -z "$hits" ] || { echo "path literal(s) in run-state.sh: $hits"; return 1; }
  # The only path source is scripts/resolve-root.sh, named on a code line.
  grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -q 'resolve-root\.sh'
  [ -f "$REPO_ROOT/scripts/resolve-root.sh" ] || skip "scripts/resolve-root.sh is not in this tree"
}

# ---------------------------------------------------------------------------
# 6. relocated tree
# ---------------------------------------------------------------------------

@test "relocated tree end to end: every run file lives under <anchor>/.project/data/workflow-runs and <anchor>/project never appears" {
  local anchor2 f n=0
  anchor2="$BATS_TEST_TMPDIR/relocated"
  make_tree "$anchor2" .project
  # A decoy conventional tree must stay untouched.
  mkdir -p "$BATS_TEST_TMPDIR/decoy"
  cd "$BATS_TEST_TMPDIR/decoy"
  export JENGA_PROJECT_ROOT="$anchor2"
  RUNS="$anchor2/.project/data/workflow-runs"

  lifecycle
  [ "$(jqf "$RID" .status)" = "completed" ]
  chain_ok "$RID"
  [ -f "$RUNS/$RID.json" ]
  [ ! -e "$anchor2/project" ]
  [ ! -e "$ANCHOR/project/data" ]
  [ ! -e "$BATS_TEST_TMPDIR/decoy/project" ]
  # Every file the run created is under the relocated runs directory.
  for f in $(find "$anchor2" -name '*.json' -path '*workflow-runs*'); do
    case "$f" in "$anchor2/.project/data/workflow-runs/"*) n=$((n + 1)) ;; *) echo "stray run file: $f"; return 1 ;; esac
  done
  [ "$n" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 7. public-mirror shipping
# ---------------------------------------------------------------------------

@test "run-state.sh and this suite classify PUBLIC for the public mirror" {
  local f
  [ -f "$REPO_ROOT/scripts/check-publicignore-match.sh" ] || skip "scripts/check-publicignore-match.sh is not in this tree"
  [ -f "$REPO_ROOT/.publicignore" ] || skip ".publicignore is not in this tree (the classifier reads it)"
  for f in scripts/workflow/run-state.sh tests/workflow-run-state-integration.bats scripts/with-lock.sh scripts/resolve-root.sh; do
    [ -f "$REPO_ROOT/$f" ] || skip "$f is not in this tree"
  done
  run bash -c 'cd "$1" && shift && scripts/check-publicignore-match.sh "$@"' _ "$REPO_ROOT" \
    scripts/workflow/run-state.sh tests/workflow-run-state-integration.bats scripts/with-lock.sh scripts/resolve-root.sh
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^PUBLIC')" -eq 4 ]
  [ -z "$(printf '%s\n' "$output" | grep '^BLOCKED' || true)" ]
}
