#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# skills/j-workflow-capture/scripts/write-capture.sh (epic E103, task E103_S02_T03): capture's own writer.
#
#   1. create writes a non-live recording with the resolver's provenance and one step per candidate row, in row
#      order (row n = step-%03d), whole or nothing, and refuses `live`, a bad or empty candidates file and a
#      credential-shaped source_ref without leaving anything behind.
#   2. seal refuses while the review is pending, seals by explicit path, is a no-op on a sealed recording, and
#      neither reads nor writes the session's active-recording pointer (a pointer that even names the captured
#      recording is left byte-identical).
#   3. emit passes emit-workflow.sh's exit codes through, and refuses a live recording.
#   4. END TO END from the fixture transcript: extract-steps.sh -> create -> review -> seal -> emit gives a closed
#      `source: session-transcript` recording and a definition that passes validate-workflow.sh and is listed by
#      `j.workflow list` (workflow-cli.sh list-render).
#
# Isolation: everything is written under $BATS_TEST_TMPDIR. JENGA_PROJECT_ROOT names a throwaway project whose
# workflows directory is the conventional project/.workflows, so the emitter and the loader agree on it; the
# pointer lives in JENGA_RECORDING_STATE_DIR under $BATS_TEST_TMPDIR. Only shipped paths and the shipped fixture
# are read, so the suite runs unchanged in the public mirror.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WC="$REPO_ROOT/skills/j-workflow-capture/scripts/write-capture.sh"
RR="$REPO_ROOT/skills/j-workflow-capture/scripts/record-review.sh"
XS="$REPO_ROOT/skills/j-workflow-capture/scripts/extract-steps.sh"
RECORDER="$REPO_ROOT/skills/j-workflow-recorder/scripts"
RF="$RECORDER/recording-file.sh"
AR="$RECORDER/active-recording.sh"
VALIDATOR="$REPO_ROOT/scripts/workflow/validate-workflow.sh"
CLI="$REPO_ROOT/skills/j-workflow/scripts/workflow-cli.sh"
FIXTURE="$REPO_ROOT/tests/fixtures/workflow-capture/session-transcript.jsonl"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  mkdir -p "$PROJ/project/configs"
  printf '%s\n' '{"paths":{"workflows":"project/.workflows"}}' > "$PROJ/project/configs/workflow.json"
  DEFS="$PROJ/project/.workflows"
  RECS="$T/recs"
  CANDS="$T/candidates.json"
  KEY="capture-write-$BATS_TEST_NUMBER"

  unset JENGA_WORKFLOWS_TEST_ROOT JENGA_RECORDING_DIR JENGA_WORKFLOW_LOADER JENGA_RUN_STATE
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID JENGA_RECORDING_SESSION_ID JENGA_RECORDING_NOW
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_RECORDER_NOW=2026-11-20T03:04:05Z
  export JENGA_RECORDING_STATE_DIR="$T/state"
}

# Two rows, the second multi-line. render-review-table.sh --check requires rows to run 1..N in file order, so an
# out-of-order file is refused (exit 4) before anything is written; the rows here are in order.
write_candidates() {
  cat > "$CANDS" <<'JSON'
{"candidate_steps_version": 1, "steps": [
  {"n": 1, "text": "Create a new release branch named release/1.4 from main"},
  {"n": 2, "text": "Bump the version in package.json to 1.4.0\nand commit it"}
]}
JSON
}

create_capture() {
  bash "$WC" create --source session-transcript --source-ref "transcript-$KEY.jsonl" --dir "$RECS" \
    "$CANDS" "Cut a release branch"
}

# Every row included and typed confirm, so nothing is pending.
review_all_confirm() {
  local rec="$1" n
  for n in 1 2; do
    bash "$RR" decide "$rec" "$n" include >/dev/null
    bash "$RR" decide "$rec" "$n" type confirm >/dev/null
  done
}

recording_files() { find "$RECS" -name '*_RECORDING.md' 2>/dev/null | grep -c . || true; }

in_session() {
  env CLAUDE_CODE_SESSION_ID="$KEY" JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" "$@"
}

pointer_snapshot() {
  local f
  [ -d "$JENGA_RECORDING_STATE_DIR" ] || return 0
  for f in "$JENGA_RECORDING_STATE_DIR"/*; do
    [ -e "$f" ] || continue
    printf '== %s\n' "${f##*/}"
    cat "$f"
  done
}

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

@test "create writes a captured recording: provenance, title, one step per row in row order" {
  write_candidates
  run --separate-stderr create_capture
  [ "$status" -eq 0 ]
  local rec="$output"
  [ "$rec" = "$RECS/cut-a-release-branch_RECORDING.md" ]
  [ -f "$rec" ]

  assert_contains "$(cat "$rec")" "source: session-transcript"
  assert_contains "$(cat "$rec")" "source_ref: \"transcript-$KEY.jsonl\""
  assert_contains "$(cat "$rec")" "# Recording: Cut a release branch"

  [ "$(bash "$RF" steps "$rec")" = "$(printf 'step-001\nstep-002')" ]
  # Row 1 is step-001 even though it comes second in the file; the multi-line row stays one step.
  local first second
  first="$(awk '/step-001/{f=1} /step-002/{f=0} f' "$rec")"
  second="$(awk '/step-002/{f=1} f' "$rec")"
  assert_contains "$first" "Create a new release branch named release/1.4 from main"
  assert_contains "$second" "Bump the version in package.json to 1.4.0"
  assert_contains "$second" "and commit it"

  # Nothing left behind: no staging directory.
  [ -z "$(find "$RECS" -name '.capture-stage.*')" ]
}

@test "create without --source-ref writes no source_ref line" {
  write_candidates
  run --separate-stderr bash "$WC" create --source pasted --dir "$RECS" "$CANDS" "Pasted steps"
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$output")" "source: pasted"
  assert_not_contains "$(cat "$output")" "source_ref:"
}

@test "create refuses --source live and writes nothing" {
  write_candidates
  run --separate-stderr bash "$WC" create --source live --dir "$RECS" "$CANDS" "Live attempt"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "j.workflow-recorder"
  [ "$(recording_files)" -eq 0 ]
}

@test "create refuses a missing, an invalid and an empty candidates file and writes nothing" {
  run --separate-stderr bash "$WC" create --source pasted --dir "$RECS" "$T/nope.json" "X"
  [ "$status" -eq 3 ]

  printf '%s\n' '{"candidate_steps_version": 1, "steps": [{"n": 1}]}' > "$CANDS"
  run --separate-stderr bash "$WC" create --source pasted --dir "$RECS" "$CANDS" "X"
  [ "$status" -eq 4 ]
  [ -z "$output" ]

  printf '%s\n' '{"candidate_steps_version": 1, "steps": []}' > "$CANDS"
  run --separate-stderr bash "$WC" create --source pasted --dir "$RECS" "$CANDS" "X"
  [ "$status" -eq 5 ]
  [ -z "$output" ]

  [ "$(recording_files)" -eq 0 ]
}

@test "create refuses a credential-shaped source_ref and leaves no recording and no staging directory" {
  write_candidates
  run --separate-stderr bash "$WC" create --source session-transcript \
    --source-ref "https://user:hunter2@example.com/t.jsonl" --dir "$RECS" "$CANDS" "Leaky"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(recording_files)" -eq 0 ]
  [ -z "$(find "$RECS" -name '.capture-stage.*' 2>/dev/null)" ]
  run grep -rF hunter2 "$RECS"
  [ "$status" -ne 0 ]
}

@test "create never overwrites: the same name twice gives a second file and leaves the first unchanged" {
  write_candidates
  local first second
  first="$(create_capture)"
  cp "$first" "$T/first.before"
  second="$(create_capture)"
  [ "$second" != "$first" ]
  [ -f "$second" ]
  cmp -s "$first" "$T/first.before"
}

@test "create rejects usage errors" {
  write_candidates
  run --separate-stderr bash "$WC" create --dir "$RECS" "$CANDS" "No source"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$WC" create --source pasted --dir "$RECS" "$CANDS"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$WC" create --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$WC" frobnicate
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$WC" --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "write-capture.sh create"
}

# ---------------------------------------------------------------------------
# seal
# ---------------------------------------------------------------------------

@test "seal refuses while the review is pending, then seals once nothing is pending, and a second seal is a no-op" {
  write_candidates
  local rec
  rec="$(create_capture)"

  run --separate-stderr bash "$WC" seal "$rec" "$CANDS"
  [ "$status" -eq 9 ]
  [ -z "$output" ]
  assert_contains "$stderr" "still need a decision"
  assert_contains "$(cat "$rec")" "status: in_progress"

  review_all_confirm "$rec"
  run --separate-stderr bash "$WC" seal "$rec" "$CANDS"
  [ "$status" -eq 0 ]
  [ "$output" = "$rec" ]
  assert_contains "$(cat "$rec")" "status: closed"

  cp "$rec" "$T/sealed.before"
  run --separate-stderr bash "$WC" seal "$rec" "$CANDS"
  [ "$status" -eq 0 ]
  [ "$output" = "$rec" ]
  cmp -s "$rec" "$T/sealed.before"
}

@test "seal neither reads nor writes the pointer: a pointer naming the captured recording itself stays byte-identical" {
  write_candidates
  local rec before
  rec="$(create_capture)"
  review_all_confirm "$rec"

  # A pointer that names the captured recording. close-recording.sh, if it consulted the session's pointer,
  # would clear exactly this one; capture's seal must not even look at it.
  in_session bash "$AR" set "$rec" --title "planted" >/dev/null
  before="$(pointer_snapshot)"
  [ -n "$before" ]

  run --separate-stderr in_session bash "$WC" seal "$rec" "$CANDS"
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$rec")" "status: closed"
  [ "$(pointer_snapshot)" = "$before" ]
}

@test "with a live recording running, a full capture leaves the live recording and its pointer untouched" {
  local live="$T/live-process_RECORDING.md" before rec
  in_session bash "$RF" create "$live" "Live Process" >/dev/null
  in_session bash "$AR" set "$live" --title "Live Process" >/dev/null
  cp "$live" "$T/live.before"
  before="$(pointer_snapshot)"

  write_candidates
  rec="$(in_session bash "$WC" create --source pasted --dir "$RECS" "$CANDS" "Side process")"
  review_all_confirm "$rec"
  run --separate-stderr in_session bash "$WC" seal "$rec" "$CANDS"
  [ "$status" -eq 0 ]
  run --separate-stderr in_session bash "$WC" emit "$rec"
  [ "$status" -eq 0 ]

  [ "$(pointer_snapshot)" = "$before" ]
  cmp -s "$live" "$T/live.before"
  run --separate-stderr in_session bash "$AR" status --field path
  [ "$output" = "$live" ]
}

@test "seal and emit refuse a live recording" {
  local live="$T/live-only_RECORDING.md"
  bash "$RF" create "$live" "Live only" >/dev/null
  bash "$RF" append "$live" "do something" >/dev/null
  write_candidates

  run --separate-stderr bash "$WC" seal "$live" "$CANDS"
  [ "$status" -eq 11 ]
  assert_contains "$(cat "$live")" "status: in_progress"

  run --separate-stderr bash "$WC" emit "$live"
  [ "$status" -eq 11 ]
  [ ! -d "$DEFS" ] || [ -z "$(ls -A "$DEFS")" ]
}

# ---------------------------------------------------------------------------
# emit
# ---------------------------------------------------------------------------

@test "emit passes emit-workflow.sh's exit codes through: 4 for an unsealed recording" {
  write_candidates
  local rec
  rec="$(create_capture)"
  review_all_confirm "$rec"
  run --separate-stderr bash "$WC" emit "$rec"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [ ! -f "$DEFS/cut-a-release-branch.json" ]
}

@test "emit forwards --answer to emit-workflow.sh" {
  write_candidates
  local rec
  rec="$(create_capture)"
  # Row 2 is included but left without a type. seal would refuse that (pending), so the recording is sealed
  # directly with close-recording.sh (private pointer directory) to reach emit-workflow.sh's exit 9 path.
  bash "$RR" decide "$rec" 1 include >/dev/null
  bash "$RR" decide "$rec" 1 type confirm >/dev/null
  bash "$RR" decide "$rec" 2 include >/dev/null
  env JENGA_RECORDING_STATE_DIR="$T/private" bash "$RECORDER/close-recording.sh" "$rec" --session x >/dev/null 2>&1

  run --separate-stderr bash "$WC" emit "$rec"
  [ "$status" -eq 9 ]
  assert_contains "$output" "step-002"

  run --separate-stderr bash "$WC" emit --answer step-002=confirm "$rec"
  [ "$status" -eq 0 ]
  [ "$output" = "$DEFS/cut-a-release-branch.json" ]
}

# ---------------------------------------------------------------------------
# End to end
# ---------------------------------------------------------------------------

@test "end to end from the fixture transcript: a closed session-transcript recording and a valid, listed definition" {
  run --separate-stderr bash "$XS" range 1 2 --kind transcript --out "$CANDS" "$FIXTURE"
  [ "$status" -eq 0 ]

  local rec def
  run --separate-stderr bash "$WC" create --source session-transcript --source-ref "$FIXTURE" --dir "$RECS" \
    "$CANDS" "Cut a release branch"
  [ "$status" -eq 0 ]
  rec="$output"

  review_all_confirm "$rec"
  run --separate-stderr bash "$RR" pending "$rec" "$CANDS"
  [ "$status" -eq 0 ]

  run --separate-stderr bash "$WC" seal "$rec" "$CANDS"
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$rec")" "status: closed"
  assert_contains "$(cat "$rec")" "source: session-transcript"

  run --separate-stderr bash "$WC" emit "$rec"
  [ "$status" -eq 0 ]
  def="$output"
  [ "$def" = "$DEFS/cut-a-release-branch.json" ]

  run --separate-stderr bash "$VALIDATOR" "$def"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.provenance.source' "$def")" = "session-transcript" ]
  [ "$(jq -r '.provenance.source_ref' "$def")" = "$FIXTURE" ]
  [ "$(jq -r '.steps | length' "$def")" -eq 2 ]
  [ "$(jq -r '.steps[0].prompt' "$def")" = "Create a new release branch named release/1.4 from main" ]
  assert_contains "$(cat "$rec")" "emitted_workflow: cut-a-release-branch"

  run --separate-stderr bash "$CLI" list-render
  [ "$status" -eq 0 ]
  assert_contains "$output" "cut-a-release-branch - Cut a release branch (project)"
}

@test "write-capture.sh never names the recorder's pointer script" {
  run grep -cE 'active-recording\.sh|active-recording["'"'"']?[[:space:]]+(set|clear|refresh)([[:space:]]|$)' "$WC"
  [ "$output" = "0" ]
}
