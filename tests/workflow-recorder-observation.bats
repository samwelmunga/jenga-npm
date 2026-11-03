#!/usr/bin/env bats
#
# hooks/on_recording_step.sh — the recorder's UserPromptSubmit capture hook (E89, task E89_S02_T03).
#
# What this suite pins, and why each one is here rather than left to review:
#
#   1. THE SUBPROCESS SESSION-KEY CASE IS THE LOAD-BEARING TEST. The decision document's §5.1 names
#      this as the design's sharpest failure mode: the skill body's `active-recording.sh set` runs in
#      the SESSION environment, the hook's `get` runs in a HOOK SUBPROCESS, and if the two resolve
#      different keys the recorder records nothing — silently, with no error and no warning, leaving an
#      empty document that looks like a working recording. A test that only proves "the hook appends
#      when run by hand in the session shell" does NOT cover this, because in that shell the
#      environment agrees with itself by construction. So the test below sets the pointer with the key
#      visible ONLY in the environment, then runs the hook with that environment CLEARED and the key
#      present only in the stdin payload — which is the real hook subprocess's situation — and requires
#      the append to land anyway.
#   2. SILENCE IS A CONTRACT, NOT A COURTESY. stdout is asserted EMPTY on every path, including
#      --probe and including every failure path, because under Claude Code a UserPromptSubmit hook's
#      stdout is injected into the model's context — a single stray byte pollutes every turn of every
#      session. stderr is asserted empty too on the ordinary no-recording path (§6 rule 3: a user who
#      never runs the recorder must not be able to tell it is installed).
#   3. EXIT 0 IS UNCONDITIONAL. A non-zero exit from UserPromptSubmit can block prompt processing and
#      ERASE THE USER'S PROMPT, so every malformed-input and broken-state case below asserts status 0
#      rather than asserting a diagnosis. Fail-open is the requirement; these tests would fail a
#      "helpful" implementation that reported an error.
#   4. DURABILITY IS DEMONSTRATED, NOT ASSERTED. The acceptance criteria require an observable test of
#      the context-summarisation survival property. It is reduced to its mechanical core: a pointer set
#      by one process, read and appended to by LATER, SEPARATE processes that share no shell state —
#      which is exactly what a fresh hook process after a summarisation is.
#   5. NO SEMANTIC FILTERING. Asserted positively: a prompt that merely MENTIONS the skill, a question,
#      and a one-word prompt are all recorded. The hook is forbidden from judging what matters (all
#      interpretation is tier 2), so the tests pin that it does not try.
#   6. THE DUPLICATED STATE_SUBDIR CONSTANT CANNOT DRIFT. The hook hardcodes "active-recordings" to
#      keep a subprocess off the no-op path; this suite asserts it still equals active-recording.sh's
#      own STATE_SUBDIR, so the duplication is made safe mechanically instead of by hoping.
#   7. NO PATH LITERAL. The task's final acceptance criterion greps the added file for `project/`; that
#      grep is run here rather than by hand. It is run over the WHOLE file, comments included, because
#      a mechanical grep does not care that a mention is prose.
#
# Isolation: JENGA_RECORDING_STATE_DIR points every test at $BATS_TEST_TMPDIR, so no real queue state
# is read or written, and each test gets its own session key. The three ambient session variables are
# unset in setup so a real session's id can never leak in and make a test pass for the wrong reason.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/on_recording_step.sh"
AR="$REPO_ROOT/skills/j-workflow-recorder/scripts/active-recording.sh"
RF="$REPO_ROOT/skills/j-workflow-recorder/scripts/recording-file.sh"

setup() {
  T="$BATS_TEST_TMPDIR"
  export JENGA_RECORDING_STATE_DIR="$T/state"
  KEY="bats-$BATS_TEST_NUMBER"
  REC="$T/my-process_RECORDING.md"
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID JENGA_RECORDING_SESSION_ID
  unset JENGA_RECORDING_NOW JENGA_RECORDER_NOW JENGA_RECORDING_HOOK_DEBUG
}

# A recording document plus a pointer at it under session key $1 (default $KEY). The pointer is set in
# a SEPARATE process from any hook run, which is the whole point.
start_recording() {
  local key="${1:-$KEY}"
  bash "$RF" create "$REC" "My Process" >/dev/null
  JENGA_RECORDING_SESSION_ID="$key" bash "$AR" set "$REC" --title "My Process" >/dev/null
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

step_count() {
  bash "$RF" steps "$REC" 2>/dev/null | grep -c . || true
}

# -----------------------------------------------------------------------------
# Shape of the script itself
# -----------------------------------------------------------------------------

@test "the hook exists, is executable and passes bash -n" {
  [ -f "$HOOK" ]
  [ -x "$HOOK" ]
  run bash -n "$HOOK"
  [ "$status" -eq 0 ]
}

@test "the state path is resolved, not hardcoded: no project/ literal anywhere in the file" {
  run grep -n 'project/' "$HOOK"
  [ "$status" -ne 0 ]
}

@test "STATE_SUBDIR has not drifted from active-recording.sh's own value" {
  # The hook duplicates this constant deliberately, to keep a subprocess off the no-op path. That is
  # only safe while the two agree, so the agreement is checked mechanically here.
  local hook_val ar_val
  hook_val="$(grep -m1 '^STATE_SUBDIR=' "$HOOK" | cut -d= -f2 | tr -d '"')"
  ar_val="$(grep -m1 '^STATE_SUBDIR=' "$AR" | cut -d= -f2 | tr -d '"')"
  [ -n "$hook_val" ]
  [ "$hook_val" = "$ar_val" ]
}

@test "the header records the session-key failure mode and the precedent it follows" {
  local header
  header="$(sed -n '1,/^set -u$/p' "$HOOK")"
  assert_contains "$header" "WorktreeCreate"
  assert_contains "$header" "JENGA_SESSION_ID"
  assert_contains "$header" "on_preflight_check.sh"
}

@test "the header records a MEASURED no-op cost against a bare-bash floor, not a claim" {
  local header
  header="$(sed -n '1,/^set -u$/p' "$HOOK")"
  assert_contains "$header" "bare-bash floor"
  assert_contains "$header" "ms/call"
}

@test "--help prints usage on STDERR and nothing on stdout, and exits 0" {
  # Rule 1 admits no exception, not even for usage: stdout belongs to the model's context.
  run --separate-stderr bash "$HOOK" --help
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_contains "$stderr" "on_recording_step.sh"
}

# -----------------------------------------------------------------------------
# Rule 3 / rule 4: the no-recording path
# -----------------------------------------------------------------------------

@test "with no recording active the hook is completely silent and exits 0" {
  run --separate-stderr bash "$HOOK" <<<"$(payload 'hello there')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "with no recording active the hook creates no state of its own" {
  run bash "$HOOK" <<<"$(payload 'hello there')"
  [ "$status" -eq 0 ]
  # It must not conjure the pointer directory, a recording, or anything else.
  [ ! -e "$JENGA_RECORDING_STATE_DIR" ]
  [ ! -e "$REC" ]
}

@test "an unresolvable queue root records nothing and still exits 0 silently" {
  # No state-dir seam and a project root with no registry: the resolver cannot answer. The hook must
  # NOT guess a location — writing to an invented path would be worse than missing a step.
  unset JENGA_RECORDING_STATE_DIR
  mkdir -p "$T/empty"
  run --separate-stderr env JENGA_PROJECT_ROOT="$T/empty" bash "$HOOK" <<<"$(payload 'hello')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# -----------------------------------------------------------------------------
# The load-bearing case: session-key agreement across a subprocess boundary (§5.1)
# -----------------------------------------------------------------------------

@test "THE SUBPROCESS CASE: a pointer set with the key only in the environment is still found when the hook has no session environment at all and the key arrives only in the payload" {
  start_recording "hostsess-abc"

  # This is the real hook subprocess's situation, and the one a hand-run-in-the-session-shell test
  # cannot reproduce: every session variable the pointer script probes is absent, so the ONLY way to
  # the right key is the stdin payload's .session_id — the WorktreeCreate fallback.
  run --separate-stderr env -u CLAUDE_CODE_SESSION_ID -u JENGA_SESSION_ID -u JENGA_RECORDING_SESSION_ID \
    JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" <<<"$(payload 'the first real step' 'hostsess-abc')"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(step_count)" -eq 1 ]
  assert_contains "$(cat "$REC")" "the first real step"
}

@test "a payload with no session_id and no session environment records nothing, silently" {
  start_recording "hostsess-abc"
  run --separate-stderr env -u CLAUDE_CODE_SESSION_ID -u JENGA_SESSION_ID -u JENGA_RECORDING_SESSION_ID \
    JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" <<<'{"hook_event_name":"UserPromptSubmit","prompt":"orphaned prompt"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(step_count)" -eq 0 ]
}

@test "env and payload DISAGREEING still records: the environment candidate is tried first, then the payload one" {
  start_recording "hostsess-abc"
  # The environment names a session that has no pointer. A single-candidate implementation would get
  # exit 3 here and record nothing — which is precisely the silent failure this hook exists to avoid.
  run --separate-stderr env CLAUDE_CODE_SESSION_ID="a-different-session" \
    JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" <<<"$(payload 'step via the payload candidate' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(step_count)" -eq 1 ]
  assert_contains "$(cat "$REC")" "step via the payload candidate"
}

@test "a malformed environment key does not block the payload candidate" {
  start_recording "hostsess-abc"
  # active-recording.sh rejects a bad key with exit 2 rather than 3; that must also fall through.
  run env CLAUDE_CODE_SESSION_ID='not a valid key!!' \
    JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" <<<"$(payload 'still recorded' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  [ "$(step_count)" -eq 1 ]
}

@test "another session's pointer is never hijacked: the hook does not record into a recording it was not keyed to" {
  # The fast-reject glob matches ANY pointer file, so a live pointer belonging to someone else does
  # reach stage 2 — and must then find nothing. This pins that the glob is an accelerator only, and
  # that the hook never degenerates into "append to whatever recording happens to be active".
  start_recording "someone-elses-session"
  run --separate-stderr env CLAUDE_CODE_SESSION_ID="my-own-session" \
    JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" <<<"$(payload 'must not be recorded' 'my-own-session')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(step_count)" -eq 0 ]
}

# -----------------------------------------------------------------------------
# Durability: the context-summarisation survival criterion, made observable
# -----------------------------------------------------------------------------

@test "DURABILITY: appends from fresh processes with no shared shell state keep landing in the same file" {
  start_recording "hostsess-abc"

  # Three separate hook processes, none of which has ever seen the recording's path. Each one can only
  # get there by reading the pointer off disk — which is what makes a context summarisation a non-event
  # for this design, since a summarisation discards conversation state and does not touch the pointer.
  local i
  for i in 1 2 3; do
    run env -u CLAUDE_CODE_SESSION_ID -u JENGA_SESSION_ID -u JENGA_RECORDING_SESSION_ID \
      JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
      bash "$HOOK" <<<"$(payload "step number $i" 'hostsess-abc')"
    [ "$status" -eq 0 ]
  done

  [ "$(step_count)" -eq 3 ]
  local body
  body="$(cat "$REC")"
  assert_contains "$body" "step number 1"
  assert_contains "$body" "step number 2"
  assert_contains "$body" "step number 3"
}

@test "two appends neither duplicate nor truncate earlier entries" {
  start_recording "hostsess-abc"
  local before after

  run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<"$(payload 'the earlier entry' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  before="$(cat "$REC")"

  run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<"$(payload 'the later entry' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  after="$(cat "$REC")"

  # Every byte of the earlier state is still a prefix of the new state: nothing rewritten, nothing lost.
  [ "${after:0:${#before}}" = "$before" ]
  [ "$(step_count)" -eq 2 ]
  # And exactly one of each, so the second run did not re-append the first.
  [ "$(grep -c 'the earlier entry' "$REC")" -eq 1 ]
  [ "$(grep -c 'the later entry' "$REC")" -eq 1 ]
}

@test "step ids and markers are produced by recording-file.sh, not reimplemented by the hook" {
  start_recording "hostsess-abc"
  run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<"$(payload 'a step' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  local body
  body="$(cat "$REC")"
  # The open marker and the CLOSE marker both matter: the close marker is what gives tier 2 an
  # insertion point INSIDE a step, so an annotation stays attached to the step it is about.
  assert_contains "$body" '<!-- jenga-recorder:step id="step-001" seq="1"'
  assert_contains "$body" '<!-- jenga-recorder:step-end id="step-001" -->'
}

# -----------------------------------------------------------------------------
# Tier 1 captures VERBATIM, and filters only on deterministic grounds (§8)
# -----------------------------------------------------------------------------

@test "a multi-line prompt is captured verbatim: not reflowed, escaped or collapsed" {
  start_recording "hostsess-abc"
  local prompt
  prompt="$(printf 'line one\nline two with  two spaces\n- a bullet\n\n    indented code')"
  run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<"$(payload "$prompt" 'hostsess-abc')"
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$REC")" "$prompt"
}

@test "markdown and quoting in a prompt survive unaltered" {
  start_recording "hostsess-abc"
  local prompt='run `ls -la "my dir"` then $HOME && echo <done> 100% #1'
  run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<"$(payload "$prompt" 'hostsess-abc')"
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$REC")" "$prompt"
}

@test "an empty prompt is excluded" {
  start_recording "hostsess-abc"
  run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<"$(payload '' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  [ "$(step_count)" -eq 0 ]
}

@test "a whitespace-only prompt is excluded" {
  start_recording "hostsess-abc"
  run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<"$(payload "$(printf '   \n\t  \n')" 'hostsess-abc')"
  [ "$status" -eq 0 ]
  [ "$(step_count)" -eq 0 ]
}

@test "a prompt that is itself a recorder control command is excluded, in all four spellings" {
  start_recording "hostsess-abc"
  local cmd
  for cmd in 'j.workflow-recorder' 'j.workflow-recorder start the release' \
             'j.workflow-recorder status' '/j-workflow-recorder stop' \
             '/j.workflow-recorder' 'j-workflow-recorder start'; do
    run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
      <<<"$(payload "$cmd" 'hostsess-abc')"
    [ "$status" -eq 0 ]
  done
  [ "$(step_count)" -eq 0 ]
}

@test "a leading-whitespace control command is still excluded" {
  start_recording "hostsess-abc"
  run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<"$(payload '   j.workflow-recorder stop' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  [ "$(step_count)" -eq 0 ]
}

@test "NO SEMANTIC FILTERING: a prompt that merely mentions the skill, a question and a one-word prompt are all recorded" {
  start_recording "hostsess-abc"
  local prompt
  for prompt in 'what does j.workflow-recorder do?' 'why did that fail?' 'yes' \
                'stop' 'thanks, that works now'; do
    run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
      <<<"$(payload "$prompt" 'hostsess-abc')"
    [ "$status" -eq 0 ]
  done
  # Five prompts, five steps. The hook is forbidden from deciding any of these "does not matter" —
  # that judgment belongs to tier 2, and a hook that made it would produce invisible gaps.
  [ "$(step_count)" -eq 5 ]
}

# -----------------------------------------------------------------------------
# Rule 2: fail-open. Every one of these must exit 0 and leave the session intact.
# -----------------------------------------------------------------------------

@test "malformed stdin exits 0 and records nothing" {
  start_recording "hostsess-abc"
  run --separate-stderr env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<'this is not json at all {{{'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(step_count)" -eq 0 ]
}

@test "empty stdin exits 0 and records nothing" {
  start_recording "hostsess-abc"
  run --separate-stderr env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(step_count)" -eq 0 ]
}

@test "a JSON payload whose prompt is not a string exits 0 and records nothing" {
  start_recording "hostsess-abc"
  run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<'{"session_id":"hostsess-abc","prompt":null}'
  [ "$status" -eq 0 ]
  [ "$(step_count)" -eq 0 ]
  run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<'{"session_id":"hostsess-abc","prompt":42}'
  [ "$status" -eq 0 ]
  [ "$(step_count)" -eq 0 ]
}

@test "a pointer naming a recording that does not exist exits 0 silently" {
  bash "$RF" create "$REC" "My Process" >/dev/null
  JENGA_RECORDING_SESSION_ID="hostsess-abc" bash "$AR" set "$REC" >/dev/null
  python3 -c "import os,sys; os.remove(sys.argv[1])" "$REC"

  run --separate-stderr env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<"$(payload 'a step with nowhere to go' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$REC" ]
}

@test "a recording with no steps section exits 0 silently rather than appending to an arbitrary document" {
  printf '%s\n' '# not a recording at all' > "$REC"
  JENGA_RECORDING_SESSION_ID="hostsess-abc" bash "$AR" set "$REC" >/dev/null
  run --separate-stderr env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<"$(payload 'a step' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$REC")" = '# not a recording at all' ]
}

@test "an unwritable recording exits 0 silently" {
  start_recording "hostsess-abc"
  python3 -c "import os,sys; os.chmod(sys.argv[1], 0o444)" "$REC"
  run --separate-stderr env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" bash "$HOOK" \
    <<<"$(payload 'a step' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  python3 -c "import os,sys; os.chmod(sys.argv[1], 0o644)" "$REC"
}

@test "an expired pointer records nothing: a dead session cannot wedge a later one" {
  start_recording "hostsess-abc"
  # The pointer's TTL seam, driven rather than slept through.
  run env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" JENGA_RECORDING_NOW="2099-01-01T00:00:00Z" \
    bash "$HOOK" <<<"$(payload 'far too late' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  [ "$(step_count)" -eq 0 ]
}

# -----------------------------------------------------------------------------
# --probe (§11): diagnosable, and still never on stdout
# -----------------------------------------------------------------------------

@test "--probe reports the payload fields and the key it used, on stderr, with stdout still empty" {
  start_recording "hostsess-abc"
  run --separate-stderr env -u CLAUDE_CODE_SESSION_ID -u JENGA_SESSION_ID -u JENGA_RECORDING_SESSION_ID \
    JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" --probe <<<"$(payload 'a probed step' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # §11's two load-bearing fields, and which candidate won.
  assert_contains "$stderr" "prompt field present"
  assert_contains "$stderr" "session_id field present"
  assert_contains "$stderr" "payload:.session_id"
  assert_contains "$stderr" "appended one step"
  [ "$(step_count)" -eq 1 ]
}

@test "--probe names the session-key disagreement explicitly when no candidate finds a recording" {
  # The whole point of the probe: turn the design's one SILENT failure into a diagnosable one.
  start_recording "someone-elses-session"
  run --separate-stderr env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" --probe <<<"$(payload 'a step' 'my-own-session')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_contains "$stderr" "NO ACTIVE RECORDING"
  assert_contains "$stderr" "session-key disagreement"
}

@test "JENGA_RECORDING_HOOK_DEBUG turns the probe on without changing the registration" {
  start_recording "hostsess-abc"
  run --separate-stderr env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    JENGA_RECORDING_HOOK_DEBUG=1 bash "$HOOK" <<<"$(payload 'a step' 'hostsess-abc')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_contains "$stderr" "appended one step"
}

@test "the probe's fast reject explains itself when nothing is recording" {
  run --separate-stderr env JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" --probe <<<"$(payload 'a step')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_contains "$stderr" "fast reject"
}
