#!/usr/bin/env bats
# bats file_tags=tier:integration
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

# Number of steps in $1 (default $REC). Distinguishes "zero steps" (prints 0) from "the helper failed"
# (prints a non-numeric token), so every `[ "$(step_count)" -eq N ]` assertion FAILS if recording-file.sh
# steps breaks, instead of all the `-eq 0` ones going vacuously green together.
step_count() {
  local f="${1:-$REC}" out rc
  out="$(bash "$RF" steps "$f" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'steps-helper-failed-exit-%s' "$rc"
    return 0
  fi
  if [ -z "$out" ]; then echo 0; else printf '%s\n' "$out" | grep -c .; fi
}

# A second recording at $1 with a pointer under session key $2: for tests where two live recordings
# must be told apart.
start_recording_at() {
  bash "$RF" create "$1" "Other Process" >/dev/null
  JENGA_RECORDING_SESSION_ID="$2" bash "$AR" set "$1" --title "Other Process" >/dev/null
}

# A throwaway project root whose registry is a copy of the real one, so the hook and the pointer script
# resolve the queue through resolve-root.sh with no state-dir seam. Prints the root.
make_project_root() {
  mkdir -p "$T/proj/project/configs"
  cp "$REPO_ROOT/project/configs/workflow.json" "$T/proj/project/configs/workflow.json"
  printf '%s' "$T/proj"
}

# A PATH made of counting shims: every executable name found on the real PATH is a symlink to one shim
# that appends its name to $SHIM_LOG and then execs the real command with the real PATH restored (so only
# the hook's DIRECT external commands are counted, not what its callees spawn). Prints the shim dir.
make_counting_path() {
  local d="$T/shims"
  mkdir -p "$d"
  cat > "$d/.shim" <<'SHIM'
#!/bin/bash
n="${0##*/}"
printf '%s\n' "$n" >> "$SHIM_LOG"
IFS=: read -r -a _dirs <<<"$SHIM_ORIG_PATH"
for _d in "${_dirs[@]}"; do
  if [ -x "$_d/$n" ] && [ ! -d "$_d/$n" ]; then
    export PATH="$SHIM_ORIG_PATH"
    exec "$_d/$n" "$@"
  fi
done
exit 127
SHIM
  chmod +x "$d/.shim"
  python3 - "$d" "$PATH" <<'PYEOF'
import os, sys
d, path = sys.argv[1], sys.argv[2]
seen = set()
for p in path.split(":"):
    if not p or not os.path.isdir(p):
        continue
    for n in os.listdir(p):
        fp = os.path.join(p, n)
        if n in seen or n.startswith(".") or not os.access(fp, os.X_OK) or os.path.isdir(fp):
            continue
        seen.add(n)
        try:
            os.symlink(".shim", os.path.join(d, n))
        except OSError:
            pass
PYEOF
  printf '%s' "$d"
}

# Minimum wall-clock ms over $1 runs of the remaining command (stdin from $PAYLOAD_FOR_TIMING if set).
# Minimum rather than mean: the floor of the distribution is what the header's figures are claims about,
# and it is the statistic least moved by a busy machine.
min_ms() {
  local n="$1"; shift
  python3 - "$n" "$@" <<'PYEOF'
import subprocess, sys, time, os
n = int(sys.argv[1]); cmd = sys.argv[2:]
inp = os.environ.get("PAYLOAD_FOR_TIMING", "").encode()
best = None
for _ in range(n):
    t = time.perf_counter()
    subprocess.run(cmd, input=inp, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ms = (time.perf_counter() - t) * 1000
    best = ms if best is None or ms < best else best
print("%.1f" % best)
PYEOF
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
  # grep: 1 = no match (what is wanted); 2 = it could not read the file, which must not pass.
  [ "$status" -eq 1 ]
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

@test "the header's MEASURED no-op figures agree with a live measurement, not merely exist" {
  # The previous version of this test asserted only that the strings `bare-bash floor` and `ms/call`
  # appeared, which a header full of invented numbers satisfies. This one parses the figures out of the
  # header's MEASURED RESULT block and holds them against a live run, with tolerances wide enough to
  # survive a busy machine (minimum over several runs, ratio and order rather than exact ms) and tight
  # enough to fail a header whose figures are fiction.
  local block h_floor h_hook h_get
  block="$(sed -n '1,/^set -u$/p' "$HOOK" | sed -n '/^# MEASURED RESULT/,$p')"
  h_floor="$(printf '%s\n' "$block" | sed -n 's/^#  *bare-bash floor [. ]*\([0-9.]*\) ms\/call.*/\1/p' | head -n1)"
  h_hook="$(printf '%s\n' "$block" | sed -n 's/^#  *on_recording_step.sh, no recording [. ]*\([0-9.]*\) ms\/call.*/\1/p' | head -n1)"
  h_get="$(printf '%s\n' "$block" | sed -n 's/^#  *active-recording.sh get (what it avoids) [. ]*\([0-9.]*\) ms\/call.*/\1/p' | head -n1)"
  [ -n "$h_floor" ] && [ -n "$h_hook" ] && [ -n "$h_get" ]

  local root l_floor l_hook l_get
  root="$(make_project_root)"
  export JENGA_PROJECT_ROOT="$root"
  unset JENGA_RECORDING_STATE_DIR
  export PAYLOAD_FOR_TIMING='{"prompt":"x","session_id":"timing-key"}'
  l_floor="$(min_ms 8 bash -c :)"
  l_hook="$(min_ms 8 bash "$HOOK")"
  l_get="$(min_ms 8 bash "$AR" get --session timing-key)"

  python3 - "$h_floor" "$h_hook" "$h_get" "$l_floor" "$l_hook" "$l_get" <<'PYEOF'
import sys
hf, hh, hg, lf, lh, lg = map(float, sys.argv[1:])
def fail(m):
    sys.stderr.write("header figures disagree with live measurement: %s\n" % m)
    sys.stderr.write("  header: floor=%s hook=%s get=%s  live(min): floor=%s hook=%s get=%s\n" % (hf, hh, hg, lf, lh, lg))
    sys.exit(1)
# The header's own ordering claim: floor < the hook's no-op path < asking `get` every prompt.
if not (hf < hh < hg):
    fail("the header's own figures are not ordered floor < hook < get")
# The live run must show the same ordering, or the 'saves ~86 ms per prompt' claim is false today.
if not (lf < lh < lg):
    fail("live ordering is not floor < hook < get")
# The headline claim is a RATIO (about 3.7x cheaper than asking get); allow a factor of 4 either way.
hr, lr = hg / hh, lg / lh
if not (lr / 4 <= hr <= lr * 4):
    fail("header says get/hook = %.1fx, live says %.1fx" % (hr, lr))
# And the absolute figures must be the right order of magnitude (factor 6, either way).
for name, h, l in (("hook", hh, lh), ("get", hg, lg)):
    if not (l / 6 <= h <= l * 6):
        fail("%s figure %.1f ms is more than 6x away from live %.1f ms" % (name, h, l))
PYEOF
}

@test "--help prints usage on STDERR and nothing on stdout, and exits 0" {
  # Rule 1 admits no exception, not even for usage: stdout belongs to the model's context.
  run --separate-stderr bash "$HOOK" --help
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_contains "$stderr" "on_recording_step.sh"
  # The full header, not a prefix of it: the last two sections must print.
  assert_contains "$stderr" "ENVIRONMENT"
  assert_contains "$stderr" "EXIT CODES"
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
# Session-key candidate ORDER and EXCLUSION, pinned by behaviour (E89_S06_T01)
#
# The header states two rules - the environment candidate is tried before the payload one, and
# JENGA_SESSION_ID is never a candidate - and until these tests the second was asserted only by grepping
# the header comment. A comment cannot fail when the code stops obeying it. Each test below has two LIVE
# recordings under different keys, so a wrong resolution lands the step in the wrong file and is visible.
# -----------------------------------------------------------------------------

@test "ORDER: when the environment key and the payload key both name live recordings, the environment's wins" {
  start_recording "env-sess"
  local other="$T/payload-side_RECORDING.md"
  start_recording_at "$other" "payload-sess"

  run --separate-stderr env CLAUDE_CODE_SESSION_ID="env-sess" \
    JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" <<<"$(payload 'goes to the environment recording' 'payload-sess')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(step_count "$REC")" -eq 1 ]
  [ "$(step_count "$other")" -eq 0 ]
  assert_contains "$(cat "$REC")" "goes to the environment recording"
}

@test "the environment candidate resolves ON ITS OWN: a payload key with no pointer is not needed" {
  start_recording "env-sess"
  run --separate-stderr env CLAUDE_CODE_SESSION_ID="env-sess" \
    JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" <<<"$(payload 'environment only' 'a-payload-key-with-no-pointer')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(step_count)" -eq 1 ]
  assert_contains "$(cat "$REC")" "environment only"
}

@test "ORDER within the environment: JENGA_RECORDING_SESSION_ID outranks CLAUDE_CODE_SESSION_ID" {
  start_recording "recording-var-sess"
  local other="$T/claude-var_RECORDING.md"
  start_recording_at "$other" "claude-var-sess"

  run env JENGA_RECORDING_SESSION_ID="recording-var-sess" CLAUDE_CODE_SESSION_ID="claude-var-sess" \
    JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" <<<"$(payload 'ranked' 'an-unrelated-payload-key')"
  [ "$status" -eq 0 ]
  [ "$(step_count "$REC")" -eq 1 ]
  [ "$(step_count "$other")" -eq 0 ]
}

@test "JENGA_SESSION_ID is never a candidate: a live pointer under it is not found when the payload names nothing" {
  # By behaviour, not by grepping the header. Its value is a fresh per-process uuid in a real session
  # (see the hook's header), so a hook that honoured it would pass this suite only by accident.
  start_recording "per-process-uuid"
  run --separate-stderr env JENGA_SESSION_ID="per-process-uuid" \
    JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" <<<'{"hook_event_name":"UserPromptSubmit","prompt":"must not be recorded"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(step_count)" -eq 0 ]
}

@test "JENGA_SESSION_ID cannot outrank or displace the payload key" {
  start_recording "per-process-uuid"
  local other="$T/payload-wins_RECORDING.md"
  start_recording_at "$other" "payload-sess"

  run env JENGA_SESSION_ID="per-process-uuid" \
    JENGA_RECORDING_STATE_DIR="$JENGA_RECORDING_STATE_DIR" \
    bash "$HOOK" <<<"$(payload 'belongs to the payload session' 'payload-sess')"
  [ "$status" -eq 0 ]
  [ "$(step_count "$other")" -eq 1 ]
  [ "$(step_count "$REC")" -eq 0 ]
}

@test "step_count reports a helper failure as a non-number, so the -eq 0 assertions cannot go vacuous" {
  run step_count "$T/no-such-recording.md"
  [ "$status" -eq 0 ]
  case "$output" in
    ''|*[!0-9]*) : ;;
    *) false ;;
  esac
  [[ "$output" == steps-helper-failed-exit-* ]]
  # And a real, empty recording is a clean 0.
  bash "$RF" create "$REC" "My Process" >/dev/null
  [ "$(step_count)" = "0" ]
}

# -----------------------------------------------------------------------------
# The REAL-SESSION path: no state-dir seam, the queue resolved through resolve-root.sh (E89_S06_T01)
#
# Every other behavioural test sets JENGA_RECORDING_STATE_DIR, which bypasses the hook's own
# `state_dir="$queue/$STATE_SUBDIR"` join entirely - so that line could be pointed anywhere and the
# suite would stay green. This is the one test where it executes and its result matters.
# -----------------------------------------------------------------------------

@test "REAL SESSION: with no state-dir seam, the hook joins the resolved queue root to the pointer directory the pointer script used" {
  local root
  root="$(make_project_root)"
  unset JENGA_RECORDING_STATE_DIR
  bash "$RF" create "$REC" "My Process" >/dev/null
  JENGA_PROJECT_ROOT="$root" JENGA_RECORDING_SESSION_ID="real-sess" bash "$AR" set "$REC" >/dev/null

  # The pointer really is where resolve-root.sh says the queue is, under the shared subdirectory.
  local queue
  queue="$(JENGA_PROJECT_ROOT="$root" bash "$REPO_ROOT/scripts/resolve-root.sh" get queue)"
  [ -n "$queue" ]
  compgen -G "$queue/active-recordings/recording-*.json" >/dev/null

  run --separate-stderr env -u JENGA_RECORDING_STATE_DIR JENGA_PROJECT_ROOT="$root" \
    bash "$HOOK" <<<"$(payload 'recorded through the real join' 'real-sess')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(step_count)" -eq 1 ]
  assert_contains "$(cat "$REC")" "recorded through the real join"
}

# -----------------------------------------------------------------------------
# The no-op path's cost, asserted as a COUNT of external commands rather than described (E89_S06_T01)
#
# Wall-clock is too noisy to assert in CI, but the property the header claims - "stage 1a forks
# nothing, stage 1b one subprocess" - is a count. It is measured by running the hook with a PATH made of
# counting shims (see make_counting_path), so any external command the hook execs by name is logged.
# -----------------------------------------------------------------------------

@test "the counting PATH really counts: a control command is logged (so a zero below means zero)" {
  local shims log="$T/shim.log" real_bash
  shims="$(make_counting_path)"
  real_bash="$(command -v bash)"
  run env PATH="$shims" SHIM_LOG="$log" SHIM_ORIG_PATH="$PATH" "$real_bash" -c 'date >/dev/null; dirname /a/b >/dev/null'
  [ "$status" -eq 0 ]
  [ "$(sort "$log" | tr '\n' ' ')" = "date dirname " ]
}

@test "the no-recording path with the state-dir seam (stage 1a) execs NO external command" {
  local shims log="$T/shim.log" real_bash
  shims="$(make_counting_path)"
  real_bash="$(command -v bash)"
  mkdir -p "$JENGA_RECORDING_STATE_DIR"
  : > "$log"
  run --separate-stderr env PATH="$shims" SHIM_LOG="$log" SHIM_ORIG_PATH="$PATH" \
    "$real_bash" "$HOOK" <<<"$(payload 'hello there')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  # Not "few": none. The names are listed in the failure message by the assert below.
  [ ! -s "$log" ] || { echo "unexpected external commands on the no-op path: $(tr '\n' ' ' < "$log")" >&2; false; }
}

@test "the no-recording path through the real resolver (stage 1b) execs exactly ONE external command: the resolver" {
  local shims log="$T/shim.log" real_bash root
  shims="$(make_counting_path)"
  real_bash="$(command -v bash)"
  root="$(make_project_root)"
  : > "$log"
  run --separate-stderr env -u JENGA_RECORDING_STATE_DIR PATH="$shims" SHIM_LOG="$log" \
    SHIM_ORIG_PATH="$PATH" JENGA_PROJECT_ROOT="$root" \
    "$real_bash" "$HOOK" <<<"$(payload 'hello there')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] || { echo "expected exactly one, got: $(tr '\n' ' ' < "$log")" >&2; false; }
  [ "$(cat "$log")" = "bash" ]
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

# -----------------------------------------------------------------------------
# E89_S06_T11: the UserPromptSubmit registration carries a timeout, identically everywhere it can be copied from.
# Decision and reasoning: project/documentation/workflow-recorder-observation-decision.md, "Hook timeout".
# -----------------------------------------------------------------------------

@test "registration: the UserPromptSubmit block carries timeout 10 in root settings.json and in the recorder fragment, and no template carries hooks" {
  root_block="$(jq -c '.hooks.UserPromptSubmit' "$REPO_ROOT/settings.json")"
  [ "$(jq -r '.[0].hooks[0].timeout' <<<"$root_block")" = "10" ]
  [ "$(jq -r '.[0].matcher' <<<"$root_block")" = "" ]

  # E100_S04_T05: the fragment is the other source a consumer's registration is built from.
  frag="$REPO_ROOT/skills/j-workflow-recorder/settings-fragment.json"
  [ "$(jq -S -c '.hooks.UserPromptSubmit' "$frag")" = "$(jq -S -c . <<<"$root_block")" ] || { echo "UserPromptSubmit block differs in $frag" >&2; return 1; }

  templates=0
  for f in "$REPO_ROOT"/templates/permission-levels/level-*.json; do
    templates=$((templates + 1))
    [ "$(jq 'has("hooks")' "$f")" = "false" ] || { echo "$f carries hooks" >&2; return 1; }
  done
  [ "$templates" -eq 5 ]
}
