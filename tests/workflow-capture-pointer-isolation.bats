#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# j.workflow-capture never makes a captured recording the session's active recording (epic E103, task
# E103_S01_T03; epic decision 6).
#
# Why this matters: hooks/on_recording_step.sh is a UserPromptSubmit hook that appends EVERY user prompt to
# whatever recording the session's active-recording pointer names. Capture reviews candidate steps with the
# user ("keep step 4", "drop that one"). If a captured recording ever sat behind the pointer, that review
# conversation would be appended into it as new steps. The epic avoids this by construction: capture never
# calls skills/j-workflow-recorder/scripts/active-recording.sh. This suite pins both halves:
#
#   1. BEHAVIOUR. A live recording is started the way the recorder starts one (create + pointer set), a
#      captured recording is built and reviewed in the SAME session the way capture builds one, and the hook
#      is then fired. The prompt must land in the live recording only, the captured recording must be
#      byte-identical (cmp against a copy taken before the hook ran), and the pointer must be unchanged.
#   2. STRUCTURE. No file under skills/j-workflow-capture/ references active-recording.sh. The scan is shown
#      to be non-vacuous (the directory, its SKILL.md and a script exist) and to bite (a planted reference in
#      a scratch copy is caught).
#
# How a captured recording is built here: exactly the way capture builds one, through capture's own writer
# (skills/j-workflow-capture/scripts/write-capture.sh, E103_S02_T03): `create` from a candidate-steps file, a
# review answer through record-review.sh (which writes with record-answer.sh, decision 5), and, in the seal test,
# `seal`. Until E103_S02_T03 this suite used the recorder's writers directly, because capture had no writer of its
# own yet. Nothing in that path touches the pointer, which is exactly what is being proved.
#
# Isolation and layout: JENGA_RECORDING_STATE_DIR points the pointer script and the hook at
# $BATS_TEST_TMPDIR, the three ambient session variables are unset in setup, and every recording lives under
# $BATS_TEST_TMPDIR. Only shipped paths are read (hooks/, skills/j-workflow-recorder/, skills/j-workflow-capture/,
# tests/helpers/), none of which .publicignore excludes, so the suite runs unchanged in the public mirror.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/on_recording_step.sh"
RECORDER="$REPO_ROOT/skills/j-workflow-recorder/scripts"
AR="$RECORDER/active-recording.sh"
RF="$RECORDER/recording-file.sh"
CAPTURE_DIR="$REPO_ROOT/skills/j-workflow-capture"
WC="$CAPTURE_DIR/scripts/write-capture.sh"
RR="$CAPTURE_DIR/scripts/record-review.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  export JENGA_RECORDING_STATE_DIR="$T/state"
  KEY="capture-sess-$BATS_TEST_NUMBER"
  LIVE="$T/live-process_RECORDING.md"
  CAP="$T/captured-process_RECORDING.md"
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID JENGA_RECORDING_SESSION_ID
  unset JENGA_RECORDING_NOW JENGA_RECORDER_NOW JENGA_RECORDING_HOOK_DEBUG
}

# Runs a command as the host session would: the session key in CLAUDE_CODE_SESSION_ID.
in_session() {
  env CLAUDE_CODE_SESSION_ID="$KEY" JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" "$@"
}

# The recorder's own start: a document plus a pointer at it under this session's key.
start_live_recording() {
  in_session bash "$RF" create "$LIVE" "Live Process" >/dev/null
  in_session bash "$AR" set "$LIVE" --title "Live Process" >/dev/null
}

# Capture's build and review, in the same session: write-capture.sh create writes a non-live recording with two
# candidate steps (at $CAP: the name "Captured Process" in directory $T), and record-review.sh persists a review
# answer. Fails loudly when the writer does not produce the expected path, so no test runs against a stale file.
build_captured_recording() {
  CANDS="$T/candidates.json"
  printf '%s\n' '{"candidate_steps_version": 1, "steps": [{"n": 1, "text": "run the release checklist"}, {"n": 2, "text": "publish the package"}]}' > "$CANDS"
  local made
  made="$(in_session bash "$WC" create --source session-transcript --source-ref "transcript-$KEY.jsonl" \
    --dir "$T" "$CANDS" "Captured Process")" || return 1
  [ "$made" = "$CAP" ] || { printf 'write-capture.sh wrote %s, expected %s\n' "$made" "$CAP" >&2; return 1; }
  in_session bash "$RR" decide "$CAP" 1 include >/dev/null
}

# The rest of capture's review, then its seal: every row included and typed, then write-capture.sh seal.
seal_captured_recording() {
  local n
  for n in 1 2; do
    in_session bash "$RR" decide "$CAP" "$n" include --replace >/dev/null
    in_session bash "$RR" decide "$CAP" "$n" type confirm >/dev/null
  done
  in_session bash "$WC" seal "$CAP" "$CANDS" >/dev/null
}

# A UserPromptSubmit payload. $1 prompt, $2 session_id (default $KEY).
payload() {
  local prompt="$1" sid="${2:-$KEY}"
  printf '%s' "$prompt" | python3 -c '
import json, sys
print(json.dumps({
    "session_id": sys.argv[1],
    "transcript_path": "/tmp/transcript.jsonl",
    "cwd": "/tmp",
    "hook_event_name": "UserPromptSubmit",
    "prompt": sys.stdin.read(),
}))' "$sid"
}

# Fires the hook as the real hook subprocess sees it: no session environment, the key only in the payload.
fire_hook() {
  env -u CLAUDE_CODE_SESSION_ID -u JENGA_SESSION_ID -u JENGA_RECORDING_SESSION_ID \
    JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" <<<"$(payload "$1")"
}

# Number of steps in $1. A helper failure prints a non-number so an -eq assertion fails instead of passing.
step_count() {
  local out rc
  out="$(bash "$RF" steps "$1" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'steps-helper-failed-exit-%s' "$rc"
    return 0
  fi
  if [ -z "$out" ]; then echo 0; else printf '%s\n' "$out" | grep -c .; fi
}

# Every pointer file's bytes, concatenated in a stable order (empty when there is none).
pointer_snapshot() {
  local f
  [ -d "$JENGA_RECORDING_STATE_DIR" ] || return 0
  for f in "$JENGA_RECORDING_STATE_DIR"/recording-*.json; do
    [ -e "$f" ] || continue
    printf '== %s\n' "${f##*/}"
    cat "$f"
  done
}

# Lists the files under directory $1 that reference the pointer script: its file name, or a call of it by a
# bare name followed by one of its mutating sub-commands. Prints one path per line; nothing when clean.
pointer_script_references() {
  grep -rlE 'active-recording\.sh|active-recording["'"'"']?[[:space:]]+(set|clear|refresh)([[:space:]]|$)' "$1" 2>/dev/null || true
}

@test "fixtures: the captured recording is non-live and the live one is behind the pointer" {
  start_live_recording
  build_captured_recording

  assert_contains "$(cat "$CAP")" "source: session-transcript"
  [ "$(step_count "$CAP")" -eq 2 ]
  [ "$(step_count "$LIVE")" -eq 0 ]
  [ "$(in_session bash "$AR" status --field path)" = "$LIVE" ]
}

@test "with a live recording active, a prompt lands only in the live recording and the captured recording is byte-unchanged" {
  start_live_recording
  local before_capture
  before_capture="$(pointer_snapshot)"
  [ -n "$before_capture" ]

  build_captured_recording
  cp "$CAP" "$T/captured.before"

  # Building and reviewing the captured recording did not move or rewrite the pointer.
  [ "$(pointer_snapshot)" = "$before_capture" ]

  run --separate-stderr fire_hook "keep step 4, drop the publish step"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # The prompt went to the live recording, once.
  [ "$(step_count "$LIVE")" -eq 1 ]
  assert_contains "$(cat "$LIVE")" "keep step 4, drop the publish step"

  # The captured recording is byte-for-byte what it was, and does not contain the prompt.
  cmp -s "$CAP" "$T/captured.before"
  assert_not_contains "$(cat "$CAP")" "keep step 4"
  [ "$(step_count "$CAP")" -eq 2 ]

  # The pointer still names the live recording, and no pointer file mentions the captured one. The positive
  # grep for the live path shows the negative one is looking in the right place.
  run --separate-stderr in_session bash "$AR" status --field path
  [ "$status" -eq 0 ]
  [ "$output" = "$LIVE" ]
  grep -rqF "$LIVE" "$JENGA_RECORDING_STATE_DIR"
  run grep -rlF "$CAP" "$JENGA_RECORDING_STATE_DIR"
  [ "$status" -eq 1 ]
}

@test "a whole review conversation lands in the live recording, never in the captured one" {
  start_live_recording
  build_captured_recording
  cp "$CAP" "$T/captured.before"

  local p
  for p in "the table looks right" "step 2 is uncertain, keep it" "yes, save it"; do
    run --separate-stderr fire_hook "$p"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done

  [ "$(step_count "$LIVE")" -eq 3 ]
  assert_contains "$(cat "$LIVE")" "step 2 is uncertain, keep it"
  cmp -s "$CAP" "$T/captured.before"
}

@test "with no live recording, building a captured recording creates no pointer and the hook leaves it unchanged" {
  build_captured_recording
  cp "$CAP" "$T/captured.before"

  # No pointer exists anywhere: capture never set one. status is run (not substituted) so a failing status
  # cannot pass as an empty answer.
  [ -z "$(pointer_snapshot)" ]
  run --separate-stderr in_session bash "$AR" status --field path
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run --separate-stderr fire_hook "drop step 2"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp -s "$CAP" "$T/captured.before"
  [ -z "$(pointer_snapshot)" ]
}

@test "sealing the captured recording with a live recording active leaves the pointer and the live recording alone" {
  start_live_recording
  local before
  before="$(pointer_snapshot)"
  [ -n "$before" ]
  build_captured_recording
  cp "$LIVE" "$T/live.before"

  seal_captured_recording
  assert_contains "$(cat "$CAP")" "status: closed"

  # The pointer is byte-identical and still names the live recording, which is still open and unchanged.
  [ "$(pointer_snapshot)" = "$before" ]
  [ "$(in_session bash "$AR" status --field path)" = "$LIVE" ]
  cmp -s "$LIVE" "$T/live.before"

  # And the next prompt still lands in the live recording only.
  cp "$CAP" "$T/captured.before"
  run --separate-stderr fire_hook "emit the captured workflow now"
  [ "$status" -eq 0 ]
  [ "$(step_count "$LIVE")" -eq 1 ]
  cmp -s "$CAP" "$T/captured.before"
}

@test "no file under skills/j-workflow-capture/ references active-recording.sh" {
  # Non-vacuous: the skill and at least one of its scripts are there to be scanned.
  [ -d "$CAPTURE_DIR" ]
  [ -f "$CAPTURE_DIR/SKILL.md" ]
  local scripts
  scripts="$(find "$CAPTURE_DIR" -type f -name '*.sh' | grep -c .)"
  [ "$scripts" -ge 1 ]

  run pointer_script_references "$CAPTURE_DIR"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    printf 'files under %s reference the active-recording pointer script:\n%s\n' "$CAPTURE_DIR" "$output" >&2
    return 1
  fi
}

@test "the reference scan bites: a planted call in a scratch copy of the skill is caught" {
  local copy="$T/capture-copy"
  cp -R "$CAPTURE_DIR" "$copy"
  [ -z "$(pointer_script_references "$copy")" ]

  printf '\nbash "$RECORDER/active-recording.sh" set "$CAP"\n' >> "$copy/SKILL.md"
  assert_contains "$(pointer_script_references "$copy")" "$copy/SKILL.md"

  cp "$CAPTURE_DIR/SKILL.md" "$copy/SKILL.md"
  printf '\nactive-recording set "$CAP"\n' >> "$copy/SKILL.md"
  assert_contains "$(pointer_script_references "$copy")" "$copy/SKILL.md"
}
